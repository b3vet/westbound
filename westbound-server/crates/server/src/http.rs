//! HTTP handlers: health, deep-link files, metrics text, 404.
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Deployment" (deep-link files);
//! docs/MULTIPLAYER_PLAN.md MP-D1 (the server serves the deep-link files itself).

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;

use anyhow::Context;
use axum::extract::{Request, State};
use axum::http::{header, HeaderValue, StatusCode};
use axum::middleware::Next;
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
    /// `ok`; `degraded` when the database does not answer (HTTP 503); N10.2: `draining`
    /// during a planned restart's notice (HTTP 503: a proxy stops sending new clients).
    pub status: String,
    pub version: String,
    pub build: String,
    /// `ok` or `error`.
    pub db: String,
}

pub async fn health(State(state): State<AppState>) -> Response {
    let db_ok = crate::db::ping(&state.db).await;
    let draining = state.drain.is_draining();
    let status = match (db_ok, draining) {
        (_, true) => "draining",
        (true, false) => "ok",
        (false, false) => "degraded",
    };
    let body = Health {
        status: status.into(),
        version: crate::VERSION.into(),
        build: crate::BUILD.into(),
        db: if db_ok { "ok" } else { "error" }.into(),
    };
    let code = if db_ok && !draining {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };
    (code, [(header::CACHE_CONTROL, "no-store")], Json(body)).into_response()
}

/// The two deep-link association files, loaded once at startup, and what the `/r/<code>`
/// invite page needs (N9.3).
#[derive(Debug, Clone)]
pub struct DeepLinks {
    pub aasa: String,
    pub assetlinks: String,
    /// `deeplinks.web_join_url` with `{origin}` filled in (`{code}` is filled per page).
    pub web_join_url: String,
    pub app_store_url: String,
    pub play_store_url: String,
    pub app_scheme: String,
}

/// The paths the association files claim for the app (invite links).
pub const INVITE_PATHS: &str = "/r/*";

impl DeepLinks {
    /// Each file: `deeplinks.dir/<file>` when present, else generated from the configured
    /// app ids, else the built-in placeholder. `origin` is `server.public_origin`.
    pub fn load(cfg: &DeepLinksConfig, origin: &str) -> anyhow::Result<Self> {
        let read = |name: &str,
                    generated: Option<String>,
                    placeholder: &str|
         -> anyhow::Result<String> {
            let from_dir = if cfg.dir.as_os_str().is_empty() {
                None
            } else {
                let path = cfg.dir.join(name);
                if path.exists() {
                    Some(
                        std::fs::read_to_string(&path)
                            .with_context(|| format!("reading {}", path.display()))?,
                    )
                } else {
                    tracing::info!(path = %path.display(), "deep-link file missing; generated or placeholder");
                    None
                }
            };
            let text = from_dir
                .or(generated)
                .unwrap_or_else(|| placeholder.to_string());
            serde_json::from_str::<serde_json::Value>(&text)
                .with_context(|| format!("{name} is not valid JSON"))?;
            Ok(text)
        };
        Ok(Self {
            aasa: read(AASA_FILE, generated_aasa(cfg), AASA_PLACEHOLDER)?,
            assetlinks: read(
                ASSETLINKS_FILE,
                generated_assetlinks(cfg),
                ASSETLINKS_PLACEHOLDER,
            )?,
            web_join_url: cfg.web_join_url.replace("{origin}", origin),
            app_store_url: cfg.app_store_url.clone(),
            play_store_url: cfg.play_store_url.clone(),
            app_scheme: cfg.app_scheme.clone(),
        })
    }
}

/// `apple-app-site-association` for the configured app ids: the current `components`
/// form plus the older `appID` / `paths` form (iOS 12 and earlier). None without ids.
pub fn generated_aasa(cfg: &DeepLinksConfig) -> Option<String> {
    if cfg.apple_app_ids.is_empty() {
        return None;
    }
    let mut details: Vec<serde_json::Value> = vec![serde_json::json!({
        "appIDs": cfg.apple_app_ids,
        "components": [{"/": INVITE_PATHS, "comment": "Westbound room and party invites"}],
    })];
    details.extend(
        cfg.apple_app_ids
            .iter()
            .map(|id| serde_json::json!({"appID": id, "paths": [INVITE_PATHS]})),
    );
    Some(serde_json::json!({"applinks": {"apps": [], "details": details}}).to_string())
}

/// `assetlinks.json` for the configured package and certificate fingerprints. None
/// without a package.
pub fn generated_assetlinks(cfg: &DeepLinksConfig) -> Option<String> {
    if cfg.android_package.is_empty() {
        return None;
    }
    Some(
        serde_json::json!([{
            "relation": ["delegate_permission/common.handle_all_urls"],
            "target": {
                "namespace": "android_app",
                "package_name": cfg.android_package,
                "sha256_cert_fingerprints": cfg.android_cert_sha256,
            },
        }])
        .to_string(),
    )
}

/// A code from an invite link: case-insensitive, spaces and dashes forgiven (a pasted
/// `abc-234`), then the protocol's rules (6 characters of `CODE_ALPHABET`).
pub fn invite_code(raw: &str) -> Option<protocol::Code> {
    let s: String = raw
        .chars()
        .filter(|c| *c != '-' && *c != ' ')
        .map(|c| c.to_ascii_uppercase())
        .collect();
    protocol::Code::new(s).ok()
}

/// HTML-escapes text for the invite page.
fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
    out
}

const INVITE_PAGE: &str = include_str!("invite_page.html");

/// The invite page's HTML for `code` (None: not a valid code).
pub fn invite_page(links: &DeepLinks, code: Option<&protocol::Code>) -> String {
    let (heading, body, actions) = match code {
        Some(c) => {
            let code = c.as_str();
            let web = links.web_join_url.replace("{code}", code);
            let mut actions = format!(
                r#"<a class="primary" id="play-web" href="{}">PLAY IN THE BROWSER</a>"#,
                esc(&web)
            );
            if !links.app_scheme.is_empty() {
                actions.push_str(&format!(
                    r#"<a id="open-app" href="{}://r/{}">OPEN THE APP</a>"#,
                    esc(&links.app_scheme),
                    code
                ));
            }
            for (label, url) in [
                ("APP STORE", &links.app_store_url),
                ("GOOGLE PLAY", &links.play_store_url),
            ] {
                if url.is_empty() {
                    actions.push_str(&format!(
                        r#"<span class="soon">{label} · COMING SOON</span>"#
                    ));
                } else {
                    actions.push_str(&format!(r#"<a href="{}">{label}</a>"#, esc(url)));
                }
            }
            (
                format!("JOIN <b>{code}</b>"),
                "You're invited to drive the Westbound loop together. With the app installed this link opens it; otherwise play in the browser.".to_string(),
                actions,
            )
        }
        None => (
            "INVITE NOT FOUND".to_string(),
            "That invite link isn't valid. Ask for a new one: codes are 6 letters and digits."
                .to_string(),
            String::new(),
        ),
    };
    INVITE_PAGE
        .replace("{{heading}}", &heading)
        .replace("{{body}}", &esc(&body))
        .replace("{{actions}}", &actions)
}

/// `GET /r/{code}`: the invite page (room or party code). It opens the web build with
/// `?room=<code>` (the client joins that room, or that party, after signing in); with the
/// app installed the OS opens the app instead (Universal Links / App Links claim `/r/*`).
/// An invalid code answers 404 with the same page saying so.
pub async fn invite(
    State(state): State<AppState>,
    axum::extract::Path(raw): axum::extract::Path<String>,
) -> Response {
    let code = invite_code(&raw);
    let status = if code.is_some() {
        StatusCode::OK
    } else {
        StatusCode::NOT_FOUND
    };
    (
        status,
        [
            (header::CONTENT_TYPE, "text/html; charset=utf-8"),
            (header::CACHE_CONTROL, "public, max-age=300"),
            (header::X_CONTENT_TYPE_OPTIONS, "nosniff"),
            (
                header::HeaderName::from_static("x-robots-tag"),
                "noindex, nofollow",
            ),
        ],
        invite_page(&state.deeplinks, code.as_ref()),
    )
        .into_response()
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
    ([(header::CONTENT_TYPE, "text/plain; version=0.0.4")], {
        let mut out = state.metrics.render(crate::VERSION, crate::BUILD);
        state.rooms.metrics().render(&mut out);
        out
    })
        .into_response()
}

/// A static page that runs the WebSocket echo (`/ws/echo`) from any browser and sends a
/// token-less `Hello` to the gateway (`/ws`), so a phone can verify `wss://` through the
/// TLS proxy without the game (N0 gate, kept for ops by N2.3).
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

/// A request's id (N10.2): the client's `X-Request-Id` when it is short and plain, else a
/// fresh one. It is in the request's log span (`req_id`) and echoed in the response.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestId(pub String);

pub const REQUEST_ID_HEADER: &str = "x-request-id";
/// Longest client-supplied request id kept.
const MAX_REQUEST_ID_LEN: usize = 64;

/// A client-supplied id is kept only if it is 1–64 characters of `[A-Za-z0-9._-]`.
pub fn valid_request_id(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= MAX_REQUEST_ID_LEN
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
}

/// A new id: 8 hex digits fixed per process (random) and a 12-digit counter.
pub fn new_request_id() -> String {
    static PREFIX: OnceLock<u32> = OnceLock::new();
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let prefix = *PREFIX.get_or_init(|| {
        let mut b = [0u8; 4];
        let _ = getrandom::fill(&mut b);
        u32::from_le_bytes(b)
    });
    format!("{prefix:08x}-{:012x}", NEXT.fetch_add(1, Ordering::Relaxed))
}

/// Middleware: tags the request with its [`RequestId`] (read by the trace span) and adds
/// `X-Request-Id` to the response.
pub async fn request_id(mut req: Request, next: Next) -> Response {
    let id = req
        .headers()
        .get(REQUEST_ID_HEADER)
        .and_then(|v| v.to_str().ok())
        .filter(|v| valid_request_id(v))
        .map(str::to_owned)
        .unwrap_or_else(new_request_id);
    req.extensions_mut().insert(RequestId(id.clone()));
    let mut resp = next.run(req).await;
    if let Ok(v) = HeaderValue::from_str(&id) {
        resp.headers_mut().insert(REQUEST_ID_HEADER, v);
    }
    resp
}

/// 404 in the API error format.
pub async fn not_found() -> Response {
    crate::error::ApiError::not_found().into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_ids() {
        let a = new_request_id();
        let b = new_request_id();
        assert_ne!(a, b);
        assert!(valid_request_id(&a), "{a}");
        assert!(valid_request_id("trace-01.AB_c"));
        for bad in ["", "has space", "semi;colon", &"x".repeat(65)] {
            assert!(!valid_request_id(bad), "{bad}");
        }
    }
}
