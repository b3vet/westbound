//! Sector facts: the per-leg half of `src/core/leg_tracker.gd` (`LegTracker`) that loop
//! mode runs on the sector gantries (multiplayer handoff → Scoring in multiplayer:
//! "Sectors replace checkpoints. Crossing a sector gantry banks your chain and pays
//! sector bonuses (Clean, Pace, Threads, Heat). A clean sector restores a lost life.";
//! `src/run/run_loop.gd`, `Run._dispatch_crossing` in loop mode). The gantry crossing
//! itself is the caller's (the server reads it from the player's states,
//! `LoopMap::sector_crossed`); this keeps what the leg summary needs: time, hits, threads,
//! close passes and the Heat hold, with the same rules and the same float steps.
//!
//! The crossing sequence (the caller's, as `_dispatch_crossing` in loop mode):
//! `scoring.notify_checkpoint` (bank), then `award_bonus` for each earned bonus in
//! Clean, Pace, Threads, Heat order, then a life back when clean.

use super::events::Tag;
use super::params::LegsParams;

/// Absorbs float accumulation of dt in the heat hold (`LegTracker.TIME_EPS_S`).
pub const TIME_EPS_S: f64 = 1e-9;

/// The facts of one crossing (`LegTracker.Crossing`, the loop's part).
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct SectorCrossing {
    /// Sector length driven (from the previous gantry or the run's start), m.
    pub distance_m: f64,
    pub duration_s: f64,
    pub avg_speed_mps: f64,
    /// No hit during the sector.
    pub clean: bool,
    /// Average speed at or above the pace target.
    pub pace: bool,
    pub threads: i64,
    pub threads_bonus: bool,
    pub close_passes: i64,
    /// Longest continuous hold at or above the heat multiplier (s).
    pub heat_best_s: f64,
    pub heat: bool,
}

impl SectorCrossing {
    /// The earned bonuses in Clean, Pace, Threads, Heat order, with their base points.
    pub fn bonuses(&self, legs: &LegsParams) -> impl Iterator<Item = (Tag, i64)> {
        [
            (self.clean, Tag::Clean, legs.bonus_clean_points),
            (self.pace, Tag::Pace, legs.bonus_pace_points),
            (self.threads_bonus, Tag::Threads, legs.bonus_threads_points),
            (self.heat, Tag::Heat, legs.bonus_heat_points),
        ]
        .into_iter()
        .filter(|(on, _, _)| *on)
        .map(|(_, t, p)| (t, p))
    }
}

#[derive(Debug, Clone)]
pub struct SectorTracker {
    legs: LegsParams,
    pace_target_mps: f64,
    start_s: f64,
    time_s: f64,
    hit: bool,
    threads: i64,
    close_passes: i64,
    heat_run_s: f64,
    heat_best_s: f64,
}

impl SectorTracker {
    pub fn new(legs: &LegsParams) -> Self {
        Self {
            pace_target_mps: legs.pace_target_mps(),
            legs: legs.clone(),
            start_s: 0.0,
            time_s: 0.0,
            hit: false,
            threads: 0,
            close_passes: 0,
            heat_run_s: 0.0,
            heat_best_s: 0.0,
        }
    }

    /// A new run (or sector) starting at `start_s` (m, unwrapped).
    pub fn start(&mut self, start_s: f64) {
        self.start_s = start_s;
        self.time_s = 0.0;
        self.hit = false;
        self.threads = 0;
        self.close_passes = 0;
        self.heat_run_s = 0.0;
        self.heat_best_s = 0.0;
    }

    /// Time passes (`step`'s leg time).
    pub fn advance(&mut self, dt: f64) {
        self.time_s += dt;
    }

    /// Heat: held at or above the heat multiplier.
    pub fn observe_multiplier(&mut self, dt: f64, multiplier: f64) {
        if multiplier >= self.legs.bonus_heat_multiplier {
            self.heat_run_s += dt;
            if self.heat_run_s > self.heat_best_s {
                self.heat_best_s = self.heat_run_s;
            }
        } else {
            self.heat_run_s = 0.0;
        }
    }

    pub fn notify_hit(&mut self) {
        self.hit = true;
    }

    pub fn notify_thread(&mut self) {
        self.threads += 1;
    }

    pub fn notify_close_pass(&mut self) {
        self.close_passes += 1;
    }

    pub fn is_clean(&self) -> bool {
        !self.hit
    }

    pub fn threads(&self) -> i64 {
        self.threads
    }

    /// The gantry at `line_s` (m, unwrapped) was crossed: the sector's summary, and the
    /// next sector starts there.
    pub fn cross(&mut self, line_s: f64) -> SectorCrossing {
        let distance_m = line_s - self.start_s;
        let avg = if self.time_s > 0.0 {
            distance_m / self.time_s
        } else {
            0.0
        };
        let c = SectorCrossing {
            distance_m,
            duration_s: self.time_s,
            avg_speed_mps: avg,
            clean: !self.hit,
            pace: avg >= self.pace_target_mps,
            threads: self.threads,
            threads_bonus: self.threads >= self.legs.bonus_threads_min_count,
            close_passes: self.close_passes,
            heat_best_s: self.heat_best_s,
            heat: self.heat_best_s >= self.legs.bonus_heat_hold_s - TIME_EPS_S,
        };
        self.start(line_s);
        c
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scoring::params::ScoringParams;

    #[test]
    fn bonuses_follow_the_leg_rules() {
        let p = ScoringParams::builtin().unwrap();
        let mut t = SectorTracker::new(&p.legs);
        t.start(1_000.0);
        let dt = 0.05;
        // 60 s at 50 m/s (180 km/h > 170), 3 threads, heat held 15 s at 20 Hz.
        for k in 0..1_200 {
            t.advance(dt);
            t.observe_multiplier(dt, if k < 300 { 12.0 } else { 3.0 });
        }
        for _ in 0..3 {
            t.notify_thread();
        }
        let c = t.cross(1_000.0 + 3_000.0);
        assert!(c.clean && c.pace && c.threads_bonus && c.heat, "{c:?}");
        let kinds: Vec<Tag> = c.bonuses(&p.legs).map(|(k, _)| k).collect();
        assert_eq!(kinds, [Tag::Clean, Tag::Pace, Tag::Threads, Tag::Heat]);
        // The next sector starts at the gantry.
        t.notify_hit();
        t.advance(1.0);
        let c = t.cross(4_010.0);
        assert!(!c.clean && !c.pace && !c.heat && !c.threads_bonus);
        assert_eq!(c.distance_m, 10.0);
        assert_eq!(c.bonuses(&p.legs).count(), 0);
    }
}
