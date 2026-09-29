extends WBTest
## PlayerHeadlights (WP5.4): the fake-light uniform follows the car's pose and the
## color script's headlight ramp (0 by day), high beams (D8) lengthen and brighten it;
## the cone decal is hidden by day and follows the road at night; nothing is allocated
## per frame. Spec: World → Night lighting (player headlights); docs/NIGHT.md.

const SKY_SCENE := "res://src/sun/sky.tscn"
const CAR_SCENE := "res://src/vehicle/player_car.tscn"
const CAR_PATH := "res://data/cars/falcon_gt.tres"
const SEED := 20260929
const S0 := 300.0
const SPEED_MPS := 30.0
const GRADE := 0.05
const POS_TOL_M := 0.01

var _ctx: RunContext
var _night: NightTuning
var _sky: SkyRig
var _log: Dictionary = {}
var _origin: FloatingOrigin
var _car: PlayerCar
var _lights: PlayerHeadlights
var _road: RoadPath
var _nodes: Array[Node] = []
static var _params: VehicleParams


func _record(global_name: StringName, value: Variant) -> void:
	_log[global_name] = value


func before_each() -> void:
	_log.clear()
	_ctx = RunContext.new(SEED)
	_night = NightTuning.load_default()
	_sky = (load(SKY_SCENE) as PackedScene).instantiate() as SkyRig
	_sky.push_sink = _record
	_sky.set_process(false)
	_add(_sky)
	_origin = FloatingOrigin.new()
	_add(_origin)
	_origin.setup(_ctx.tuning.road.floating_origin_shift_km)
	_make_car(StraightRoadPath.new(3, _ctx.tuning.road, 0.0, GRADE))


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()


func _add(n: Node) -> void:
	tree.root.add_child(n)
	_nodes.append(n)


func _make_car(road: RoadPath) -> void:
	_road = road
	var car_def := load(CAR_PATH) as CarDef
	if _params == null:
		_params = VehicleParams.build(_ctx.tuning, car_def)
	if _car != null:
		_car.free()
	_car = (load(CAR_SCENE) as PackedScene).instantiate() as PlayerCar
	_car.self_tick = false
	_add(_car)
	_car.setup(_ctx, road, _origin, car_def, _params)
	_car.place_at(S0, road.lane_center_d(1, S0), SPEED_MPS)
	if _lights == null:
		_lights = PlayerHeadlights.new()
		_lights.sky = _sky
		_add(_lights)
	_lights.setup(_ctx, road, _origin)
	_lights.bind(_car)


## One frame as the run does it: the lights read the sky's last sample (the ramp) and
## hand it the fake light, then the sky pushes. Sampled once first so the test's
## sky_t is the one in effect.
func _frame(sky_t: float) -> void:
	_sky.sky_t = sky_t
	_sky.push_now()
	_lights.update_view(_car.state.s)
	_sky.push_now()


func test_fake_light_follows_the_car_and_the_ramp() -> void:
	var sun := _ctx.tuning.sun
	_frame(sun.sky_t_afternoon)
	near(float(_log[&"wb_player_light_strength"]), 0.0, 1e-9, "day: no fake light")
	check(not _lights.cone_visible(), "day: no cone draw call")
	_frame(sun.sky_t_night)
	var ramp := _sky.current().emissive_headlight
	gt(ramp, 0.0, "the night key has a headlight ramp")
	near(float(_log[&"wb_player_light_strength"]), _night.low_beam_gain * ramp, 1e-6, "night: gain x ramp")
	var xf := _car.global_transform
	var lamp := PlayerHeadlights.lamp_center(_car)
	var pos: Vector3 = _log[&"wb_player_light_pos"]
	check(pos.distance_to(xf * lamp) < POS_TOL_M, "the light sits at the lamps")
	lt(lamp.z, 0.0, "lamps in the front half")
	gt(lamp.y, 0.0, "lamps above the road")
	var dir: Vector3 = _log[&"wb_player_light_dir"]
	near(dir.length(), _night.low_beam_reach, 1e-4, "low beams: reach 1 in the axis length")
	gt(dir.normalized().dot(-xf.basis.z), 0.99, "the beam points forward")
	lt(dir.y, (-xf.basis.z).y, "aimed slightly down")
	# The car moves: the light moves with it.
	_car.place_at(S0 + 100.0, _road.lane_center_d(2, S0 + 100.0), SPEED_MPS)
	_frame(sun.sky_t_night)
	pos = _log[&"wb_player_light_pos"]
	check(pos.distance_to(_car.global_transform * lamp) < POS_TOL_M, "follows the car's pose")


func test_high_beams_brighten_and_lengthen() -> void:
	var sun := _ctx.tuning.sun
	_frame(sun.sky_t_night)
	var low_len := _cone_reach()
	var ramp := _sky.current().emissive_headlight
	_lights.high_beam = true
	_frame(sun.sky_t_night)
	near(float(_log[&"wb_player_light_strength"]), _night.high_beam_gain * ramp, 1e-6, "high gain")
	near((_log[&"wb_player_light_dir"] as Vector3).length(), _night.high_beam_reach, 1e-4, "high reach")
	var high_len := _cone_reach()
	gt(high_len, low_len + 10.0, "the cone reaches further")
	near(high_len, _night.high_cone_length_m, 0.5, "to the high-beam length")
	near(low_len, _night.low_cone_length_m, 0.5, "low beams to the low-beam length")
	gt(_night.high_beam_gain, _night.low_beam_gain)


## Distance from the lamps to the far row's center, along the road.
func _cone_reach() -> float:
	var last := _lights.cone_rows() - 1
	var far := (_lights.cone_row(last, false) + _lights.cone_row(last, true)) * 0.5 + _lights.position
	var lamp := _car.global_transform * PlayerHeadlights.lamp_center(_car)
	var d := far - lamp
	return Vector2(d.x, d.z).length() * sqrt(1.0 + GRADE * GRADE)


func test_cone_hidden_by_day_and_when_disabled() -> void:
	var sun := _ctx.tuning.sun
	_frame(sun.sky_t_morning)
	check(not _lights.cone_node().visible, "morning: hidden")
	_frame(sun.sky_t_night)
	check(_lights.cone_visible(), "night: drawn")
	_lights.enabled = false
	_frame(sun.sky_t_night)
	check(not _lights.cone_visible(), "disabled (crash): hidden")
	_lights.enabled = true
	_frame(sun.sky_t_dawn)
	check(_lights.cone_visible(), "dawn: still lit")


func test_cone_rows_lie_on_the_road() -> void:
	# A curved road: every row's center is on the surface (plus the lift) ahead of the car.
	_make_car(ArcRoadPath.new(1200.0, 1, 3, _ctx.tuning.road))
	_frame(_ctx.tuning.sun.sky_t_night)
	var smp := RoadSample.new()
	var st := _car.state
	for i in _lights.cone_rows():
		var mid := (_lights.cone_row(i, false) + _lights.cone_row(i, true)) * 0.5 + _car.global_position
		# Nearest road sample along s: the row was sampled ahead of the car.
		var best := INF
		var s := st.s
		while s < st.s + _night.high_cone_length_m + 10.0:
			_road.sample_into(s, smp)
			var p := smp.local_point(st.d, _origin.origin_x, _origin.origin_y, _origin.origin_z) \
				+ smp.up * _night.cone_lift_m
			best = minf(best, p.distance_to(mid))
			s += 0.25
		lt(best, 0.2, "row %d on the road surface (lane center)" % i)


func test_no_objects_per_frame() -> void:
	var t := _ctx.tuning.sun.sky_t_night
	_frame(t)
	_frame(t)
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	for i in 30:
		_car.tick(1.0 / 120.0)
		_frame(t)
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), objects, "no objects created by 30 frames")
