//! Traffic parameters. Two data files, both compiled in with `include_str!`:
//!
//! - `data/traffic_params.json`: **exported from the Godot tuning** by
//!   `tools/server_data/export_sim_data.gd` (never edited by hand): `TrafficTuning`,
//!   the driver profiles and vehicle types in `TrafficRegistry` order (already in SI, as
//!   the registry computes them), the spawn mix, the loop mode's traffic settings
//!   (`LoopTuning`, `DirectorTuning` at the loop's director leg) and the tick rate. Every
//!   float is written twice: readable, and as its exact IEEE-754 bits under `exact`
//!   (`"<path>": "<16 hex digits>"`), because Godot's JSON writer does not round-trip
//!   every double. The loader applies the exact bits and checks both agree.
//! - `data/mp_traffic.json`: the server-only rules the Godot tuning does not hold
//!   (multiplayer handoff → Tuning reference: 1.0 s minimum signal time, densities
//!   light / normal / rush, capacity, ramp upkeep). Server-owned data, not code.

use serde::Deserialize;
use serde_json::Value;

pub const TRAFFIC_PARAMS_JSON: &str = include_str!("../../data/traffic_params.json");
pub const MP_TRAFFIC_JSON: &str = include_str!("../../data/mp_traffic.json");
pub const PARAMS_FORMAT_VERSION: u32 = 1;

/// `TrafficTuning` (+ the few other tuning values the sim reads), SI units.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct TuningParams {
    pub max_active_vehicles: usize,
    pub near_radius_m: f64,
    pub near_tick_hz: u32,
    pub far_tick_hz: u32,
    pub far_tick_ratio: i32,
    pub max_decel_mps2: f64,
    pub scripted_max_decel_mps2: f64,
    pub idm_lookahead_m: f64,
    pub idm_gap_floor_m: f64,
    pub lateral_margin_m: f64,
    pub mobil_eval_interval_s: f64,
    pub lane_change_cooldown_s: f64,
    pub lane_discipline_bias_mps2: f64,
    pub player_lateral_anticipation_s: f64,
    pub player_idm_a_max_mps2: f64,
    pub player_idm_b_comfort_mps2: f64,
    pub player_idm_headway_s: f64,
    pub player_idm_s0_m: f64,
    pub player_length_m: f64,
    pub player_width_m: f64,
    pub lane_split_max_traffic_mps: f64,
    pub lane_split_max_speed_mps: f64,
    pub lane_split_scan_m: f64,
    pub lane_split_clearance_m: f64,
    pub lane_split_player_lateral_mps: f64,
    pub lane_split_player_range_m: f64,
    pub merge_zone_m: f64,
    pub merge_urgency_mps2: f64,
    pub merge_stop_margin_m: f64,
    pub merge_spawn_clear_m: f64,
    // Lane drops (WP6.8)
    pub lane_drop_merge_zone_m: f64,
    pub lane_drop_urgency_min_mps2: f64,
    pub lane_drop_slow_zone_m: f64,
    pub lane_drop_slow_after_m: f64,
    pub lane_drop_narrow_max_m: f64,
    pub lane_drop_through_mps: f64,
    pub lane_drop_merge_lane_mps: f64,
    pub lane_drop_brake_onset_frac: f64,
    pub lane_drop_view_m: f64,
    pub lane_drop_release_m: f64,
    pub lane_drop_yield_range_m: f64,
    pub lane_drop_yield_frac: f64,
    pub lane_drop_yield_decel_mps2: f64,
    pub lane_drop_merge_floor_mps: f64,
    pub lane_drop_merge_floor_until_m: f64,
    pub mobil_follower_horizon_s: f64,
    pub brake_light_decel_mps2: f64,
    pub brake_light_strong_decel_mps2: f64,
    pub signal_time_floor_s: f64,
    pub no_ambush_window_s: f64,
    pub no_ambush_margin_m: f64,
    pub player_b_safe_mps2: f64,
    /// Lane flow speeds, index 0 = the rightmost lane (the open road's; the loop's
    /// sections carry their own in the map).
    pub lane_flow_speeds_from_right_mps: Vec<f64>,
    pub close_pass_horn_frac: f64,
    pub cut_in_brake_tap_distance_m: f64,
    pub blind_spot_horn_s: f64,
    pub blind_spot_horn_frac: f64,
    pub blind_spot_behind_m: f64,
    pub hit_recover_s: f64,
    pub hit_swerve_m: f64,
    pub hit_swerve_s: f64,
    pub hit_brake_decel_mps2: f64,
    pub hit_brake_s: f64,
    pub brake_tap_decel_mps2: f64,
    pub brake_tap_s: f64,
    pub reaction_cooldown_s: f64,
    pub spawn_lane_speed_tolerance_mps: f64,
    pub spawn_keep_right_lane_count: i32,
    pub spawn_v0_jitter_frac: f64,
    pub spawn_palette_fallback_count: i32,
    /// `LivesTuning.collision_inset_m` (the rule checker's collision boxes).
    pub collision_inset_m: f64,
    /// `TrafficViewTuning`: how clients turn a traffic car for its lateral motion,
    /// atan2(v_lat, max(v, yaw_min_speed)) within +-yaw_max (the rule checker's boxes).
    pub view_yaw_min_speed_mps: f64,
    pub view_yaw_max_rad: f64,
}

/// One `DriverProfile`, as `TrafficRegistry` caches it (SI; the signal floor applied to
/// `signal_s` is the single-player one; the sim re-applies its own floor to
/// `signal_time_s`).
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct ProfileParams {
    pub id: String,
    pub v0_min_mps: f64,
    pub v0_max_mps: f64,
    pub a_max_mps2: f64,
    pub b_comfort_mps2: f64,
    pub headway_s: f64,
    pub s0_m: f64,
    pub delta: i32,
    pub politeness: f64,
    pub a_threshold_mps2: f64,
    pub a_bias_mps2: f64,
    pub b_safe_mps2: f64,
    /// The profile's own signal time (before any floor).
    pub signal_time_s: f64,
    /// `TrafficRegistry.signal_s`: max(signal_time_s, single-player floor).
    pub signal_s: f64,
    pub move_min_s: f64,
    pub move_max_s: f64,
    pub eval_interval_s: f64,
    pub cancel_p: f64,
    pub keep_right: bool,
    pub keep_right_lanes: i32,
    pub lane_split: bool,
    pub min_leg: i32,
    pub spawn_left_lane_count: i32,
    /// `TrafficTuning.spawn_profile_weights_pct` for this profile (0 when not listed).
    pub spawn_weight: f64,
}

/// One `VehicleType`.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct TypeParams {
    pub id: String,
    pub length_m: f64,
    pub width_m: f64,
    pub is_motorbike: bool,
    pub model_variants: i32,
}

/// The spawn mix (`SpawnSources.Flow`): special profiles and the per-profile type lists.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct SpawnParams {
    /// Profile index or -1.
    pub aggressive_profile: i32,
    pub racer_profile: i32,
    pub hesitant_profile: i32,
    /// `TrafficRegistry.types_for_profile(p)` for every profile.
    pub types_for_profile: Vec<Vec<i32>>,
}

/// The loop mode's traffic (`LoopTuning`, and `DirectorTuning` at its director leg).
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct LoopTrafficParams {
    pub director_leg: i32,
    pub density_per_km_lane: f64,
    /// Per loop section (map order), the share of the density.
    pub section_density_frac: Vec<f64>,
    pub aggressive_share_frac: f64,
    pub racer_share_frac: f64,
    pub headway_scale: f64,
    pub hesitant_allowed: bool,
    /// Traffic palette size per loop section (the biome's; the fallback when empty).
    pub palette_counts: Vec<i32>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct NetParams {
    pub tick_rate_hz: f64,
}

/// `data/traffic_params.json`.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct TrafficParams {
    pub format_version: u32,
    pub tuning: TuningParams,
    pub profiles: Vec<ProfileParams>,
    pub types: Vec<TypeParams>,
    pub spawn: SpawnParams,
    pub loop_traffic: LoopTrafficParams,
    pub net: NetParams,
}

/// Room traffic density (multiplayer handoff: light / normal / rush).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Density {
    Light,
    Normal,
    Rush,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct DensityRules {
    pub light: f64,
    pub normal: f64,
    pub rush: f64,
}

/// Ramp upkeep (not in spec beyond "the ring is kept at the room's density through the
/// ramps").
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct RampRules {
    /// Share of the rightmost lane's cars that take an off-ramp at the target density.
    pub exit_share_base_frac: f64,
    /// Extra exit share per unit of relative surplus ((count - target) / target).
    pub exit_share_gain: f64,
    pub exit_share_max_frac: f64,
    /// A car decides to exit when its center is within this far past the diverge.
    pub exit_decision_window_m: f64,
    /// At most one on-ramp spawn per ramp per this long.
    pub spawn_interval_s: f64,
    /// An on-ramp spawn needs this much clear road (bumper to bumper) ahead and behind
    /// on the ramp.
    pub spawn_clear_m: f64,
    /// The ramp's merge lane is closed from its end for this long (the wall).
    pub merge_wall_m: f64,
    /// On-ramp spawns stop above target x (1 + this).
    pub spawn_stop_surplus_frac: f64,
    /// No car enters (ramp or fill) within this distance of a player along the loop.
    pub spawn_player_clear_m: f64,
}

/// Initial fill of the ring.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct FillRules {
    /// Per-car spacing jitter around the mean spacing (1000 / density), +- this share.
    pub spacing_jitter_frac: f64,
    /// Extra clearance (m) on top of IDM's s* between consecutive cars in a lane.
    pub extra_gap_m: f64,
}

/// `data/mp_traffic.json`.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct MpTrafficRules {
    pub format_version: u32,
    /// Multiplayer signal time (all profiles): at least this long.
    pub signal_time_floor_s: f64,
    pub density_per_km_lane: DensityRules,
    /// Vehicle slots per room.
    pub capacity: usize,
    pub max_players: usize,
    /// A player's reported state is extrapolated at most this far (older: held).
    pub player_max_extrapolation_s: f64,
    /// Motorbike lane splitting on the server (its boundary targets have no protocol
    /// encoding yet; see docs/SERVER.md → Traffic simulation).
    pub lane_split: bool,
    /// Not in the GDScript model: a leader leaving the path does not hide what is ahead
    /// of it (following and MOBIL's own safety look through it). See docs/SERVER.md →
    /// Traffic simulation, deviations.
    pub look_through_leaving_leaders: bool,
    /// Not in the GDScript model: MOBIL's own safety also judges the new leader as it
    /// will be when the car is in the lane (signal + half the minimum move time), with its
    /// current deceleration. See docs/SERVER.md → Traffic simulation, deviations.
    pub predict_leader_braking: bool,
    /// Not in the GDScript model: a follower brakes for its leader's stopping point when
    /// that needs more than its comfortable b. See docs/SERVER.md → Traffic simulation.
    pub anticipate_leader_braking: bool,
    pub ramps: RampRules,
    pub fill: FillRules,
}

impl Density {
    pub fn per_km_lane(self, rules: &DensityRules) -> f64 {
        match self {
            Density::Light => rules.light,
            Density::Normal => rules.normal,
            Density::Rush => rules.rush,
        }
    }
}

impl TrafficParams {
    /// The compiled-in export.
    pub fn builtin() -> Result<Self, String> {
        Self::from_json(TRAFFIC_PARAMS_JSON)
    }

    /// Parses an export: applies the `exact` bit overlay and checks it against the
    /// readable numbers.
    pub fn from_json(text: &str) -> Result<Self, String> {
        let mut root: Value =
            serde_json::from_str(text).map_err(|e| format!("traffic params: {e}"))?;
        apply_exact(&mut root)?;
        let p: TrafficParams =
            serde_json::from_value(root).map_err(|e| format!("traffic params: {e}"))?;
        if p.format_version != PARAMS_FORMAT_VERSION {
            return Err(format!(
                "traffic params: format_version {} (this build reads {PARAMS_FORMAT_VERSION})",
                p.format_version
            ));
        }
        if p.profiles.is_empty() || p.types.is_empty() {
            return Err("traffic params: no profiles or types".into());
        }
        if p.spawn.types_for_profile.len() != p.profiles.len() {
            return Err("traffic params: types_for_profile does not match the profiles".into());
        }
        Ok(p)
    }

    pub fn profile_index(&self, id: &str) -> Option<usize> {
        self.profiles.iter().position(|p| p.id == id)
    }

    pub fn type_index(&self, id: &str) -> Option<usize> {
        self.types.iter().position(|t| t.id == id)
    }
}

impl MpTrafficRules {
    pub fn builtin() -> Result<Self, String> {
        let r: MpTrafficRules =
            serde_json::from_str(MP_TRAFFIC_JSON).map_err(|e| format!("mp traffic rules: {e}"))?;
        if r.format_version != 1 {
            return Err("mp traffic rules: format_version must be 1".into());
        }
        Ok(r)
    }
}

/// Replaces every number named in `root["exact"]` (a map of dotted paths to hex bits)
/// with its exact value, after checking the readable number agrees (relative 1e-12).
fn apply_exact(root: &mut Value) -> Result<(), String> {
    let Some(Value::Object(exact)) = root.as_object_mut().and_then(|o| o.remove("exact")) else {
        return Err("traffic params: no `exact` map".into());
    };
    for (path, bits) in exact {
        let bits = bits
            .as_str()
            .and_then(|b| u64::from_str_radix(b, 16).ok())
            .ok_or_else(|| format!("traffic params: bad bits at {path}"))?;
        let x = f64::from_bits(bits);
        let slot =
            lookup(root, &path).ok_or_else(|| format!("traffic params: no value at {path}"))?;
        let shown = slot
            .as_f64()
            .ok_or_else(|| format!("traffic params: {path} is not a number"))?;
        if (shown - x).abs() > 1e-12 * x.abs().max(1.0) {
            return Err(format!(
                "traffic params: {path} reads {shown} but its exact bits are {x}"
            ));
        }
        *slot = serde_json::Number::from_f64(x)
            .map(Value::Number)
            .ok_or_else(|| format!("traffic params: {path} is not finite"))?;
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
    fn builtin_files_parse() {
        let p = TrafficParams::builtin().expect("exported params");
        assert!(p.profiles.len() >= 9);
        assert!(p.tuning.max_decel_mps2 > 0.0);
        let r = MpTrafficRules::builtin().expect("mp rules");
        assert!(r.signal_time_floor_s >= 1.0);
        assert!(r.density_per_km_lane.light < r.density_per_km_lane.rush);
    }

    #[test]
    fn exact_overlay_is_checked() {
        let bad = r#"{"a": 1.5, "exact": {"a": "3ff0000000000000"}}"#;
        let mut v: Value = serde_json::from_str(bad).unwrap();
        assert!(apply_exact(&mut v).is_err());
        let good = r#"{"a": [0.1], "exact": {"a.0": "3fb999999999999a"}}"#;
        let mut v: Value = serde_json::from_str(good).unwrap();
        apply_exact(&mut v).unwrap();
        assert_eq!(v["a"][0].as_f64(), Some(0.1));
    }
}
