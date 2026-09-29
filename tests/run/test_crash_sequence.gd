extends WBTest
## CrashSequence (WP4.2). Spec: Lives, hits and crashes → Second hit (run over): Jolt
## RigidBody3D hand-off at the current velocities with an impulse from the relative
## velocity at the contact point, 0.25× for 2.5 s, orbit crash camera, tap to skip,
## pooled bodies return to kinematic; Cameras → Scripted cameras (Crash). Contracts
## §2 (road space → world), §13 (floating origin), §14 (CrashSequence).

const SEED := 20260929
const CAR_PATH := "res://data/cars/falcon_gt.tres"
const PLAYER_SCENE := "res://src/vehicle/player_car.tscn"
const RIG_SCENE := "res://src/camera/camera_rig.tscn"
const HEADING := 0.3
const ROAD_ORIGIN := Vector3(40.0, 12.0, -30.0)
const PLAYER_S := 120.0
const PLAYER_LANE := 1
const PLAYER_KMH := 180.0
const TRAFFIC_KMH := 110.0
const BARRIER_KMH := 150.0
## Velocity tolerance after one physics step (gravity and ground friction act for
## one 120 Hz tick: ~0.1 m/s each).
const VEL_TOL_MPS := 0.35
const POS_TOL_M := 0.02
const ANGLE_TOL := 0.02
const CYCLES := 3
const FRAMES_PER_CYCLE := 3
const ADVANCE_STEP_S := 0.05
## A tap during the skip grace, as iOS Safari reports touch ids (CLAUDE.md).
const IOS_TOUCH_ID := 1_893_457_201

static var _params: VehicleParams

var _ctx: RunContext
var _road: StraightRoadPath
var _origin: FloatingOrigin
var _registry: TrafficRegistry
var _traffic: TrafficState
var _view: TrafficView
var _car: PlayerCar
var _rig: CameraRig
var _crash: CrashSequence
var _contact := HitDetection.Contact.new()
var _smp := RoadSample.new()
var _nodes: Array[Node] = []

var _started: int = 0
var _crash_finished: int = 0
var _finished: int = 0
var _last_skipped: bool = false
var _slowmo_scale: float = 0.0
var _slowmo_s: float = 0.0
var _slowmo_reason: StringName = &""


func before_each() -> void:
	_ctx = RunContext.new(SEED)
	_road = StraightRoadPath.new(3, _ctx.tuning.road, HEADING, 0.0, ROAD_ORIGIN)
	_origin = FloatingOrigin.new()
	_add(_origin)
	_origin.setup(_ctx.tuning.road.floating_origin_shift_km)
	_road.sample_into(PLAYER_S, _smp)
	_origin.update_focus(_smp.pos_x, _smp.pos_y, _smp.pos_z)
	_registry = TrafficRegistry.load_default(_ctx.tuning.traffic)
	_traffic = TrafficState.new(_ctx.tuning.traffic.max_active_vehicles)
	_view = TrafficView.new()
	_add(_view)
	_view.setup(_ctx, _road, _origin, _registry, _traffic)
	_view.set_palette((load("res://data/biomes/farmland.tres") as BiomeDef).traffic_palette)
	var car_def := load(CAR_PATH) as CarDef
	if _params == null:
		_params = VehicleParams.build(_ctx.tuning, car_def)
	_car = (load(PLAYER_SCENE) as PackedScene).instantiate() as PlayerCar
	_add(_car)
	_car.setup(_ctx, _road, _origin, car_def, _params)
	_car.place_at(PLAYER_S, _road.lane_center_d(PLAYER_LANE, PLAYER_S), Units.kmh_to_mps(PLAYER_KMH))
	_rig = (load(RIG_SCENE) as PackedScene).instantiate() as CameraRig
	_add(_rig)
	_rig.set_target(_car, _car.state, _car.params.top_speed_mps)
	_rig.camera().make_current()
	_crash = CrashSequence.new()
	_crash.auto_advance = false
	_add(_crash)
	_crash.setup(_ctx, _registry)
	_started = 0
	_crash_finished = 0
	_finished = 0
	_last_skipped = false
	_slowmo_reason = &""
	Events.crash_started.connect(_on_crash_started)
	Events.crash_finished.connect(_on_crash_finished)
	Events.slowmo_requested.connect(_on_slowmo)
	_crash.finished.connect(_on_finished)


func after_each() -> void:
	Events.crash_started.disconnect(_on_crash_started)
	Events.crash_finished.disconnect(_on_crash_finished)
	Events.slowmo_requested.disconnect(_on_slowmo)
	for i in range(_nodes.size() - 1, -1, -1):
		if is_instance_valid(_nodes[i]):
			_nodes[i].free()
	_nodes.clear()


func _add(n: Node) -> void:
	tree.root.add_child(n)
	_nodes.append(n)


func _on_crash_started() -> void:
	_started += 1


func _on_crash_finished() -> void:
	_crash_finished += 1


func _on_finished(skipped: bool) -> void:
	_finished += 1
	_last_skipped = skipped


func _on_slowmo(scale: float, duration_s: float, reason: StringName) -> void:
	_slowmo_scale = scale
	_slowmo_s = duration_s
	_slowmo_reason = reason


# ---------------------------------------------------------------- Scenario helpers

## A sedan `gap_m` ahead of the player's nose in the player's lane (box to box).
func _spawn_ahead(gap_m: float, kmh: float) -> int:
	var i := _traffic.allocate()
	var t := _registry.type_index(&"sedan")
	var car := _car.car
	_traffic.length[i] = _registry.length[t]
	_traffic.width[i] = _registry.width[t]
	_traffic.s[i] = PLAYER_S + (car.length_m + _traffic.length[i]) * 0.5 + gap_m
	_traffic.d[i] = _car.state.d
	_traffic.v[i] = Units.kmh_to_mps(kmh)
	_traffic.v0[i] = _traffic.v[i]
	_traffic.lane[i] = PLAYER_LANE
	_traffic.target_lane[i] = PLAYER_LANE
	_traffic.type_id[i] = t
	_traffic.color_index[i] = 3
	_view.capture_tick()
	_view.capture_tick()
	_view.render(1.0)
	return i


## A rear-end contact with slot `i` at the player's nose, relative velocity (player
## minus traffic) along s.
func _rear_end(i: int) -> HitDetection.Contact:
	_contact.clear()
	_contact.hit = true
	_contact.source = HitDetection.HIT_TRAFFIC
	_contact.slot = i
	_contact.vehicle_id = _traffic.vehicle_id[i]
	_contact.s = PLAYER_S + _car.car.length_m * 0.5
	_contact.d = _car.state.d
	_contact.normal_s = 1.0
	_contact.normal_d = 0.0
	_contact.rel_v_s = _car.state.v - _traffic.v[i]
	_contact.rel_v_d = 0.0
	_contact.end = 1
	_contact.away_side = 1
	return _contact


## The player scraping the guardrail on its right.
func _barrier() -> HitDetection.Contact:
	_contact.clear()
	_contact.hit = true
	_contact.source = HitDetection.HIT_BARRIER
	_contact.s = PLAYER_S
	_contact.d = _car.state.d + _car.car.width_m * 0.5
	_contact.normal_s = 0.0
	_contact.normal_d = 1.0
	_contact.rel_v_s = _car.state.v
	_contact.rel_v_d = Units.kmh_to_mps(BARRIER_KMH) * 0.1
	_contact.side = 1
	_contact.away_side = -1
	return _contact


func _start(contact: HitDetection.Contact) -> void:
	_crash.start(_car, contact, _traffic, _view, _road, _origin, _rig)


func _frames(n: int) -> void:
	for k in n:
		await tree.physics_frame


func _count_nodes(n: Node) -> int:
	var c := 1
	for child in n.get_children():
		c += _count_nodes(child)
	return c


func _tangent() -> Vector3:
	_road.sample_into(PLAYER_S, _smp)
	return _smp.tangent


func _near_v(a: Vector3, b: Vector3, tol: float, msg: String) -> bool:
	if a.distance_to(b) > tol:
		fail("%s: expected %s, got %s" % [msg, b, a])
		return false
	return true


func _quiet_tuning() -> CrashTuning:
	var t := CrashTuning.load_default().duplicate() as CrashTuning
	t.min_approach_kmh = 0.0
	t.lift_frac = 0.0
	t.tangential_frac = 0.0
	return t


# ---------------------------------------------------------------- Pool

func test_pool_is_built_once_and_reused_across_runs() -> void:
	var nodes := _count_nodes(_crash)
	var root_children := tree.root.get_child_count()
	var pb := _crash.player_body()
	var tb := _crash.traffic_body()
	var cam := _crash.crash_camera()
	gt(_crash.arena_shape_count(), 0, "arena boxes preallocated")
	for c in CYCLES:
		var i := _spawn_ahead(0.0, TRAFFIC_KMH)
		_start(_rear_end(i))
		await _frames(FRAMES_PER_CYCLE)
		eq(_count_nodes(_crash), nodes, "no new nodes during crash %d" % c)
		check(_crash.player_body() == pb and _crash.traffic_body() == tb and _crash.crash_camera() == cam,
			"the same pooled bodies and camera")
		_crash.reset()
		_traffic.free_slot(i)
		_car.place_at(PLAYER_S, _road.lane_center_d(PLAYER_LANE, PLAYER_S), Units.kmh_to_mps(PLAYER_KMH))
	# setup() again (a new run) must not rebuild the pool.
	_crash.setup(_ctx, _registry)
	eq(_count_nodes(_crash), nodes, "no new nodes after 3 runs and a second setup")
	eq(tree.root.get_child_count(), root_children, "nothing added to the tree root")


# ---------------------------------------------------------------- Hand-off

func test_handoff_velocities_match_world_velocities_at_first_physics_frame() -> void:
	_crash.setup(_ctx, _registry, _quiet_tuning())
	var i := _spawn_ahead(6.0, TRAFFIC_KMH)
	var c := _rear_end(i)
	c.rel_v_s = 0.0   # no approach: no impulse, no tumble
	var v_player := _car.world_velocity()
	var v_traffic := _tangent() * _traffic.v[i]
	_start(c)
	near(_crash.player_impulse().length(), 0.0, 1e-6, "no impulse")
	await _frames(1)
	_near_v(_crash.player_body().linear_velocity, v_player, VEL_TOL_MPS, "player body = car world velocity")
	_near_v(_crash.traffic_body().linear_velocity, v_traffic, VEL_TOL_MPS, "traffic body = car world velocity")
	check(not _crash.player_body().freeze and not _crash.traffic_body().freeze, "bodies are dynamic")


func test_bodies_start_at_the_drawn_poses() -> void:
	var i := _spawn_ahead(0.0, TRAFFIC_KMH)
	var car_xf := _car.global_transform
	var drawn := _view.slot_transform(i, false, 1.0)
	_start(_rear_end(i))
	var pb := _crash.player_body().global_transform
	_near_v(pb.origin, car_xf.origin + car_xf.basis.y * (_car.car.height_m * 0.5), POS_TOL_M,
		"player body centre = car origin + half height")
	near(pb.basis.z.angle_to(car_xf.basis.z), 0.0, ANGLE_TOL, "player body heading = car heading")
	var tb := _crash.traffic_body().global_transform
	var h := _registry.types[_traffic.type_id[i]].height_m
	_near_v(tb.origin, drawn.origin + drawn.basis.y * (h * 0.5), POS_TOL_M, "traffic body centre = drawn car")
	near(tb.basis.z.angle_to(drawn.basis.z), 0.0, ANGLE_TOL, "traffic body heading = drawn heading")
	# The PlayerCar node (and its CarVisual) sits where it was.
	_near_v(_car.global_transform.origin, car_xf.origin, POS_TOL_M, "car node unmoved at start")


func test_impulse_follows_the_relative_velocity() -> void:
	var i := _spawn_ahead(0.0, TRAFFIC_KMH)
	var c := _rear_end(i)
	var rel := _tangent() * c.rel_v_s
	var v_player := _car.world_velocity()
	var v_traffic := _tangent() * _traffic.v[i]
	_start(c)
	var jp := _crash.player_impulse()
	var jt := _crash.traffic_impulse()
	lt(jp.dot(rel), 0.0, "player impulse opposes the relative velocity")
	gt(jt.dot(rel), 0.0, "traffic impulse follows the relative velocity")
	var up := Vector3.UP
	_near_v((jp + jt) - up * (jp + jt).dot(up), Vector3.ZERO, 1e-3, "horizontal impulses are equal and opposite")
	lt((_crash.player_body().linear_velocity - v_player).dot(rel), 0.0, "player slowed relative to the hit car")
	gt((_crash.traffic_body().linear_velocity - v_traffic).dot(rel), 0.0, "hit car pushed ahead")
	gt(_crash.player_body().angular_velocity.length(), 0.0, "player tumbles")
	gt(_crash.traffic_body().angular_velocity.length(), 0.0, "hit car tumbles")
	await _frames(FRAMES_PER_CYCLE)
	var closing := (_crash.player_body().linear_velocity - _crash.traffic_body().linear_velocity).dot(_tangent())
	lt(closing, 0.0, "after the hit the bodies separate")


func test_impulse_is_deterministic() -> void:
	var i := _spawn_ahead(0.0, TRAFFIC_KMH)
	_start(_rear_end(i))
	var jp := _crash.player_impulse()
	var wp := _crash.player_body().angular_velocity
	_crash.reset()
	_car.place_at(PLAYER_S, _road.lane_center_d(PLAYER_LANE, PLAYER_S), Units.kmh_to_mps(PLAYER_KMH))
	_start(_rear_end(i))
	check(jp == _crash.player_impulse(), "same contact, same impulse (exact)")
	check(wp == _crash.player_body().angular_velocity, "same contact, same tumble (exact)")


func test_barrier_contact_moves_only_the_player() -> void:
	_start(_barrier())
	check(not _crash.has_traffic_body(), "no traffic body")
	check(not _crash.traffic_body().visible and _crash.traffic_body().freeze, "traffic body stays pooled")
	eq(_crash.hidden_slot(), -1, "no slot hidden")
	_road.sample_into(PLAYER_S, _smp)
	lt(_crash.player_impulse().dot(_smp.right), 0.0, "pushed away from the guardrail (left)")
	lt(_crash.player_impulse().dot(_smp.tangent), 0.0, "the scrape slows the car")
	eq(_started, 1, "crash_started")
	await _frames(FRAMES_PER_CYCLE)
	check(_crash.player_body().visible and not _crash.player_body().freeze, "player body live")


func test_arena_catches_the_bodies() -> void:
	var i := _spawn_ahead(0.0, TRAFFIC_KMH)
	_road.sample_into(PLAYER_S, _smp)
	var ground_y := _smp.local_point(0.0, _origin.origin_x, _origin.origin_y, _origin.origin_z).y
	_start(_rear_end(i))
	await _frames(60)
	gt(_crash.player_body().global_position.y, ground_y, "player body above the road after 0.5 s")
	gt(_crash.traffic_body().global_position.y, ground_y, "traffic body above the road after 0.5 s")
	var d_p := (_crash.player_body().global_position - _smp.local_point(0.0, _origin.origin_x, _origin.origin_y,
		_origin.origin_z)).dot(_smp.right)
	gt(d_p, 0.0, "player body stays on its side of the median barrier")


# ---------------------------------------------------------------- Player car

func test_player_car_stops_and_follows_its_body() -> void:
	var i := _spawn_ahead(0.0, TRAFFIC_KMH)
	var s0 := _car.state.s
	var d0 := _car.state.d
	check(_car.is_physics_processing(), "car ticks before the crash")
	_start(_rear_end(i))
	check(not _car.is_physics_processing(), "car stops ticking")
	check(not _car.shadow.visible, "blob shadow hidden while airborne")
	await _frames(FRAMES_PER_CYCLE)
	# physics_frame resumes before this frame's _physics_process: let it run.
	await tree.process_frame
	eq(_car.state.s, s0, "VehicleState untouched (s)")
	eq(_car.state.d, d0, "VehicleState untouched (d)")
	var expected := _crash.player_body().global_transform \
		* Transform3D(Basis.IDENTITY, Vector3(0.0, -_car.car.height_m * 0.5, 0.0))
	_near_v(_car.global_transform.origin, expected.origin, POS_TOL_M, "car follows the body")


func test_reset_returns_bodies_and_restores_the_car() -> void:
	var i := _spawn_ahead(0.0, TRAFFIC_KMH)
	var car_xf := _car.global_transform
	_start(_rear_end(i))
	await _frames(FRAMES_PER_CYCLE)
	_crash.reset()
	for b: RigidBody3D in [_crash.player_body(), _crash.traffic_body()]:
		check(b.freeze, "%s frozen" % b.name)
		eq(b.freeze_mode, RigidBody3D.FREEZE_MODE_KINEMATIC, "%s kinematic" % b.name)
		check(not b.visible, "%s hidden" % b.name)
		eq(b.collision_layer, 0, "%s collides with nothing" % b.name)
		eq(b.linear_velocity, Vector3.ZERO, "%s at rest" % b.name)
	check(_car.is_physics_processing(), "car ticks again")
	check(_car.shadow.visible, "blob shadow back")
	_near_v(_car.global_transform.origin, car_xf.origin, POS_TOL_M, "car back at its pose")
	check(not _crash.is_running(), "not running")
	await _frames(1)
	check(_crash.player_body().freeze, "still frozen after a physics frame")


# ---------------------------------------------------------------- Traffic view

func test_hit_car_is_hidden_during_the_crash_and_shown_after() -> void:
	var i := _spawn_ahead(0.0, TRAFFIC_KMH)
	eq(_view.visible_count(), 1, "drawn before")
	_start(_rear_end(i))
	eq(_crash.hidden_slot(), i, "hidden slot")
	_view.render(1.0)
	eq(_view.visible_count(), 0, "hidden in the view during the crash")
	check(_crash.traffic_body().visible, "drawn on its body instead")
	_crash.reset()
	_view.render(1.0)
	eq(_view.visible_count(), 1, "drawn again after reset")


# ---------------------------------------------------------------- Timing and events

func test_finished_fires_once_after_the_duration() -> void:
	var i := _spawn_ahead(0.0, TRAFFIC_KMH)
	_start(_rear_end(i))
	eq(_started, 1, "crash_started once")
	near(_slowmo_scale, _ctx.tuning.feel.slowmo_crash_scale, 1e-9, "slow motion scale (0.25)")
	near(_slowmo_s, _ctx.tuning.feel.slowmo_crash_s, 1e-9, "slow motion duration (2.5 s)")
	eq(_slowmo_reason, &"crash", "slow motion reason")
	var duration := _crash.duration_s()
	ge(duration, _ctx.tuning.feel.slowmo_crash_s, "the cinematic covers the slow motion")
	var t := 0.0
	while t + ADVANCE_STEP_S < duration - ADVANCE_STEP_S:
		_crash.advance(ADVANCE_STEP_S)
		t += ADVANCE_STEP_S
	eq(_finished, 0, "not finished before the duration")
	_crash.advance(ADVANCE_STEP_S * 3.0)
	eq(_finished, 1, "finished once")
	check(not _last_skipped, "not skipped")
	eq(_crash_finished, 1, "crash_finished once")
	_crash.advance(duration)
	_crash.skip()
	eq(_finished, 1, "still once")
	eq(_crash_finished, 1, "crash_finished still once")
	eq(_started, 1, "crash_started still once")
	check(_crash.is_running(), "bodies keep going behind the results until reset")


func test_skip_finishes_at_once() -> void:
	var i := _spawn_ahead(0.0, TRAFFIC_KMH)
	_start(_rear_end(i))
	_crash.skip()
	eq(_finished, 1, "finished on skip")
	check(_last_skipped, "skipped")
	eq(_crash_finished, 1, "crash_finished on skip")
	_crash.skip()
	_crash.advance(_crash.duration_s() * 2.0)
	eq(_finished, 1, "exactly once")
	eq(_crash_finished, 1, "exactly once")


func test_events_fire_once_per_sequence() -> void:
	for c in CYCLES:
		var i := _spawn_ahead(0.0, TRAFFIC_KMH)
		_start(_rear_end(i))
		_crash.advance(_crash.duration_s() + ADVANCE_STEP_S)
		_crash.reset()
		_traffic.free_slot(i)
		_car.place_at(PLAYER_S, _road.lane_center_d(PLAYER_LANE, PLAYER_S), Units.kmh_to_mps(PLAYER_KMH))
	eq(_started, CYCLES, "one crash_started per sequence")
	eq(_crash_finished, CYCLES, "one crash_finished per sequence")
	eq(_finished, CYCLES, "one finished per sequence")


func test_tap_skips_after_the_grace_period() -> void:
	var i := _spawn_ahead(0.0, TRAFFIC_KMH)
	_start(_rear_end(i))
	var tap := InputEventScreenTouch.new()
	tap.index = IOS_TOUCH_ID
	tap.pressed = true
	tap.position = Vector2(100.0, 100.0)
	tree.root.push_input(tap)
	eq(_finished, 0, "a tap inside the grace does not skip")
	_crash.advance(_crash.tuning.skip_grace_s + ADVANCE_STEP_S)
	var release := InputEventScreenTouch.new()
	release.index = IOS_TOUCH_ID
	release.pressed = false
	tree.root.push_input(release)
	eq(_finished, 0, "a release does not skip")
	tree.root.push_input(tap)
	eq(_finished, 1, "a tap after the grace skips")
	check(_last_skipped, "skipped")


func test_tap_to_skip_can_be_turned_off() -> void:
	var i := _spawn_ahead(0.0, TRAFFIC_KMH)
	_crash.tap_to_skip = false
	_start(_rear_end(i))
	_crash.advance(_crash.tuning.skip_grace_s + ADVANCE_STEP_S)
	var tap := InputEventScreenTouch.new()
	tap.index = IOS_TOUCH_ID
	tap.pressed = true
	tree.root.push_input(tap)
	eq(_finished, 0, "no skip when tap_to_skip is off")


# ---------------------------------------------------------------- Camera

func test_orbit_camera_is_current_and_frames_the_bodies() -> void:
	var i := _spawn_ahead(0.0, TRAFFIC_KMH)
	var rig_cam := _rig.camera()
	eq(tree.root.get_camera_3d(), rig_cam, "rig camera before")
	_start(_rear_end(i))
	eq(tree.root.get_camera_3d(), _crash.crash_camera(), "crash camera current")
	await _frames(FRAMES_PER_CYCLE)
	var cam := _crash.crash_camera()
	var angle0 := cam.global_position - _crash.player_body().global_position
	_crash.advance(ADVANCE_STEP_S)
	var mid := (_crash.player_body().get_global_transform_interpolated().origin
		+ _crash.traffic_body().get_global_transform_interpolated().origin) * 0.5
	var to_mid := (mid - cam.global_position).normalized()
	var fwd := -cam.global_transform.basis.z
	gt(fwd.dot(to_mid), cos(deg_to_rad(15.0)), "looks at the midpoint of the bodies")
	_crash.advance(ADVANCE_STEP_S * 10.0)
	var angle1 := cam.global_position - _crash.player_body().global_position
	var a0 := atan2(angle0.z, angle0.x)
	var a1 := atan2(angle1.z, angle1.x)
	ne(snappedf(a0, 1e-3), snappedf(a1, 1e-3), "the camera orbits")
	_crash.reset()
	eq(tree.root.get_camera_3d(), rig_cam, "rig camera restored")
	check(not _crash.crash_camera().current, "crash camera released")


func test_reduced_motion_orbits_slower() -> void:
	var rates: Array[float] = []
	for reduced: bool in [false, true]:
		Settings.set_value(&"reduced_motion", reduced)
		var i := _spawn_ahead(0.0, TRAFFIC_KMH)
		_start(_rear_end(i))
		var cam := _crash.crash_camera()
		var p0 := cam.global_position - _crash.player_body().global_position
		_crash.advance(ADVANCE_STEP_S)
		var p1 := cam.global_position - _crash.player_body().global_position
		rates.append(absf(angle_difference(atan2(p0.z, p0.x), atan2(p1.z, p1.x))))
		_crash.reset()
		_traffic.free_slot(i)
		_car.place_at(PLAYER_S, _road.lane_center_d(PLAYER_LANE, PLAYER_S), Units.kmh_to_mps(PLAYER_KMH))
	Settings.set_value(&"reduced_motion", false)
	gt(rates[0], 0.0, "orbits")
	within_pct(rates[1], rates[0] * _crash.tuning.orbit_reduced_motion_frac, 0.05, "gentler orbit")


# ---------------------------------------------------------------- Floating origin

func test_origin_shift_moves_the_crash_with_the_world() -> void:
	var i := _spawn_ahead(0.0, TRAFFIC_KMH)
	_start(_rear_end(i))
	await _frames(1)
	var before := _crash.player_body().global_position
	var shift := _origin.shift_distance_m * 1.5
	_road.sample_into(PLAYER_S + shift, _smp)
	check(_origin.update_focus(_smp.pos_x, _smp.pos_y, _smp.pos_z), "origin shifted")
	var offset := _origin.last_offset
	_near_v(_crash.player_body().global_position, before - offset, POS_TOL_M, "body moved with the world")
	var expected := _crash.player_body().global_transform \
		* Transform3D(Basis.IDENTITY, Vector3(0.0, -_car.car.height_m * 0.5, 0.0))
	_near_v(_car.global_transform.origin, expected.origin, POS_TOL_M, "car still on its body")

