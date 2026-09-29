extends WBTest
## StreetLampPools (WP5.4): light pools under the median light poles' twin heads, one
## MultiMesh, only within the window around the player; hidden by day; rewritten only
## when the window moves or the origin shifts; no objects per frame. Also NightTuning.
## Spec: World → Night lighting (street lamps), Road (light poles every 50 m).

const SKY_SCENE := "res://src/sun/sky.tscn"
const SEED := 20260929
const S0 := 1000.0

var _ctx: RunContext
var _night: NightTuning
var _road: StraightRoadPath
var _origin: FloatingOrigin
var _sky: SkyRig
var _pools: StreetLampPools


func before_each() -> void:
	_ctx = RunContext.new(SEED)
	_night = NightTuning.load_default()
	_road = StraightRoadPath.new(3, _ctx.tuning.road)
	_origin = FloatingOrigin.new()
	tree.root.add_child(_origin)
	_origin.setup(_ctx.tuning.road.floating_origin_shift_km)
	_sky = (load(SKY_SCENE) as PackedScene).instantiate() as SkyRig
	_sky.push_sink = func(_n: StringName, _v: Variant) -> void: pass
	_sky.set_process(false)
	tree.root.add_child(_sky)
	_pools = StreetLampPools.new()
	_pools.sky = _sky
	tree.root.add_child(_pools)
	_pools.setup(_ctx, _road, _origin)
	_set_sky(_ctx.tuning.sun.sky_t_night)


func after_each() -> void:
	for n: Node in [_pools, _sky, _origin]:
		if is_instance_valid(n):
			n.free()


func _set_sky(t: float) -> void:
	_sky.sky_t = t
	_sky.push_now()


func test_hidden_by_day_visible_at_night() -> void:
	_set_sky(_ctx.tuning.sun.sky_t_afternoon)
	_pools.update_view(S0)
	check(not _pools.node().visible, "day: hidden (no draw call)")
	eq(_pools.draw_calls(), 0)
	_set_sky(_ctx.tuning.sun.sky_t_dusk)
	_pools.update_view(S0)
	check(_pools.node().visible, "dusk: lamps on")
	eq(_pools.draw_calls(), 1, "one draw call")


func test_pools_under_every_pole_in_the_window() -> void:
	_pools.update_view(S0)
	var spacing := _ctx.tuning.road.light_pole_spacing_m
	var k0 := ceili((S0 - _night.pool_behind_m) / spacing)
	var k1 := floori((S0 + _night.pool_ahead_m) / spacing)
	eq(_pools.count(), (k1 - k0 + 1) * StreetLampPools.HEADS, "two pools per pole in the window")
	le(_pools.multimesh().visible_instance_count, _pools.capacity(), "never past the pool")
	var smp := RoadSample.new()
	for i in _pools.count():
		var k := k0 + floori(i / 2.0)
		_road.sample_into(float(k) * spacing, smp)
		var side := 1.0 if i % 2 == 0 else -1.0
		var want := smp.local_point(side * _night.pool_d_m, _origin.origin_x, _origin.origin_y, _origin.origin_z) \
			+ smp.up * _night.pool_lift_m
		check(_pools.pool_transform(i).origin.distance_to(want) < 0.01, "pool %d under its lamp head" % i)
	var b := _pools.pool_transform(0).basis
	near(b.x.length(), _night.pool_width_m, 1e-3, "width across")
	near(b.z.length(), _night.pool_length_m, 1e-3, "length along")


func test_rewritten_only_when_the_window_moves() -> void:
	_pools.update_view(S0)
	var n := _pools.rewrites()
	_pools.update_view(S0 + 1.0)
	_pools.update_view(S0 + 2.0)
	eq(_pools.rewrites(), n, "same poles: nothing rewritten")
	_pools.update_view(S0 + _ctx.tuning.road.light_pole_spacing_m)
	eq(_pools.rewrites(), n + 1, "next pole: rewritten once")
	_origin.update_focus(0.0, 0.0, -1.0e5)
	_pools.update_view(S0 + _ctx.tuning.road.light_pole_spacing_m)
	eq(_pools.rewrites(), n + 2, "origin shift: rewritten")


func test_window_stops_at_the_generated_road() -> void:
	var short := StraightRoadPath.new(3, _ctx.tuning.road)
	short._length = S0 + 100.0
	_pools.setup(_ctx, short, _origin)
	_pools.update_view(S0)
	var spacing := _ctx.tuning.road.light_pole_spacing_m
	var k1 := floori((S0 + 100.0) / spacing)
	var k0 := ceili((S0 - _night.pool_behind_m) / spacing)
	eq(_pools.count(), (k1 - k0 + 1) * StreetLampPools.HEADS)


func test_no_objects_per_frame() -> void:
	_pools.update_view(S0)
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	for f in 60:
		_pools.update_view(S0 + float(f) * 2.0)
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), objects, "no objects created by 60 frames")


func test_night_tuning_loads() -> void:
	var t := NightTuning.load_default()
	check(t != null)
	var caps := t.traffic_cones_per_tier
	eq(caps.size(), _ctx.tuning.quality.tier_names.size(), "one cap per quality tier")
	for i in range(1, caps.size()):
		ge(caps[i], caps[i - 1], "caps grow with the tier")
	eq(t.traffic_cones_for_tier(99), caps[caps.size() - 1], "clamped")
	gt(t.high_beam_reach, t.low_beam_reach)
	gt(t.high_cone_length_m, t.low_cone_length_m)
	le(t.cone_segments + 1, PlayerHeadlights.MAX_ROWS, "rows fit the shader's arrays")
	gt(t.visible_min_ramp, 0.0)
