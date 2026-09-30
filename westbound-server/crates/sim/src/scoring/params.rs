//! Scoring parameters, compiled in with `include_str!`: `data/scoring_params.json`,
//! **exported from the Godot tuning** by `tools/server_data/export_sim_data.gd`
//! (`--only=scoring`; never edited by hand): `ScoringTuning` (the spec's units: km/h,
//! percent, converted exactly as the GDScript converts them), the `LegsTuning` sector
//! bonuses, `LivesTuning` (lives, the ghost period, the hull inset), the `SunTuning`
//! nudges (the parity traces write them), the default player body and the tick rate.
//! Every float is written readable and again as its exact IEEE-754 bits under `exact`;
//! the loader applies the bits and checks both agree (as `traffic::params` does).

use serde::Deserialize;
use serde_json::Value;

use crate::traffic::gd::clampf;

pub const SCORING_PARAMS_JSON: &str = include_str!("../../data/scoring_params.json");
pub const SCORING_FORMAT_VERSION: u32 = 1;

/// `Units.KMH_PER_MPS`.
pub const KMH_PER_MPS: f64 = 3.6;
/// `Units.PCT`.
pub const PCT: f64 = 100.0;

/// `ScoringTuning` (`src/core/tuning/scoring_tuning.gd`), field for field.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct ScoringTuning {
    pub speed_factor_min_kmh: f64,
    pub speed_factor_max_kmh: f64,
    pub speed_factor_at_min: f64,
    pub speed_factor_at_max: f64,
    pub night_factor: f64,
    pub multiplier_start: f64,
    pub multiplier_decay_per_s: f64,
    pub decay_term_min_kmh: f64,
    pub decay_term_max_kmh: f64,
    pub decay_term_at_min: f64,
    pub decay_term_at_max: f64,
    pub boost_decay_factor: f64,
    pub min_speed_kmh: f64,
    pub below_min_drain_per_s: f64,
    pub hesitation_timeout_s: f64,
    pub min_speed_grace_until_reached: bool,
    pub min_speed_grace_after_hit_s: f64,
    pub pass_points: i64,
    pub pass_multiplier_gain: f64,
    pub pass_lateral_window_m: f64,
    pub close_pass_points: i64,
    pub close_pass_multiplier_gain: f64,
    pub close_pass_clearance_m: f64,
    pub cut_points: i64,
    pub cut_multiplier_gain: f64,
    pub cut_min_speed_kmh: f64,
    pub cut_traffic_window_m: f64,
    pub cut_per_car_cooldown_s: f64,
    pub thread_points: i64,
    pub thread_multiplier_gain: f64,
    pub thread_window_s: f64,
    pub thread_clearance_m: f64,
    pub slipstream_distance_m: f64,
    pub slipstream_min_speed_kmh: f64,
    pub shoulder_decay_factor: f64,
    pub shoulder_penalty_after_s: f64,
    pub shoulder_penalty_block_s: f64,
    pub boost_fill_slipstream_pct_per_s: f64,
    pub boost_fill_close_pass_pct: f64,
    pub boost_fill_thread_pct: f64,
}

/// Godot's `inverse_lerp`.
#[inline]
fn inverse_lerp(from: f64, to: f64, x: f64) -> f64 {
    (x - from) / (to - from)
}

/// Godot's `lerpf`.
#[inline]
fn lerpf(from: f64, to: f64, t: f64) -> f64 {
    from + (to - from) * t
}

/// `Units.kmh_to_mps`.
#[inline]
pub fn kmh_to_mps(kmh: f64) -> f64 {
    kmh / KMH_PER_MPS
}

/// `Units.pct_to_frac`.
#[inline]
pub fn pct_to_frac(pct: f64) -> f64 {
    pct / PCT
}

impl ScoringTuning {
    pub fn min_speed_mps(&self) -> f64 {
        kmh_to_mps(self.min_speed_kmh)
    }

    pub fn cut_min_speed_mps(&self) -> f64 {
        kmh_to_mps(self.cut_min_speed_kmh)
    }

    pub fn slipstream_min_speed_mps(&self) -> f64 {
        kmh_to_mps(self.slipstream_min_speed_kmh)
    }

    /// Speed factor for a speed in m/s (1.0 at 100 km/h → 2.0 at 250 km/h, clamped).
    pub fn speed_factor(&self, speed_mps: f64) -> f64 {
        let t = inverse_lerp(
            self.speed_factor_min_kmh,
            self.speed_factor_max_kmh,
            speed_mps * KMH_PER_MPS,
        );
        lerpf(
            self.speed_factor_at_min,
            self.speed_factor_at_max,
            clampf(t, 0.0, 1.0),
        )
    }

    /// Multiplier decay speed term (1.0 at 100 km/h → 0.1 at 250 km/h, clamped).
    pub fn decay_term(&self, speed_mps: f64) -> f64 {
        let t = inverse_lerp(
            self.decay_term_min_kmh,
            self.decay_term_max_kmh,
            speed_mps * KMH_PER_MPS,
        );
        lerpf(
            self.decay_term_at_min,
            self.decay_term_at_max,
            clampf(t, 0.0, 1.0),
        )
    }
}

/// The `LegsTuning` values sectors use (loop mode: "Sectors replace checkpoints").
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct LegsParams {
    pub pace_target_kmh: f64,
    pub bonus_threads_min_count: i64,
    pub bonus_heat_multiplier: f64,
    pub bonus_heat_hold_s: f64,
    pub bonus_clean_points: i64,
    pub bonus_pace_points: i64,
    pub bonus_threads_points: i64,
    pub bonus_heat_points: i64,
}

impl LegsParams {
    pub fn pace_target_mps(&self) -> f64 {
        kmh_to_mps(self.pace_target_kmh)
    }
}

/// `LivesTuning` values scoring and the room use.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct LivesParams {
    pub lives: i64,
    pub ghost_period_s: f64,
    pub clean_leg_restore: bool,
    pub collision_inset_m: f64,
}

/// `SunTuning`'s play nudges (single-player only; the rule set still writes them).
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct SunParams {
    pub thread_nudge_pct: f64,
    pub close_pass_nudge_count: i64,
    pub close_pass_nudge_window_s: f64,
    pub close_pass_nudge_pct: f64,
}

/// The default player body (`TrafficTuning.player_*`) and the slot count scoring sizes
/// its per-car memory with (`TrafficTuning.max_active_vehicles`).
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct BodyParams {
    pub player_length_m: f64,
    pub player_width_m: f64,
    pub max_active_vehicles: usize,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct NetParams {
    pub tick_rate_hz: f64,
}

/// The whole export.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct ScoringParams {
    pub format_version: u32,
    pub scoring: ScoringTuning,
    pub legs: LegsParams,
    pub lives: LivesParams,
    pub sun: SunParams,
    pub body: BodyParams,
    pub net: NetParams,
}

impl ScoringParams {
    /// The compiled-in export.
    pub fn builtin() -> Result<Self, String> {
        Self::from_json(SCORING_PARAMS_JSON)
    }

    pub fn from_json(text: &str) -> Result<Self, String> {
        let mut root: Value =
            serde_json::from_str(text).map_err(|e| format!("scoring params: {e}"))?;
        apply_exact(&mut root)?;
        let p: ScoringParams =
            serde_json::from_value(root).map_err(|e| format!("scoring params: {e}"))?;
        if p.format_version != SCORING_FORMAT_VERSION {
            return Err(format!(
                "scoring params: format_version {} (this build reads {SCORING_FORMAT_VERSION})",
                p.format_version
            ));
        }
        if p.body.max_active_vehicles == 0 || p.sun.close_pass_nudge_count < 0 {
            return Err("scoring params: bad body or sun values".into());
        }
        Ok(p)
    }

    /// Seconds per tick at the exported rate.
    pub fn tick_dt(&self) -> f64 {
        1.0 / self.net.tick_rate_hz
    }
}

/// Replaces every number named in `root["exact"]` (dotted paths → hex bits) with its
/// exact value, after checking the readable number agrees (relative 1e-12).
fn apply_exact(root: &mut Value) -> Result<(), String> {
    let Some(Value::Object(exact)) = root.as_object_mut().and_then(|o| o.remove("exact")) else {
        return Err("scoring params: no `exact` map".into());
    };
    for (path, bits) in exact {
        let bits = bits
            .as_str()
            .and_then(|b| u64::from_str_radix(b, 16).ok())
            .ok_or_else(|| format!("scoring params: bad bits at {path}"))?;
        let x = f64::from_bits(bits);
        let slot =
            lookup(root, &path).ok_or_else(|| format!("scoring params: no value at {path}"))?;
        let shown = slot
            .as_f64()
            .ok_or_else(|| format!("scoring params: {path} is not a number"))?;
        if (shown - x).abs() > 1e-12 * x.abs().max(1.0) {
            return Err(format!(
                "scoring params: {path} reads {shown} but its exact bits are {x}"
            ));
        }
        *slot = serde_json::Number::from_f64(x)
            .map(Value::Number)
            .ok_or_else(|| format!("scoring params: {path} is not finite"))?;
    }
    Ok(())
}

fn lookup<'a>(root: &'a mut Value, path: &str) -> Option<&'a mut Value> {
    let mut v = root;
    for key in path.split('.') {
        v = match v {
            Value::Object(o) => o.get_mut(key)?,
            Value::Array(a) => a.get_mut(key.parse::<usize>().ok()?)?,
            _ => return None,
        };
    }
    Some(v)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builtin_parses_with_the_spec_numbers() {
        let p = ScoringParams::builtin().expect("exported scoring params");
        let s = &p.scoring;
        assert_eq!(s.pass_points, 10);
        assert_eq!(s.close_pass_points, 30);
        assert_eq!(s.thread_points, 50);
        assert_eq!(s.cut_points, 15);
        assert_eq!(s.close_pass_clearance_m, 1.0);
        assert_eq!(p.legs.bonus_threads_min_count, 3);
        assert_eq!(p.lives.lives, 2);
        assert_eq!(p.net.tick_rate_hz, 20.0);
        // The worked examples of docs/SCORING.md.
        assert_eq!(s.speed_factor(kmh_to_mps(175.0)), 1.5);
        assert!((s.decay_term(kmh_to_mps(175.0)) - 0.55).abs() < 1e-12);
        assert_eq!(s.speed_factor(kmh_to_mps(300.0)), 2.0);
        assert_eq!(s.speed_factor(0.0), 1.0);
    }

    #[test]
    fn exact_overlay_is_checked() {
        let mut bad: Value = serde_json::from_str(r#"{"a": 1.5, "exact": {"a": "3ff0000000000000"}}"#).unwrap();
        assert!(apply_exact(&mut bad).is_err());
        let mut none: Value = serde_json::from_str(r#"{"a": 1.5}"#).unwrap();
        assert!(apply_exact(&mut none).is_err());
    }
}
