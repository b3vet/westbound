//! The HTTP API's error format and its JSON body extractor. Every `/api/*` error is
//! `{"error": "<code>", "message": "<English text>"}`, sometimes with one extra field
//! (`banned_until`, `next_rename_at`, `retry_after_secs`). Clients switch on `error`;
//! `message` is for logs and developer builds.
//! Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Accounts and authentication" (security:
//! input validation), docs/SERVER.md → "Accounts API".

use axum::extract::rejection::JsonRejection;
use axum::extract::{FromRequest, Request};
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value};

/// An API error response.
#[derive(Debug)]
pub struct ApiError {
    pub status: StatusCode,
    pub code: &'static str,
    pub message: String,
    /// One optional extra field, e.g. `("banned_until", 1790000000)`.
    pub extra: Option<(&'static str, Value)>,
    /// `Retry-After` header value in seconds (429 responses).
    pub retry_after: Option<u64>,
    /// Adds `WWW-Authenticate: Bearer error="invalid_token"` (401 on bearer routes).
    pub bearer_challenge: bool,
}

impl ApiError {
    pub fn new(status: StatusCode, code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            code,
            message: message.into(),
            extra: None,
            retry_after: None,
            bearer_challenge: false,
        }
    }

    pub fn with(mut self, key: &'static str, value: impl Into<Value>) -> Self {
        self.extra = Some((key, value.into()));
        self
    }

    pub fn bad_request(code: &'static str, message: impl Into<String>) -> Self {
        Self::new(StatusCode::BAD_REQUEST, code, message)
    }

    pub fn unauthorized(code: &'static str, message: impl Into<String>) -> Self {
        let mut e = Self::new(StatusCode::UNAUTHORIZED, code, message);
        e.bearer_challenge = true;
        e
    }

    /// 403 for a banned account, with the ban end (unix seconds).
    pub fn banned(until: i64) -> Self {
        Self::new(
            StatusCode::FORBIDDEN,
            "banned",
            "This account is banned from online play.",
        )
        .with("banned_until", until)
    }

    pub fn rate_limited(retry_after_secs: u64) -> Self {
        let mut e = Self::new(
            StatusCode::TOO_MANY_REQUESTS,
            "rate_limited",
            format!("Too many requests. Retry in {retry_after_secs} s."),
        )
        .with("retry_after_secs", retry_after_secs);
        e.retry_after = Some(retry_after_secs);
        e
    }

    pub fn not_found() -> Self {
        Self::new(StatusCode::NOT_FOUND, "not_found", "No such route.")
    }

    pub fn method_not_allowed() -> Self {
        Self::new(
            StatusCode::METHOD_NOT_ALLOWED,
            "method_not_allowed",
            "This route does not accept that method.",
        )
    }

    /// 500 without details for the client; the cause is logged here.
    pub fn internal(err: impl std::fmt::Display) -> Self {
        tracing::error!(error = %err, "internal error");
        Self::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "internal",
            "Internal server error.",
        )
    }

    pub fn body(&self) -> Value {
        let mut m = Map::new();
        m.insert("error".into(), Value::from(self.code));
        m.insert("message".into(), Value::from(self.message.clone()));
        if let Some((k, v)) = &self.extra {
            m.insert((*k).into(), v.clone());
        }
        Value::Object(m)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let mut resp = (self.status, Json(self.body())).into_response();
        let h = resp.headers_mut();
        h.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
        if let Some(secs) = self.retry_after {
            h.insert(header::RETRY_AFTER, HeaderValue::from(secs));
        }
        if self.bearer_challenge {
            h.insert(
                header::WWW_AUTHENTICATE,
                HeaderValue::from_static("Bearer error=\"invalid_token\""),
            );
        }
        resp
    }
}

impl From<sqlx::Error> for ApiError {
    fn from(e: sqlx::Error) -> Self {
        ApiError::internal(format_args!("database: {e}"))
    }
}

impl From<anyhow::Error> for ApiError {
    fn from(e: anyhow::Error) -> Self {
        ApiError::internal(format_args!("{e:#}"))
    }
}

pub type ApiResult<T> = Result<T, ApiError>;

/// `Json<T>` whose rejections use the API error format: 413 `body_too_large` over
/// `http.max_body_bytes`, 415 `unsupported_media_type` without a JSON content type,
/// 400 `invalid_body` for malformed JSON, unknown fields or wrong types.
pub struct ApiJson<T>(pub T);

impl<S, T> FromRequest<S> for ApiJson<T>
where
    T: DeserializeOwned,
    S: Send + Sync,
{
    type Rejection = ApiError;

    async fn from_request(req: Request, state: &S) -> Result<Self, Self::Rejection> {
        match Json::<T>::from_request(req, state).await {
            Ok(Json(v)) => Ok(ApiJson(v)),
            Err(rej) => Err(json_rejection(rej)),
        }
    }
}

fn json_rejection(rej: JsonRejection) -> ApiError {
    let status = rej.status();
    let (status, code) = match status {
        StatusCode::PAYLOAD_TOO_LARGE => (status, "body_too_large"),
        StatusCode::UNSUPPORTED_MEDIA_TYPE => (status, "unsupported_media_type"),
        _ => (StatusCode::BAD_REQUEST, "invalid_body"),
    };
    ApiError::new(status, code, rej.body_text())
}
