//! Shared state, router and the server lifecycle (bind → run → graceful shutdown).
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Architecture" (one binary: HTTP API +
//! WebSocket gateway), "Resource budget and deployment" (restarts).

use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::Context;
use axum::extract::{Request, State};
use axum::http::{HeaderValue, Method};
use axum::middleware::{self, Next};
use axum::response::Response;
use axum::routing::get;
use axum::Router;
use sqlx::SqlitePool;
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;
use tower_http::compression::CompressionLayer;
use tower_http::cors::{AllowOrigin, CorsLayer};
use tower_http::trace::TraceLayer;

use crate::config::Config;
use crate::http::{self, DeepLinks};
use crate::metrics::Metrics;
use crate::ws;

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<Config>,
    pub db: SqlitePool,
    pub metrics: Arc<Metrics>,
    /// Cancelled when the server begins shutting down (after the pre-shutdown hook).
    pub shutdown: CancellationToken,
    /// Every WebSocket connection task, awaited on shutdown.
    pub tasks: TaskTracker,
    pub deeplinks: Arc<DeepLinks>,
}

impl AppState {
    pub fn new(config: Config, db: SqlitePool) -> anyhow::Result<Self> {
        let deeplinks = DeepLinks::load(&config.deeplinks)?;
        Ok(Self {
            config: Arc::new(config),
            db,
            metrics: Arc::new(Metrics::default()),
            shutdown: CancellationToken::new(),
            tasks: TaskTracker::new(),
            deeplinks: Arc::new(deeplinks),
        })
    }
}

/// The public router: `/api/v1/*`, `/ws`, `/.well-known/*`.
pub fn router(state: AppState) -> Router {
    let api = Router::new()
        .route("/api/v1/health", get(http::health))
        .route("/api/v1/echo-check", get(http::echo_check))
        .layer(cors_layer(&state.config))
        .layer(CompressionLayer::new());
    Router::new()
        .merge(api)
        .route("/ws", get(ws::upgrade))
        .route(
            "/.well-known/apple-app-site-association",
            get(http::apple_app_site_association),
        )
        .route("/.well-known/assetlinks.json", get(http::assetlinks))
        .fallback(http::not_found)
        .layer(middleware::from_fn_with_state(state.clone(), count_requests))
        .layer(
            // Spans carry method + path only: query strings and headers can hold
            // tokens, and tokens are never logged.
            TraceLayer::new_for_http().make_span_with(|req: &Request| {
                tracing::info_span!("http", method = %req.method(), path = %req.uri().path())
            }),
        )
        .with_state(state)
}

fn cors_layer(cfg: &Config) -> CorsLayer {
    let origins = &cfg.http.cors_allowed_origins;
    let allow = if origins.iter().any(|o| o == "*") {
        AllowOrigin::any()
    } else {
        AllowOrigin::list(
            origins
                .iter()
                .filter_map(|o| HeaderValue::from_str(o).ok())
                .collect::<Vec<_>>(),
        )
    };
    CorsLayer::new()
        .allow_origin(allow)
        .allow_methods([
            Method::GET,
            Method::POST,
            Method::PATCH,
            Method::DELETE,
            Method::OPTIONS,
        ])
        .allow_headers([
            axum::http::header::AUTHORIZATION,
            axum::http::header::CONTENT_TYPE,
        ])
}

async fn count_requests(State(state): State<AppState>, req: Request, next: Next) -> Response {
    let resp = next.run(req).await;
    state.metrics.count_http(resp.status());
    resp
}

fn metrics_router(state: AppState) -> Router {
    Router::new()
        .route("/metrics", get(http::metrics))
        .with_state(state)
}

/// A bound, not yet running server. Binding first lets tests use port 0.
pub struct Server {
    listener: TcpListener,
    metrics_listener: Option<TcpListener>,
    state: AppState,
}

impl Server {
    pub async fn bind(config: Config, db: SqlitePool) -> anyhow::Result<Self> {
        let state = AppState::new(config, db)?;
        let bind = state.config.bind_addr();
        let listener = TcpListener::bind(bind)
            .await
            .with_context(|| format!("binding {bind}"))?;
        let metrics_listener = match state.config.metrics_addr() {
            Some(addr) => Some(
                TcpListener::bind(addr)
                    .await
                    .with_context(|| format!("binding metrics {addr}"))?,
            ),
            None => None,
        };
        Ok(Self {
            listener,
            metrics_listener,
            state,
        })
    }

    pub fn local_addr(&self) -> SocketAddr {
        self.listener.local_addr().expect("bound listener")
    }

    pub fn metrics_addr(&self) -> Option<SocketAddr> {
        self.metrics_listener
            .as_ref()
            .map(|l| l.local_addr().expect("bound listener"))
    }

    pub fn state(&self) -> &AppState {
        &self.state
    }

    /// Serves until `state.shutdown` is cancelled, then: stops accepting, lets
    /// in-flight requests finish, closes every WebSocket with a close frame, all
    /// within `server.shutdown_grace_ms`. The caller closes the database after.
    pub async fn run(self) -> anyhow::Result<()> {
        let Server {
            listener,
            metrics_listener,
            state,
        } = self;
        let cancel = state.shutdown.clone();
        let grace = state.config.shutdown_grace();
        tracing::info!(
            addr = %listener.local_addr()?,
            public_origin = %state.config.server.public_origin,
            version = crate::VERSION,
            build = crate::BUILD,
            "listening"
        );

        let metrics_task = metrics_listener.map(|l| {
            let app = metrics_router(state.clone());
            let cancel = cancel.clone();
            tracing::info!(addr = %l.local_addr().map(|a| a.to_string()).unwrap_or_default(), "metrics listening");
            tokio::spawn(async move {
                let _ = axum::serve(l, app)
                    .with_graceful_shutdown(cancel.cancelled_owned())
                    .await;
            })
        });

        let serve = axum::serve(
            listener,
            router(state.clone()).into_make_service_with_connect_info::<SocketAddr>(),
        )
        .with_graceful_shutdown(cancel.clone().cancelled_owned());
        let deadline = async {
            cancel.cancelled().await;
            tokio::time::sleep(grace).await;
        };
        tokio::select! {
            r = serve => r.context("http server")?,
            _ = deadline => tracing::warn!("http requests still running at the shutdown deadline"),
        }

        // WebSocket tasks saw the same token and are sending their close frames.
        state.tasks.close();
        if tokio::time::timeout(grace, state.tasks.wait())
            .await
            .is_err()
        {
            tracing::warn!(
                remaining = state.tasks.len(),
                "websocket tasks still open at the shutdown deadline"
            );
        }
        if let Some(t) = metrics_task {
            t.abort();
        }
        tracing::info!("server stopped");
        Ok(())
    }
}
