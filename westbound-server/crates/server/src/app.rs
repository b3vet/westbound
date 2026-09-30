//! Shared state, router and the server lifecycle (bind → run → graceful shutdown).
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Architecture" (one binary: HTTP API +
//! WebSocket gateway), "Resource budget and deployment" (restarts).

use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::Context;
use axum::extract::{DefaultBodyLimit, Request, State};
use axum::http::{HeaderValue, Method};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, MethodRouter};
use axum::Router;
use sqlx::SqlitePool;
use tokio::net::TcpListener;
use tokio::sync::Notify;
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;
use tower_http::compression::CompressionLayer;
use tower_http::cors::{AllowOrigin, CorsLayer};
use tower_http::trace::{DefaultOnFailure, TraceLayer};

use crate::auth::{self, AuthKeys};
use crate::clock::{Clock, SystemClock};
use crate::config::Config;
use crate::error::ApiError;
use crate::gateway::GatewayPolicy;
use crate::http::{self, DeepLinks};
use crate::leaderboards::Leaderboards;
use crate::map::ServerMap;
use crate::metrics::Metrics;
use crate::presence::PresenceHub;
use crate::ratelimit::{RateLimiters, CLEANUP_INTERVAL};
use crate::rooms::Rooms;
use crate::sessions::Sessions;
use crate::tick::{MonotonicTickClock, TickClock};
use crate::{accounts, leaderboards, profile, runs, ws};

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
    /// Wall clock for tokens, bans and renames (a `ManualClock` in tests).
    pub clock: Arc<dyn Clock>,
    /// JWT keys, device-secret pepper, token lifetimes.
    pub auth: Arc<AuthKeys>,
    pub rate_limiters: RateLimiters,
    /// What `/ws` accepts (versions, map hashes) and announces in `Welcome`.
    pub gateway: Arc<GatewayPolicy>,
    /// Live sessions: account id → connection handle (the lobby's and rooms' way in).
    pub sessions: Arc<Sessions>,
    /// Tick clock for `Pong` (server-wide 20 Hz since start; N5 adds room clocks).
    pub tick_clock: Arc<dyn TickClock>,
    /// Leaderboards with their top-N cache (N7.1). N6 records multiplayer runs through
    /// `boards.record_multiplayer_run`, N8 replay verdicts through
    /// `boards.set_run_verification`.
    pub boards: Arc<Leaderboards>,
    /// Friends presence over the session registry (N9.1): subscriptions, pushes, and the
    /// N5 room seam (`presence.set_room`).
    pub presence: Arc<PresenceHub>,
    /// The loop map (N3.2: `loop_v1`, compiled in, validated and hashed at startup) for
    /// the room code (N4+). Its hash is accepted by the gateway unless
    /// `gateway.map_hashes` overrides it.
    pub map: Arc<ServerMap>,
    /// Woken by each replay upload: the verification worker looks for work (N8.1).
    pub replay_jobs: Arc<Notify>,
    /// The rooms registry (N5.1): room tasks, codes, seats, Quick Join, the browser.
    pub rooms: Arc<Rooms>,
}

impl AppState {
    pub fn new(config: Config, db: SqlitePool) -> anyhow::Result<Self> {
        Self::with_clock(config, db, Arc::new(SystemClock))
    }

    pub fn with_clock(
        config: Config,
        db: SqlitePool,
        clock: Arc<dyn Clock>,
    ) -> anyhow::Result<Self> {
        let tick_clock = Arc::new(MonotonicTickClock::new(u32::from(
            config.gateway.tick_rate_hz,
        )));
        Self::with_clocks(config, db, clock, tick_clock)
    }

    /// With both clocks injected (tests).
    pub fn with_clocks(
        config: Config,
        db: SqlitePool,
        clock: Arc<dyn Clock>,
        tick_clock: Arc<dyn TickClock>,
    ) -> anyhow::Result<Self> {
        let deeplinks = DeepLinks::load(&config.deeplinks)?;
        if config.is_dev()
            && (config.auth.jwt_secret.is_empty() || config.auth.device_secret_pepper.is_empty())
        {
            tracing::warn!("server.env = dev: using the public development auth secrets");
        }
        let auth = Arc::new(AuthKeys::from_config(&config));
        let metrics = Arc::new(Metrics::default());
        let rate_limiters = RateLimiters::new(&config, auth.clone(), metrics.clone());
        let map = crate::map::builtin().context("the built-in loop map")?;
        let gateway = crate::gateway::policy(&config, &map);
        let sessions = Arc::new(Sessions::new(metrics.clone()));
        let presence = Arc::new(PresenceHub::new(sessions.clone()));
        let shutdown = CancellationToken::new();
        let rooms = Arc::new(Rooms::new(
            &config,
            map.clone(),
            presence.clone(),
            shutdown.clone(),
        )?);
        let boards = Arc::new(Leaderboards::new(
            db.clone(),
            config.leaderboards.clone(),
            clock.clone(),
        ));
        Ok(Self {
            config: Arc::new(config),
            db,
            metrics,
            shutdown,
            tasks: TaskTracker::new(),
            deeplinks: Arc::new(deeplinks),
            clock,
            auth,
            rate_limiters,
            gateway,
            sessions,
            tick_clock,
            boards,
            presence,
            map,
            replay_jobs: Arc::new(Notify::new()),
            rooms,
        })
    }

    /// The replay verification worker over this state (N8.1).
    pub fn replay_worker(&self) -> crate::replays::worker::Worker {
        crate::replays::worker::Worker {
            db: self.db.clone(),
            boards: self.boards.clone(),
            cfg: self.config.replays.clone(),
            clock: self.clock.clone(),
            wake: self.replay_jobs.clone(),
        }
    }
}

/// `/api/v1/auth/*` and the authenticated account routes, each class behind its
/// rate limiter, with the JSON body limit.
fn accounts_router(state: &AppState) -> Router<AppState> {
    let rl = &state.rate_limiters;
    let device_create =
        Router::new().route("/api/v1/auth/device", post(auth::routes::device_create));
    let auth_routes = Router::new()
        .route(
            "/api/v1/auth/device/login",
            post(auth::routes::device_login),
        )
        .route("/api/v1/auth/refresh", post(auth::routes::refresh))
        .route("/api/v1/auth/logout", post(auth::routes::logout))
        .route(
            "/api/v1/auth/link/apple",
            post(auth::routes::apple_not_enabled),
        )
        .route(
            "/api/v1/auth/signin/apple",
            post(auth::routes::apple_not_enabled),
        )
        .route(
            "/api/v1/auth/link/google",
            post(auth::routes::google_not_enabled),
        )
        .route(
            "/api/v1/auth/signin/google",
            post(auth::routes::google_not_enabled),
        );
    let account_routes = Router::new()
        .route("/api/v1/me", get(profile::get_me).patch(profile::patch_me))
        .route(
            "/api/v1/account",
            axum::routing::delete(profile::delete_account),
        );
    // N7.1: boards read under the account limit; run submissions also under their own.
    let board_routes = Router::new().route(
        "/api/v1/boards/{board}",
        get(leaderboards::routes::get_board),
    );
    let run_routes = Router::new()
        .route("/api/v1/runs", post(runs::routes::submit))
        .route("/api/v1/runs/legacy", post(runs::routes::legacy))
        // N8.1: the replay upload, with its own (larger) body limit.
        .route(
            "/api/v1/runs/{run_id}/replay",
            post(crate::replays::routes::upload).layer(DefaultBodyLimit::max(
                usize::try_from(state.config.replays.max_bytes).unwrap_or(usize::MAX),
            )),
        );
    let social_routes = social_router(state);
    let (device_create, auth_routes, account_routes, board_routes, run_routes) = if rl.enabled {
        (
            device_create.layer(rl.layer(&rl.device_create)),
            auth_routes.layer(rl.layer(&rl.auth)),
            account_routes.layer(rl.layer(&rl.account)),
            board_routes.layer(rl.layer(&rl.account)),
            run_routes
                .layer(rl.layer(&rl.runs))
                .layer(rl.layer(&rl.account)),
        )
    } else {
        (
            device_create,
            auth_routes,
            account_routes,
            board_routes,
            run_routes,
        )
    };
    Router::new()
        .merge(device_create)
        .merge(auth_routes)
        .merge(account_routes)
        .merge(board_routes)
        .merge(run_routes)
        .merge(social_routes)
        .layer(DefaultBodyLimit::max(state.config.http.max_body_bytes))
}

/// N9.1: friends, blocks, presence, crews, reports. Every route is under the account
/// limit; the writes that create something (friend requests, blocks, crew create / join,
/// reports) also under the social limit.
fn social_router(state: &AppState) -> Router<AppState> {
    use crate::social::{crews, friends, reports};
    let rl = &state.rate_limiters;
    let social = |m: MethodRouter<AppState>| {
        if rl.enabled {
            m.layer(rl.layer(&rl.social))
        } else {
            m
        }
    };
    let r = Router::new()
        .route("/api/v1/friends", get(friends::get_friends))
        .route(
            "/api/v1/friends/requests",
            social(post(friends::post_request)),
        )
        .route(
            "/api/v1/friends/requests/{id}/accept",
            post(friends::post_accept),
        )
        .route(
            "/api/v1/friends/requests/{id}/decline",
            post(friends::post_decline),
        )
        .route(
            "/api/v1/friends/{account_id}",
            axum::routing::delete(friends::delete_friend),
        )
        .route("/api/v1/presence", get(friends::get_presence))
        .route(
            "/api/v1/blocks",
            social(post(friends::post_block)).get(friends::get_blocks),
        )
        .route(
            "/api/v1/blocks/{account_id}",
            axum::routing::delete(friends::delete_block),
        )
        .route("/api/v1/crews", social(post(crews::post_crew)))
        .route("/api/v1/crews/mine", get(crews::get_mine))
        .route("/api/v1/crews/join", social(post(crews::post_join)))
        .route(
            "/api/v1/crews/{id}",
            get(crews::get_crew).delete(crews::delete_crew),
        )
        .route("/api/v1/crews/{id}/leave", post(crews::post_leave))
        .route("/api/v1/crews/{id}/kick", post(crews::post_kick))
        .route("/api/v1/crews/{id}/promote", post(crews::post_promote))
        .route("/api/v1/crews/{id}/demote", post(crews::post_demote))
        .route("/api/v1/crews/{id}/transfer", post(crews::post_transfer))
        .route(
            "/api/v1/crews/{id}/invite-code",
            post(crews::post_invite_code),
        )
        .route("/api/v1/reports", social(post(reports::post_report)));
    if rl.enabled {
        r.layer(rl.layer(&rl.account))
    } else {
        r
    }
}

/// The public router: `/api/v1/*`, `/ws`, `/.well-known/*`.
pub fn router(state: AppState) -> Router {
    let api = Router::new()
        .route("/api/v1/health", get(http::health))
        .route("/api/v1/echo-check", get(http::echo_check))
        .merge(accounts_router(&state))
        .method_not_allowed_fallback(method_not_allowed)
        .layer(cors_layer(&state.config))
        .layer(CompressionLayer::new());
    Router::new()
        .merge(api)
        .route("/ws", get(ws::upgrade))
        .route("/ws/echo", get(ws::upgrade_echo))
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
            TraceLayer::new_for_http()
                .make_span_with(|req: &Request| {
                    tracing::info_span!("http", method = %req.method(), path = %req.uri().path())
                })
                // 5xx at WARN: the provider stubs answer 501 by design, and real
                // internal errors are already logged at ERROR where they happen.
                .on_failure(DefaultOnFailure::new().level(tracing::Level::WARN)),
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
        // 429s carry it; the web build reads it cross-origin.
        .expose_headers([axum::http::header::RETRY_AFTER])
}

async fn method_not_allowed() -> Response {
    ApiError::method_not_allowed().into_response()
}

/// Hourly: drop expired refresh tokens. Every `CLEANUP_INTERVAL`: drop idle
/// rate-limit buckets. Stops at shutdown.
async fn maintenance(state: AppState) {
    let mut tick = tokio::time::interval(CLEANUP_INTERVAL);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut n: u64 = 0;
    let prune_every = PRUNE_EVERY_SECS / CLEANUP_INTERVAL.as_secs();
    loop {
        tokio::select! {
            _ = state.shutdown.cancelled() => return,
            _ = tick.tick() => {}
        }
        state.rate_limiters.cleanup();
        if n.is_multiple_of(prune_every) {
            match accounts::prune_refresh_tokens(&state.db, state.clock.now()).await {
                Ok(0) => {}
                Ok(pruned) => tracing::debug!(pruned, "expired refresh tokens pruned"),
                Err(e) => tracing::warn!(error = %e, "pruning refresh tokens failed"),
            }
        }
        n += 1;
    }
}

/// How often expired refresh tokens are deleted.
const PRUNE_EVERY_SECS: u64 = 3_600;

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
        Self::bind_state(AppState::new(config, db)?).await
    }

    /// Binds a server around a prepared state (tests inject clocks this way).
    pub async fn bind_state(state: AppState) -> anyhow::Result<Self> {
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

        let maintenance_task = tokio::spawn(maintenance(state.clone()));
        let ban_sweep_task = tokio::spawn(crate::gateway::ban_sweep(state.clone()));
        // N8.1: replay verification (one job at a time) and retention.
        let replays = &state.config.replays;
        let worker = state.replay_worker();
        let worker_task = if replays.worker_enabled && worker.configured() {
            Some(tokio::spawn(worker.run(cancel.clone())))
        } else {
            if replays.verifier_command.is_empty() {
                tracing::info!(
                    "no replay verifier configured (replays.verifier_command): replays wait in pending, runs stay verifying"
                );
            } else {
                tracing::info!("replay worker disabled here (replays.worker_enabled = false): a verify-worker runs the queue");
            }
            None
        };
        let retention_task = tokio::spawn(crate::replays::retention::periodic(
            state.db.clone(),
            replays.clone(),
            state.clock.clone(),
            cancel.clone(),
        ));
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
        maintenance_task.abort();
        ban_sweep_task.abort();
        retention_task.abort();
        if let Some(t) = worker_task {
            t.abort();
        }
        tracing::info!("server stopped");
        Ok(())
    }
}
