//! Process metrics in Prometheus text format, served on a separate localhost-only
//! listener. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Server tech stack" (logging and
//! metrics: a small Prometheus-text `/metrics` endpoint on localhost).
//! Plain atomics: no registry crate, no locks on the hot path.

use std::fmt::Write as _;
use std::sync::atomic::{AtomicU64, Ordering};

use axum::http::StatusCode;

/// HTTP status classes counted by `http_requests_total{class=...}`.
const STATUS_CLASSES: [&str; 5] = ["1xx", "2xx", "3xx", "4xx", "5xx"];

#[derive(Debug, Default)]
pub struct Metrics {
    pub ws_connections: AtomicU64,
    pub ws_connections_total: AtomicU64,
    pub ws_frames_in: AtomicU64,
    pub ws_frames_out: AtomicU64,
    pub ws_bytes_in: AtomicU64,
    pub ws_bytes_out: AtomicU64,
    pub ws_rejected_full: AtomicU64,
    pub ws_oversize_closed: AtomicU64,
    pub ws_slow_client_closed: AtomicU64,
    pub ws_timeout_closed: AtomicU64,
    http_requests: [AtomicU64; 5],
    pub backups_ok: AtomicU64,
    pub backups_failed: AtomicU64,
    pub accounts_created: AtomicU64,
    pub auth_logins: AtomicU64,
    pub auth_refreshes: AtomicU64,
    pub auth_refresh_reuse: AtomicU64,
    pub http_rate_limited: AtomicU64,
}

impl Metrics {
    pub fn count_http(&self, status: StatusCode) {
        let class = (status.as_u16() / 100).clamp(1, 5) as usize - 1;
        self.http_requests[class].fetch_add(1, Ordering::Relaxed);
    }

    pub fn http_requests(&self, class_index: usize) -> u64 {
        self.http_requests[class_index].load(Ordering::Relaxed)
    }

    pub fn get(counter: &AtomicU64) -> u64 {
        counter.load(Ordering::Relaxed)
    }

    pub fn inc(counter: &AtomicU64) {
        counter.fetch_add(1, Ordering::Relaxed);
    }

    pub fn add(counter: &AtomicU64, n: u64) {
        counter.fetch_add(n, Ordering::Relaxed);
    }

    pub fn render(&self, version: &str, build: &str) -> String {
        let mut out = String::with_capacity(2048);
        let g = |c: &AtomicU64| c.load(Ordering::Relaxed);
        let mut metric = |name: &str, kind: &str, help: &str, value: u64| {
            let _ = writeln!(out, "# HELP {name} {help}");
            let _ = writeln!(out, "# TYPE {name} {kind}");
            let _ = writeln!(out, "{name} {value}");
        };
        metric(
            "wb_ws_connections",
            "gauge",
            "Open WebSocket connections.",
            g(&self.ws_connections),
        );
        metric(
            "wb_ws_connections_total",
            "counter",
            "WebSocket connections accepted.",
            g(&self.ws_connections_total),
        );
        metric(
            "wb_ws_frames_in_total",
            "counter",
            "Data frames received (text + binary).",
            g(&self.ws_frames_in),
        );
        metric(
            "wb_ws_frames_out_total",
            "counter",
            "Data frames sent (text + binary).",
            g(&self.ws_frames_out),
        );
        metric(
            "wb_ws_bytes_in_total",
            "counter",
            "Payload bytes received.",
            g(&self.ws_bytes_in),
        );
        metric(
            "wb_ws_bytes_out_total",
            "counter",
            "Payload bytes sent.",
            g(&self.ws_bytes_out),
        );
        metric(
            "wb_ws_rejected_full_total",
            "counter",
            "Upgrades refused at the connection cap.",
            g(&self.ws_rejected_full),
        );
        metric(
            "wb_ws_oversize_closed_total",
            "counter",
            "Connections closed for an oversized inbound message.",
            g(&self.ws_oversize_closed),
        );
        metric(
            "wb_ws_slow_client_closed_total",
            "counter",
            "Connections closed because the outbound queue was full.",
            g(&self.ws_slow_client_closed),
        );
        metric(
            "wb_ws_timeout_closed_total",
            "counter",
            "Connections closed after the keepalive silence limit.",
            g(&self.ws_timeout_closed),
        );
        metric(
            "wb_backups_ok_total",
            "counter",
            "Successful scheduled backups.",
            g(&self.backups_ok),
        );
        metric(
            "wb_backups_failed_total",
            "counter",
            "Failed scheduled backups.",
            g(&self.backups_failed),
        );
        metric(
            "wb_accounts_created_total",
            "counter",
            "Device accounts created.",
            g(&self.accounts_created),
        );
        metric(
            "wb_auth_logins_total",
            "counter",
            "Successful device sign-ins.",
            g(&self.auth_logins),
        );
        metric(
            "wb_auth_refreshes_total",
            "counter",
            "Refresh-token rotations.",
            g(&self.auth_refreshes),
        );
        metric(
            "wb_auth_refresh_reuse_total",
            "counter",
            "Refresh-token reuse detections (session family revoked).",
            g(&self.auth_refresh_reuse),
        );
        metric(
            "wb_http_rate_limited_total",
            "counter",
            "HTTP requests refused with 429.",
            g(&self.http_rate_limited),
        );
        let _ = writeln!(
            out,
            "# HELP wb_http_requests_total HTTP responses by status class."
        );
        let _ = writeln!(out, "# TYPE wb_http_requests_total counter");
        for (i, class) in STATUS_CLASSES.iter().enumerate() {
            let _ = writeln!(
                out,
                "wb_http_requests_total{{class=\"{class}\"}} {}",
                g(&self.http_requests[i])
            );
        }
        let _ = writeln!(out, "# HELP wb_build_info Build information.");
        let _ = writeln!(out, "# TYPE wb_build_info gauge");
        let _ = writeln!(
            out,
            "wb_build_info{{version=\"{version}\",build=\"{build}\"}} 1"
        );
        out
    }
}
