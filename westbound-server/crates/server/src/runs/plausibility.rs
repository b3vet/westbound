//! Plausibility checks on every single-player submission. Spec:
//! WESTBOUND_MULTIPLAYER_HANDOFF.md → "Leaderboards" → single-player runs, step 2:
//! score per minute below a cap; distance consistent with duration and top speed; stats
//! consistent with the score; the build still supported; the Daily Drive seed matches the
//! date. Plus: the run's date within the submission window.
//!
//! Every threshold is in `[runs]` (`config::RunsConfig`). The checks bound what the game
//! can produce; they do not replay it (the replay verifier, N8, does). A failed check
//! stores the run as `rejected` with the reason code below.

use super::{daily_seed, RunSubmission};
use crate::clock::{parse_date_days, SECS_PER_DAY};
use crate::config::RunsConfig;
use crate::leaderboards::mode;

const KMH_PER_MPS: f64 = 3.6;
const SECS_PER_MINUTE: f64 = 60.0;
const PERCENT: f64 = 100.0;
/// Each event's points are rounded on their own (scoring: round half away from zero).
const ROUNDING_PER_EVENT: f64 = 0.5;
/// Float noise allowed on the multiplier and time comparisons.
const EPSILON: f64 = 1e-6;

/// Why a run was rejected (`runs.reject_reason`, the API's `reason`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rejection {
    /// The client build is below `runs.min_build` or not in `runs.supported_builds`.
    BuildUnsupported,
    /// `date` is outside the submission window around now.
    DateWindow,
    /// A Daily Drive seed that is not the date's seed.
    DailySeed,
    /// Longer than `runs.max_duration_s`, or times inside the run exceed its duration.
    Duration,
    /// Top speed above `runs.max_top_speed_kmh`.
    TopSpeed,
    /// Farther than top speed × duration allows, or legs without the distance.
    Distance,
    /// Score per minute above `runs.max_score_per_minute`.
    ScoreRate,
    /// Stats inconsistent with each other or with the score.
    Stats,
}

impl Rejection {
    pub fn code(self) -> &'static str {
        match self {
            Rejection::BuildUnsupported => "build_unsupported",
            Rejection::DateWindow => "date_window",
            Rejection::DailySeed => "daily_seed",
            Rejection::Duration => "duration",
            Rejection::TopSpeed => "top_speed",
            Rejection::Distance => "distance",
            Rejection::ScoreRate => "score_rate",
            Rejection::Stats => "stats",
        }
    }
}

/// Whether a run dated `date` (UTC) may be submitted at `now`: from `date_early_secs`
/// before the day starts until `date_late_secs` after it ends.
pub fn date_in_window(cfg: &RunsConfig, date: &str, now: i64) -> bool {
    let Some(day) = parse_date_days(date) else {
        return false;
    };
    let start = day.saturating_mul(SECS_PER_DAY);
    let end = start.saturating_add(SECS_PER_DAY);
    let early = i64::try_from(cfg.date_early_secs).unwrap_or(i64::MAX);
    let late = i64::try_from(cfg.date_late_secs).unwrap_or(i64::MAX);
    now >= start.saturating_sub(early) && now < end.saturating_add(late)
}

/// Runs every check in order; the first failure is the reason.
pub fn check(cfg: &RunsConfig, r: &RunSubmission, now: i64) -> Result<(), Rejection> {
    if !cfg.build_supported(r.client_build) {
        return Err(Rejection::BuildUnsupported);
    }
    if !date_in_window(cfg, &r.date, now) {
        return Err(Rejection::DateWindow);
    }
    if r.mode == mode::DAILY && daily_seed::daily_seed_for_date(&r.date) != Some(r.seed) {
        return Err(Rejection::DailySeed);
    }
    let duration = r.duration_s;
    if duration > cfg.max_duration_s
        || r.night_time_s > duration + EPSILON
        || r.journey_time_s > duration + EPSILON
    {
        return Err(Rejection::Duration);
    }
    if r.top_speed_kmh > cfg.max_top_speed_kmh {
        return Err(Rejection::TopSpeed);
    }
    check_distance(cfg, r)?;
    let score = r.score as f64;
    if score * SECS_PER_MINUTE / duration.max(cfg.min_duration_s) > cfg.max_score_per_minute {
        return Err(Rejection::ScoreRate);
    }
    check_stats(cfg, r)
}

/// Distance against top speed × duration, and against the legs completed.
fn check_distance(cfg: &RunsConfig, r: &RunSubmission) -> Result<(), Rejection> {
    let slack = 1.0 + cfg.distance_slack_pct / PERCENT;
    let reachable = r.top_speed_kmh / KMH_PER_MPS * r.duration_s * slack + cfg.distance_slack_m;
    if r.distance_m > reachable || r.journey_distance_m > r.distance_m + EPSILON {
        return Err(Rejection::Distance);
    }
    if f64::from(r.legs_completed) * cfg.leg_min_length_m > r.distance_m + cfg.distance_slack_m {
        return Err(Rejection::Distance);
    }
    Ok(())
}

/// The stats against each other and the score: the multiplier can only have grown by the
/// events' gains; no event pays more than its base × that multiplier × the top speed
/// factor × the night factor; bonuses need legs, the journey bonus the coast.
fn check_stats(cfg: &RunsConfig, r: &RunSubmission) -> Result<(), Rejection> {
    let stats = || Err(Rejection::Stats);
    if r.close_passes > r.passes || u64::from(r.threads) * 2 > u64::from(r.passes) {
        return stats();
    }
    if r.coast_reached && r.legs_completed < cfg.legs_to_coast {
        return stats();
    }
    if r.journey_complete && !r.coast_reached {
        return stats();
    }
    if u64::from(r.hits) > u64::from(cfg.lives) + u64::from(r.legs_completed) {
        return stats();
    }
    let plain = f64::from(r.passes - r.close_passes);
    let close = f64::from(r.close_passes);
    let threads = f64::from(r.threads);
    let cuts = f64::from(r.cuts);
    let max_multiplier = cfg.multiplier_start
        + plain * cfg.pass_multiplier_gain
        + close * cfg.close_pass_multiplier_gain
        + threads * cfg.thread_multiplier_gain
        + cuts * cfg.cut_multiplier_gain;
    if r.best_multiplier < cfg.multiplier_start - EPSILON
        || r.best_multiplier > max_multiplier + EPSILON
    {
        return stats();
    }
    let base = plain * cfg.pass_points
        + close * cfg.close_pass_points
        + threads * cfg.thread_points
        + cuts * cfg.cut_points;
    let events = plain + close + threads + cuts;
    let event_points = base * r.best_multiplier * cfg.speed_factor_max * cfg.night_factor
        + events * ROUNDING_PER_EVENT;
    let journey = if r.coast_reached {
        cfg.journey_bonus_points
    } else {
        0.0
    };
    // The leg in progress can have paid its objective already, hence legs + 1.
    let bonuses = ((f64::from(r.legs_completed) + 1.0) * cfg.leg_bonus_max_points + journey)
        * cfg.night_factor;
    let slack = 1.0 + cfg.score_slack_pct / PERCENT;
    if r.score as f64 > (event_points + bonuses) * slack
        || r.best_chain as f64 > event_points * slack
    {
        return stats();
    }
    Ok(())
}
