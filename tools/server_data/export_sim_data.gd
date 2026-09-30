extends SceneTree
## Exports what the server's traffic sim (the Rust `sim` crate, N4.1) takes from the client:
## the traffic parameters and the parity vectors. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md →
## Traffic → Server simulation ("Parameters come from the exported driver profiles"),
## Testing ("the Rust IDM and MOBIL match the GDScript versions on shared test vectors to
## within 1e-9"); docs/MULTIPLAYER_PLAN.md §3 ("data shared with the client comes from the
## client"); docs/SERVER.md → Traffic simulation.
##   tools/godot.sh --headless --path . --import      # once, if the project was never imported
##   tools/godot.sh --headless --path . --script res://tools/server_data/export_sim_data.gd
##       [-- --out=westbound-server/crates/sim] [--check] [--only=params|vectors|traces]
##       [--dump=<trace name>:<tick>]
## Writes (under --out):
##   data/traffic_params.json   TrafficTuning, TrafficRegistry (profiles, types), the spawn mix,
##                              LoopTuning + DirectorTuning at the loop's leg, NetTuning's tick
##   vectors/rng.json           Rng (PCG32 draws, derive_seed)
##   vectors/idm.json, mobil.json, no_ambush.json, player_velocity.json   the pure models
##   vectors/loop_closures.json TrafficSim.sync_road_closures on loop_v1 (closures, drop zones)
##   vectors/trace_*.json       whole-sim traces: a scripted player, spawns / despawns / hits as
##                              ops, and TrafficState.trace_hash() + events after every tick
## Floats are exact: vectors carry IEEE-754 bits as 16 hex digits; the params file carries
## readable numbers plus an `exact` map of bits (Godot's JSON writer does not round-trip every
## double). --check compares with the committed files and exits 1 when any is stale.
## Re-run after any change to src/traffic/, the traffic tuning or the driver profiles, then
## run the Rust parity tests (westbound-server: cargo test -p sim).

const DEFAULT_OUT := "westbound-server/crates/sim"
const PARAMS_FILE := "data/traffic_params.json"
const VEC_DIR := "vectors/"
const FORMAT_VERSION := 1
const GENERATOR := "tools/server_data/export_sim_data.gd"

## Vector counts and the seeds of their input streams (any fixed values).
const IDM_CASES := 1200
const MOBIL_CASES := 600
const NO_AMBUSH_CASES := 1500
const VELOCITY_CASES := 300
const RNG_SEEDS: Array[int] = [0, 1, 42, -7, 123456789012345, 9223372036854775807, -9223372036854775807]
const RNG_DRAWS := 24
const RNG_NAMES: Array[String] = ["traffic", "sim_lane_change", "sim_react", "sim_spawn", "ç ğ", "retry/3"]
const INPUT_SEED := 20260930

## Input ranges (m, m/s, m/s^2, s): wide enough to cover the loop's traffic and edge cases.
const V_MAX := 75.0
const V0_MIN := 5.0
const GAP_MAX := 700.0
const DV_MAX := 40.0
const A_MIN := 0.3
const A_MAX := 4.0
const B_MIN := 1.0
const B_MAX := 5.0
const T_MIN := 0.5
const T_MAX := 2.5
const S0_MIN := 0.5
const S0_MAX := 4.0
const DELTA_MAX := 6
const MOBIL_ACC_MIN := -9.0
const MOBIL_ACC_MAX := 4.0
const AMBUSH_S_RANGE := 40.0
const AMBUSH_V_REL := 30.0
const AMBUSH_D_MAX := 11.0
const AMBUSH_VLAT_MAX := 4.0
const YAW_MAX := 0.6
const KAPPA_MAX := 1.0 / 1200.0
const PCT := 100.0
const SPECIAL_PCT := 10.0   # share of special cases (INF gap, zero lateral speed, ...)

## Loop closures: samples every this many metres over one lap, lanes 0..LOOP_LANES-1.
const LOOP_SAMPLE_M := 50.0
const LOOP_LANES := 5
const LOOP_SEED := 1

## Trace scenarios (tick-level parity). far: the single-player near/far ticks, else every
## vehicle every tick (the server). floor: signal time floor (s; 0 = the tuning's).
## drop: a road lane drop (3 -> 2) this far ahead of the player; closure: a set-piece
## closure of the right lane this far ahead. density: vehicles per km per lane.
const SCENARIOS: Array[Dictionary] = [
	{"name": "sp_weave_120hz", "seed": 11, "lanes": 3, "hz": 120, "far": true, "floor": 0.0, "seconds": 40.0,
		"player_kmh": 130.0, "weave": true, "density": 16.0, "hits": [12.0, 24.0], "closure": 0.0, "drop": 0.0,
		"headway": 1.0},
	{"name": "mp_weave_20hz", "seed": 22, "lanes": 4, "hz": 20, "far": false, "floor": 1.0, "seconds": 120.0,
		"player_kmh": 150.0, "weave": true, "density": 14.0, "hits": [30.0], "closure": 0.0, "drop": 0.0,
		"headway": 0.9},
	{"name": "mp_lane_drop_20hz", "seed": 33, "lanes": 3, "hz": 20, "far": false, "floor": 1.0, "seconds": 90.0,
		"player_kmh": 115.0, "weave": false, "density": 14.0, "hits": [], "closure": 0.0, "drop": 1300.0,
		"headway": 1.0},
	{"name": "sp_closure_120hz", "seed": 44, "lanes": 3, "hz": 120, "far": true, "floor": 0.0, "seconds": 30.0,
		"player_kmh": 110.0, "weave": false, "density": 14.0, "hits": [], "closure": 700.0, "drop": 0.0,
		"headway": 1.0},
]
## Scenario rig (tool-local): window around the player, spawn cadence, player script.
const WINDOW_BEHIND_M := 250.0
const WINDOW_AHEAD_M := 800.0
const SPAWN_EVERY_S := 0.25
const SPAWN_PLAYER_CLEAR_M := 40.0
const SPAWN_EXTRA_GAP_M := 5.0
const POPULATE_TRIES := 30
const WEAVE_MIN_S := 3.0
const WEAVE_MAX_S := 7.0
const PLAYER_LC_S := 1.6
const SPEED_CHANGE_EVERY_S := 11.0
const SPEED_JITTER_KMH := 25.0
const CLOSE_PASS_EVERY_S := 2.0
const PLAYER_LENGTH_M := 4.5
const PLAYER_WIDTH_M := 1.9
const DROP_CLOSURE_M := 250.0
const CLOSURE_LENGTH_M := 300.0
const EVENT_KINDS := {&"traffic_horn": "horn", &"traffic_brake_tap": "brake_tap", &"traffic_hazards": "hazards"}

var _out := DEFAULT_OUT
var _check := false
var _only := ""
var _dump_name := ""
var _dump_tick := -1
var _stale: Array[String] = []
var _written := 0
var _bits := PackedByteArray()


func _initialize() -> void:
	_bits.resize(8)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.get_slice("=", 1)
		elif a == "--check":
			_check = true
		elif a.begins_with("--only="):
			_only = a.get_slice("=", 1)
		elif a.begins_with("--dump="):
			var spec := a.get_slice("=", 1)
			_dump_name = spec.get_slice(":", 0)
			_dump_tick = int(spec.get_slice(":", 1))
	var tuning := Tuning.load_default()
	var reg := TrafficRegistry.load_default(tuning.traffic)
	if _only == "" or _only == "params":
		_emit(PARAMS_FILE, _params_text(tuning, reg))
	if _only == "" or _only == "vectors":
		_emit(VEC_DIR + "rng.json", _rng_vectors())
		_emit(VEC_DIR + "idm.json", _idm_vectors(reg))
		_emit(VEC_DIR + "mobil.json", _mobil_vectors())
		_emit(VEC_DIR + "no_ambush.json", _no_ambush_vectors())
		_emit(VEC_DIR + "player_velocity.json", _velocity_vectors())
		_emit(VEC_DIR + "loop_closures.json", _loop_closures(tuning))
	if _only == "" or _only == "traces":
		for sc in SCENARIOS:
			_emit(VEC_DIR + "trace_%s.json" % sc["name"], _trace(tuning, sc))
	if _check:
		if _stale.is_empty():
			print("SIM_DATA ok (current) files=%d" % _written)
			quit(0)
		else:
			printerr("SIM_DATA stale: %s (re-run tools/server_data/export_sim_data.gd)" % ", ".join(_stale))
			quit(1)
		return
	print("SIM_DATA ok %s files=%d" % [_out, _written])
	quit(0)


# ---------------------------------------------------------------- Output

func _path(rel: String) -> String:
	var base := _out if _out.begins_with("/") else ProjectSettings.globalize_path("res://" + _out)
	return base.path_join(rel)


func _emit(rel: String, text: String) -> void:
	var path := _path(rel)
	_written += 1
	if _check:
		if not FileAccess.file_exists(path) or FileAccess.get_file_as_string(path) != text:
			_stale.append(rel)
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		printerr("SIM_DATA FAIL cannot write %s" % path)
		quit(1)
		return
	f.store_string(text)
	f.close()


## IEEE-754 bits of x as 16 hex digits (exact; INF and NAN included).
func _hx(x: float) -> String:
	_bits.encode_double(0, x)
	return "%08x%08x" % [_bits.decode_u32(4), _bits.decode_u32(0)]


func _header(what: String) -> Dictionary:
	return {
		"format_version": FORMAT_VERSION,
		"generator": GENERATOR,
		"godot": Engine.get_version_info()["string"],
		"what": what,
	}


## A document whose `list_key` array is written one element per line (diff-friendly and
## compact); every other key is a normal JSON value.
func _doc_text(head: Dictionary, list_key: String, items: Array) -> String:
	var lines := PackedStringArray(["{"])
	for k: String in head:
		lines.append("  %s: %s," % [JSON.stringify(k), JSON.stringify(head[k], "", false, true)])
	lines.append("  %s: [" % JSON.stringify(list_key))
	for n in items.size():
		lines.append("    %s%s" % [JSON.stringify(items[n], "", false, true), "," if n < items.size() - 1 else ""])
	lines.append("  ]")
	lines.append("}")
	return "\n".join(lines) + "\n"


# ---------------------------------------------------------------- Params

func _params_text(tuning: Tuning, reg: TrafficRegistry) -> String:
	var t := tuning.traffic
	var tun := {
		"max_active_vehicles": t.max_active_vehicles,
		"near_radius_m": t.near_radius_m,
		"near_tick_hz": t.near_tick_hz,
		"far_tick_hz": t.far_tick_hz,
		"far_tick_ratio": t.far_tick_ratio(),
		"max_decel_mps2": t.max_decel_mps2,
		"scripted_max_decel_mps2": t.scripted_max_decel_mps2,
		"idm_lookahead_m": t.idm_lookahead_m,
		"idm_gap_floor_m": t.idm_gap_floor_m,
		"lateral_margin_m": t.lateral_margin_m,
		"mobil_eval_interval_s": t.mobil_eval_interval_s,
		"lane_change_cooldown_s": t.lane_change_cooldown_s,
		"lane_discipline_bias_mps2": t.lane_discipline_bias_mps2,
		"player_lateral_anticipation_s": t.player_lateral_anticipation_s,
		"player_idm_a_max_mps2": t.player_idm_a_max_mps2,
		"player_idm_b_comfort_mps2": t.player_idm_b_comfort_mps2,
		"player_idm_headway_s": t.player_idm_headway_s,
		"player_idm_s0_m": t.player_idm_s0_m,
		"player_length_m": t.player_length_m,
		"player_width_m": t.player_width_m,
		"lane_split_max_traffic_mps": Units.kmh_to_mps(t.lane_split_max_traffic_kmh),
		"lane_split_max_speed_mps": Units.kmh_to_mps(t.lane_split_max_speed_kmh),
		"lane_split_scan_m": t.lane_split_scan_m,
		"lane_split_clearance_m": t.lane_split_clearance_m,
		"lane_split_player_lateral_mps": t.lane_split_player_lateral_mps,
		"lane_split_player_range_m": t.lane_split_player_range_m,
		"merge_zone_m": t.merge_zone_m,
		"merge_urgency_mps2": t.merge_urgency_mps2,
		"merge_stop_margin_m": t.merge_stop_margin_m,
		"merge_spawn_clear_m": t.merge_spawn_clear_m,
		"lane_drop_merge_zone_m": t.lane_drop_merge_zone_m,
		"lane_drop_urgency_min_mps2": t.lane_drop_urgency_min_mps2,
		"lane_drop_slow_zone_m": t.lane_drop_slow_zone_m,
		"lane_drop_slow_after_m": t.lane_drop_slow_after_m,
		"lane_drop_narrow_max_m": t.lane_drop_narrow_max_m,
		"lane_drop_through_mps": Units.kmh_to_mps(t.lane_drop_through_kmh),
		"lane_drop_merge_lane_mps": Units.kmh_to_mps(t.lane_drop_merge_lane_kmh),
		"lane_drop_brake_onset_frac": t.lane_drop_brake_onset_frac,
		"lane_drop_view_m": t.lane_drop_view_m,
		"lane_drop_release_m": t.lane_drop_release_m,
		"lane_drop_yield_range_m": t.lane_drop_yield_range_m,
		"lane_drop_yield_frac": t.lane_drop_yield_frac,
		"lane_drop_yield_decel_mps2": t.lane_drop_yield_decel_mps2,
		"lane_drop_merge_floor_mps": Units.kmh_to_mps(t.lane_drop_merge_floor_kmh),
		"lane_drop_merge_floor_until_m": t.lane_drop_merge_floor_until_m,
		"mobil_follower_horizon_s": t.mobil_follower_horizon_s,
		"brake_light_decel_mps2": t.brake_light_decel_mps2,
		"brake_light_strong_decel_mps2": t.brake_light_strong_decel_mps2,
		"signal_time_floor_s": t.signal_time_floor_s,
		"no_ambush_window_s": t.no_ambush_window_s,
		"no_ambush_margin_m": t.no_ambush_margin_m,
		"player_b_safe_mps2": t.player_b_safe_mps2,
		"lane_flow_speeds_from_right_mps": _flows(t),
		"close_pass_horn_frac": t.close_pass_horn_frac(),
		"cut_in_brake_tap_distance_m": t.cut_in_brake_tap_distance_m,
		"blind_spot_horn_s": t.blind_spot_horn_s,
		"blind_spot_horn_frac": t.blind_spot_horn_frac(),
		"blind_spot_behind_m": t.blind_spot_behind_m,
		"hit_recover_s": t.hit_recover_s,
		"hit_swerve_m": t.hit_swerve_m,
		"hit_swerve_s": t.hit_swerve_s,
		"hit_brake_decel_mps2": t.hit_brake_decel_mps2,
		"hit_brake_s": t.hit_brake_s,
		"brake_tap_decel_mps2": t.brake_tap_decel_mps2,
		"brake_tap_s": t.brake_tap_s,
		"reaction_cooldown_s": t.reaction_cooldown_s,
		"spawn_lane_speed_tolerance_mps": Units.kmh_to_mps(t.spawn_lane_speed_tolerance_kmh),
		"spawn_keep_right_lane_count": t.spawn_keep_right_lane_count,
		"spawn_v0_jitter_frac": t.spawn_v0_jitter_frac(),
		"spawn_palette_fallback_count": t.spawn_palette_fallback_count,
		"collision_inset_m": tuning.lives.collision_inset_m,
	}
	var profiles: Array = []
	for p in reg.profile_count():
		var pr := reg.profiles[p]
		var w := 0.0
		var wi := t.spawn_profile_ids.find(pr.id)
		if wi >= 0 and wi < t.spawn_profile_weights_pct.size():
			w = t.spawn_profile_weights_pct[wi]
		profiles.append({
			"id": String(pr.id),
			"v0_min_mps": reg.v0_min[p],
			"v0_max_mps": reg.v0_max[p],
			"a_max_mps2": reg.a_max[p],
			"b_comfort_mps2": reg.b_comfort[p],
			"headway_s": reg.headway[p],
			"s0_m": reg.s0[p],
			"delta": reg.delta[p],
			"politeness": reg.politeness[p],
			"a_threshold_mps2": reg.a_threshold[p],
			"a_bias_mps2": reg.a_bias[p],
			"b_safe_mps2": reg.b_safe[p],
			"signal_time_s": pr.signal_time_s,
			"signal_s": reg.signal_s[p],
			"move_min_s": reg.move_min_s[p],
			"move_max_s": reg.move_max_s[p],
			"eval_interval_s": reg.eval_interval_s[p],
			"cancel_p": reg.cancel_p[p],
			"keep_right": reg.keep_right[p] == 1,
			"keep_right_lanes": reg.keep_right_lanes[p],
			"lane_split": reg.lane_split[p] == 1,
			"min_leg": pr.min_leg,
			"spawn_left_lane_count": pr.spawn_left_lane_count,
			"spawn_weight": w,
		})
	var types: Array = []
	for ti in reg.type_count():
		var ty := reg.types[ti]
		types.append({
			"id": String(ty.id),
			"length_m": reg.length[ti],
			"width_m": reg.width[ti],
			"is_motorbike": reg.is_motorbike[ti] == 1,
			"model_variants": maxi(ty.model_scene_paths.size(), 1),
		})
	var tfp: Array = []
	for p in reg.profile_count():
		tfp.append(Array(reg.types_for_profile(p)))
	var loop_t := LoopTuning.load_default()
	var dir := tuning.director
	var leg := loop_t.director_leg
	var def := LoopMapDef.load_default()
	var shares: Array = []
	var palettes: Array = []
	for i in def.sections.size():
		shares.append(loop_t.section_density_frac(i))
		palettes.append(_palette_count(def.sections[i].biome_id, t))
	var doc := {
		"format_version": FORMAT_VERSION,
		"generator": GENERATOR,
		"godot": Engine.get_version_info()["string"],
		"sources": ["data/tuning/traffic.tres", "data/driver_profiles/*.tres", "data/vehicle_types/*.tres",
			"data/tuning/loop.tres", "data/tuning/director.tres", "data/tuning/lives.tres", "data/tuning/net.tres"],
		"tuning": tun,
		"profiles": profiles,
		"types": types,
		"spawn": {
			"aggressive_profile": reg.profile_index(t.spawn_aggressive_profile_id),
			"racer_profile": reg.profile_index(t.spawn_racer_profile_id),
			"hesitant_profile": reg.profile_index(t.spawn_hesitant_profile_id),
			"types_for_profile": tfp,
		},
		"loop_traffic": {
			"director_leg": leg,
			"density_per_km_lane": loop_t.density_per_km_lane,
			"section_density_frac": shares,
			"aggressive_share_frac": dir.aggressive_share_frac(leg),
			"racer_share_frac": dir.racer_share_frac(leg),
			"headway_scale": dir.headway_scale(leg),
			"hesitant_allowed": leg >= dir.hesitant_first_leg,
			"palette_counts": palettes,
		},
		"net": {"tick_rate_hz": tuning.net.tick_rate_hz},
	}
	var exact := {}
	_exact_walk(doc, "", exact)
	doc["exact"] = exact
	return JSON.stringify(doc, "  ", false, true) + "\n"


func _flows(t: TrafficTuning) -> Array:
	var out: Array = []
	var n := t.lane_flow_speeds_from_right_kmh.size()
	for i in n:
		out.append(t.lane_flow_speed_mps(n - 1 - i, n))
	return out


func _palette_count(biome_id: StringName, t: TrafficTuning) -> int:
	var path := "res://data/biomes/%s.tres" % biome_id
	var b := load(path) as BiomeDef if ResourceLoader.exists(path) else null
	if b != null and b.traffic_palette.size() > 0:
		return b.traffic_palette.size()
	return maxi(t.spawn_palette_fallback_count, 1)


## Records the exact bits of every float under `v` at its dotted path.
func _exact_walk(v: Variant, path: String, out: Dictionary) -> void:
	if v is Dictionary:
		var d: Dictionary = v
		for k: String in d:
			_exact_walk(d[k], k if path == "" else path + "." + k, out)
	elif v is Array:
		var a: Array = v
		for i in a.size():
			_exact_walk(a[i], "%s.%d" % [path, i], out)
	elif v is float:
		out[path] = _hx(v)


# ---------------------------------------------------------------- Pure-model vectors

func _rng_vectors() -> String:
	var cases: Array = []
	for sd in RNG_SEEDS:
		var r := Rng.new(sd)
		var units: Array = []
		for k in RNG_DRAWS:
			units.append(_hx(r.unit()))
		var ints: Array = []
		for k in RNG_DRAWS:
			ints.append(r.int_range(-5, 17))
		var bytes: Array = []
		for k in RNG_DRAWS:
			bytes.append(r.int_range(7, 0))
		var ranges: Array = []
		for k in RNG_DRAWS:
			ranges.append(_hx(r.float_range(2.0, 3.5)))
		var chances: Array = []
		for k in RNG_DRAWS:
			chances.append(r.chance(0.3))
		var picks: Array = []
		for k in RNG_DRAWS:
			picks.append(r.pick_weighted(PackedFloat64Array([22.0, 40.0, 12.0, 0.0, 10.0, 6.0, 6.0])))
		var derived: Array = []
		for nm in RNG_NAMES:
			derived.append(str(Rng.derive_seed(sd, nm)))
		cases.append({"seed": str(sd), "unit": units, "int_m5_17": ints, "int_7_0": bytes, "float_2_3p5": ranges,
			"chance_0p3": chances, "pick": picks, "state": str(r.get_state()), "derive": derived})
	var head := _header("Rng: seed -> unit x N, int_range(-5, 17) x N, int_range(7, 0) x N, float_range(2, 3.5) x N, "
		+ "chance(0.3) x N, pick_weighted([22, 40, 12, 0, 10, 6, 6]) x N, final state; derive_seed(seed, names)")
	head["names"] = RNG_NAMES
	# The traffic stream chain of a run seed: Rng.new(s).derive(traffic).derive(sim_*).
	var chain: Array = []
	for sd in RNG_SEEDS:
		var traffic := Rng.new(sd).derive(Rng.STREAM_TRAFFIC)
		chain.append([str(sd), str(traffic.get_seed()), str(traffic.derive(&"sim_lane_change").get_seed())])
	head["traffic_chain"] = chain
	return _doc_text(head, "cases", cases)


func _idm_vectors(reg: TrafficRegistry) -> String:
	var r := Rng.new(INPUT_SEED).derive(&"idm")
	var gap_floor := 0.1
	var cases: Array = []
	for n in IDM_CASES:
		var v := 0.0 if r.chance(SPECIAL_PCT / PCT) else r.float_range(0.0, V_MAX)
		var v0 := r.float_range(V0_MIN, V_MAX)
		var gap := r.float_range(0.1, GAP_MAX)
		var roll := r.unit()
		if roll < SPECIAL_PCT / PCT:
			gap = INF
		elif roll < 2.0 * SPECIAL_PCT / PCT:
			gap = r.float_range(-2.0, 0.2)
		var dv := r.float_range(-DV_MAX, DV_MAX)
		var a := 0.0
		var b := 0.0
		var hw := 0.0
		var s0 := 0.0
		var dl := 4
		if r.chance(0.5):
			var p := r.int_range(0, reg.profile_count() - 1)
			a = reg.a_max[p]
			b = reg.b_comfort[p]
			hw = reg.headway[p]
			s0 = reg.s0[p]
			dl = reg.delta[p]
		else:
			a = r.float_range(A_MIN, A_MAX)
			b = r.float_range(B_MIN, B_MAX)
			hw = r.float_range(T_MIN, T_MAX)
			s0 = r.float_range(S0_MIN, S0_MAX)
			dl = r.int_range(0, DELTA_MAX)
		cases.append([_hx(v), _hx(v0), _hx(gap), _hx(dv), _hx(a), _hx(b), _hx(hw), _hx(s0), dl, _hx(gap_floor),
			_hx(Idm.accel(v, v0, gap, dv, a, b, hw, s0, dl, gap_floor)),
			_hx(Idm.free_accel(v, v0, a, dl)),
			_hx(Idm.interaction_accel(v, gap, dv, a, b, hw, s0, gap_floor)),
			_hx(Idm.desired_gap(v, dv, a, b, hw, s0)),
			_hx(Idm.equilibrium_gap(v, v0, hw, s0, dl)),
			_hx(Idm.pow_int(v / v0, dl))])
	var head := _header("Idm (src/traffic/idm.gd): inputs, then accel, free_accel, interaction_accel, desired_gap, "
		+ "equilibrium_gap, pow_int(v / v0, delta)")
	head["columns"] = ["v", "v0", "gap", "dv", "a_max", "b", "headway", "s0", "delta", "gap_floor",
		"accel", "free_accel", "interaction_accel", "desired_gap", "equilibrium_gap", "pow_int"]
	return _doc_text(head, "cases", cases)


func _mobil_vectors() -> String:
	var r := Rng.new(INPUT_SEED).derive(&"mobil")
	var cases: Array = []
	for n in MOBIL_CASES:
		var acc: Array[float] = []
		for k in 6:
			acc.append(r.float_range(MOBIL_ACC_MIN, MOBIL_ACC_MAX))
		var p := 0.0 if r.chance(SPECIAL_PCT / PCT) else r.unit()
		var th := r.float_range(0.0, 0.5)
		var bias := r.float_range(0.0, 0.8)
		var to_right := r.chance(0.5)
		var inc := Mobil.incentive(acc[0], acc[1], acc[2], acc[3], acc[4], acc[5], p)
		var bsafe := r.float_range(1.5, 5.0)
		var is_player := r.chance(0.3)
		var pbs := r.float_range(1.0, 3.0)
		cases.append([_hx(acc[0]), _hx(acc[1]), _hx(acc[2]), _hx(acc[3]), _hx(acc[4]), _hx(acc[5]), _hx(p),
			_hx(th), _hx(bias), to_right, _hx(bsafe), is_player, _hx(pbs),
			_hx(inc), _hx(Mobil.threshold(th, bias, to_right)), Mobil.accepts(inc, th, bias, to_right),
			Mobil.is_safe(acc[2], bsafe), _hx(Mobil.b_safe_for(bsafe, is_player, pbs))])
	var head := _header("Mobil (src/traffic/mobil.gd): incentive, threshold, accepts, is_safe(a_n_new, b_safe), b_safe_for")
	head["columns"] = ["a_c_new", "a_c", "a_n_new", "a_n", "a_o_new", "a_o", "p", "a_th", "a_bias", "to_right",
		"b_safe", "follower_is_player", "player_b_safe", "incentive", "threshold", "accepts", "is_safe", "b_safe_for"]
	return _doc_text(head, "cases", cases)


func _no_ambush_vectors() -> String:
	var r := Rng.new(INPUT_SEED).derive(&"no_ambush")
	var cases: Array = []
	var hits := 0
	for n in NO_AMBUSH_CASES:
		var car_s := r.float_range(0.0, 1000.0)
		var car_v := r.float_range(0.0, V_MAX)
		var car_l := r.float_range(2.0, 16.0)
		var car_w := r.float_range(0.8, 2.6)
		var target_d := r.float_range(2.0, AMBUSH_D_MAX)
		var p_s := car_s + r.float_range(-AMBUSH_S_RANGE, AMBUSH_S_RANGE)
		var p_v := car_v if r.chance(SPECIAL_PCT / PCT) else maxf(0.0, car_v + r.float_range(-AMBUSH_V_REL, AMBUSH_V_REL))
		var p_d := r.float_range(0.0, AMBUSH_D_MAX + 2.0)
		var p_vl := 0.0 if r.chance(2.0 * SPECIAL_PCT / PCT) else r.float_range(-AMBUSH_VLAT_MAX, AMBUSH_VLAT_MAX)
		var window := 1.5
		var margin := 1.0
		var hit := NoAmbush.violates(car_s, car_v, car_l, car_w, target_d, p_s, p_v, p_d, p_vl, PLAYER_LENGTH_M,
			PLAYER_WIDTH_M, window, margin)
		hits += 1 if hit else 0
		cases.append([_hx(car_s), _hx(car_v), _hx(car_l), _hx(car_w), _hx(target_d), _hx(p_s), _hx(p_v), _hx(p_d),
			_hx(p_vl), _hx(PLAYER_LENGTH_M), _hx(PLAYER_WIDTH_M), _hx(window), _hx(margin), hit])
	var head := _header("NoAmbush.violates (src/traffic/no_ambush.gd)")
	head["columns"] = ["car_s", "car_v", "car_length", "car_width", "target_d", "p_s", "p_v", "p_d", "p_v_lat",
		"p_length", "p_width", "window", "margin", "violates"]
	head["violations"] = hits
	return _doc_text(head, "cases", cases)


## TrafficSim._read_player's road-frame velocity (s_dot, d_dot) from v, v_lat, yaw, kappa, d.
func _velocity_vectors() -> String:
	var r := Rng.new(INPUT_SEED).derive(&"velocity")
	var cases: Array = []
	for n in VELOCITY_CASES:
		var v := r.float_range(0.0, V_MAX)
		var vl := r.float_range(-AMBUSH_VLAT_MAX, AMBUSH_VLAT_MAX)
		var yaw := 0.0 if r.chance(SPECIAL_PCT / PCT) else r.float_range(-YAW_MAX, YAW_MAX)
		var kappa := 0.0 if r.chance(SPECIAL_PCT / PCT) else r.float_range(-KAPPA_MAX, KAPPA_MAX)
		var d := r.float_range(0.0, AMBUSH_D_MAX)
		var cy := cos(yaw)
		var sy := sin(yaw)
		cases.append([_hx(v), _hx(vl), _hx(yaw), _hx(kappa), _hx(d),
			_hx((v * cy - vl * sy) / (1.0 - kappa * d)), _hx(v * sy + vl * cy)])
	var head := _header("TrafficSim._read_player: s_dot = (v cos yaw - v_lat sin yaw) / (1 - kappa d), "
		+ "d_dot = v sin yaw + v_lat cos yaw (libm: compare within 1e-12)")
	head["columns"] = ["v", "v_lat", "yaw", "kappa", "d", "s_dot", "d_dot"]
	return _doc_text(head, "cases", cases)


## The client's lane closures and lane-drop zones on loop_v1 (TrafficSim.sync_road_closures
## over two laps, so lap one sees the next lap's changes), sampled: closure_ahead and
## merge_zone_frac per lane every LOOP_SAMPLE_M over lap one.
func _loop_closures(tuning: Tuning) -> String:
	var road := LoopRoadPath.load_default(tuning)
	var ctx := RunContext.new(LOOP_SEED, RunContext.MODE_JOURNEY, tuning)
	var sim := TrafficSim.new(ctx, road, TrafficRegistry.load_default(tuning.traffic))
	var length := road.period_m()
	sim.sync_road_closures(0.0, 2.0 * length)
	var zones: Array = []
	for z in sim.lane_drop_zone_count():
		if sim.lane_drop_zone_s0(z) < length:
			zones.append([_hx(sim.lane_drop_zone_s0(z)), _hx(sim.lane_drop_zone_s1(z))])
	var samples: Array = []
	var s := 0.0
	while s < length:
		var row: Array = [_hx(s)]
		for lane in LOOP_LANES:
			row.append(_hx(sim.closure_ahead(lane, s)))
			row.append(_hx(sim.merge_zone_frac(lane, s)))
		samples.append(row)
		s += LOOP_SAMPLE_M
	var head := _header("loop_v1 closures: TrafficSim.sync_road_closures(0, 2L) on LoopRoadPath; per sample s: "
		+ "closure_ahead(lane, s), merge_zone_frac(lane, s) for lanes 0..%d" % (LOOP_LANES - 1))
	head["length_m"] = _hx(length)
	head["drop_zones"] = zones
	head["closures"] = sim.lane_closure_count()
	return _doc_text(head, "samples", samples)


# ---------------------------------------------------------------- Trace scenarios

## One scenario, recorded: the ops (spawns, despawns, hits, close passes, closures) the
## Rust replay applies, the scripted player's schedule, and after every tick the state's
## trace hash and the sim's events.
func _trace(base: Tuning, sc: Dictionary) -> String:
	var tuning := base.duplicate() as Tuning
	tuning.traffic = base.traffic.duplicate() as TrafficTuning
	var tt := tuning.traffic
	var floor_s: float = sc["floor"]
	if floor_s > 0.0:
		tt.signal_time_floor_s = floor_s
	var far: bool = sc["far"]
	if not far:
		tt.near_radius_m = INF
	var hz: int = sc["hz"]
	var dt := 1.0 / float(hz)
	var lanes: int = sc["lanes"]
	var seed_value: int = sc["seed"]
	var ctx := RunContext.new(seed_value, RunContext.MODE_JOURNEY, tuning)
	var road := StraightRoadPath.new(lanes, tuning.road)
	var reg := TrafficRegistry.load_default(tt)
	var sim := TrafficSim.new(ctx, road, reg)
	sim.set_player_body(PLAYER_LENGTH_M, PLAYER_WIDTH_M)
	var events := ScoreEventBuffer.new(1024)
	var rig := Rng.new(seed_value).derive(&"parity_rig")
	var ticks := roundi(float(sc["seconds"]) * float(hz))
	# The player's script: lane changes and speed changes at fixed ticks.
	var player := VehicleState.new()
	var start_lane := mini(1, lanes - 1)
	player.s = WINDOW_BEHIND_M + 100.0
	player.d = road.lane_center_d(start_lane, player.s)
	player.v = Units.kmh_to_mps(float(sc["player_kmh"]))
	var script: Array = []
	var lane := start_lane
	var next_lc := roundi(rig.float_range(WEAVE_MIN_S, WEAVE_MAX_S) * float(hz))
	var next_v := roundi(SPEED_CHANGE_EVERY_S * float(hz))
	for k in range(1, ticks + 1):
		if bool(sc["weave"]) and k == next_lc:
			var to := lane + (1 if rig.chance(0.5) else -1)
			if to < 0 or to >= lanes:
				to = lane - (to - lane)
			script.append([k, "lane", to, _hx(PLAYER_LC_S)])
			lane = to
			next_lc = k + roundi(rig.float_range(WEAVE_MIN_S, WEAVE_MAX_S) * float(hz))
		if k == next_v:
			var kmh := float(sc["player_kmh"]) + rig.float_range(-SPEED_JITTER_KMH, SPEED_JITTER_KMH)
			script.append([k, "v", _hx(Units.kmh_to_mps(kmh))])
			next_v = k + roundi(SPEED_CHANGE_EVERY_S * float(hz))
	var ops: Array = []
	var headway: float = sc["headway"]
	if headway != 1.0:
		sim.set_headway_scale(headway)
		ops.append([0, "headway_scale", _hx(headway)])
	var closure_m: float = sc["closure"]
	if closure_m > 0.0:
		var c0 := player.s + closure_m
		sim.add_lane_closure(lanes - 1, c0, c0 + CLOSURE_LENGTH_M, 7)
		ops.append([0, "closure", lanes - 1, _hx(c0), _hx(c0 + CLOSURE_LENGTH_M), 7, _hx(0.0), _hx(0.0)])
	var drop_m: float = sc["drop"]
	if drop_m > 0.0:
		# A road lane drop as sync_road_closures builds it (lanes -> lanes - 1).
		var s_drop := player.s + drop_m
		var zone := tt.lane_drop_merge_zone_m
		var base_u := tt.lane_drop_urgency_min_mps2
		sim.add_lane_closure(lanes - 1, s_drop, s_drop + DROP_CLOSURE_M, TrafficSim.ROAD_CLOSURE_TAG, zone, base_u)
		ops.append([0, "closure", lanes - 1, _hx(s_drop), _hx(s_drop + DROP_CLOSURE_M), TrafficSim.ROAD_CLOSURE_TAG,
			_hx(zone), _hx(base_u)])
		var z0 := s_drop - tt.lane_drop_slow_zone_m
		var z1 := s_drop + DROP_CLOSURE_M + tt.lane_drop_slow_after_m
		sim.add_lane_drop_zone(lanes - 1, z0, z1)
		ops.append([0, "drop_zone", lanes - 1, _hx(z0), _hx(z1)])
	var density: float = sc["density"]
	var spawn_rng := Rng.new(seed_value).derive(&"parity_spawner")
	_populate(sim, reg, road, tt, spawn_rng, player, lanes, density, ops)
	var hits_s: Array = sc["hits"]
	var hit_ticks: Array[int] = []
	for h: float in hits_s:
		hit_ticks.append(roundi(h * float(hz)))
	var close_every := roundi(CLOSE_PASS_EVERY_S * float(hz))
	var spawn_every := maxi(1, roundi(SPAWN_EVERY_S * float(hz)))
	var hashes := PackedStringArray()
	var ev_out: Array = []
	var lc_from := player.d
	var lc_to := player.d
	var lc_t0 := -1
	var lc_dur := 0.0
	var si := 0
	for k in range(1, ticks + 1):
		# Player script (exact arithmetic the Rust replay repeats).
		while si < script.size() and int(script[si][0]) == k:
			var e: Array = script[si]
			if e[1] == "lane":
				lc_from = player.d
				lc_to = road.lane_center_d(int(e[2]), player.s)
				lc_t0 = k
				lc_dur = PLAYER_LC_S
			else:
				player.v = _unhx(e[2])
			si += 1
		player.s += player.v * dt
		if lc_t0 >= 0:
			var u := float(k - lc_t0) * dt / lc_dur
			if u >= 1.0:
				player.d = lc_to
				player.v_lat = 0.0
				lc_t0 = -1
			else:
				var span := lc_to - lc_from
				player.d = lc_from + span * u * u * (3.0 - 2.0 * u)
				player.v_lat = span * 6.0 * u * (1.0 - u) / lc_dur
		sim.step(dt, player, null, events)
		for e in events.size():
			ev_out.append([k, EVENT_KINDS.get(events.kind[e], String(events.kind[e])), events.slot[e],
				_hx(events.value[e]), String(events.tag[e])])
		events.clear()
		# Ops after the step: hits, close passes, then the spawner.
		if hit_ticks.has(k):
			var slot := _nearest_ahead(sim, player)
			if slot >= 0:
				sim.notify_hit(slot)
				ops.append([k, "hit", slot])
		if k % close_every == 0:
			var slot := _nearest_ahead(sim, player)
			if slot >= 0:
				sim.notify_close_pass(slot)
				ops.append([k, "close_pass", slot])
		if k % spawn_every == 0:
			_maintain(sim, reg, road, tt, spawn_rng, player, lanes, density, k, ops)
		hashes.append(str(sim.state.trace_hash()))
		if sc["name"] == _dump_name and k == _dump_tick:
			_dump(sim, k)
	var head := _header("TrafficSim trace (tick-level parity): a StraightRoadPath, a scripted player, ops after each "
		+ "tick's step (tick 0: before the first), then TrafficState.trace_hash() per tick")
	head["name"] = sc["name"]
	head["seed"] = seed_value
	head["lanes"] = lanes
	head["tick_hz"] = hz
	head["dt"] = _hx(dt)
	head["ticks"] = ticks
	head["far"] = far
	head["near_radius_m"] = _hx(tt.near_radius_m)
	head["signal_time_floor_s"] = _hx(tt.signal_time_floor_s)
	head["left_edge_d"] = _hx(road.lanes_left_edge_d(0.0))
	head["lane_width"] = _hx(road.lane_width(0.0))
	head["player"] = {"s": _hx(WINDOW_BEHIND_M + 100.0), "lane": start_lane, "v": _hx(Units.kmh_to_mps(float(sc["player_kmh"]))),
		"length": _hx(PLAYER_LENGTH_M), "width": _hx(PLAYER_WIDTH_M), "script": script}
	head["stats"] = {"signals": sim.stat_signals, "moves": sim.stat_moves, "completed": sim.stat_completed,
		"cancel_player": sim.stat_cancel_player, "cancel_hesitant": sim.stat_cancel_hesitant,
		"cancel_unsafe": sim.stat_cancel_unsafe, "merges": sim.stat_merges, "events": ev_out.size(),
		"vehicles_end": sim.state.count}
	head["ops"] = ops
	head["events"] = ev_out
	return _doc_text(head, "hashes", Array(hashes))


func _unhx(h: String) -> float:
	_bits.encode_u32(4, h.substr(0, 8).hex_to_int())
	_bits.encode_u32(0, h.substr(8, 8).hex_to_int())
	return _bits.decode_double(0)


func _nearest_ahead(sim: TrafficSim, player: VehicleState) -> int:
	var best := -1
	var best_ds := INF
	var ts := sim.state
	for i in ts.capacity:
		if ts.active[i] == 0:
			continue
		var ds := ts.s[i] - player.s
		if ds > 0.0 and ds < best_ds:
			best_ds = ds
			best = i
	return best


## Fills the window with traffic at IDM-consistent gaps (ops at tick 0).
func _populate(sim: TrafficSim, reg: TrafficRegistry, road: StraightRoadPath, tt: TrafficTuning, rng: Rng,
		player: VehicleState, lanes: int, density: float, ops: Array) -> void:
	var target := int(density * lanes * (WINDOW_AHEAD_M + WINDOW_BEHIND_M) / 1000.0)
	var tries := 0
	while sim.state.count < mini(target, sim.state.capacity) and tries < target * POPULATE_TRIES:
		tries += 1
		var s := rng.float_range(player.s - WINDOW_BEHIND_M + 20.0, player.s + WINDOW_AHEAD_M)
		_try_spawn(sim, reg, road, tt, rng, player, lanes, s, 0, ops)


func _maintain(sim: TrafficSim, reg: TrafficRegistry, road: StraightRoadPath, tt: TrafficTuning, rng: Rng,
		player: VehicleState, lanes: int, density: float, k: int, ops: Array) -> void:
	var ts := sim.state
	for i in ts.capacity:
		if ts.active[i] == 1 and (ts.s[i] < player.s - WINDOW_BEHIND_M or ts.s[i] > player.s + WINDOW_AHEAD_M + 100.0):
			sim.despawn(i)
			ops.append([k, "despawn", i])
	var target := int(density * lanes * (WINDOW_AHEAD_M + WINDOW_BEHIND_M) / 1000.0)
	if ts.count >= mini(target, ts.capacity):
		return
	var s := player.s + WINDOW_AHEAD_M - rng.float_range(0.0, 50.0)
	if rng.chance(0.3):
		s = player.s - WINDOW_BEHIND_M + 30.0
	_try_spawn(sim, reg, road, tt, rng, player, lanes, s, k, ops)


func _try_spawn(sim: TrafficSim, reg: TrafficRegistry, road: StraightRoadPath, tt: TrafficTuning, rng: Rng,
		player: VehicleState, lanes: int, s: float, k: int, ops: Array) -> void:
	var pid := rng.int_range(0, reg.profile_count() - 1)
	var krl := reg.keep_right_lanes[pid]
	var ln := rng.int_range(lanes - krl if krl > 0 else 0, lanes - 1)
	var v0 := rng.float_range(reg.v0_min[pid], reg.v0_max[pid])
	var v := minf(v0, tt.lane_flow_speed_mps(ln, lanes))
	if s < player.s:
		v = maxf(v, player.v + 1.0)
		v0 = maxf(v0, v)
	var tids := reg.types_for_profile(pid)
	if tids.is_empty():
		return
	var tid := tids[rng.int_range(0, tids.size() - 1)]
	var d := road.lane_center_d(ln, s)
	var hl := reg.length[tid] * 0.5
	var ts := sim.state
	for i in ts.capacity:
		if ts.active[i] == 0:
			continue
		var in_lane := ts.lane[i] == ln or (ts.lc_state[i] != TrafficState.LaneChange.NONE and ts.target_lane[i] == ln) \
			or absf(ts.d[i] - d) < (ts.width[i] + reg.width[tid]) * 0.5 + 0.5
		if not in_lane:
			continue
		var need: float
		if ts.s[i] > s:
			need = Idm.desired_gap(v, v - ts.v[i], reg.a_max[pid], reg.b_comfort[pid], sim.headway(pid), reg.s0[pid])
		else:
			var q := ts.profile_id[i]
			need = Idm.desired_gap(ts.v[i], ts.v[i] - v, reg.a_max[q], reg.b_comfort[q], sim.headway(q), reg.s0[q])
		if absf(ts.s[i] - s) < hl + ts.length[i] * 0.5 + need + SPAWN_EXTRA_GAP_M:
			return
	var need_p := Idm.desired_gap(v, v - player.v, reg.a_max[pid], reg.b_comfort[pid], sim.headway(pid), reg.s0[pid])
	if absf(player.s - s) < hl + PLAYER_LENGTH_M * 0.5 + maxf(need_p, 0.0) + SPAWN_PLAYER_CLEAR_M:
		return
	if sim.closure_ahead(ln, s + hl) < tt.merge_spawn_clear_m:
		return
	var rec := SpawnSource.Record.new()
	rec.s = s
	rec.lane = ln
	rec.d = NAN
	rec.v = v
	rec.v0 = v0
	rec.profile_id = pid
	rec.type_id = tid
	rec.model_variant = 0
	rec.color_index = rng.int_range(0, 7)
	rec.flags = 0
	var slot := sim.spawn(rec)
	if slot >= 0:
		ops.append([k, "spawn", _hx(s), ln, _hx(ts.d[slot]), _hx(v), _hx(v0), tid, pid, 0, rec.color_index, 0])


## --dump: prints every live vehicle of this trace at this tick (to diff a divergence
## against the Rust replay's own dump).
func _dump(sim: TrafficSim, k: int) -> void:
	var ts := sim.state
	print("DUMP tick %d count %d" % [k, ts.count])
	for i in ts.capacity:
		if ts.active[i] == 0:
			continue
		print("DUMP slot=%d vid=%d s=%s d=%s v=%s a=%s lane=%d tl=%d lc=%d timer=%s dur=%s flags=%d lead=%d" % [
			i, ts.vehicle_id[i], _hx(ts.s[i]), _hx(ts.d[i]), _hx(ts.v[i]), _hx(ts.accel[i]), ts.lane[i],
			ts.target_lane[i], ts.lc_state[i], _hx(ts.lc_timer[i]), _hx(ts.lc_duration[i]), ts.flags[i],
			sim.leader_of(i)])
