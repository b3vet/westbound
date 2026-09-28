extends WBTest
## TrafficView (WP3.1). Spec: Traffic → Visuals (lights, motion, rendering pooled per
## model with shared materials and per-instance color), Lives → Fairness rules 1 and 3
## (blinkers, brake lights), Cameras → Glare rule (tail and brake lights always lit),
## Performance budget (draw calls, triangles), Traffic roster and vehicle budget
## (models, 3k tris). Contracts §2 (road space → world, godot_yaw), §5 (the view
## interpolates between ticks), §13 (floating origin).

const SEED := 20260928
const HEADING := 0.35
const GRADE := 0.03
const EPS := 1e-3
const POS_TOL := 0.01
const ANGLE_TOL := 1e-3
## Asset bounds vs VehicleType (spec: "wrong scale"). Width may exceed the type's body
## by the mirrors.
const LENGTH_TOL_FRAC := 0.05
const WIDTH_UNDER_FRAC := 0.05
const WIDTH_OVER_FRAC := 0.12
const HEIGHT_TOL_FRAC := 0.12
const GROUND_TOL_M := 0.02
const CENTER_TOL_M := 0.1

var _ctx: RunContext
var _road: StraightRoadPath
var _reg: TrafficRegistry
var _state: TrafficState
var _opp: TrafficState
var _origin: FloatingOrigin
var _view: TrafficView
var _tt: TrafficViewTuning
var _smp := RoadSample.new()


func before_each() -> void:
	_ctx = RunContext.new(SEED)
	_road = StraightRoadPath.new(3, _ctx.tuning.road, HEADING, GRADE, Vector3(100.0, 20.0, -50.0))
	_reg = TrafficRegistry.load_default(_ctx.tuning.traffic)
	_state = TrafficState.new(_ctx.tuning.traffic.max_active_vehicles)
	_opp = TrafficState.new(_ctx.tuning.traffic.opposite_max_vehicles)
	_origin = FloatingOrigin.new()
	tree.root.add_child(_origin)
	_origin.setup(_ctx.tuning.road.floating_origin_shift_km)
	_view = TrafficView.new()
	tree.root.add_child(_view)
	_view.setup(_ctx, _road, _origin, _reg, _state, _opp)
	_view.set_palette((load("res://data/biomes/farmland.tres") as BiomeDef).traffic_palette)
	_tt = _view.tuning


func after_each() -> void:
	for n: Node in [_view, _origin]:
		if is_instance_valid(n):
			n.free()


func _spawn(st: TrafficState, type_id: StringName, lane: int, s: float, v: float, flags: int = 0,
		variant: int = 0, color: int = 0) -> int:
	var i := st.allocate()
	var t := _reg.type_index(type_id)
	st.s[i] = s
	st.d[i] = _road.lane_center_d(lane, s) if st == _state else _road.opposite_lane_center_d(lane, s)
	st.v[i] = v
	st.length[i] = _reg.length[t]
	st.width[i] = _reg.width[t]
	st.lane[i] = lane
	st.type_id[i] = t
	st.model_variant[i] = variant
	st.color_index[i] = color
	st.flags[i] = flags
	return i


func _local(s: float, d: float) -> Vector3:
	_road.sample_into(s, _smp)
	return _smp.local_point(d, _origin.origin_x, _origin.origin_y, _origin.origin_z)


func _near_v(a: Vector3, b: Vector3, tol: float, msg: String) -> bool:
	if a.distance_to(b) > tol:
		fail("%s: expected %s, got %s" % [msg, b, a])
		return false
	return true


## Signed angle (rad, + = clockwise seen from above, i.e. to the right) from a to b.
func _yaw_between(a: Vector3, b: Vector3) -> float:
	var ah := Vector2(a.x, a.z).normalized()
	var bh := Vector2(b.x, b.z).normalized()
	return ah.angle_to(bh)


# ---------------------------------------------------------------- Mapping

func test_slot_at_lane_center_follows_road_frame() -> void:
	var i := _spawn(_state, &"sedan", 1, 120.0, 30.0)
	_view.capture_tick()
	var xf := _view.slot_transform(i, false, 1.0)
	_near_v(xf.origin, _local(120.0, _state.d[i]), POS_TOL, "position = road local_point(s, d)")
	_road.sample_into(120.0, _smp)
	_near_v(-xf.basis.z, _smp.tangent, EPS, "model -Z (forward) = road tangent (grade included)")
	_near_v(xf.basis.x, _smp.right, EPS, "model +X = road right")
	_near_v(xf.basis.y, _smp.up, EPS, "model +Y = road up")
	# Godot yaw convention (CONTRACTS §2): rotation.y = -(heading + yaw) on a flat road.
	var flat := StraightRoadPath.new(3, _ctx.tuning.road, HEADING)
	var smp := flat.sample(0.0)
	var b := Basis(smp.right, smp.up, -smp.tangent)
	near(b.get_euler().y, smp.godot_yaw(0.0), ANGLE_TOL, "basis yaw = godot_yaw")


func test_lane_change_yaw_points_into_the_lane() -> void:
	var v := 25.0
	var i := _spawn(_state, &"sedan", 1, 200.0, v)
	_state.v_lat[i] = 2.0
	var j := _spawn(_state, &"sedan", 1, 260.0, v)
	_state.v_lat[j] = -2.0
	_view.capture_tick()
	_road.sample_into(200.0, _smp)
	var fwd := -_view.slot_transform(i, false, 1.0).basis.z
	near(_yaw_between(_smp.tangent, fwd), atan2(2.0, v), ANGLE_TOL, "yaw = atan2(v_lat, v)")
	gt(fwd.dot(_smp.right), 0.0, "moving right: nose right")
	var fwd_j := -_view.slot_transform(j, false, 1.0).basis.z
	lt(fwd_j.dot(_smp.right), 0.0, "moving left: nose left")
	# The up vector stays the road normal while yawed.
	_near_v(_view.slot_transform(i, false, 1.0).basis.y, _smp.up, EPS, "yaw about the road normal")


func test_lane_change_yaw_is_floored_and_clamped() -> void:
	var i := _spawn(_state, &"sedan", 1, 200.0, 0.0)
	_state.v_lat[i] = 1.5
	_view.capture_tick()
	_road.sample_into(200.0, _smp)
	var yaw := _yaw_between(_smp.tangent, -_view.slot_transform(i, false, 1.0).basis.z)
	near(yaw, minf(atan2(1.5, _tt.yaw_min_speed_mps()), deg_to_rad(_tt.yaw_max_deg)), ANGLE_TOL,
		"a stopped car sliding sideways never turns broadside")


func test_opposite_carriageway_faces_minus_s() -> void:
	var i := _spawn(_opp, &"suv", 1, 300.0, 30.0)
	_view.capture_tick()
	var xf := _view.slot_transform(i, true, 1.0)
	lt(_opp.d[i], 0.0, "opposite side is d < 0")
	_near_v(xf.origin, _local(300.0, _opp.d[i]), POS_TOL, "position on the opposite carriageway")
	_road.sample_into(300.0, _smp)
	_near_v(-xf.basis.z, -_smp.tangent, EPS, "rotated 180 deg: forward = -tangent")
	# A lateral move toward -d is to that vehicle's right: nose right of its heading.
	_opp.v_lat[i] = -2.0
	_view.capture_tick()
	var fwd := -_view.slot_transform(i, true, 1.0).basis.z
	near(_yaw_between(-_smp.tangent, fwd), atan2(2.0, 30.0), ANGLE_TOL, "opposite lane-change yaw")


func test_interpolates_between_two_ticks() -> void:
	var i := _spawn(_state, &"sedan", 1, 100.0, 30.0)
	_view.capture_tick()
	_state.s[i] = 101.0
	_state.d[i] += 0.2
	_view.capture_tick()
	var d0 := _state.d[i] - 0.2
	_near_v(_view.slot_transform(i, false, 0.0).origin, _local(100.0, d0), POS_TOL, "fraction 0 = previous tick")
	_near_v(_view.slot_transform(i, false, 0.5).origin, _local(100.5, d0 + 0.1), POS_TOL, "fraction 0.5 = midway")
	_near_v(_view.slot_transform(i, false, 1.0).origin, _local(101.0, d0 + 0.2), POS_TOL, "fraction 1 = last tick")


func test_teleport_and_slot_reuse_do_not_interpolate() -> void:
	var i := _spawn(_state, &"sedan", 1, 100.0, 30.0)
	_view.capture_tick()
	_state.s[i] = 100.0 + _tt.teleport_distance_m * 3.0
	_view.capture_tick()
	_near_v(_view.slot_transform(i, false, 0.0).origin, _local(_state.s[i], _state.d[i]), POS_TOL,
		"a jump snaps instead of sweeping")
	# Free the slot and reuse it (a new vehicle_id) in the same tick.
	_state.free_slot(i)
	var k := _spawn(_state, &"hatchback", 2, 400.0, 30.0)
	eq(k, i, "slot reused")
	_view.capture_tick()
	_near_v(_view.slot_transform(k, false, 0.0).origin, _local(400.0, _state.d[k]), POS_TOL,
		"a new vehicle in a reused slot starts at its own position")
	eq(_view.slot_model(k), _view_model_index(&"hatchback_a"), "model follows the new vehicle's type")


func test_floating_origin_shift_moves_render_space() -> void:
	var i := _spawn(_state, &"sedan", 1, 100.0, 30.0)
	_view.capture_tick()
	_view.render(1.0)
	var before := _view.slot_transform(i, false, 1.0).origin
	var shift := _ctx.tuning.road.floating_origin_shift_km * 1000.0 + 10.0
	check(_origin.update_focus(shift, 0.0, 0.0), "origin shifted")
	var after := _view.slot_transform(i, false, 1.0).origin
	_near_v(after, before - _origin.last_offset, POS_TOL, "render position moves by -offset")


# ---------------------------------------------------------------- Lights

func _bits(i: int, opposite: bool = false) -> int:
	return _view.slot_bits(i, opposite, 1.0)


func test_brake_lights_follow_flags() -> void:
	var a := _spawn(_state, &"sedan", 0, 100.0, 30.0)
	var b := _spawn(_state, &"sedan", 1, 100.0, 30.0, TrafficState.FLAG_BRAKE)
	var c := _spawn(_state, &"sedan", 2, 100.0, 30.0, TrafficState.FLAG_BRAKE | TrafficState.FLAG_BRAKE_STRONG)
	_view.capture_tick()
	eq(_bits(a) & (TrafficLights.BIT_BRAKE | TrafficLights.BIT_BRAKE_STRONG), 0, "no brake")
	eq(_bits(b) & (TrafficLights.BIT_BRAKE | TrafficLights.BIT_BRAKE_STRONG), TrafficLights.BIT_BRAKE, "brake")
	eq(_bits(c) & (TrafficLights.BIT_BRAKE | TrafficLights.BIT_BRAKE_STRONG),
		TrafficLights.BIT_BRAKE | TrafficLights.BIT_BRAKE_STRONG, "strong brake")
	# Brightness: tail (always lit) < brake < strong brake, in the shared material.
	var m := load("res://assets/shaders/materials/traffic.tres") as ShaderMaterial
	var tail_day := float(m.get_shader_parameter(&"tail_day_level"))
	var tail_night := float(m.get_shader_parameter(&"tail_night_level"))
	var brake := float(m.get_shader_parameter(&"brake_level"))
	var strong := float(m.get_shader_parameter(&"brake_strong_level"))
	gt(tail_day, 0.0, "glare rule: tail lamps emissive by day")
	gt(tail_night, tail_day, "tail lamps brighter with the headlights on")
	gt(brake, tail_night, "brake brighter than tail")
	gt(strong, brake, "strong brake brighter than brake")
	# Glow sprites: none for a plain car by day; the rear pair for brakes, stronger kind.
	eq(TrafficLights.rear_kind(_bits(a), TrafficLights.BIT_BLINK_L, false), TrafficLights.KIND_OFF)
	eq(TrafficLights.rear_kind(_bits(b), TrafficLights.BIT_BLINK_L, false), TrafficLights.KIND_BRAKE)
	eq(TrafficLights.rear_kind(_bits(c), TrafficLights.BIT_BLINK_L, false), TrafficLights.KIND_BRAKE_STRONG)
	_view.render(1.0)
	eq(_view.glow_count(), 2, "one rear glow pair per braking car, none for the others (day)")


func test_headlights_only_with_the_flag_and_tail_glow_at_night() -> void:
	var day := _spawn(_state, &"sedan", 0, 100.0, 30.0)
	var night := _spawn(_state, &"sedan", 1, 100.0, 30.0, TrafficState.FLAG_HEADLIGHTS)
	var opp := _spawn(_opp, &"sedan", 1, 150.0, 30.0, TrafficState.FLAG_HEADLIGHTS)
	_view.capture_tick()
	eq(_bits(day) & TrafficLights.BIT_HEAD, 0, "headlights off by day")
	eq(_bits(night) & TrafficLights.BIT_HEAD, TrafficLights.BIT_HEAD, "headlights on at night")
	eq(_bits(opp, true) & TrafficLights.BIT_HEAD, TrafficLights.BIT_HEAD, "opposite headlights at night")
	eq(TrafficLights.front_kind(_bits(night), TrafficLights.BIT_BLINK_L), TrafficLights.KIND_HEAD)
	eq(TrafficLights.rear_kind(_bits(night), TrafficLights.BIT_BLINK_L, false), TrafficLights.KIND_TAIL,
		"tail lamps glow at night")
	_view.render(1.0)
	eq(_view.glow_count(), 4, "front and rear pairs for both lit cars, none for the day car")


func test_high_beam_flag_is_ignored() -> void:
	var i := _spawn(_state, &"sedan", 1, 100.0, 30.0, TrafficState.FLAG_HIGH_BEAM)
	_view.capture_tick()
	eq(_bits(i), 0, "owner decision D8: no high beams")


## Rising edges of `bit` over `ticks` captures after the flags are set; returns their tick indices.
func _edges(i: int, bit: int, ticks: int, opposite: bool = false) -> PackedInt32Array:
	var out := PackedInt32Array()
	var was := false
	for k in ticks:
		_view.capture_tick()
		var on := (_view.slot_bits(i, opposite, 1.0) & bit) != 0
		if on and not was:
			out.append(k)
		was = on
	return out


func test_blinkers_flash_at_the_tuned_rate_starting_lit() -> void:
	var i := _spawn(_state, &"sedan", 1, 100.0, 30.0)
	_view.capture_tick()
	_state.set_flag(i, TrafficState.FLAG_BLINKER_LEFT, true)
	var dt := _ctx.tuning.traffic.near_dt()
	var period_ticks := 1.0 / (_tt.blinker_hz * dt)
	var edges := _edges(i, TrafficLights.BIT_BLINK_L, ceili(period_ticks * 4.0))
	check(edges.size() >= 4, "flashes repeatedly")
	eq(edges[0], 0, "the first flash is immediate (telegraphing starts lit)")
	for k in range(1, edges.size()):
		near(float(edges[k] - edges[k - 1]), period_ticks, 1.0, "period = 1 / blinker_hz")
	eq(_bits(i) & TrafficLights.BIT_BLINK_R, 0, "right side stays dark")
	# Duty: lit share of a period.
	var lit := 0
	var n := roundi(period_ticks) * 2
	for k in n:
		_view.capture_tick()
		if (_bits(i) & TrafficLights.BIT_BLINK_L) != 0:
			lit += 1
	near(float(lit) / float(n), _tt.blinker_duty_frac(), 2.0 / period_ticks, "duty")
	_state.set_flag(i, TrafficState.FLAG_BLINKER_LEFT, false)
	_view.capture_tick()
	eq(_bits(i) & TrafficLights.BIT_BLINK_L, 0, "off with the flag")


func test_hazards_flash_both_sides_together() -> void:
	var i := _spawn(_state, &"suv", 1, 100.0, 30.0)
	_view.capture_tick()
	_state.set_flag(i, TrafficState.FLAG_HAZARD, true)
	var both := TrafficLights.BIT_BLINK_L | TrafficLights.BIT_BLINK_R
	var seen_on := false
	var seen_off := false
	for k in roundi(2.0 / (_tt.blinker_hz * _ctx.tuning.traffic.near_dt())):
		_view.capture_tick()
		var b := _bits(i) & both
		check(b == 0 or b == both, "hazards: both sides in phase")
		seen_on = seen_on or b == both
		seen_off = seen_off or b == 0
	check(seen_on and seen_off, "hazards flash")
	eq(TrafficLights.rear_kind(both, TrafficLights.BIT_BLINK_R, false), TrafficLights.KIND_BLINKER)


func test_blinker_change_restarts_the_cycle() -> void:
	var i := _spawn(_state, &"sedan", 1, 100.0, 30.0, TrafficState.FLAG_BLINKER_LEFT)
	var dt := _ctx.tuning.traffic.near_dt()
	# Run into the dark half of the cycle, then add hazards: both lamps light at once.
	for k in ceili(_tt.blinker_duty_frac() / (_tt.blinker_hz * dt)) + 2:
		_view.capture_tick()
	eq(_bits(i) & TrafficLights.BIT_BLINK_L, 0, "in the dark half")
	_state.set_flag(i, TrafficState.FLAG_HAZARD, true)
	_view.capture_tick()
	eq(_bits(i) & (TrafficLights.BIT_BLINK_L | TrafficLights.BIT_BLINK_R),
		TrafficLights.BIT_BLINK_L | TrafficLights.BIT_BLINK_R, "hazards start lit")


func test_view_bits_match_the_helper() -> void:
	var i := _spawn(_state, &"sedan", 1, 100.0, 30.0)
	_view.capture_tick()
	for flags in 1 << 9:
		_state.flags[i] = flags
		_view.capture_tick()
		var mask := TrafficLights.blink_mask(flags)
		eq(_bits(i), TrafficLights.bits(flags, mask, _ctx.tuning.traffic.near_dt(), _tt.blinker_hz,
			_tt.blinker_duty_frac()), "flags %d" % flags)


func test_light_helpers() -> void:
	eq(TrafficLights.blink_mask(0), 0)
	eq(TrafficLights.blink_mask(TrafficState.FLAG_BLINKER_RIGHT), TrafficLights.MASK_R)
	eq(TrafficLights.blink_mask(TrafficState.FLAG_HAZARD), TrafficLights.MASK_L | TrafficLights.MASK_R)
	for bits in 32:
		for slot: int in [0, 7, 31, TrafficLights.PALETTE_SLOTS - 1]:
			var p := TrafficLights.pack(bits, slot)
			lt(p, 2048.0, "packed value exact in a 16-bit float")
			eq(TrafficLights.unpack_bits(p), bits)
			eq(TrafficLights.unpack_slot(p), slot)
	# Priority: blinker > strong brake > brake > tail.
	var all := TrafficLights.BIT_BRAKE | TrafficLights.BIT_BRAKE_STRONG | TrafficLights.BIT_HEAD
	eq(TrafficLights.rear_kind(all | TrafficLights.BIT_BLINK_L, TrafficLights.BIT_BLINK_L, false),
		TrafficLights.KIND_BLINKER)
	eq(TrafficLights.rear_kind(all, TrafficLights.BIT_BLINK_L, false), TrafficLights.KIND_BRAKE_STRONG)
	eq(TrafficLights.rear_kind(0, TrafficLights.BIT_BLINK_L, true), TrafficLights.KIND_TAIL, "day tail option")
	check(TrafficLights.KIND_BLINKER > TrafficLights.KIND_BRAKE_STRONG and
		TrafficLights.KIND_BRAKE_STRONG > TrafficLights.KIND_BRAKE and TrafficLights.KIND_BRAKE > TrafficLights.KIND_TAIL,
		"kinds rise with priority (single-lamp glows take the max)")


# ---------------------------------------------------------------- Motion

func test_wheels_spin_with_speed_and_body_moves_with_accel() -> void:
	var i := _spawn(_state, &"sedan", 1, 100.0, 30.0)
	var j := _spawn(_state, &"sedan", 2, 100.0, 0.0)
	var dt := _ctx.tuning.traffic.near_dt()
	_view.capture_tick()
	_view.render(1.0)
	var w0 := _view.slot_custom(i, false, 1.0).r
	_view.capture_tick()
	_view.render(0.5)
	var w_half := _view.slot_custom(i, false, 0.5).r
	_view.capture_tick()
	_view.render(1.0)
	var w1 := _view.slot_custom(i, false, 1.0).r
	var r := float(TrafficView.load_model_mesh(_reg.types[_state.type_id[i]].model_scene_paths[0]).get_meta(&"wheel_radius_m"))
	near(w_half - w0, 0.5 * 30.0 * dt / r, EPS, "wheels advance by v * (sim time since the last frame) / r")
	near(w1 - w0, 2.0 * 30.0 * dt / r, EPS, "two ticks later")
	near(_view.slot_custom(j, false, 1.0).r, 0.0, EPS, "a stopped car's wheels stand still")
	# Braking pitches the nose down; accelerating to the right leans the body left.
	_state.accel[i] = -5.0
	for k in 120:
		_state.v_lat[i] = 1.5 * float(k) / 120.0
		_view.capture_tick()
		_view.render(1.0)
	var c := _view.slot_custom(i, false, 1.0)
	lt(c.b, 0.0, "braking: nose down")
	ge(c.b, -deg_to_rad(_tt.body_pitch_max_deg) - EPS, "pitch within the clamp")
	gt(c.g, 0.0, "accelerating to the right: body leans left (+roll)")
	le(c.g, deg_to_rad(_tt.body_roll_max_deg) + EPS, "roll within the clamp")
	# Body motion is visual only: the sim state is untouched.
	eq(_state.accel[i], -5.0)


# ---------------------------------------------------------------- Pool and budget

func _view_model_index(id: StringName) -> int:
	for k in _view.model_count():
		if _view.model_id(k) == id:
			return k
	return -1


## Every model once (types and variants in order), then cycles until n vehicles.
func _spawn_mix(n: int, s0: float) -> void:
	var k := 0
	while k < n:
		for t in _reg.types.size():
			for variant in _reg.types[t].model_scene_paths.size():
				if k >= n:
					return
				var i := _spawn(_state, _reg.types[t].id, k % 3, s0 + 25.0 * float(k), 30.0, 0, variant, k)
				check(i >= 0)
				k += 1


func _instances() -> int:
	var n := 0
	for k in _view.model_count():
		n += _view.model_instances(k)
	return n


func test_instance_counts_follow_active_slots() -> void:
	_spawn_mix(40, 100.0)
	var o := _spawn(_opp, &"coach", 0, 500.0, 30.0)
	_view.capture_tick()
	_view.render(1.0)
	eq(_instances(), 41, "one instance per live vehicle")
	eq(_view.visible_count(), 41)
	eq(_view.shadow_count(), 41, "one blob shadow each")
	var per := PackedInt32Array()
	per.resize(_view.model_count())
	for i in _state.capacity:
		if _state.active[i] == 1:
			per[_view.slot_model(i)] += 1
	per[_view.slot_model(o, true)] += 1
	for k in _view.model_count():
		eq(_view.model_instances(k), per[k], "model %s instances" % _view.model_id(k))
	# Free some: their instances go away (hidden) on the next frame.
	for i: int in [0, 3, 7]:
		_state.free_slot(i)
	_opp.free_slot(o)
	_view.capture_tick()
	_view.render(1.0)
	eq(_instances(), 37, "freed slots are not drawn")
	eq(_view.slot_model(3), -1, "freed slot has no model")


func test_draw_calls_do_not_grow_with_vehicle_count() -> void:
	_spawn_mix(_view.model_count(), 100.0)
	_view.capture_tick()
	_view.render(1.0)
	var few := _view.draw_calls()
	_spawn_mix(_state.capacity - _state.count, 1000.0)
	for i in _opp.capacity:
		_spawn(_opp, &"sedan", i % 3, 200.0 + 30.0 * float(i), 30.0, TrafficState.FLAG_HEADLIGHTS)
	_view.capture_tick()
	_view.render(1.0)
	eq(_view.visible_count(), _state.capacity + _opp.capacity)
	le(_view.draw_calls(), few + 1, "draw calls independent of count (+1 once any glow shows)")
	le(_view.draw_calls(), _view.model_count() + 2, "at most one per model + glow + shadows")
	var budget := _ctx.tuning.progression.traffic_tris_lod0 * (_state.capacity + _opp.capacity)
	le(_view.triangles(), budget, "triangles within the per-vehicle budget")
	print("  traffic view at %d vehicles: %d draw calls, %d triangles, %d glows" % [
		_view.visible_count(), _view.draw_calls(), _view.triangles(), _view.glow_count()])


func test_pool_does_not_grow_under_churn() -> void:
	var rng := Rng.new(SEED).derive(&"churn")
	var caps := PackedInt32Array()
	for k in _view.model_count():
		caps.append(_view.model_capacity(k))
	var children := _view.get_child_count()
	var mem0 := 0
	for tick in 3000:
		if rng.unit() < 0.3 and not _state.is_full():
			var t := rng.int_range(0, _reg.types.size() - 1)
			_spawn(_state, _reg.types[t].id, rng.int_range(0, 2), rng.float_range(0.0, 900.0), 30.0,
				rng.int_range(0, 63), rng.int_range(0, 2), rng.int_range(0, 9))
		if rng.unit() < 0.25 and _state.count > 0:
			var i := rng.int_range(0, _state.capacity - 1)
			if _state.active[i] == 1:
				_state.free_slot(i)
		for i in _state.capacity:
			if _state.active[i] == 1:
				_state.s[i] += _state.v[i] * _ctx.tuning.traffic.near_dt()
		_view.capture_tick()
		_view.render(0.5)
		if tick == 500:
			mem0 = OS.get_static_memory_usage()
		eq(_instances(), _state.count, "instances track live vehicles")
		if _instances() != _state.count:
			return
	for k in _view.model_count():
		eq(_view.model_capacity(k), caps[k], "pool capacity fixed")
	eq(_view.get_child_count(), children, "no nodes added")
	le(OS.get_static_memory_usage() - mem0, 0, "no memory growth after warm-up")


func test_palette_colors_and_fixed_model_palettes() -> void:
	var pal := PackedColorArray([Color.RED, Color.GREEN, Color.BLUE])
	_view.set_palette(pal)
	var a := _spawn(_state, &"sedan", 1, 100.0, 30.0, 0, 0, 5)
	var bike := _spawn(_state, &"motorbike", 0, 120.0, 30.0, 0, 0, 1)
	_view.capture_tick()
	eq(_view.slot_paint(a), Color.BLUE, "color_index wraps into the biome palette")
	var mesh := TrafficView.load_model_mesh(_reg.types[_state.type_id[bike]].model_scene_paths[0])
	var own: PackedColorArray = mesh.get_meta(&"paint_palette")
	eq(_view.slot_paint(bike), own[1], "motorbikes keep their fixed palette")


func test_render_budget_bench() -> void:
	_spawn_mix(_state.capacity, 100.0)
	for i in _opp.capacity:
		_spawn(_opp, &"sedan", i % 3, 200.0 + 30.0 * float(i), 30.0)
	var n := _state.capacity + _opp.capacity
	_view.capture_tick()
	_view.capture_tick()
	var day := WBBench.usec_per_call(_view.render.bind(0.5), 20)
	WBBench.report("traffic view render, %d vehicles by day" % n, day, 2000.0)
	le(day, WBBench.budget(2000.0), "render usec (day)")
	for i in _state.capacity:
		_state.set_flag(i, TrafficState.FLAG_HEADLIGHTS, true)
	for i in _opp.capacity:
		_opp.set_flag(i, TrafficState.FLAG_HEADLIGHTS, true)
	_view.capture_tick()
	var night := WBBench.usec_per_call(_view.render.bind(0.5), 20)
	WBBench.report("traffic view render, %d vehicles at night (%d glows)" % [n, _view.glow_count()], night, 3000.0)
	le(night, WBBench.budget(3000.0), "render usec (night)")
	var cap_usec := WBBench.usec_per_call(_view.capture_tick, 50)
	WBBench.report("traffic view capture_tick, %d vehicles" % n, cap_usec, 600.0)
	le(cap_usec, WBBench.budget(600.0), "capture usec")


# ---------------------------------------------------------------- Assets

func test_every_vehicle_type_has_valid_models() -> void:
	var pt := _ctx.tuning.progression
	var models := 0
	for t in _reg.types:
		gt(t.model_scene_paths.size(), 0, "%s has a model" % t.id)
		for path in t.model_scene_paths:
			models += 1
			var mesh := TrafficView.load_model_mesh(path)
			if not check(mesh != null, "%s loads" % path):
				continue
			var tris := TrafficView.mesh_triangles(mesh)
			le(tris, pt.traffic_tris_lod0, "%s tris within the LOD0 budget" % path)
			eq(StringName(mesh.get_meta(&"vehicle_type", &"")), t.id, "%s built for %s" % [path, t.id])
			var bb := mesh.get_aabb()
			within_pct(bb.size.z, t.length_m, LENGTH_TOL_FRAC, "%s length" % path)
			ge(bb.size.x, t.width_m * (1.0 - WIDTH_UNDER_FRAC), "%s width" % path)
			le(bb.size.x, t.width_m * (1.0 + WIDTH_OVER_FRAC), "%s width (mirrors)" % path)
			within_pct(bb.size.y, t.height_m, HEIGHT_TOL_FRAC, "%s height" % path)
			near(bb.position.y, 0.0, GROUND_TOL_M, "%s on the ground" % path)
			near(bb.get_center().x, 0.0, CENTER_TOL_M, "%s centered across" % path)
			near(bb.get_center().z, 0.0, t.length_m * LENGTH_TOL_FRAC, "%s centered along" % path)
			_check_orientation(path, mesh)
			var front: Vector3 = mesh.get_meta(&"glow_front")
			var rear: Vector3 = mesh.get_meta(&"glow_rear")
			lt(front.z, 0.0, "%s headlights at -Z (forward)" % path)
			gt(rear.z, 0.0, "%s tail lamps at +Z" % path)
			gt(float(mesh.get_meta(&"wheel_radius_m", 0.0)), 0.0, "%s wheel radius" % path)
			var mat := mesh.surface_get_material(0) as ShaderMaterial
			check(mat != null and mat.shader.resource_path == "res://assets/shaders/traffic.gdshader",
				"%s uses the traffic shader" % path)
	ge(models, 14, "spec roster: about 14 models")


## Head lamps sit at the front (-Z), rear lamps at the back, wheels touch the ground,
## and every lamp group exists.
func _check_orientation(path: String, mesh: Mesh) -> void:
	var arrays := mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var sum := PackedFloat64Array()
	var cnt := PackedInt32Array()
	sum.resize(TrafficLights.PART_COUNT)
	cnt.resize(TrafficLights.PART_COUNT)
	var wheel_min_y := INF
	for k in v.size():
		var part := roundi(uv[k].x)
		if part < 0 or part >= sum.size():
			fail("%s: unknown part %d" % [path, part])
			return
		sum[part] += v[k].z
		cnt[part] += 1
		if part == TrafficLights.PART_WHEEL:
			wheel_min_y = minf(wheel_min_y, v[k].y)
	for p: int in [TrafficLights.PART_PAINT, TrafficLights.PART_WHEEL, TrafficLights.PART_HEAD,
			TrafficLights.PART_REAR, TrafficLights.PART_BLINK_L, TrafficLights.PART_BLINK_R]:
		gt(cnt[p], 0, "%s has part %d" % [path, p])
	if cnt[TrafficLights.PART_HEAD] > 0 and cnt[TrafficLights.PART_REAR] > 0:
		lt(sum[TrafficLights.PART_HEAD] / cnt[TrafficLights.PART_HEAD], 0.0, "%s headlamps forward (-Z)" % path)
		gt(sum[TrafficLights.PART_REAR] / cnt[TrafficLights.PART_REAR], 0.0, "%s tail lamps rearward" % path)
	near(wheel_min_y, 0.0, GROUND_TOL_M, "%s wheels touch the ground" % path)
