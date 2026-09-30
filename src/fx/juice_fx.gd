class_name JuiceFx
extends Node3D
## The run's speed and impact particles. Spec: Audio, haptics and game feel → Speed
## effects (speed lines and wind streaks above 180 km/h), Particles (tire smoke on hard
## braking, sparks on barrier scrapes); Performance budget (particles clamped per tier);
## plan D16 (nothing covers the road in the hood and cockpit cameras).
##
## A listener only (Architecture rule 8). Two draws at most, none when idle:
##   - SpeedLines (1 draw call above FeelTuning.speed_lines_min_kmh): intensity from
##     the car's speed and boost, read each frame; edge-only in
##     FeelTuning.speed_lines_edge_camera_modes (the active CameraRig's mode, so a
##     dev/snap set_mode counts too); hidden from Events.crash_started until the next
##     Events.run_started.
##   - FxParticles (1 draw call while a particle lives): tire smoke at the rear wheels'
##     contact points while Events.hard_braking_changed is on (FeelTuning
##     tire_smoke_rate_hz per wheel x particle scale), and a spark burst at
##     Events.barrier_scrape(world_pos) (sparks_count x particle scale), thrown off the
##     barrier toward the car. World space, so they are fine in every camera.
## Quality.particle_scale (re-read on Events.quality_changed / governor_changed) clamps
## the streak count and the particle cap and scales the emission counts.
## Other scoring feedback lives elsewhere: glitter bursts in the HUD (HudGlitter), the
## FOV punch and shake in CameraRig, slow motion in TimeScale.

const REAR_WHEELS: Array[int] = [2, 3]   # CarModel.WHEEL_NAMES: RL, RR

var car: PlayerCar
var feel: FeelTuning
var speed_lines: SpeedLines
var particles: FxParticles
var hard_braking: bool = false
## Spark bursts played (tests, dev stats).
var spark_bursts: int = 0

var _scale: float = 1.0
var _smoke_acc: float = 0.0
var _crashed: bool = false
var _mode: StringName = &""


func _init() -> void:
	name = "JuiceFx"


func _enter_tree() -> void:
	if feel == null:
		feel = Tuning.load_default().feel
	if speed_lines == null:
		_scale = _quality_scale()
		speed_lines = SpeedLines.new()
		speed_lines.setup(feel, _scale)
		add_child(speed_lines)
		particles = FxParticles.new()
		particles.setup(feel, _scale)
		add_child(particles)
	_mode = StringName(str(Settings.get_value(&"camera_mode")))
	_connect(Events.hard_braking_changed, _on_hard_braking_changed)
	_connect(Events.barrier_scrape, _on_barrier_scrape)
	_connect(Events.crash_started, _on_crash_started)
	_connect(Events.run_started, _on_run_started)
	_connect(Events.camera_mode_changed, _on_camera_mode_changed)
	_connect(Events.quality_changed, _on_quality_changed)
	_connect(Events.governor_changed, _on_governor_changed)


func _exit_tree() -> void:
	_disconnect(Events.hard_braking_changed, _on_hard_braking_changed)
	_disconnect(Events.barrier_scrape, _on_barrier_scrape)
	_disconnect(Events.crash_started, _on_crash_started)
	_disconnect(Events.run_started, _on_run_started)
	_disconnect(Events.camera_mode_changed, _on_camera_mode_changed)
	_disconnect(Events.quality_changed, _on_quality_changed)
	_disconnect(Events.governor_changed, _on_governor_changed)


func bind(player_car: PlayerCar) -> void:
	car = player_car


func _process(delta: float) -> void:
	advance(delta)


## One frame (`dt`: the scaled frame time). Allocation-free.
func advance(dt: float) -> void:
	var has_car := car != null and is_instance_valid(car)
	if has_car and not _crashed:
		speed_lines.set_edge_only(feel.speed_lines_edge_camera_modes.has(_camera_mode()))
		speed_lines.update(dt, car.state.v, car.state.boost_active)
	elif speed_lines.visible:
		speed_lines.hide_lines()
	if hard_braking and has_car and car.model != null:
		_smoke_acc += dt * feel.tire_smoke_rate_hz * _scale
		var vel := car.world_velocity() * feel.tire_smoke_carry
		while _smoke_acc >= 1.0:
			_smoke_acc -= 1.0
			for w in REAR_WHEELS:
				particles.emit_smoke(_wheel_contact(w), vel)
	particles.advance(dt)


## Particles and speed lines currently drawn (0 when idle, at most 2).
func active_draws() -> int:
	return int(speed_lines.visible) + int(particles.visible)


## Current particle scale (Quality.particle_scale when it was last read).
func particle_scale() -> float:
	return _scale


func set_particle_scale(value: float) -> void:
	_scale = clampf(value, 0.0, 1.0)
	speed_lines.set_particle_scale(_scale)
	particles.set_particle_scale(_scale)


## Spark burst at `world_pos` (the Events.barrier_scrape handler).
func sparks_at(world_pos: Vector3) -> int:
	var carrier := Vector3.ZERO
	var away := Vector3.ZERO
	if car != null and is_instance_valid(car):
		carrier = car.world_velocity()
		away = car.global_position - world_pos
		away.y = 0.0
		away = away.normalized() if away.length_squared() > 0.0 else Vector3.ZERO
	spark_bursts += 1
	return particles.burst_sparks(world_pos, carrier, away, roundi(float(feel.sparks_count) * _scale))


func _wheel_contact(i: int) -> Vector3:
	var model := car.model
	var up := car.global_basis.y
	if i < model.wheels.size() and model.wheels[i] != null:
		return model.wheels[i].global_position - up * model.wheel_radius_m
	var box := model.body_aabb
	var side := -0.5 if i % 2 == 0 else 0.5
	return car.global_transform * Vector3(box.size.x * side, 0.0, box.end.z)


func _camera_mode() -> StringName:
	var vp := get_viewport()
	var cam := vp.get_camera_3d() if vp != null else null
	var rig := cam.get_parent() as CameraRig if cam != null else null
	return rig.mode if rig != null else _mode


func _quality_scale() -> float:
	return clampf(float(Quality.particle_scale), 0.0, 1.0)


func _on_hard_braking_changed(active: bool) -> void:
	hard_braking = active
	if not active:
		_smoke_acc = 0.0


func _on_barrier_scrape(world_pos: Vector3) -> void:
	sparks_at(world_pos)


func _on_crash_started() -> void:
	_crashed = true
	hard_braking = false
	speed_lines.hide_lines()


func _on_run_started(_mode_name: StringName, _seed: int) -> void:
	_crashed = false
	hard_braking = false
	_smoke_acc = 0.0
	particles.clear()
	speed_lines.hide_lines()


func _on_camera_mode_changed(mode: StringName) -> void:
	_mode = mode


func _on_quality_changed(_tier: StringName) -> void:
	set_particle_scale(_quality_scale())


func _on_governor_changed(_rung: int) -> void:
	set_particle_scale(_quality_scale())


static func _connect(sig: Signal, fn: Callable) -> void:
	if not sig.is_connected(fn):
		sig.connect(fn)


static func _disconnect(sig: Signal, fn: Callable) -> void:
	if sig.is_connected(fn):
		sig.disconnect(fn)
