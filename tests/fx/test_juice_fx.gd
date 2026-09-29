extends WBTest
## Juice (WP7.4): speed lines and wind streaks above 180 km/h, tire smoke on hard
## braking at the rear wheels, sparks at the barrier-scrape point, all clamped by
## Quality.particle_scale, pooled, hidden when idle (0 draw calls), at most 2 draws.
## Spec: Audio, haptics and game feel → Speed effects, Particles; Performance budget;
## plan D16. Also CarFxEvents (publishes hard_braking_changed and barrier_scrape) and
## PlayerFx carrying both.

const CAR_SCENE := "res://src/vehicle/player_car.tscn"
const CAR_PATH := "res://data/cars/falcon_gt.tres"
const RIG_SCENE := "res://src/camera/camera_rig.tscn"
const FRAME := 1.0 / 60.0

var _tuning: Tuning
var _feel: FeelTuning
var _nodes: Array[Node] = []
var _road: RoadPath
var _car: PlayerCar
var _log: Array = []


func before_all() -> void:
	_tuning = Tuning.load_default()
	_feel = _tuning.feel


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	_car = null
	_log.clear()
	for c: Callable in [_on_hard_braking, _on_scrape]:
		if Events.hard_braking_changed.is_connected(c):
			Events.hard_braking_changed.disconnect(c)
		if Events.barrier_scrape.is_connected(c):
			Events.barrier_scrape.disconnect(c)
	await tree.process_frame


func _add(n: Node) -> Node:
	tree.root.add_child(n)
	_nodes.append(n)
	return n


func _make_car(kmh: float, lane: int = 1) -> PlayerCar:
	_road = StraightRoadPath.new(3, _tuning.road)
	var car_def := load(CAR_PATH) as CarDef
	var car := (load(CAR_SCENE) as PackedScene).instantiate() as PlayerCar
	car.self_tick = false
	_add(car)
	car.setup(RunContext.new(1), _road, null, car_def, VehicleParams.build(_tuning, car_def))
	car.place_at(100.0, _road.lane_center_d(lane, 100.0), Units.kmh_to_mps(kmh))
	_car = car
	return car


func _make_juice(car: PlayerCar) -> JuiceFx:
	var j := JuiceFx.new()
	j.feel = _feel
	_add(j)
	j.set_process(false)
	j.bind(car)
	j.set_particle_scale(1.0)
	return j


func _on_hard_braking(active: bool) -> void:
	_log.append(["hard_braking", active])


func _on_scrape(pos: Vector3) -> void:
	_log.append(["scrape", pos])


# ---------------------------------------------------------------- Speed lines

func test_speed_line_threshold() -> void:
	var sl := SpeedLines.new()
	_add(sl)
	sl.setup(_feel, 1.0)
	var at := func(kmh: float, boost: bool = false) -> float:
		return sl.intensity_for(Units.kmh_to_mps(kmh), boost)
	near(_feel.speed_lines_min_kmh, 180.0, 1e-9, "spec: above 180 km/h")
	eq(at.call(120.0), 0.0)
	eq(at.call(179.9), 0.0)
	eq(at.call(180.0), 0.0, "not at 180 exactly: above it")
	gt(at.call(181.0), 0.0, "on just above 180")
	near(at.call(180.01), _feel.speed_lines_min_intensity, 1e-3, "starts at the minimum intensity")
	near(at.call(_feel.speed_lines_full_kmh), 1.0, 1e-9)
	gt(at.call(200.0, true), at.call(200.0), "boost strengthens them")
	eq(at.call(170.0, true), 0.0, "boost alone below 180 does not")
	sl.update(FRAME, Units.kmh_to_mps(179.0), false)
	check(not sl.visible, "hidden (0 draw calls) at or below the threshold")
	sl.update(FRAME, Units.kmh_to_mps(220.0), false)
	check(sl.visible, "drawn above it")
	near(sl.intensity, lerpf(_feel.speed_lines_min_intensity, 1.0, 0.5), 1e-6, "220 km/h is halfway up the ramp")
	sl.update(FRAME, Units.kmh_to_mps(150.0), false)
	check(not sl.visible, "hidden again when slowing")


func test_speed_lines_are_one_mesh_clamped_by_tier() -> void:
	var sl := SpeedLines.new()
	_add(sl)
	sl.setup(_feel, 1.0)
	eq(sl.mesh.get_surface_count(), 1, "one surface: 1 draw call")
	eq(sl.visible_count, _feel.speed_lines_count)
	sl.set_particle_scale(0.5)
	eq(sl.visible_count, roundi(_feel.speed_lines_count * 0.5), "Low tier: 50 %")
	sl.set_particle_scale(0.0)
	sl.update(FRAME, Units.kmh_to_mps(250.0), false)
	check(not sl.visible, "no streaks at a zero clamp: not drawn")


func test_speed_lines_keep_to_the_edges_in_hood_and_cockpit() -> void:
	var car := _make_car(220.0)
	var j := _make_juice(car)
	var rig: CameraRig = (load(RIG_SCENE) as PackedScene).instantiate()
	_add(rig)
	rig.set_physics_process(false)
	rig.set_target(car, car.state, car.params.top_speed_mps)
	(rig.get_node("Camera3D") as Camera3D).make_current()
	for mode: StringName in [&"chase", &"hood", &"cockpit", &"far"]:
		rig.set_mode(mode)   # no event: the juice reads the active rig
		j.advance(FRAME)
		check(j.speed_lines.visible, "%s: drawn at 220 km/h" % mode)
		eq(j.speed_lines.edge_only, mode == &"hood" or mode == &"cockpit", "%s: edge-only (D16)" % mode)
	gt(_feel.speed_lines_inner_edge, _feel.speed_lines_inner, "edge-only starts farther out")


# ---------------------------------------------------------------- Particles

func test_idle_draws_nothing_and_active_draws_at_most_two() -> void:
	var car := _make_car(120.0)
	var j := _make_juice(car)
	j.advance(FRAME)
	eq(j.active_draws(), 0, "idle: 0 draw calls")
	check(not j.speed_lines.visible and not j.particles.visible, "hidden, not transparent")
	car.state.v = Units.kmh_to_mps(230.0)
	Events.hard_braking_changed.emit(true)
	Events.barrier_scrape.emit(car.global_position + Vector3(2.0, 0.4, 0.0))
	for i in 10:
		j.advance(FRAME)
		le(j.active_draws(), 2, "everything at once: at most 2 draws")
	eq(j.active_draws(), 2)
	Events.hard_braking_changed.emit(false)
	car.state.v = Units.kmh_to_mps(120.0)
	for i in 120:
		j.advance(FRAME)
	eq(j.particles.alive, 0, "every particle died")
	eq(j.active_draws(), 0, "idle again: 0 draw calls")


func test_tire_smoke_at_the_rear_wheels_while_braking_hard() -> void:
	var car := _make_car(200.0)
	var j := _make_juice(car)
	j.advance(0.5)
	eq(j.particles.count_kind(FxParticles.KIND_SMOKE), 0, "no smoke without hard braking")
	Events.hard_braking_changed.emit(true)
	# The car is not ticked here: hold its velocity at zero so the puffs stay where they
	# were born (in a run the car drives away from them).
	car.state.v = 0.0
	j.advance(2.0 / _feel.tire_smoke_rate_hz)   # two puffs per wheel, freshly born
	var n := j.particles.count_kind(FxParticles.KIND_SMOKE)
	gt(n, 0, "smoke on hard braking")
	eq(n % 2, 0, "one puff per rear wheel")
	var inv := car.global_transform.affine_inverse()
	var model := car.model
	var rl: Vector3 = inv * model.wheels[2].global_position
	var rr: Vector3 = inv * model.wheels[3].global_position
	for i in n:
		var p: Vector3 = inv * j.particles.particle_position(i)
		gt(p.z, 0.0, "behind the car's centre (+Z is the rear)")
		lt(absf(p.z - rl.z), 0.5, "at the rear axle")
		check(absf(p.x - rl.x) < 1.0 or absf(p.x - rr.x) < 1.0, "at a rear wheel's track")
		lt(absf(p.y), 1.0, "near the road")
	car.state.v = Units.kmh_to_mps(200.0)
	var rate_count := j.particles.emitted_total
	j.advance(1.0)
	near(float(j.particles.emitted_total - rate_count), _feel.tire_smoke_rate_hz * 2.0, 2.0,
		"tire_smoke_rate_hz per wheel")
	Events.hard_braking_changed.emit(false)
	var before := j.particles.emitted_total
	j.advance(0.5)
	eq(j.particles.emitted_total, before, "stops with the braking")


func test_sparks_at_the_scrape_position() -> void:
	var car := _make_car(200.0)
	var j := _make_juice(car)
	var at := car.global_position + Vector3(-1.2, 0.45, -0.5)
	Events.barrier_scrape.emit(at)
	eq(j.spark_bursts, 1)
	eq(j.particles.count_kind(FxParticles.KIND_SPARK), _feel.sparks_count, "a full burst at 100 %")
	for i in j.particles.alive:
		near(j.particles.particle_position(i).distance_to(at), 0.0, 1e-5, "born at the contact point")
	j.advance(FRAME)
	for i in j.particles.alive:
		lt(j.particles.particle_position(i).distance_to(at), 2.0, "flying off it")
	j.advance(_feel.sparks_lifetime_max_s + FRAME)
	eq(j.particles.alive, 0, "short-lived")


func test_tier_clamps_particle_counts() -> void:
	var car := _make_car(200.0)
	var j := _make_juice(car)
	j.set_particle_scale(0.5)
	eq(j.particles.cap, roundi(_feel.particles_pool * 0.5), "pool cap x 50 %")
	eq(j.speed_lines.visible_count, roundi(_feel.speed_lines_count * 0.5))
	eq(j.sparks_at(car.global_position), roundi(_feel.sparks_count * 0.5), "burst x 50 %")
	j.particles.clear()
	Events.hard_braking_changed.emit(true)
	var e0 := j.particles.emitted_total
	j.advance(0.5)
	near(float(j.particles.emitted_total - e0), _feel.tire_smoke_rate_hz * 0.5 * 2.0 * 0.5, 2.0, "smoke rate x 50 %")
	# The pool never grows past its cap.
	for i in 20:
		j.sparks_at(car.global_position)
	le(j.particles.alive, j.particles.cap)
	gt(j.particles.dropped_total, 0, "a full pool drops")
	# The quality autoload's scale is picked up on its events.
	Events.quality_changed.emit(&"medium")
	near(j.particle_scale(), clampf(Quality.particle_scale, 0.0, 1.0), 1e-9)


func test_pools_do_not_allocate_per_event() -> void:
	var car := _make_car(230.0)
	var j := _make_juice(car)
	# Warm up every path once.
	Events.hard_braking_changed.emit(true)
	Events.barrier_scrape.emit(car.global_position)
	j.advance(FRAME)
	Events.hard_braking_changed.emit(false)
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var nodes := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	for i in 100:
		Events.barrier_scrape.emit(car.global_position + Vector3(0.0, 0.0, float(i)))
		Events.hard_braking_changed.emit(i % 2 == 0)
		j.advance(FRAME)
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), objects, "no objects per event or frame")
	eq(Performance.get_monitor(Performance.OBJECT_NODE_COUNT), nodes, "no nodes per event")
	eq(j.get_child_count(), 2, "one speed-line mesh, one particle MultiMesh")


func test_crash_hides_speed_lines_until_the_next_run() -> void:
	var car := _make_car(240.0)
	var j := _make_juice(car)
	j.advance(FRAME)
	check(j.speed_lines.visible)
	Events.crash_started.emit()
	j.advance(FRAME)
	check(not j.speed_lines.visible, "no speed lines over the crash cinematic")
	Events.barrier_scrape.emit(car.global_position)
	Events.run_started.emit(&"journey", 1)
	eq(j.particles.alive, 0, "a new run clears the particles")
	j.advance(FRAME)
	check(j.speed_lines.visible, "back on the next run")


func test_particles_follow_the_floating_origin() -> void:
	var car := _make_car(200.0)
	var j := _make_juice(car)
	var at := Vector3(10.0, 0.5, -2000.0)
	j.sparks_at(at)
	Events.origin_shifted.emit(Vector3(0.0, 0.0, -2000.0))
	near(j.particles.particle_position(0).distance_to(Vector3(10.0, 0.5, 0.0)), 0.0, 1e-3)


# ---------------------------------------------------------------- CarFxEvents

func test_hard_braking_is_published_on_change() -> void:
	var car := _make_car(200.0)
	var ev := CarFxEvents.new()
	_add(ev)
	ev.set_process(false)
	ev.bind(car)
	Events.hard_braking_changed.connect(_on_hard_braking)
	ev.poll()
	eq(_log.size(), 0, "no change, no event")
	car.visual.tire_smoke = true
	ev.poll()
	ev.poll()
	eq(_log, [["hard_braking", true]], "once, on the change")
	car.visual.tire_smoke = false
	ev.poll()
	eq(_log, [["hard_braking", true], ["hard_braking", false]])
	car.visual.tire_smoke = true
	ev.poll()
	Events.crash_started.emit()
	eq(_log.back(), ["hard_braking", false], "a crash ends it")


func test_barrier_scrape_at_the_barrier_the_car_touched() -> void:
	var car := _make_car(200.0, 2)
	var ev := CarFxEvents.new()
	_add(ev)
	ev.set_process(false)
	ev.bind(car)
	Events.barrier_scrape.connect(_on_scrape)
	var s := car.state.s
	Events.hit.emit(Events.HIT_TRAFFIC, 1)
	eq(_log.size(), 0, "a traffic hit is not a scrape")
	# Right lane, pushed to the guardrail.
	car.place_at(s, _road.guardrail_d(s) - 1.0, car.state.v)
	Events.hit.emit(Events.HIT_BARRIER, 1)
	var smp := _road.sample(s)
	var rail := smp.local_point(_road.guardrail_d(s), 0.0, 0.0, 0.0) + smp.up * _feel.sparks_height_m
	eq(_log.size(), 1)
	near((_log[0][1] as Vector3).distance_to(rail), 0.0, 1e-3, "at the guardrail")
	# Left lane against the median barrier.
	car.place_at(s, _road.median_barrier_d(s) + 1.0, car.state.v)
	Events.hit.emit(Events.HIT_BARRIER, 0)
	var median := smp.local_point(_road.median_barrier_d(s), 0.0, 0.0, 0.0) + smp.up * _feel.sparks_height_m
	near((_log[1][1] as Vector3).distance_to(median), 0.0, 1e-3, "at the median barrier (the crash hit too)")


func test_player_fx_carries_the_juice() -> void:
	var car := _make_car(200.0)
	var fx := PlayerFx.new()
	_add(fx)
	check(fx.juice != null and fx.fx_events != null, "created on entering the tree")
	fx.bind(car)
	eq(fx.juice.car, car)
	eq(fx.fx_events.car, car)
	var juice := fx.juice
	tree.root.remove_child(fx)
	tree.root.add_child(fx)
	eq(fx.juice, juice, "created once")
