//! The admin stats view (N10.1): `GET /admin/stats` on the localhost-only metrics listener
//! (the same trust as `/metrics`: only the host, a `docker exec` or Coolify's terminal can
//! reach it; there is no admin HTTP auth). One JSON document for an operator: the process
//! (CPU over the window since the last call, memory), connections and bytes, the rooms'
//! tick times against the 5 ms budget, the netcode numbers (claims, offences, hits) and the
//! shadow collision aggregates (spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Players: "contacts
//! per hour, speeds, disagreement distribution go into the admin stats"), live since the
//! start and from `shadow_contacts` over the last day and week.
//!
//! `curl -s 127.0.0.1:9090/admin/stats | jq` (docs/SERVER.md → "Admin stats").

use std::sync::atomic::AtomicU64;
use std::sync::Mutex;
use std::time::Instant;

use axum::extract::State;
use axum::http::header;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Serialize;

use crate::app::AppState;
use crate::metrics::{Metrics, ProcessStats};
use crate::rooms::metrics::{RoomMetrics, SHADOW_DISAGREEMENT_M, SHADOW_SPEED_KMH};
use crate::rooms::plausibility::Offence;
use crate::rooms::shadow_log::{self, Summary};

const PCT: f64 = 100.0;
const BYTES_PER_MB: f64 = 1_048_576.0;
const SECS_PER_HOUR: f64 = 3_600.0;
const DAY_S: i64 = 86_400;
const WEEK_S: i64 = 7 * DAY_S;

/// The counters a window is measured against (the previous call's).
#[derive(Debug, Clone, Copy)]
struct Sample {
    at: Instant,
    cpu_s: f64,
    bytes_out: u64,
    bytes_in: u64,
    ticks: u64,
    tick_us: u64,
}

static LAST: Mutex<Option<Sample>> = Mutex::new(None);

#[derive(Debug, Serialize)]
pub struct AdminStats {
    pub version: &'static str,
    pub build: &'static str,
    pub process: ProcessView,
    pub gateway: GatewayView,
    pub rooms: RoomsView,
    pub netcode: NetcodeView,
    pub shadow: ShadowView,
}

#[derive(Debug, Serialize)]
pub struct ProcessView {
    pub uptime_s: f64,
    pub cpu_seconds: f64,
    /// Seconds since the previous `/admin/stats` (the window of the rates below; the
    /// whole uptime on the first call).
    pub window_s: f64,
    /// CPU over the window, % of one core (budget: ≤ 50 % for 20 full rooms).
    pub cpu_pct_of_core: f64,
    pub rss_mb: f64,
    pub rss_peak_mb: f64,
    pub threads: u64,
}

#[derive(Debug, Serialize)]
pub struct GatewayView {
    pub connections: u64,
    pub sessions: u64,
    pub bytes_out_per_s: f64,
    pub bytes_in_per_s: f64,
    /// Over the window, per live session (budget: ≤ 10 KB/s down per player).
    pub bytes_out_per_session_s: f64,
    pub bytes_in_per_session_s: f64,
}

#[derive(Debug, Serialize)]
pub struct RoomsView {
    pub rooms: u64,
    pub seats: u64,
    pub ticks: u64,
    /// Mean over the window; the quantiles are bucket bounds since the start.
    pub tick_mean_us: f64,
    pub tick_p50_le_us: u64,
    pub tick_p99_le_us: u64,
    pub tick_max_us: u64,
    /// Room ticks' share of one core over the window.
    pub tick_cpu_pct_of_core: f64,
}

#[derive(Debug, Serialize)]
pub struct NetcodeView {
    pub claims_accepted: u64,
    pub claims_rejected: u64,
    pub acceptance_pct: f64,
    pub offences: Vec<(&'static str, u64)>,
    pub hits_confirmed: u64,
    pub hits_refused: u64,
    /// Server-detected traffic contacts nobody reported, and per player-hour driven.
    pub hits_unreported: u64,
    pub unreported_per_player_hour: f64,
    pub placements: u64,
    pub crash_outs: u64,
}

#[derive(Debug, Serialize)]
pub struct ShadowView {
    /// Player-hours the shadow check covered (every player with a run in progress).
    pub player_hours: f64,
    pub contacts: u64,
    pub contacts_per_player_hour: f64,
    pub contact_ticks: u64,
    /// (upper bound, contacts): the last bound is `null` (above every bound).
    pub disagreement_m: Vec<(Option<f64>, u64)>,
    pub speed_kmh: Vec<(Option<f64>, u64)>,
    pub rows_written: u64,
    pub rows_dropped: u64,
    /// From `shadow_contacts` (survives restarts); `null` when the database failed.
    pub last_day: Option<Summary>,
    pub last_week: Option<Summary>,
}

fn buckets(bounds: &[f64], counts: &[u64]) -> Vec<(Option<f64>, u64)> {
    counts
        .iter()
        .enumerate()
        .map(|(i, &n)| (bounds.get(i).copied(), n))
        .collect()
}

/// The stats now; `last_day` / `last_week` are filled by the handler.
pub fn collect(m: &Metrics, r: &RoomMetrics, tick_rate_hz: f64) -> AdminStats {
    let g = |c: &AtomicU64| Metrics::get(c);
    let p = ProcessStats::read();
    let now = Sample {
        at: Instant::now(),
        cpu_s: p.cpu_seconds,
        bytes_out: g(&m.ws_bytes_out),
        bytes_in: g(&m.ws_bytes_in),
        ticks: RoomMetrics::get(&r.ticks),
        tick_us: RoomMetrics::get(&r.tick_us_sum),
    };
    let prev = {
        let mut last = LAST.lock().unwrap_or_else(|e| e.into_inner());
        last.replace(now)
    };
    let (window, d_cpu, d_out, d_in, d_ticks, d_us) = match prev {
        Some(s) => (
            now.at.duration_since(s.at).as_secs_f64(),
            now.cpu_s - s.cpu_s,
            now.bytes_out - s.bytes_out.min(now.bytes_out),
            now.bytes_in - s.bytes_in.min(now.bytes_in),
            now.ticks - s.ticks.min(now.ticks),
            now.tick_us - s.tick_us.min(now.tick_us),
        ),
        None => (
            p.uptime_s,
            now.cpu_s,
            now.bytes_out,
            now.bytes_in,
            now.ticks,
            now.tick_us,
        ),
    };
    let w = window.max(1e-3);
    let sessions = g(&m.ws_sessions);
    let per_session = |bytes: u64| bytes as f64 / w / sessions.max(1) as f64;
    let accepted = RoomMetrics::get(&r.claims_accepted);
    let rejected = r.claims_rejected_total();
    let player_hours =
        RoomMetrics::get(&r.shadow_player_ticks) as f64 / tick_rate_hz.max(1.0) / SECS_PER_HOUR;
    let per_hour = |n: u64| {
        if player_hours > 0.0 {
            n as f64 / player_hours
        } else {
            0.0
        }
    };
    AdminStats {
        version: crate::VERSION,
        build: crate::BUILD,
        process: ProcessView {
            uptime_s: p.uptime_s,
            cpu_seconds: p.cpu_seconds,
            window_s: window,
            cpu_pct_of_core: d_cpu / w * PCT,
            rss_mb: p.rss_bytes as f64 / BYTES_PER_MB,
            rss_peak_mb: p.rss_peak_bytes as f64 / BYTES_PER_MB,
            threads: p.threads,
        },
        gateway: GatewayView {
            connections: g(&m.ws_connections),
            sessions,
            bytes_out_per_s: d_out as f64 / w,
            bytes_in_per_s: d_in as f64 / w,
            bytes_out_per_session_s: per_session(d_out),
            bytes_in_per_session_s: per_session(d_in),
        },
        rooms: RoomsView {
            rooms: RoomMetrics::get(&r.rooms),
            seats: RoomMetrics::get(&r.seats),
            ticks: now.ticks,
            tick_mean_us: d_us as f64 / d_ticks.max(1) as f64,
            tick_p50_le_us: r.tick_quantile_us(0.5),
            tick_p99_le_us: r.tick_quantile_us(0.99),
            tick_max_us: RoomMetrics::get(&r.tick_us_max),
            tick_cpu_pct_of_core: d_us as f64 / 1e6 / w * PCT,
        },
        netcode: NetcodeView {
            claims_accepted: accepted,
            claims_rejected: rejected,
            acceptance_pct: PCT * accepted as f64 / (accepted + rejected).max(1) as f64,
            offences: Offence::ALL
                .iter()
                .map(|o| (o.label(), r.offences(*o)))
                .collect(),
            hits_confirmed: RoomMetrics::get(&r.hits_confirmed),
            hits_refused: RoomMetrics::get(&r.hits_refused),
            hits_unreported: RoomMetrics::get(&r.hits_unreported),
            unreported_per_player_hour: per_hour(RoomMetrics::get(&r.hits_unreported)),
            placements: RoomMetrics::get(&r.placements),
            crash_outs: RoomMetrics::get(&r.crash_outs),
        },
        shadow: ShadowView {
            player_hours,
            contacts: RoomMetrics::get(&r.shadow_contacts),
            contacts_per_player_hour: per_hour(RoomMetrics::get(&r.shadow_contacts)),
            contact_ticks: RoomMetrics::get(&r.shadow_contact_ticks),
            disagreement_m: buckets(&SHADOW_DISAGREEMENT_M, &r.shadow_disagreement()),
            speed_kmh: buckets(&SHADOW_SPEED_KMH, &r.shadow_speed()),
            rows_written: RoomMetrics::get(&r.shadow_rows_written),
            rows_dropped: RoomMetrics::get(&r.shadow_rows_dropped),
            last_day: None,
            last_week: None,
        },
    }
}

/// `GET /admin/stats` (metrics listener).
pub async fn handler(State(state): State<AppState>) -> Response {
    let rate = f64::from(state.rooms.params().tick_rate_hz);
    let mut stats = collect(&state.metrics, state.rooms.metrics(), rate);
    let now = crate::rooms::unix_now_ms() / 1_000;
    stats.shadow.last_day = shadow_log::summary(&state.db, now - DAY_S).await.ok();
    stats.shadow.last_week = shadow_log::summary(&state.db, now - WEEK_S).await.ok();
    ([(header::CACHE_CONTROL, "no-store")], Json(stats)).into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn process_stats_come_from_proc() {
        let p = ProcessStats::read();
        if cfg!(target_os = "linux") {
            assert!(p.rss_bytes > 1_000_000, "{p:?}");
            assert!(p.rss_peak_bytes >= p.rss_bytes);
            assert!(p.threads >= 1);
            assert!(p.uptime_s >= 0.0 && p.uptime_s < 86_400.0 * 365.0);
        }
    }

    #[test]
    fn the_view_reads_the_counters_and_windows_the_rates() {
        let m = Metrics::default();
        let r = RoomMetrics::default();
        Metrics::add(&m.ws_sessions, 4);
        r.observe_tick(std::time::Duration::from_micros(400));
        r.observe_shadow_contact(4, 40.0, 0.3);
        RoomMetrics::add(&r.shadow_player_ticks, 72_000);
        RoomMetrics::inc(&r.claims_accepted);
        let s = collect(&m, &r, 20.0);
        assert_eq!(s.gateway.sessions, 4);
        assert_eq!(s.rooms.ticks, 1);
        assert_eq!(s.rooms.tick_p99_le_us, 500);
        assert!((s.shadow.player_hours - 1.0).abs() < 1e-9);
        assert!((s.shadow.contacts_per_player_hour - 1.0).abs() < 1e-9);
        assert_eq!(s.shadow.disagreement_m[2], (Some(0.5), 1));
        assert_eq!(s.shadow.disagreement_m.last(), Some(&(None, 0)));
        assert_eq!(s.netcode.acceptance_pct, 100.0);
        // The second call's window is the time since the first.
        Metrics::add(&m.ws_bytes_out, 1_000);
        let s2 = collect(&m, &r, 20.0);
        assert!(s2.process.window_s < 5.0);
        assert!(s2.gateway.bytes_out_per_s > 0.0);
        let json = serde_json::to_value(&s2).unwrap();
        assert!(json["shadow"]["disagreement_m"].is_array());
        assert!(json["process"]["rss_mb"].as_f64().is_some());
    }
}
