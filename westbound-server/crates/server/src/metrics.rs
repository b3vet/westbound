//! Process metrics in Prometheus text format, served on a separate localhost-only
//! listener. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Server tech stack" (logging and
//! metrics: a small Prometheus-text `/metrics` endpoint on localhost).
//! Plain atomics: no registry crate, no locks on the hot path.
//!
//! N10.1: the process's own CPU time and resident memory ([`ProcessStats`], from `/proc`)
//! as `process_cpu_seconds_total` and `process_resident_memory_bytes`, so the load test and
//! the admin stats read them off the running server (spec: Resource budget, "20 full rooms
//! at no more than 50% of one core", "server memory under 300 MB").

use std::fmt::Write as _;
use std::sync::atomic::{AtomicU64, Ordering};

use axum::http::StatusCode;

/// The kernel's clock ticks per second for `/proc/<pid>/stat` times (`USER_HZ`: 100 on
/// every Linux the server runs on).
const USER_HZ: f64 = 100.0;
const BYTES_PER_KB: u64 = 1_024;

/// The process's CPU time and memory (Linux `/proc/self`; zeros elsewhere).
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct ProcessStats {
    /// User + system CPU seconds since the process started.
    pub cpu_seconds: f64,
    /// Resident set size (bytes) and its peak (`VmHWM`).
    pub rss_bytes: u64,
    pub rss_peak_bytes: u64,
    pub threads: u64,
    /// Seconds since the process started.
    pub uptime_s: f64,
}

impl ProcessStats {
    pub fn read() -> Self {
        let mut p = ProcessStats::default();
        if let Ok(stat) = std::fs::read_to_string("/proc/self/stat") {
            // After the command name (in parentheses): state is field 3; utime, stime are
            // 14 and 15; num_threads 20; starttime 22 (clock ticks after boot).
            if let Some((_, rest)) = stat.rsplit_once(')') {
                let f: Vec<&str> = rest.split_whitespace().collect();
                let num = |i: usize| f.get(i).and_then(|x| x.parse::<f64>().ok()).unwrap_or(0.0);
                p.cpu_seconds = (num(11) + num(12)) / USER_HZ;
                p.threads = num(17) as u64;
                let boot_up = std::fs::read_to_string("/proc/uptime")
                    .ok()
                    .and_then(|u| u.split_whitespace().next()?.parse::<f64>().ok())
                    .unwrap_or(0.0);
                p.uptime_s = (boot_up - num(19) / USER_HZ).max(0.0);
            }
        }
        if let Ok(status) = std::fs::read_to_string("/proc/self/status") {
            let kb = |key: &str| {
                status
                    .lines()
                    .find_map(|l| l.strip_prefix(key))
                    .and_then(|v| v.split_whitespace().next()?.parse::<u64>().ok())
                    .unwrap_or(0)
            };
            p.rss_bytes = kb("VmRSS:") * BYTES_PER_KB;
            p.rss_peak_bytes = kb("VmHWM:") * BYTES_PER_KB;
        }
        p
    }
}

/// HTTP status classes counted by `http_requests_total{class=...}`.
const STATUS_CLASSES: [&str; 5] = ["1xx", "2xx", "3xx", "4xx", "5xx"];

/// Handshake outcomes counted by `wb_ws_handshakes_total{result=...}`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HandshakeResult {
    Ok,
    UpdateRequired,
    ServerOutdated,
    MapMismatch,
    AuthFailed,
    Banned,
    HandshakeRequired,
    Malformed,
    /// No `Hello` within `gateway.hello_timeout_ms`.
    HelloTimeout,
    /// The client closed (or the socket failed) before its `Hello` was answered.
    Abandoned,
    /// Database error while checking the token.
    Internal,
}

impl HandshakeResult {
    pub const ALL: [HandshakeResult; 11] = [
        HandshakeResult::Ok,
        HandshakeResult::UpdateRequired,
        HandshakeResult::ServerOutdated,
        HandshakeResult::MapMismatch,
        HandshakeResult::AuthFailed,
        HandshakeResult::Banned,
        HandshakeResult::HandshakeRequired,
        HandshakeResult::Malformed,
        HandshakeResult::HelloTimeout,
        HandshakeResult::Abandoned,
        HandshakeResult::Internal,
    ];

    pub fn label(self) -> &'static str {
        match self {
            HandshakeResult::Ok => "ok",
            HandshakeResult::UpdateRequired => "update_required",
            HandshakeResult::ServerOutdated => "server_outdated",
            HandshakeResult::MapMismatch => "map_mismatch",
            HandshakeResult::AuthFailed => "auth_failed",
            HandshakeResult::Banned => "banned",
            HandshakeResult::HandshakeRequired => "handshake_required",
            HandshakeResult::Malformed => "malformed",
            HandshakeResult::HelloTimeout => "hello_timeout",
            HandshakeResult::Abandoned => "abandoned",
            HandshakeResult::Internal => "internal",
        }
    }

    /// The outcome for a fatal handshake error code.
    pub fn from_error(code: protocol::ErrorCode) -> Self {
        use protocol::ErrorCode as E;
        match code {
            E::UpdateRequired => HandshakeResult::UpdateRequired,
            E::ServerOutdated => HandshakeResult::ServerOutdated,
            E::MapMismatch => HandshakeResult::MapMismatch,
            E::AuthFailed => HandshakeResult::AuthFailed,
            E::Banned => HandshakeResult::Banned,
            E::HandshakeRequired => HandshakeResult::HandshakeRequired,
            E::Malformed => HandshakeResult::Malformed,
            _ => HandshakeResult::Internal,
        }
    }

    fn index(self) -> usize {
        Self::ALL.iter().position(|r| *r == self).unwrap_or(0)
    }
}

/// Why the gateway ended an established session from outside (`wb_ws_kicks_total{reason}`).
pub const KICK_REASONS: [&str; 5] = ["replaced", "banned", "revoked", "slow_client", "closed"];
const HANDSHAKE_RESULTS: usize = HandshakeResult::ALL.len();
const CLIENT_TYPES: usize = crate::msg_limits::CLIENT_TYPES;

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
    /// Live, handshaken sessions (the registry's size).
    pub ws_sessions: AtomicU64,
    /// Sessions replaced by a second login of the same account.
    pub ws_sessions_replaced: AtomicU64,
    ws_handshakes: [AtomicU64; HANDSHAKE_RESULTS],
    ws_messages_in: [AtomicU64; CLIENT_TYPES],
    ws_rate_limited: [AtomicU64; CLIENT_TYPES],
    /// Connections closed for flooding past the violation bucket.
    pub ws_rate_limit_closed: AtomicU64,
    ws_kicks: [AtomicU64; KICK_REASONS.len()],
    /// Echo connections on `/ws/echo`.
    pub ws_echo_connections_total: AtomicU64,
}

impl Metrics {
    pub fn count_http(&self, status: StatusCode) {
        let class = (status.as_u16() / 100).clamp(1, 5) as usize - 1;
        self.http_requests[class].fetch_add(1, Ordering::Relaxed);
    }

    pub fn http_requests(&self, class_index: usize) -> u64 {
        self.http_requests[class_index].load(Ordering::Relaxed)
    }

    pub fn count_handshake(&self, r: HandshakeResult) {
        self.ws_handshakes[r.index()].fetch_add(1, Ordering::Relaxed);
    }

    pub fn handshakes(&self, r: HandshakeResult) -> u64 {
        self.ws_handshakes[r.index()].load(Ordering::Relaxed)
    }

    /// Counts one inbound message by client type index (`msg_limits::client_type_index`).
    pub fn count_message_in(&self, type_index: usize) {
        if let Some(c) = self.ws_messages_in.get(type_index) {
            c.fetch_add(1, Ordering::Relaxed);
        }
    }

    pub fn messages_in(&self, type_index: usize) -> u64 {
        self.ws_messages_in
            .get(type_index)
            .map_or(0, |c| c.load(Ordering::Relaxed))
    }

    pub fn count_rate_limited(&self, type_index: usize) {
        if let Some(c) = self.ws_rate_limited.get(type_index) {
            c.fetch_add(1, Ordering::Relaxed);
        }
    }

    pub fn rate_limited(&self, type_index: usize) -> u64 {
        self.ws_rate_limited
            .get(type_index)
            .map_or(0, |c| c.load(Ordering::Relaxed))
    }

    /// Counts a kick by its `KICK_REASONS` label.
    pub fn count_kick(&self, reason: &str) {
        if let Some(i) = KICK_REASONS.iter().position(|r| *r == reason) {
            self.ws_kicks[i].fetch_add(1, Ordering::Relaxed);
        }
    }

    pub fn kicks(&self, reason: &str) -> u64 {
        KICK_REASONS
            .iter()
            .position(|r| *r == reason)
            .map_or(0, |i| self.ws_kicks[i].load(Ordering::Relaxed))
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
        metric(
            "wb_ws_sessions",
            "gauge",
            "Live handshaken sessions (one per account).",
            g(&self.ws_sessions),
        );
        metric(
            "wb_ws_sessions_replaced_total",
            "counter",
            "Sessions replaced by a second login of the same account.",
            g(&self.ws_sessions_replaced),
        );
        metric(
            "wb_ws_rate_limit_closed_total",
            "counter",
            "Connections closed for flooding past the rate limits.",
            g(&self.ws_rate_limit_closed),
        );
        metric(
            "wb_ws_echo_connections_total",
            "counter",
            "Connections to the /ws/echo ops route.",
            g(&self.ws_echo_connections_total),
        );
        let mut labelled =
            |name: &str, help: &str, label: &str, rows: &mut dyn Iterator<Item = (&str, u64)>| {
                let _ = writeln!(out, "# HELP {name} {help}");
                let _ = writeln!(out, "# TYPE {name} counter");
                for (l, v) in rows {
                    let _ = writeln!(out, "{name}{{{label}=\"{l}\"}} {v}");
                }
            };
        labelled(
            "wb_ws_handshakes_total",
            "Handshakes on /ws by result (ok or the failure reason).",
            "result",
            &mut HandshakeResult::ALL
                .iter()
                .map(|r| (r.label(), self.handshakes(*r))),
        );
        let types = &crate::msg_limits::CLIENT_TYPE_NAMES;
        labelled(
            "wb_ws_messages_in_total",
            "Decoded client messages by type.",
            "type",
            &mut types
                .iter()
                .enumerate()
                .map(|(i, t)| (*t, g(&self.ws_messages_in[i]))),
        );
        labelled(
            "wb_ws_rate_limited_total",
            "Client messages dropped by the per-connection rate limits, by type.",
            "type",
            &mut types
                .iter()
                .enumerate()
                .map(|(i, t)| (*t, g(&self.ws_rate_limited[i]))),
        );
        labelled(
            "wb_ws_kicks_total",
            "Live sessions ended by the server, by reason.",
            "reason",
            &mut KICK_REASONS
                .iter()
                .enumerate()
                .map(|(i, r)| (*r, g(&self.ws_kicks[i]))),
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
        let p = ProcessStats::read();
        let _ = writeln!(
            out,
            "# HELP process_cpu_seconds_total User and system CPU time of the server process."
        );
        let _ = writeln!(out, "# TYPE process_cpu_seconds_total counter");
        let _ = writeln!(out, "process_cpu_seconds_total {}", p.cpu_seconds);
        let _ = writeln!(
            out,
            "# HELP process_resident_memory_bytes Resident memory of the server process."
        );
        let _ = writeln!(out, "# TYPE process_resident_memory_bytes gauge");
        let _ = writeln!(out, "process_resident_memory_bytes {}", p.rss_bytes);
        let _ = writeln!(
            out,
            "# HELP process_resident_memory_peak_bytes Peak resident memory of the server process."
        );
        let _ = writeln!(out, "# TYPE process_resident_memory_peak_bytes gauge");
        let _ = writeln!(
            out,
            "process_resident_memory_peak_bytes {}",
            p.rss_peak_bytes
        );
        let _ = writeln!(out, "# HELP wb_build_info Build information.");
        let _ = writeln!(out, "# TYPE wb_build_info gauge");
        let _ = writeln!(
            out,
            "wb_build_info{{version=\"{version}\",build=\"{build}\"}} 1"
        );
        out
    }
}
