//! Process metrics in Prometheus text format, served on a separate localhost-only
//! listener. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → "Server tech stack" (logging and
//! metrics: a small Prometheus-text `/metrics` endpoint on localhost).
//! Plain atomics: no registry crate, no locks on the hot path.

use std::fmt::Write as _;
use std::sync::atomic::{AtomicU64, Ordering};

use axum::http::StatusCode;

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
const MS_PER_SEC: f64 = 1_000.0;
const MICROS_PER_SEC: f64 = 1_000_000.0;

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
    /// N10.2 operations (see [`Metrics::render_ops`]).
    pub server_notices: AtomicU64,
    pub server_draining: AtomicU64,
    pub rooms_handed_over: AtomicU64,
    pub rooms_restored: AtomicU64,
    pub room_create_limited: AtomicU64,
    pub admin_requests: AtomicU64,
    pub admin_denied: AtomicU64,
    pub backup_last_success_unix: AtomicU64,
    pub backup_last_bytes: AtomicU64,
    pub backup_last_duration_ms: AtomicU64,
    pub backup_verify_failed: AtomicU64,
    pub backup_uploads_ok: AtomicU64,
    pub backup_uploads_failed: AtomicU64,
    /// The periodic database probe (`metrics.db_probe_interval_secs`).
    pub db_probe_micros: AtomicU64,
    pub db_probe_failures: AtomicU64,
    pub db_file_bytes: AtomicU64,
    pub db_wal_bytes: AtomicU64,
    pub db_pool_size: AtomicU64,
    pub db_pool_idle: AtomicU64,
    /// Replay verification jobs by `REPLAY_STATUSES`.
    replay_jobs: [AtomicU64; REPLAY_STATUSES.len()],
    pub reports_unhandled: AtomicU64,
    /// Unix seconds at startup.
    pub started_unix: AtomicU64,
}

/// Replay queue statuses, in `wb_replay_jobs{status}` order.
pub const REPLAY_STATUSES: [&str; 4] = ["pending", "running", "done", "failed"];

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

    /// Sets a gauge.
    pub fn set(gauge: &AtomicU64, v: u64) {
        gauge.store(v, Ordering::Relaxed);
    }

    /// Sets the replay queue gauge of `status` (unknown statuses are ignored).
    pub fn set_replay_jobs(&self, status: &str, n: u64) {
        if let Some(i) = REPLAY_STATUSES.iter().position(|s| *s == status) {
            self.replay_jobs[i].store(n, Ordering::Relaxed);
        }
    }

    pub fn replay_jobs(&self, status: &str) -> u64 {
        REPLAY_STATUSES
            .iter()
            .position(|s| *s == status)
            .map_or(0, |i| self.replay_jobs[i].load(Ordering::Relaxed))
    }

    /// N10.2: restart, admin, backup, database, queue, log and process metrics.
    pub fn render_ops(&self, out: &mut String) {
        let g = |c: &AtomicU64| c.load(Ordering::Relaxed);
        let secs = |ms: u64| format!("{}", ms as f64 / MS_PER_SEC);
        let rows: [(&str, &str, &str, String); 20] = [
            (
                "wb_server_draining",
                "gauge",
                "1 while a planned restart drains the server.",
                g(&self.server_draining).to_string(),
            ),
            (
                "wb_server_notices_total",
                "counter",
                "server_notice broadcasts (restart notices, reminders, admin notices).",
                g(&self.server_notices).to_string(),
            ),
            (
                "wb_rooms_handed_over_total",
                "counter",
                "Rooms handed over to the next instance at a restart.",
                g(&self.rooms_handed_over).to_string(),
            ),
            (
                "wb_rooms_restored_total",
                "counter",
                "Handed-over rooms recreated by a rejoin by code.",
                g(&self.rooms_restored).to_string(),
            ),
            (
                "wb_room_create_limited_total",
                "counter",
                "room_create refused by the per-account limit.",
                g(&self.room_create_limited).to_string(),
            ),
            (
                "wb_admin_requests_total",
                "counter",
                "Admin API requests served.",
                g(&self.admin_requests).to_string(),
            ),
            (
                "wb_admin_denied_total",
                "counter",
                "Admin API requests refused (bad or missing token).",
                g(&self.admin_denied).to_string(),
            ),
            (
                "wb_backup_last_success_timestamp_seconds",
                "gauge",
                "Unix time of the last good backup (0: none since start).",
                g(&self.backup_last_success_unix).to_string(),
            ),
            (
                "wb_backup_last_size_bytes",
                "gauge",
                "Size of the last good backup.",
                g(&self.backup_last_bytes).to_string(),
            ),
            (
                "wb_backup_last_duration_seconds",
                "gauge",
                "Duration of the last good backup.",
                secs(g(&self.backup_last_duration_ms)),
            ),
            (
                "wb_backup_verify_failed_total",
                "counter",
                "Backups whose integrity check failed.",
                g(&self.backup_verify_failed).to_string(),
            ),
            (
                "wb_backup_uploads_ok_total",
                "counter",
                "Off-site backup hook runs that exited 0.",
                g(&self.backup_uploads_ok).to_string(),
            ),
            (
                "wb_backup_uploads_failed_total",
                "counter",
                "Off-site backup hook runs that failed or timed out.",
                g(&self.backup_uploads_failed).to_string(),
            ),
            (
                "wb_db_probe_seconds",
                "gauge",
                "Latency of the last database probe (a query through the pool).",
                format!("{}", g(&self.db_probe_micros) as f64 / MICROS_PER_SEC),
            ),
            (
                "wb_db_probe_failures_total",
                "counter",
                "Database probes that failed.",
                g(&self.db_probe_failures).to_string(),
            ),
            (
                "wb_db_file_bytes",
                "gauge",
                "Database file size.",
                g(&self.db_file_bytes).to_string(),
            ),
            (
                "wb_db_wal_bytes",
                "gauge",
                "Write-ahead log size.",
                g(&self.db_wal_bytes).to_string(),
            ),
            (
                "wb_db_pool_connections",
                "gauge",
                "Open database pool connections.",
                g(&self.db_pool_size).to_string(),
            ),
            (
                "wb_db_pool_idle",
                "gauge",
                "Idle database pool connections.",
                g(&self.db_pool_idle).to_string(),
            ),
            (
                "wb_reports_unhandled",
                "gauge",
                "Player reports not handled yet.",
                g(&self.reports_unhandled).to_string(),
            ),
        ];
        for (name, kind, help, value) in rows {
            let _ = writeln!(out, "# HELP {name} {help}");
            let _ = writeln!(out, "# TYPE {name} {kind}");
            let _ = writeln!(out, "{name} {value}");
        }
        let _ = writeln!(
            out,
            "# HELP wb_replay_jobs Replay verification jobs by status (the queue depth is pending)."
        );
        let _ = writeln!(out, "# TYPE wb_replay_jobs gauge");
        for (i, st) in REPLAY_STATUSES.iter().enumerate() {
            let _ = writeln!(
                out,
                "wb_replay_jobs{{status=\"{st}\"}} {}",
                g(&self.replay_jobs[i])
            );
        }
        let (errors, warnings) = crate::telemetry::log_event_counts();
        let _ = writeln!(
            out,
            "# HELP wb_log_events_total Log events at WARN and ERROR (every logged failure)."
        );
        let _ = writeln!(out, "# TYPE wb_log_events_total counter");
        let _ = writeln!(out, "wb_log_events_total{{level=\"error\"}} {errors}");
        let _ = writeln!(out, "wb_log_events_total{{level=\"warn\"}} {warnings}");
        render_process(out, g(&self.started_unix));
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
        self.render_ops(&mut out);
        let _ = writeln!(out, "# HELP wb_build_info Build information.");
        let _ = writeln!(out, "# TYPE wb_build_info gauge");
        let _ = writeln!(
            out,
            "wb_build_info{{version=\"{version}\",build=\"{build}\"}} 1"
        );
        out
    }
}

/// Process metrics in the Prometheus client conventions, from `/proc/self` (Linux; left
/// out elsewhere): CPU seconds, resident memory, threads, open file descriptors, start time.
fn render_process(out: &mut String, started_unix: u64) {
    let mut metric = |name: &str, kind: &str, help: &str, value: String| {
        let _ = writeln!(out, "# HELP {name} {help}");
        let _ = writeln!(out, "# TYPE {name} {kind}");
        let _ = writeln!(out, "{name} {value}");
    };
    metric(
        "process_start_time_seconds",
        "gauge",
        "Start time of the process since the Unix epoch.",
        started_unix.to_string(),
    );
    let Some(p) = ProcStat::read() else {
        return;
    };
    metric(
        "process_cpu_seconds_total",
        "counter",
        "User and system CPU time spent.",
        format!("{}", p.cpu_secs),
    );
    metric(
        "process_resident_memory_bytes",
        "gauge",
        "Resident memory size.",
        p.rss_bytes.to_string(),
    );
    metric(
        "process_threads",
        "gauge",
        "OS threads.",
        p.threads.to_string(),
    );
    metric(
        "process_open_fds",
        "gauge",
        "Open file descriptors.",
        p.open_fds.to_string(),
    );
}

/// What `/proc/self/stat` and `/proc/self/fd` say.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ProcStat {
    pub cpu_secs: f64,
    pub rss_bytes: u64,
    pub threads: u64,
    pub open_fds: u64,
}

/// Clock ticks per second and page size on Linux (x86_64 and aarch64).
const CLK_TCK: f64 = 100.0;
const PAGE_BYTES: u64 = 4_096;
/// `/proc/self/stat` field numbers (1-based, `man proc`); fields from 3 on follow the
/// parenthesised command name.
const STAT_FIRST_AFTER_COMM: usize = 3;
const STAT_UTIME: usize = 14;
const STAT_STIME: usize = 15;
const STAT_THREADS: usize = 20;
const STAT_RSS: usize = 24;

impl ProcStat {
    pub fn read() -> Option<Self> {
        let stat = std::fs::read_to_string("/proc/self/stat").ok()?;
        let mut p = Self::parse(&stat)?;
        p.open_fds = std::fs::read_dir("/proc/self/fd")
            .map(|d| d.count() as u64)
            .unwrap_or(0);
        Some(p)
    }

    /// Parses `/proc/self/stat`.
    pub fn parse(stat: &str) -> Option<Self> {
        let rest = &stat[stat.rfind(')')? + 1..];
        let f: Vec<&str> = rest.split_whitespace().collect();
        let at = |n: usize| {
            f.get(n - STAT_FIRST_AFTER_COMM)
                .and_then(|v| v.parse::<u64>().ok())
        };
        Some(Self {
            cpu_secs: (at(STAT_UTIME)? + at(STAT_STIME)?) as f64 / CLK_TCK,
            threads: at(STAT_THREADS)?,
            rss_bytes: at(STAT_RSS)? * PAGE_BYTES,
            open_fds: 0,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_proc_stat() {
        let line = "4242 (westbound (srv)) S 1 4242 4242 0 -1 4194560 1234 0 0 0 150 50 0 0 20 0 7 0 1000 123456789 2500 18446744073709551615";
        let p = ProcStat::parse(line).unwrap();
        assert_eq!(p.cpu_secs, 2.0);
        assert_eq!(p.threads, 7);
        assert_eq!(p.rss_bytes, 2500 * PAGE_BYTES);
        assert!(ProcStat::parse("garbage").is_none());
    }

    #[test]
    fn ops_metrics_render() {
        let m = Metrics::default();
        Metrics::set(&m.server_draining, 1);
        m.set_replay_jobs("pending", 3);
        Metrics::set(&m.db_probe_micros, 1_500);
        let out = m.render("0.1.0", "dev");
        assert!(out.contains("wb_server_draining 1"), "{out}");
        assert!(
            out.contains("wb_replay_jobs{status=\"pending\"} 3"),
            "{out}"
        );
        assert!(out.contains("wb_db_probe_seconds 0.0015"), "{out}");
        assert!(
            out.contains("wb_log_events_total{level=\"error\"}"),
            "{out}"
        );
        assert!(out.contains("process_start_time_seconds"), "{out}");
        // Every sample line is `name{labels} value` with a numeric value.
        for l in out.lines().filter(|l| !l.starts_with('#')) {
            let v = l.rsplit(' ').next().unwrap();
            assert!(v.parse::<f64>().is_ok(), "{l}");
        }
    }
}
