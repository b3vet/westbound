//! Room metrics for `/metrics` (N5.1): live rooms and seats, tick cost (a fixed-bucket
//! histogram, so the p99 against the spec's 5 ms can be read off it), plausibility offences
//! and dropped room messages. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Resource budget
//! ("Room tick time: p99 under 5 ms per 20 Hz tick").

use std::fmt::Write as _;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use super::plausibility::Offence;
use super::scoring::claims::Reject;

/// Upper bounds (µs) of the tick-time buckets; the last bucket is everything above.
pub const TICK_BUCKETS_US: [u64; 17] = [
    25, 50, 100, 200, 300, 500, 750, 1_000, 1_500, 2_000, 3_000, 4_000, 5_000, 10_000, 20_000,
    50_000, 100_000,
];

/// Why a message for a room never reached it or was not taken.
pub const DROP_REASONS: [&str; 6] = [
    "queue_full",
    "out_of_order",
    "stale",
    "future",
    "in_flight",
    "not_seated",
];

#[derive(Debug, Default)]
pub struct RoomMetrics {
    /// Live room tasks.
    pub rooms: AtomicU64,
    pub rooms_created: AtomicU64,
    /// Occupied seats (held seats included).
    pub seats: AtomicU64,
    pub joins: AtomicU64,
    pub reconnects: AtomicU64,
    pub seat_timeouts: AtomicU64,
    pub placements: AtomicU64,
    pub crash_outs: AtomicU64,
    pub ticks: AtomicU64,
    pub tick_us_sum: AtomicU64,
    pub tick_us_max: AtomicU64,
    tick_buckets: [AtomicU64; TICK_BUCKETS_US.len() + 1],
    offences: [AtomicU64; Offence::ALL.len()],
    drops: [AtomicU64; DROP_REASONS.len()],
    // Scoring (N6.1).
    pub claims_accepted: AtomicU64,
    claims_rejected: [AtomicU64; Reject::ALL.len()],
    /// Claims paid after their tick was scored (they arrived after the official lag).
    pub scoring_late: AtomicU64,
    pub score_syncs: AtomicU64,
    pub trains: AtomicU64,
    /// Reported traffic hits the server confirmed (the car reacts) or could not.
    pub hits_confirmed: AtomicU64,
    pub hits_refused: AtomicU64,
    /// Server-detected contacts the client never reported (the run goes unverified).
    pub hits_unreported: AtomicU64,
    /// Wall time spent in scoring (µs, summed over room ticks).
    pub scoring_us_sum: AtomicU64,
    /// Multiplayer runs handed to the boards.
    pub runs_recorded: AtomicU64,
}

impl RoomMetrics {
    pub fn inc(c: &AtomicU64) {
        c.fetch_add(1, Ordering::Relaxed);
    }

    pub fn dec(c: &AtomicU64) {
        c.fetch_sub(1, Ordering::Relaxed);
    }

    pub fn get(c: &AtomicU64) -> u64 {
        c.load(Ordering::Relaxed)
    }

    /// One room tick's wall time.
    pub fn observe_tick(&self, d: Duration) {
        let us = u64::try_from(d.as_micros()).unwrap_or(u64::MAX);
        self.ticks.fetch_add(1, Ordering::Relaxed);
        self.tick_us_sum.fetch_add(us, Ordering::Relaxed);
        self.tick_us_max.fetch_max(us, Ordering::Relaxed);
        let i = TICK_BUCKETS_US
            .iter()
            .position(|&b| us <= b)
            .unwrap_or(TICK_BUCKETS_US.len());
        self.tick_buckets[i].fetch_add(1, Ordering::Relaxed);
    }

    /// Ticks per bucket (the last one is above every bound).
    pub fn tick_histogram(&self) -> [u64; TICK_BUCKETS_US.len() + 1] {
        std::array::from_fn(|i| self.tick_buckets[i].load(Ordering::Relaxed))
    }

    /// The smallest bucket bound (µs) at or below which `q` (0..1) of the ticks fall;
    /// `u64::MAX` when it is in the overflow bucket, 0 without ticks.
    pub fn tick_quantile_us(&self, q: f64) -> u64 {
        let h = self.tick_histogram();
        let total: u64 = h.iter().sum();
        if total == 0 {
            return 0;
        }
        let need = (q * total as f64).ceil() as u64;
        let mut seen = 0;
        for (i, n) in h.iter().enumerate() {
            seen += n;
            if seen >= need {
                return TICK_BUCKETS_US.get(i).copied().unwrap_or(u64::MAX);
            }
        }
        u64::MAX
    }

    pub fn count_offence(&self, o: Offence) {
        self.offences[o as usize].fetch_add(1, Ordering::Relaxed);
    }

    pub fn offences(&self, o: Offence) -> u64 {
        self.offences[o as usize].load(Ordering::Relaxed)
    }

    pub fn count_claim_rejected(&self, r: Reject) {
        self.claims_rejected[r as usize].fetch_add(1, Ordering::Relaxed);
    }

    pub fn claims_rejected(&self, r: Reject) -> u64 {
        self.claims_rejected[r as usize].load(Ordering::Relaxed)
    }

    /// Rejected claims of every reason but `no_run` (claims in flight after a run ended).
    pub fn claims_rejected_total(&self) -> u64 {
        Reject::ALL
            .iter()
            .filter(|r| **r != Reject::NoRun)
            .map(|r| self.claims_rejected(*r))
            .sum()
    }

    /// Counts a drop by its `DROP_REASONS` label.
    pub fn count_drop(&self, reason: &str) {
        if let Some(i) = DROP_REASONS.iter().position(|r| *r == reason) {
            self.drops[i].fetch_add(1, Ordering::Relaxed);
        }
    }

    pub fn drops(&self, reason: &str) -> u64 {
        DROP_REASONS
            .iter()
            .position(|r| *r == reason)
            .map_or(0, |i| self.drops[i].load(Ordering::Relaxed))
    }

    /// Prometheus text, appended to the server's.
    pub fn render(&self, out: &mut String) {
        let g = |c: &AtomicU64| c.load(Ordering::Relaxed);
        let mut metric = |name: &str, kind: &str, help: &str, value: u64| {
            let _ = writeln!(out, "# HELP {name} {help}");
            let _ = writeln!(out, "# TYPE {name} {kind}");
            let _ = writeln!(out, "{name} {value}");
        };
        metric("wb_rooms", "gauge", "Live rooms.", g(&self.rooms));
        metric(
            "wb_rooms_created_total",
            "counter",
            "Rooms created.",
            g(&self.rooms_created),
        );
        metric(
            "wb_room_seats",
            "gauge",
            "Occupied room seats (held seats included).",
            g(&self.seats),
        );
        metric(
            "wb_room_joins_total",
            "counter",
            "New room seats.",
            g(&self.joins),
        );
        metric(
            "wb_room_reconnects_total",
            "counter",
            "Held or replaced seats taken back by their player.",
            g(&self.reconnects),
        );
        metric(
            "wb_room_seat_timeouts_total",
            "counter",
            "Held seats released after the seat hold.",
            g(&self.seat_timeouts),
        );
        metric(
            "wb_room_placements_total",
            "counter",
            "Server placements (spawns, respawns, rejoins, reconnects).",
            g(&self.placements),
        );
        metric(
            "wb_room_crash_outs_total",
            "counter",
            "Runs ended by a crash-out.",
            g(&self.crash_outs),
        );
        let _ = writeln!(
            out,
            "# HELP wb_room_tick_seconds Wall time of one room tick."
        );
        let _ = writeln!(out, "# TYPE wb_room_tick_seconds histogram");
        let h = self.tick_histogram();
        let mut cum = 0;
        for (i, bound) in TICK_BUCKETS_US.iter().enumerate() {
            cum += h[i];
            let _ = writeln!(
                out,
                "wb_room_tick_seconds_bucket{{le=\"{}\"}} {cum}",
                *bound as f64 / 1e6
            );
        }
        cum += h[TICK_BUCKETS_US.len()];
        let _ = writeln!(out, "wb_room_tick_seconds_bucket{{le=\"+Inf\"}} {cum}");
        let _ = writeln!(
            out,
            "wb_room_tick_seconds_sum {}",
            g(&self.tick_us_sum) as f64 / 1e6
        );
        let _ = writeln!(out, "wb_room_tick_seconds_count {}", g(&self.ticks));
        let _ = writeln!(
            out,
            "# HELP wb_room_offences_total Implausible player states by kind."
        );
        let _ = writeln!(out, "# TYPE wb_room_offences_total counter");
        for o in Offence::ALL {
            let _ = writeln!(
                out,
                "wb_room_offences_total{{kind=\"{}\"}} {}",
                o.label(),
                self.offences(o)
            );
        }
        let _ = writeln!(
            out,
            "# HELP wb_room_claims_total Score claims by verdict (rejections by reason)."
        );
        let _ = writeln!(out, "# TYPE wb_room_claims_total counter");
        let _ = writeln!(
            out,
            "wb_room_claims_total{{verdict=\"accepted\"}} {}",
            g(&self.claims_accepted)
        );
        for r in Reject::ALL {
            let _ = writeln!(
                out,
                "wb_room_claims_total{{verdict=\"rejected\",reason=\"{}\"}} {}",
                r.label(),
                self.claims_rejected(r)
            );
        }
        let mut metric = |name: &str, kind: &str, help: &str, value: u64| {
            let _ = writeln!(out, "# HELP {name} {help}");
            let _ = writeln!(out, "# TYPE {name} {kind}");
            let _ = writeln!(out, "{name} {value}");
        };
        metric(
            "wb_room_claims_late_total",
            "counter",
            "Accepted claims paid after their tick was scored.",
            g(&self.scoring_late),
        );
        metric(
            "wb_room_score_syncs_total",
            "counter",
            "ScoreSync messages sent.",
            g(&self.score_syncs),
        );
        metric(
            "wb_room_trains_total",
            "counter",
            "Crew train links paid.",
            g(&self.trains),
        );
        metric(
            "wb_room_hits_confirmed_total",
            "counter",
            "Reported traffic hits the server confirmed (the car reacts).",
            g(&self.hits_confirmed),
        );
        metric(
            "wb_room_hits_refused_total",
            "counter",
            "Reported traffic hits the server saw no contact for.",
            g(&self.hits_refused),
        );
        metric(
            "wb_room_hits_unreported_total",
            "counter",
            "Server-detected contacts the client did not report (run unverified).",
            g(&self.hits_unreported),
        );
        metric(
            "wb_room_runs_recorded_total",
            "counter",
            "Multiplayer runs handed to the leaderboards.",
            g(&self.runs_recorded),
        );
        let _ = writeln!(
            out,
            "# HELP wb_room_scoring_seconds_total Wall time spent in room scoring."
        );
        let _ = writeln!(out, "# TYPE wb_room_scoring_seconds_total counter");
        let _ = writeln!(
            out,
            "wb_room_scoring_seconds_total {}",
            g(&self.scoring_us_sum) as f64 / 1e6
        );
        let _ = writeln!(
            out,
            "# HELP wb_room_dropped_total Room messages dropped, by reason."
        );
        let _ = writeln!(out, "# TYPE wb_room_dropped_total counter");
        for (i, r) in DROP_REASONS.iter().enumerate() {
            let _ = writeln!(
                out,
                "wb_room_dropped_total{{reason=\"{r}\"}} {}",
                g(&self.drops[i])
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tick_quantiles_read_off_the_buckets() {
        let m = RoomMetrics::default();
        assert_eq!(m.tick_quantile_us(0.99), 0);
        for _ in 0..98 {
            m.observe_tick(Duration::from_micros(30));
        }
        m.observe_tick(Duration::from_micros(700));
        m.observe_tick(Duration::from_millis(3));
        assert_eq!(m.tick_quantile_us(0.5), 50);
        assert_eq!(m.tick_quantile_us(0.99), 750);
        assert_eq!(m.tick_quantile_us(1.0), 3_000);
        assert_eq!(RoomMetrics::get(&m.tick_us_max), 3_000);
        let mut out = String::new();
        m.render(&mut out);
        assert!(out.contains("wb_room_tick_seconds_count 100"));
        assert!(out.contains("wb_room_tick_seconds_bucket{le=\"+Inf\"} 100"));
        assert!(out.contains("wb_room_offences_total{kind=\"teleport\"} 0"));
    }
}
