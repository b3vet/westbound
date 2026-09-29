//! HTTP handlers: health, deep-link files, metrics text, 404.
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Deployment" (deep-link files);
//! docs/MULTIPLAYER_PLAN.md MP-D1 (the server serves the deep-link files itself).

use anyhow::Context;
use axum::extract::State;
use axum::http::{header, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Serialize;

use crate::app::AppState;
use crate::config::DeepLinksConfig;

pub const AASA_FILE: &str = "apple-app-site-association";
pub const ASSETLINKS_FILE: &str = "assetlinks.json";
const AASA_PLACEHOLDER: &str =
    include_str!("../../../config/well-known/apple-app-site-association");
const ASSETLINKS_PLACEHOLDER: &str = include_str!("../../../config/well-known/assetlinks.json");

#[derive(Debug, Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct Health {
    /// `ok`, or `degraded` when the database does not answer (HTTP 503).
    pub status: String,
    pub version: String,
    pub build: String,
    /// `ok` or `error`.
    pub db: String,
}

pub async fn health(State(state): State<AppState>) -> Response {
    let db_ok = crate::db::ping(&state.db).await;
    let body = Health {
        status: if db_ok { "ok" } else { "degraded" }.into(),
        version: crate::VERSION.into(),
        build: crate::BUILD.into(),
        db: if db_ok { "ok" } else { "error" }.into(),
    };
    let code = if db_ok {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };
    (code, [(header::CACHE_CONTROL, "no-store")], Json(body)).into_response()
}

/// The two deep-link association files, loaded once at startup.
#[derive(Debug, Clone)]
pub struct DeepLinks {
    pub aasa: String,
    pub assetlinks: String,
}

impl DeepLinks {
    pub fn load(cfg: &DeepLinksConfig) -> anyhow::Result<Self> {
        let read = |name: &str, placeholder: &str| -> anyhow::Result<String> {
            let text = if cfg.dir.as_os_str().is_empty() {
                placeholder.to_string()
            } else {
                let path = cfg.dir.join(name);
                if path.exists() {
                    std::fs::read_to_string(&path)
                        .with_context(|| format!("reading {}", path.display()))?
                } else {
                    tracing::info!(path = %path.display(), "deep-link file missing; serving placeholder");
                    placeholder.to_string()
                }
            };
            serde_json::from_str::<serde_json::Value>(&text)
                .with_context(|| format!("{name} is not valid JSON"))?;
            Ok(text)
        };
        Ok(Self {
            aasa: read(AASA_FILE, AASA_PLACEHOLDER)?,
            assetlinks: read(ASSETLINKS_FILE, ASSETLINKS_PLACEHOLDER)?,
        })
    }
}

fn json_file(body: String) -> Response {
    (
        [
            (header::CONTENT_TYPE, "application/json"),
            (header::CACHE_CONTROL, "public, max-age=3600"),
        ],
        body,
    )
        .into_response()
}

pub async fn apple_app_site_association(State(state): State<AppState>) -> Response {
    json_file(state.deeplinks.aasa.clone())
}

pub async fn assetlinks(State(state): State<AppState>) -> Response {
    json_file(state.deeplinks.assetlinks.clone())
}

pub async fn metrics(State(state): State<AppState>) -> Response {
    (
        [(header::CONTENT_TYPE, "text/plain; version=0.0.4")],
        state.metrics.render(crate::VERSION, crate::BUILD),
    )
        .into_response()
}

/// A static page that runs the WebSocket echo from any browser, so a phone can
/// verify `wss://` through the TLS proxy before the game has network code (N0 gate).
pub async fn echo_check() -> Response {
    (
        [
            (header::CONTENT_TYPE, "text/html; charset=utf-8"),
            (header::CACHE_CONTROL, "no-store"),
        ],
        include_str!("echo_check.html"),
    )
        .into_response()
}

/// 404 in the API error format.
pub async fn not_found() -> Response {
    crate::error::ApiError::not_found().into_response()
}
