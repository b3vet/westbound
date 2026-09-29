class_name CrashSequence
extends Node3D
## The run-over crash cinematic (WP4.2). Spec: Lives, hits and crashes → Second hit
## (run over): the player car and the car it hit become Jolt RigidBody3Ds at their
## current velocities with an impulse from the relative velocity at the contact point;
## 0.25× for 2.5 s with an orbit crash camera; results after the cinematic, tap skips
## at any time; pooled bodies return to kinematic on the next run. Cameras → Scripted
## cameras (Crash). Contracts: docs/CONTRACTS.md §2 (road space → world), §13
## (floating origin), §14 (CrashSequence). Details: docs/CRASH.md.
##
##   crash.setup(ctx, registry)                  # load time: builds the whole pool
##   # tick step 4, on Lives.Outcome.RUN_OVER (after traffic_sim.notify_hit):
##   crash.start(player_car, contact, traffic_sim.state, traffic_view, road, origin, rig)
##   crash.finished.connect(_on_crash_finished)  # after the cinematic, or skip()
##   crash.reset()                               # on retry, before placing the car
##
## Presentation only: it never writes VehicleState, TrafficState or any sim. The
## PlayerCar stops ticking (physics process off; a run that calls PlayerCar.tick()
## itself must stop doing so) and follows the player body; its CarVisual is untouched.
## The hit traffic car is hidden in the TrafficView and drawn on its own body with the
## same mesh, material and paint. An invisible arena of static boxes (ground slabs,
## median barrier, guardrails) is built along the road around the contact.
##
## Time: slow motion is requested with Events.slowmo_requested (FeelTuning crash scale
## and duration); the sequence never sets Engine.time_scale itself and works at any
## scale. Its clock (duration, orbit, skip grace) runs in real, unscaled seconds:
## `finished` fires slowmo_crash_s + cinematic_tail_s real seconds after start().
## _process feeds advance() with delta / Engine.time_scale; tests turn auto_advance
## off and call advance(dt) themselves.
##
## Pool: two RigidBody3Ds (player, hit car) with box shapes, the hit car's one-instance
## MultiMesh, one StaticBody3D with the arena boxes and the crash Camera3D are built once
## in setup(). start() and reset() create and free no nodes. Pooled bodies are frozen
## (kinematic), hidden and collide with nothing.

## Emitted once per sequence: when the cinematic ends, or at once on skip().
signal finished(skipped: bool)

## Physics layer the crash bodies and the arena use while a crash runs (nothing else in
## the game has physics bodies).
const CRASH_LAYER := 1
## Arena boxes per road segment: ground slab, median barrier, right and left guardrail.
const SHAPES_PER_SEGMENT := 4
const GROUND := 0
const MEDIAN := 1
const RAIL_RIGHT := 2
const RAIL_LEFT := 3
const SLOWMO_REASON := &"crash"

## Crash numbers; setup() fills it (ctx.tuning.crash once it exists, else
## CrashTuning.load_default()).
var tuning: CrashTuning
## Slow-motion scale and duration (the spec's 0.25× for 2.5 s).
var feel: FeelTuning
## Drive the clock from _process (off in tests, which call advance(dt)).
var auto_advance: bool = true
## Tap (touch, click or key press) anywhere skips to the results once the skip grace
## has passed. The run may turn it off and call skip() from its own input handling.
var tap_to_skip: bool = true

var _road_tuning: RoadTuning
var _inset_m: float = 0.0
var _registry: TrafficRegistry
var _meshes: Dictionary = {}   # model scene path -> Mesh
var _built: bool = false

var _player_body: RigidBody3D
var _player_shape: BoxShape3D
var _traffic_body: RigidBody3D
var _traffic_shape: BoxShape3D
var _traffic_mmi: MultiMeshInstance3D
var _traffic_mm: MultiMesh
var _traffic_material: ShaderMaterial
var _palette_v4 := PackedVector4Array()
var _arena: StaticBody3D
var _arena_shapes: Array[CollisionShape3D] = []
var _arena_boxes: Array[BoxShape3D] = []
var _segments: int = 0
var _camera: Camera3D
var _physics_material: PhysicsMaterial

var _running: bool = false
var _finished: bool = false
var _skipped: bool = false
var _elapsed_s: float = 0.0
var _duration_s: float = 0.0
var _player: PlayerCar
var _player_processing: bool = true
var _player_shadow_visible: bool = true
var _player_start_xf := Transform3D.IDENTITY
## PlayerCar transform relative to the player body (the body's centre is half the car
## height above the car's road-level origin).
var _player_offset := Transform3D.IDENTITY
var _has_traffic_body: bool = false
var _view: TrafficView
var _hidden_slot: int = -1
var _prev_camera: Camera3D
var _reduced_motion: bool = false
var _orbit_angle: float = 0.0
var _look := Vector3.ZERO
var _player_impulse := Vector3.ZERO
var _traffic_impulse := Vector3.ZERO
var _smp := RoadSample.new()


func _ready() -> void:
	if not Events.origin_shifted.is_connected(_on_origin_shifted):
		Events.origin_shifted.connect(_on_origin_shifted)


func _exit_tree() -> void:
	if Events.origin_shifted.is_connected(_on_origin_shifted):
		Events.origin_shifted.disconnect(_on_origin_shifted)


func _enter_tree() -> void:
	if _built and not Events.origin_shifted.is_connected(_on_origin_shifted):
		Events.origin_shifted.connect(_on_origin_shifted)


## Load time. Builds the pool once (later calls only rebind the tuning and registry)
## and caches the traffic model meshes of `registry`. `crash_tuning` overrides the
## tuning (tests).
func setup(ctx: RunContext, registry: TrafficRegistry, crash_tuning: CrashTuning = null) -> void:
	tuning = crash_tuning
	if tuning == null:
		tuning = ctx.tuning.get(&"crash") as CrashTuning
	if tuning == null:
		tuning = CrashTuning.load_default()
	feel = ctx.tuning.feel
	_road_tuning = ctx.tuning.road
	_inset_m = ctx.tuning.lives.collision_inset_m
	if registry != _registry:
		_registry = registry
		_cache_meshes()
	if not _built:
		_build_pool()
	_apply_body_tuning()


## Hands the crash to physics. `contact` is the run-over contact from HitDetection
## (slot >= 0: a traffic car, which gets a body too; barrier and prop contacts only
## move the player). `traffic` and `view` may be null for barrier contacts. `rig` may
## be null (the viewport's current camera is restored instead). Emits
## Events.crash_started and Events.slowmo_requested. A running sequence is reset first.
func start(player: PlayerCar, contact: HitDetection.Contact, traffic: TrafficState, view: TrafficView,
		road: RoadPath, origin: FloatingOrigin, rig: CameraRig) -> void:
	if not _built:
		push_error("CrashSequence.start: call setup() first")
		return
	if _running:
		reset()
	_running = true
	_finished = false
	_skipped = false
	_elapsed_s = 0.0
	_duration_s = feel.slowmo_crash_s + tuning.cinematic_tail_s
	_reduced_motion = bool(Settings.get_value(&"reduced_motion"))

	# Player body at the car's pose and world velocity.
	_player = player
	var car := player.car
	_player_start_xf = player.global_transform
	_player_offset = Transform3D(Basis.IDENTITY, Vector3(0.0, -car.height_m * 0.5, 0.0))
	var p_xf := _player_start_xf * _player_offset.affine_inverse()
	var p_mass := car.mass_kg
	_player_shape.size = Vector3(maxf(car.width_m - 2.0 * _inset_m, _inset_m),
		car.height_m, maxf(car.length_m - 2.0 * _inset_m, _inset_m))
	var p_vel := player.world_velocity()
	var p_spin := player.road_sample().up * -_world_yaw_rate(player)
	_player_processing = player.is_physics_processing()
	player.set_physics_process(false)
	if player.shadow != null:
		_player_shadow_visible = player.shadow.visible
		player.shadow.visible = false

	# Traffic body at the drawn pose and the car's world velocity.
	_has_traffic_body = false
	_view = view
	_hidden_slot = -1
	var o_xf := Transform3D.IDENTITY
	var o_mass := 0.0
	var o_vel := Vector3.ZERO
	if contact.slot >= 0 and traffic != null and traffic.is_active(contact.slot):
		_has_traffic_body = true
		var slot := contact.slot
		var vt := _registry.types[traffic.type_id[slot]]
		o_mass = vt.mass_kg
		var height := vt.height_m
		_traffic_shape.size = Vector3(maxf(traffic.width[slot] - 2.0 * _inset_m, _inset_m), height,
			maxf(traffic.length[slot] - 2.0 * _inset_m, _inset_m))
		road.sample_into(traffic.s[slot], _smp)
		var model_xf := _traffic_pose(slot, traffic, view, origin)
		o_xf = model_xf * Transform3D(Basis.IDENTITY, Vector3(0.0, height * 0.5, 0.0))
		o_vel = _smp.tangent * traffic.v[slot] + _smp.right * traffic.v_lat[slot]
		_show_traffic_model(slot, traffic, view, height)
		if view != null:
			view.set_slot_hidden(slot, true)
			_hidden_slot = slot

	# Impulse from the relative velocity at the contact point.
	road.sample_into(contact.s, _smp)
	var up := _smp.up
	var cp := _local(contact.d, origin) + up * (car.height_m * tuning.contact_height_frac)
	var n := (_smp.tangent * contact.normal_s + _smp.right * contact.normal_d).normalized()
	if n == Vector3.ZERO:
		n = -p_xf.basis.z.normalized()
	var rel := _smp.tangent * contact.rel_v_s + _smp.right * contact.rel_v_d
	var vn := rel.dot(n)
	var rel_t := rel - n * vn
	var approach := maxf(vn, tuning.min_approach_mps())
	var mu := p_mass * o_mass / (p_mass + o_mass) if _has_traffic_body else p_mass
	var jn := (1.0 + tuning.restitution_frac) * mu * approach
	var j_other := n * jn + rel_t * (tuning.tangential_frac * mu)
	_player_impulse = -j_other + up * (p_mass * _lift_mps(jn / p_mass))
	_traffic_impulse = j_other + up * (o_mass * _lift_mps(jn / o_mass)) if _has_traffic_body else Vector3.ZERO
	var tumble := clampf(approach / tuning.tumble_full_mps(), 0.0, 1.0)

	var p_dw := _spin_from_impulse(p_xf, _player_shape.size, p_mass, cp, _player_impulse)
	p_dw = _cap_spin(p_dw + _tumble(p_xf, -n, p_dw, tumble * mu / p_mass))
	_launch(_player_body, p_xf, p_mass, p_vel + _player_impulse / p_mass, p_spin + p_dw)
	if _has_traffic_body:
		var o_dw := _spin_from_impulse(o_xf, _traffic_shape.size, o_mass, cp, _traffic_impulse)
		o_dw = _cap_spin(o_dw + _tumble(o_xf, n, o_dw, tumble * mu / o_mass))
		_launch(_traffic_body, o_xf, o_mass, o_vel + _traffic_impulse / o_mass, o_dw)

	_build_arena(road, origin, contact.s)
	_follow_player()
	_start_camera(rig)
	Events.crash_started.emit()
	Events.slowmo_requested.emit(feel.slowmo_crash_scale, feel.slowmo_crash_s, SLOWMO_REASON)


## Advances the cinematic clock by `real_dt` unscaled seconds: moves the orbit camera
## and fires `finished` when the duration has passed. Called from _process unless
## auto_advance is off.
func advance(real_dt: float) -> void:
	if not _running:
		return
	_elapsed_s += real_dt
	_update_camera(real_dt, false)
	if not _finished and _elapsed_s >= _duration_s:
		_finish(false)


## Ends the cinematic now (tap to skip): `finished(true)` and Events.crash_finished.
## The bodies and the orbit camera keep going behind the results until reset().
func skip() -> void:
	if _running and not _finished:
		_finish(true)


## Returns the bodies to the pool (frozen, kinematic, hidden, no collisions), shows the
## hit car in the TrafficView again, restores the PlayerCar (physics process, blob
## shadow, the transform it had at start()) and the previous camera. Creates and frees
## nothing. Emits nothing (a reset before the end aborts the cinematic silently).
func reset() -> void:
	_park(_player_body)
	_park(_traffic_body)
	_traffic_mmi.visible = false
	_arena.collision_layer = 0
	for cs in _arena_shapes:
		cs.disabled = true
	if _view != null and is_instance_valid(_view) and _hidden_slot >= 0:
		_view.set_slot_hidden(_hidden_slot, false)
	_view = null
	_hidden_slot = -1
	_has_traffic_body = false
	if _player != null and is_instance_valid(_player):
		_player.set_physics_process(_player_processing)
		if _player.shadow != null:
			_player.shadow.visible = _player_shadow_visible
		if _running:
			_player.global_transform = _player_start_xf
			_player.reset_physics_interpolation()
	_player = null
	if _camera.current:
		_camera.current = false
		if _prev_camera != null and is_instance_valid(_prev_camera) and _prev_camera.is_inside_tree():
			_prev_camera.make_current()
	_prev_camera = null
	_running = false
	_finished = false
	_skipped = false
	_elapsed_s = 0.0


# ---------------------------------------------------------------- Inspection

## True between start() and reset() (also after `finished`).
func is_running() -> bool:
	return _running


## True once `finished` fired (until reset()).
func is_finished() -> bool:
	return _finished


func was_skipped() -> bool:
	return _skipped


## Real seconds since start().
func elapsed_s() -> float:
	return _elapsed_s


## Real seconds from start() to `finished`: slow motion plus the tail.
func duration_s() -> float:
	return _duration_s


func player_body() -> RigidBody3D:
	return _player_body


func traffic_body() -> RigidBody3D:
	return _traffic_body


## Whether this crash has a body for a hit traffic car.
func has_traffic_body() -> bool:
	return _has_traffic_body


func crash_camera() -> Camera3D:
	return _camera


## The TrafficView slot hidden during this crash, or -1.
func hidden_slot() -> int:
	return _hidden_slot


## The impulses start() applied (N·s, world): the player's and the hit car's.
func player_impulse() -> Vector3:
	return _player_impulse


func traffic_impulse() -> Vector3:
	return _traffic_impulse


## Arena boxes in the pool (segments × SHAPES_PER_SEGMENT).
func arena_shape_count() -> int:
	return _arena_shapes.size()


# ---------------------------------------------------------------- Frame

func _process(delta: float) -> void:
	if not _running or not auto_advance:
		return
	var ts := Engine.time_scale
	advance(delta / ts if ts > 0.0 else delta)


func _physics_process(_delta: float) -> void:
	if _running:
		_follow_player()


func _unhandled_input(event: InputEvent) -> void:
	if not tap_to_skip or not _running or _finished or _elapsed_s < tuning.skip_grace_s:
		return
	var tap := false
	if event is InputEventScreenTouch:
		tap = (event as InputEventScreenTouch).pressed
	elif event is InputEventMouseButton:
		tap = (event as InputEventMouseButton).pressed
	elif event is InputEventKey:
		var k := event as InputEventKey
		tap = k.pressed and not k.echo
	if tap:
		skip()
		get_viewport().set_input_as_handled()


func _finish(skipped: bool) -> void:
	_finished = true
	_skipped = skipped
	finished.emit(skipped)
	Events.crash_finished.emit()


## The PlayerCar (and its CarVisual) takes the player body's pose.
func _follow_player() -> void:
	if _player != null and is_instance_valid(_player):
		_player.global_transform = _player_body.global_transform * _player_offset


# ---------------------------------------------------------------- Camera

func _start_camera(rig: CameraRig) -> void:
	_prev_camera = rig.camera() if rig != null else get_viewport().get_camera_3d()
	if _prev_camera != null:
		_camera.near = _prev_camera.near
		_camera.far = _prev_camera.far
	_camera.fov = tuning.fov_deg
	var target := _look_target()
	_look = target
	var from := _prev_camera.global_position if _prev_camera != null else target + Vector3.BACK
	var dir := from - target
	_orbit_angle = atan2(dir.z, dir.x) + deg_to_rad(tuning.orbit_start_offset_deg)
	_update_camera(0.0, true)
	_camera.make_current()


func _update_camera(real_dt: float, snap: bool) -> void:
	var target := _look_target()
	if snap or tuning.look_follow_s <= 0.0:
		_look = target
	else:
		_look = _look.lerp(target, 1.0 - exp(-real_dt / tuning.look_follow_s))
	var speed := deg_to_rad(tuning.orbit_speed_deg_per_s)
	if _reduced_motion:
		speed *= tuning.orbit_reduced_motion_frac
	_orbit_angle = fposmod(_orbit_angle + speed * real_dt, TAU)
	var radius := tuning.orbit_radius_m
	if _has_traffic_body:
		radius += _body_origin(_player_body).distance_to(_body_origin(_traffic_body)) \
			* tuning.orbit_radius_per_separation_frac
	radius = minf(radius, tuning.orbit_radius_max_m)
	var pos := _look + Vector3(cos(_orbit_angle) * radius, tuning.orbit_height_m, sin(_orbit_angle) * radius)
	_camera.look_at_from_position(pos, _look + Vector3.UP * tuning.look_height_m, Vector3.UP)


## Midpoint of the crash bodies (the player body alone for barrier contacts).
func _look_target() -> Vector3:
	var p := _body_origin(_player_body)
	if _has_traffic_body:
		return (p + _body_origin(_traffic_body)) * 0.5
	return p


func _body_origin(body: RigidBody3D) -> Vector3:
	return body.get_global_transform_interpolated().origin if body.is_inside_tree() else body.global_position


# ---------------------------------------------------------------- Bodies

func _launch(body: RigidBody3D, xf: Transform3D, mass: float, velocity: Vector3, spin: Vector3) -> void:
	body.mass = mass
	body.global_transform = xf
	body.collision_layer = CRASH_LAYER
	body.collision_mask = CRASH_LAYER
	body.freeze = false
	body.sleeping = false
	body.linear_velocity = velocity
	body.angular_velocity = spin
	body.visible = true
	body.reset_physics_interpolation()


func _park(body: RigidBody3D) -> void:
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	body.freeze = true
	body.collision_layer = 0
	body.collision_mask = 0
	body.visible = false
	body.global_transform = Transform3D.IDENTITY
	body.reset_physics_interpolation()


## Change of angular velocity from `impulse` at world point `at` on a box body (size:
## width, height, length) of `mass` at `xf`: I⁻¹ (r × J), with the solid-box inertia.
static func _spin_from_impulse(xf: Transform3D, size: Vector3, mass: float, at: Vector3,
		impulse: Vector3) -> Vector3:
	var torque := (at - xf.origin).cross(impulse)
	var b := xf.basis.orthonormalized()
	var local := b.transposed() * torque
	var k := mass / 12.0   # lint: allow-number solid-box moment of inertia, m (a² + b²) / 12
	var ix := k * (size.y * size.y + size.z * size.z)
	var iy := k * (size.x * size.x + size.z * size.z)
	var iz := k * (size.x * size.x + size.y * size.y)
	return b * Vector3(local.x / ix, local.y / iy, local.z / iz)


## Deterministic extra tumble for a body pushed along `push` (world): a roll toward the
## push around the body's forward axis, and a yaw spin in the sense of `spin` (the spin
## the impulse already gives). `amount` 0..1 scales the tuning rates.
func _tumble(xf: Transform3D, push: Vector3, spin: Vector3, amount: float) -> Vector3:
	var b := xf.basis.orthonormalized()
	var fwd := -b.z
	var right := b.x
	var up := b.y
	# Positive rotation about the forward axis (-Z) lowers the right side.
	var roll_sign := 1.0 if push.dot(right) >= 0.0 else -1.0
	var yaw_sign := 1.0 if spin.dot(up) >= 0.0 else -1.0
	return fwd * (roll_sign * deg_to_rad(tuning.tumble_roll_deg_per_s) * amount) \
		+ up * (yaw_sign * deg_to_rad(tuning.tumble_yaw_deg_per_s) * amount)


## Upward speed for a body whose speed along the normal changes by `dv_normal`.
func _lift_mps(dv_normal: float) -> float:
	return minf(tuning.lift_frac * dv_normal, tuning.lift_max_mps())


func _cap_spin(dw: Vector3) -> Vector3:
	return dw.limit_length(deg_to_rad(tuning.spin_max_deg_per_s))


## World yaw rate of the player car (right-positive): road-relative yaw rate plus the
## road's own turn at the car's speed along s.
static func _world_yaw_rate(player: PlayerCar) -> float:
	var st := player.state
	var smp := player.road_sample()
	var denom := 1.0 - smp.curvature * st.d
	var s_dot := st.v * cos(st.yaw) / denom if denom > 0.0 else st.v
	return st.yaw_rate + smp.curvature * s_dot


## The hit car's model transform (origin at road level): as the TrafficView drew it at
## the last capture, or from (s, d) and atan2(v_lat, v) when the view has no such slot.
func _traffic_pose(slot: int, traffic: TrafficState, view: TrafficView, origin: FloatingOrigin) -> Transform3D:
	if view != null and view.slot_model(slot) >= 0:
		return view.slot_transform(slot, false, 1.0)
	var yaw := atan2(traffic.v_lat[slot], traffic.v[slot]) if traffic.v[slot] > 0.0 else 0.0
	var up := _smp.up
	return Transform3D(Basis(_smp.right.rotated(up, -yaw), up, (-_smp.tangent).rotated(up, -yaw)),
		_local(traffic.d[slot], origin))


## Draws the hit car on its body: the registry's model mesh, the traffic material with
## the car's paint in slot 0 and its lamp bits at the moment of the crash.
func _show_traffic_model(slot: int, traffic: TrafficState, view: TrafficView, height: float) -> void:
	var vt := _registry.types[traffic.type_id[slot]]
	var mesh: Mesh = null
	if not vt.model_scene_paths.is_empty():
		var path := vt.model_scene_paths[posmod(traffic.model_variant[slot], vt.model_scene_paths.size())]
		mesh = _meshes.get(path) as Mesh
	if mesh == null:
		push_warning("CrashSequence: no model mesh for vehicle type %s" % vt.id)
		_traffic_mmi.visible = false
		return
	var paint := view.slot_paint(slot) if view != null else TrafficView.FALLBACK_PAINT
	var bits := view.slot_bits(slot, false, 1.0) if view != null else 0
	_palette_v4.fill(Vector4(paint.r, paint.g, paint.b, paint.a))
	_traffic_material.set_shader_parameter(&"palette", _palette_v4)
	if _traffic_mm.mesh != mesh:
		_traffic_mm.instance_count = 0
		_traffic_mm.mesh = mesh
		_traffic_mm.instance_count = 1
	_traffic_mm.set_instance_transform(0, Transform3D.IDENTITY)
	_traffic_mm.set_instance_color(0, Color.WHITE)
	_traffic_mm.set_instance_custom_data(0, Color(0.0, 0.0, 0.0, float(bits)))
	_traffic_mmi.position = Vector3(0.0, -height * 0.5, 0.0)
	_traffic_mmi.visible = true


func _local(d: float, origin: FloatingOrigin) -> Vector3:
	if origin != null:
		return _smp.local_point(d, origin.origin_x, origin.origin_y, origin.origin_z)
	return _smp.local_point(d, 0.0, 0.0, 0.0)


# ---------------------------------------------------------------- Arena

## Places the arena boxes along the road from contact_s - behind to contact_s + ahead
## (within the generated road): per segment a ground slab whose top is the road
## surface, the median barrier and both guardrails as walls whose faces follow
## RoadPath's barrier offsets. Segments past the generated road are disabled.
func _build_arena(road: RoadPath, origin: FloatingOrigin, contact_s: float) -> void:
	_arena.global_transform = Transform3D.IDENTITY
	_arena.collision_layer = CRASH_LAYER
	var seg := tuning.arena_segment_m
	var s0 := maxf(contact_s - tuning.arena_behind_m, 0.0)
	var s_max := road.length_generated()
	var overlap := tuning.arena_ground_thickness_m
	var wall := tuning.arena_wall_thickness_m
	for k in _segments:
		var s_mid := s0 + (float(k) + 0.5) * seg
		var off := s_mid > s_max
		for j in SHAPES_PER_SEGMENT:
			_arena_shapes[k * SHAPES_PER_SEGMENT + j].disabled = off
		if off:
			continue
		road.sample_into(s_mid, _smp)
		var b := Basis(_smp.right, _smp.up, -_smp.tangent)
		var up := _smp.up
		var rail := road.guardrail_d(s_mid)
		var median := road.median_barrier_d(s_mid)
		var i := k * SHAPES_PER_SEGMENT
		var half_ground := rail + wall + tuning.arena_ground_margin_m
		_place_box(i + GROUND, b, _local(0.0, origin) - up * (tuning.arena_ground_thickness_m * 0.5),
			Vector3(2.0 * half_ground, tuning.arena_ground_thickness_m, seg + overlap))
		var mh := _road_tuning.median_barrier_height_m
		_place_box(i + MEDIAN, b, _local(0.0, origin) + up * (mh * 0.5), Vector3(2.0 * median, mh, seg))
		var rh := _road_tuning.guardrail_top_m
		_place_box(i + RAIL_RIGHT, b, _local(rail + wall * 0.5, origin) + up * (rh * 0.5), Vector3(wall, rh, seg))
		_place_box(i + RAIL_LEFT, b, _local(-rail - wall * 0.5, origin) + up * (rh * 0.5), Vector3(wall, rh, seg))


func _place_box(index: int, b: Basis, center: Vector3, size: Vector3) -> void:
	_arena_boxes[index].size = size
	_arena_shapes[index].transform = Transform3D(b, center)


# ---------------------------------------------------------------- Pool

func _build_pool() -> void:
	_physics_material = PhysicsMaterial.new()
	_player_body = _make_body(&"PlayerBody")
	_player_shape = _player_body.get_child(0).get(&"shape") as BoxShape3D
	_traffic_body = _make_body(&"TrafficBody")
	_traffic_shape = _traffic_body.get_child(0).get(&"shape") as BoxShape3D
	_traffic_material = TrafficView.TRAFFIC_MATERIAL.duplicate() as ShaderMaterial
	_palette_v4.resize(TrafficLights.PALETTE_SLOTS)
	_traffic_mm = MultiMesh.new()
	_traffic_mm.transform_format = MultiMesh.TRANSFORM_3D
	_traffic_mm.use_custom_data = true
	# Compatibility multiplies vertex COLOR by the instance color (CONTRACTS §13 quirks).
	_traffic_mm.use_colors = true
	_traffic_mmi = MultiMeshInstance3D.new()
	_traffic_mmi.name = &"Model"
	_traffic_mmi.multimesh = _traffic_mm
	_traffic_mmi.material_override = _traffic_material
	_traffic_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_traffic_mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_traffic_mmi.visible = false
	_traffic_body.add_child(_traffic_mmi)

	_arena = StaticBody3D.new()
	_arena.name = &"Arena"
	_arena.top_level = true
	_arena.collision_layer = 0
	_arena.collision_mask = 0
	_arena.physics_material_override = _physics_material
	add_child(_arena)
	_segments = ceili((tuning.arena_ahead_m + tuning.arena_behind_m) / tuning.arena_segment_m)
	for i in _segments * SHAPES_PER_SEGMENT:
		var box := BoxShape3D.new()
		var cs := CollisionShape3D.new()
		cs.shape = box
		cs.disabled = true
		_arena.add_child(cs)
		_arena_shapes.append(cs)
		_arena_boxes.append(box)

	_camera = Camera3D.new()
	_camera.name = &"CrashCamera"
	_camera.top_level = true
	# Placed every frame from interpolated body poses: never interpolate again.
	_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_camera)
	_built = true


func _make_body(node_name: StringName) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = node_name
	body.top_level = true
	body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body.freeze = true
	body.continuous_cd = true
	body.physics_material_override = _physics_material
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.collision_layer = 0
	body.collision_mask = 0
	body.visible = false
	var cs := CollisionShape3D.new()
	cs.name = &"Shape"
	cs.shape = BoxShape3D.new()
	body.add_child(cs)
	add_child(body)
	return body


func _apply_body_tuning() -> void:
	_physics_material.friction = tuning.body_friction_frac
	_physics_material.bounce = tuning.body_bounce_frac
	for body: RigidBody3D in [_player_body, _traffic_body]:
		body.linear_damp = tuning.body_linear_damp_factor
		body.angular_damp = tuning.body_angular_damp_factor


func _cache_meshes() -> void:
	_meshes.clear()
	if _registry == null:
		return
	for t in _registry.types:
		for path in t.model_scene_paths:
			if not _meshes.has(path):
				var mesh := TrafficView.load_model_mesh(path)
				if mesh != null:
					_meshes[path] = mesh


# ---------------------------------------------------------------- Floating origin

func _on_origin_shifted(offset: Vector3) -> void:
	if not _running:
		return
	for body: RigidBody3D in [_player_body, _traffic_body]:
		if body.visible:
			body.global_position -= offset
			body.reset_physics_interpolation()
	_arena.global_position -= offset
	_player_start_xf.origin -= offset
	_look -= offset
	_follow_player()
	if _player != null and is_instance_valid(_player):
		_player.reset_physics_interpolation()
	_update_camera(0.0, true)
