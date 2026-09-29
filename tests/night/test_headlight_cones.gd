extends WBTest
## HeadlightCones (WP5.4): traffic headlight light-cone decals, one MultiMesh, capped
## per quality tier to the nearest vehicles with headlights on; hidden by day; follows
## the drawn poses; no objects per frame. Also the TrafficView hooks it uses
## (is_slot_drawn, headlight_pools). Spec: World → Night lighting (traffic
## headlights); Performance budget (draw calls, counts per tier). docs/NIGHT.md.

const SKY_SCENE := "res://src/sun/sky.tscn"
const SEED := 20260929
const S0 := 400.0
const SPEED_MPS := 30.0
const GAP_M := 12.0

var _ctx: RunContext
var _night: NightTuning
var _road: StraightRoadPath
var _reg: TrafficRegistry
var _state: TrafficState
var _opp: TrafficState
var _origin: FloatingOrigin
var _view: TrafficView
var _sky: SkyRig
var _cones: HeadlightCones


func before_each() -> void:
	_ctx = RunContext.new(SEED)
	_night = NightTuning.load_default()
	_road = StraightRoadPath.new(3, _ctx.tuning.road)
	_reg = TrafficRegistry.load_default(_ctx.tuning.traffic)
	_state = TrafficState.new(_ctx.tuning.traffic.max_active_vehicles)
	_opp = TrafficState.new(_ctx.tuning.traffic.max_active_vehicles)
	_origin = FloatingOrigin.new()
	tree.root.add_child(_origin)
	_origin.setup(_ctx.tuning.road.floating_origin_shift_km)
	_view = TrafficView.new()
	_view.headlight_pools = false
	tree.root.add_child(_view)
	_view.setup(_ctx, _road, _origin, _reg, _state, _opp)
	_sky = (load(SKY_SCENE) as PackedScene).instantiate() as SkyRig
	_sky.push_sink = func(_n: StringName, _v: Variant) -> void: pass
	_sky.set_process(false)
	tree.root.add_child(_sky)
	_cones = HeadlightCones.new()
	_cones.sky = _sky
	_cones.fraction_override = 1.0
	tree.root.add_child(_cones)
	_cones.setup(_ctx, _road, _origin)
	_cones.bind(_view, _state, _opp)
	_set_sky(_ctx.tuning.sun.sky_t_night)


func after_each() -> void:
	for n: Node in [_cones, _sky, _view, _origin]:
		if is_instance_valid(n):
			n.free()


func _set_sky(t: float) -> void:
	_sky.sky_t = t
	_sky.push_now()


func _spawn(st: TrafficState, s: float, lane: int, flags: int = TrafficState.FLAG_HEADLIGHTS) -> int:
	var i := st.allocate()
	var t := _reg.type_index(&"sedan")
	st.s[i] = s
	st.d[i] = _road.lane_center_d(lane, s) if st == _state else _road.opposite_lane_center_d(lane, s)
	st.v[i] = SPEED_MPS
	st.length[i] = _reg.length[t]
	st.width[i] = _reg.width[t]
	st.lane[i] = lane
	st.type_id[i] = t
	st.flags[i] = flags
	return i


func _frame(focus_s: float = S0) -> void:
	_view.capture_tick()
	_view.render(1.0)
	_cones.update_view(focus_s)


func test_hidden_by_day_visible_at_night() -> void:
	_spawn(_state, S0 + 30.0, 1)
	_set_sky(_ctx.tuning.sun.sky_t_afternoon)
	_frame()
	eq(_cones.count(), 0, "day: no cones")
	check(not _cones.node().visible, "day: hidden, not alpha 0")
	eq(_cones.draw_calls(), 0)
	_set_sky(_ctx.tuning.sun.sky_t_night)
	_frame()
	eq(_cones.count(), 1, "night: one cone")
	check(_cones.node().visible)
	eq(_cones.draw_calls(), 1, "one draw call")


func test_only_vehicles_with_headlights() -> void:
	_spawn(_state, S0 + 20.0, 0, 0)
	var lit := _spawn(_state, S0 + 40.0, 1)
	_frame()
	eq(_cones.count(), 1)
	eq(_cones.cone_slot(0), lit, "the lit one")


func test_capped_per_tier_and_nearest_first() -> void:
	var n := 24
	for k in n:
		# Alternate ahead and behind, both carriageways, spread over the range.
		var ds := GAP_M * float(floori(k / 2.0) + 1) * (1.0 if k % 2 == 0 else -1.0)
		_spawn(_state if k % 3 != 0 else _opp, S0 + ds, k % 3)
	for tier in _night.traffic_cones_per_tier.size():
		_cones.tier_index_override = tier
		_frame()
		var cap := _night.traffic_cones_per_tier[tier]
		eq(_cones.count(), mini(cap, n), "tier %d: capped at %d" % [tier, cap])
		le(_cones.multimesh().visible_instance_count, _cones.multimesh().instance_count, "never past the pool")
		# The drawn cones are the nearest: none left out is closer than the farthest drawn.
		var farthest := 0.0
		var chosen := {}
		for k in _cones.count():
			var st := _state if _cones.cone_side(k) == HeadlightCones.CARRIAGEWAY else _opp
			farthest = maxf(farthest, absf(st.s[_cones.cone_slot(k)] - S0))
			chosen[Vector2i(_cones.cone_side(k), _cones.cone_slot(k))] = true
		for side in 2:
			var st := _state if side == 0 else _opp
			for i in st.capacity:
				if st.active[i] != 0 and not chosen.has(Vector2i(side, i)):
					ge(absf(st.s[i] - S0), farthest - 1e-6, "left-out vehicle %d/%d is not nearer" % [side, i])
	eq(_cones.capacity(), 16, "the pool is the largest tier cap")


func test_out_of_range_and_hidden_slots_are_skipped() -> void:
	_spawn(_state, S0 + _night.traffic_cone_range_m + 20.0, 1)
	var hidden := _spawn(_state, S0 + 30.0, 2)
	_frame()
	_view.set_slot_hidden(hidden, true)
	check(not _view.is_slot_drawn(hidden), "TrafficView.is_slot_drawn follows set_slot_hidden")
	_frame()
	eq(_cones.count(), 0, "beyond the range, or hidden (crash body): no cone")


func test_cone_starts_at_the_front_bumper_and_fades_at_range() -> void:
	var near_i := _spawn(_state, S0 + 30.0, 1)
	var far_i := _spawn(_state, S0 + _night.traffic_cone_range_m - 5.0, 0)
	_frame()
	eq(_cones.count(), 2)
	eq(_cones.cone_slot(0), near_i, "nearest first")
	var body := _view.slot_transform(near_i, false, 1.0)
	var xf := _cones.cone_transform(0)
	var ahead := (xf.origin - body.origin).dot(-body.basis.z)
	near(ahead, _state.length[near_i] * 0.5, 0.01, "at the front bumper")
	check(xf.basis.is_equal_approx(body.basis), "same orientation as the body")
	near(_cones.cone_strength(0), 1.0, 1e-3, "full strength nearby")
	lt(_cones.cone_strength(1), 0.2, "fading at the edge of the range")
	eq(_cones.cone_slot(1), far_i)


func test_opposite_carriageway_cones_point_the_other_way() -> void:
	var i := _spawn(_opp, S0 + 50.0, 0)
	_frame()
	eq(_cones.count(), 1)
	eq(_cones.cone_side(0), HeadlightCones.OPPOSITE)
	var fwd := -_cones.cone_transform(0).basis.z
	var smp := _road.sample(S0 + 50.0)
	lt(fwd.dot(smp.tangent), -0.9, "oncoming traffic lights toward -s")
	eq(_cones.cone_slot(0), i)


func test_glow_pools_off_when_cones_draw_them() -> void:
	var glow := _view.get_node(^"Glow") as MultiMeshInstance3D
	var mat := glow.material_override as ShaderMaterial
	near(float(mat.get_shader_parameter(&"pool_strength")), 0.0, 1e-9, "pools off in this view")
	ne(mat, TrafficView.GLOW_MATERIAL, "a copy: the shared material keeps its pools")
	gt(float(TrafficView.GLOW_MATERIAL.get_shader_parameter(&"pool_strength")), 0.0)


func test_no_objects_per_frame() -> void:
	for k in 20:
		_spawn(_state, S0 + GAP_M * float(k - 10), k % 3)
	_frame()
	_frame()
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	for f in 30:
		for i in _state.capacity:
			if _state.active[i] != 0:
				_state.s[i] += SPEED_MPS / 60.0
		_frame(S0 + float(f))
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), objects, "no objects created by 30 frames")
	gt(_cones.count(), 0)
