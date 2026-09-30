class_name FxParticles
extends MultiMeshInstance3D
## Pooled world-space particles for tire smoke and barrier sparks. Spec: Audio, haptics
## and game feel → Particles ("tire smoke on hard braking, and sparks on barrier
## scrapes"); Performance budget (Transparency: "particles clamped in screen size and
## count per tier"; unlit effects only).
##
## One MultiMesh of unit quads drawn by assets/shaders/fx_particles.gdshader: 1 draw
## call while any particle is alive, hidden (0 draw calls) when none is. The pool is
## allocated once (setup) at FeelTuning.particles_pool; the live cap is the pool x
## Quality.particle_scale (set_particle_scale). Particles live in structure-of-arrays
## storage and are compacted by swap-remove; emit() and advance() allocate nothing.
## A full pool drops new particles (counted).
##
## Top-level at the origin: positions are world (render) space and move with
## Events.origin_shifted. Visual only: the randomness is this node's own generator
## with a fixed seed, never a gameplay stream.

const SHADER := preload("res://assets/shaders/fx_particles.gdshader")
const KIND_SMOKE := 0
const KIND_SPARK := 1
## Transparent pass order: above the sky layers (-100..-97, CONTRACTS.md §13) and the
## damage smoke (2).
const RENDER_PRIORITY := 3
## Visual-only random seed (any constant).
const VISUAL_SEED := 7411

var feel: FeelTuning
## Pool size (allocated) and live cap (pool x particle scale).
var capacity: int = 0
var cap: int = 0
var alive: int = 0
## Particles emitted and dropped (pool full) since setup (tests, dev stats).
var emitted_total: int = 0
var dropped_total: int = 0

var _pos := PackedVector3Array()
var _vel := PackedVector3Array()
var _ref := PackedVector3Array()
var _age := PackedFloat32Array()
var _life := PackedFloat32Array()
var _kind := PackedInt32Array()
var _rng := RandomNumberGenerator.new()
var _mat: ShaderMaterial


func _init() -> void:
	name = "FxParticles"
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	visible = false
	_rng.seed = VISUAL_SEED


func _enter_tree() -> void:
	if not Events.origin_shifted.is_connected(_on_origin_shifted):
		Events.origin_shifted.connect(_on_origin_shifted)


func _exit_tree() -> void:
	if Events.origin_shifted.is_connected(_on_origin_shifted):
		Events.origin_shifted.disconnect(_on_origin_shifted)


## Allocates the pool and the material (load time).
func setup(tuning: FeelTuning, particle_scale: float) -> void:
	feel = tuning
	capacity = maxi(tuning.particles_pool, 0)
	_pos.resize(capacity)
	_vel.resize(capacity)
	_ref.resize(capacity)
	_age.resize(capacity)
	_life.resize(capacity)
	_kind.resize(capacity)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	mm.mesh = quad
	mm.instance_count = capacity
	mm.visible_instance_count = 0
	multimesh = mm
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_mat.render_priority = RENDER_PRIORITY
	_mat.set_shader_parameter(&"smoke_color", _rgb(tuning.tire_smoke_color))
	_mat.set_shader_parameter(&"smoke_alpha", tuning.tire_smoke_alpha)
	_mat.set_shader_parameter(&"hot_color", _rgb(tuning.sparks_hot_color))
	_mat.set_shader_parameter(&"cool_color", _rgb(tuning.sparks_cool_color))
	material_override = _mat
	alive = 0
	visible = false
	set_particle_scale(particle_scale)


## The quality clamp: the live cap becomes pool x `scale` (0..1); extra live particles
## are dropped.
func set_particle_scale(particle_scale: float) -> void:
	cap = clampi(roundi(float(capacity) * particle_scale), 0, capacity)
	if alive > cap:
		alive = cap
		_publish()


## One smoke puff at `pos` (world), moving at `vel` (m/s). False when the pool is full.
func emit_smoke(pos: Vector3, vel: Vector3) -> bool:
	var f := feel
	var jitter := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(0.0, 1.0), _rng.randf_range(-1.0, 1.0))
	return _emit(KIND_SMOKE, pos, vel + jitter * f.tire_smoke_spread_mps, Vector3.ZERO, f.tire_smoke_lifetime_s)


## A burst of sparks at `pos` (world) from a body moving at `carrier_vel`, thrown
## toward `away` (a horizontal unit vector off the barrier; zero: any side). Returns the
## number emitted (the quality clamp and a full pool limit it).
func burst_sparks(pos: Vector3, carrier_vel: Vector3, away: Vector3, count: int) -> int:
	var f := feel
	var n := 0
	for i in count:
		var dir := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(0.2, 1.0), _rng.randf_range(-1.0, 1.0))
		dir += away
		dir = dir.normalized()
		var v := carrier_vel * f.sparks_carry + dir * _rng.randf_range(f.sparks_speed_min_mps, f.sparks_speed_max_mps)
		var life := _rng.randf_range(f.sparks_lifetime_min_s, f.sparks_lifetime_max_s)
		if _emit(KIND_SPARK, pos, v, carrier_vel, life):
			n += 1
	return n


## Ages, moves and draws every live particle (`dt`: the scaled frame time, so slow
## motion slows them). Allocation-free.
func advance(dt: float) -> void:
	if alive == 0:
		return
	var f := feel
	var smoke_keep := maxf(0.0, 1.0 - f.tire_smoke_drag_per_s * dt)
	var spark_keep := maxf(0.0, 1.0 - f.sparks_drag_per_s * dt)
	var rise := Vector3(0.0, f.tire_smoke_rise_mps2 * dt, 0.0)
	var fall := Vector3(0.0, -f.sparks_gravity_mps2 * dt, 0.0)
	var i := 0
	while i < alive:
		_age[i] += dt
		if _age[i] >= _life[i]:
			_kill(i)
			continue
		if _kind[i] == KIND_SMOKE:
			_vel[i] = (_vel[i] + rise) * smoke_keep
		else:
			_vel[i] = (_vel[i] + fall) * spark_keep
		_pos[i] += _vel[i] * dt
		i += 1
	_publish()


## Drops every particle (a new run).
func clear() -> void:
	alive = 0
	_publish()


## Live particles of `kind` (tests).
func count_kind(kind: int) -> int:
	var n := 0
	for i in alive:
		if _kind[i] == kind:
			n += 1
	return n


## Position of live particle `i` (tests).
func particle_position(i: int) -> Vector3:
	return _pos[i]


func _emit(kind: int, pos: Vector3, vel: Vector3, ref: Vector3, life: float) -> bool:
	if alive >= cap or life <= 0.0:
		dropped_total += 1
		return false
	var i := alive
	_pos[i] = pos
	_vel[i] = vel
	_ref[i] = ref
	_age[i] = 0.0
	_life[i] = life
	_kind[i] = kind
	alive += 1
	emitted_total += 1
	return true


func _kill(i: int) -> void:
	var last := alive - 1
	if i != last:
		_pos[i] = _pos[last]
		_vel[i] = _vel[last]
		_ref[i] = _ref[last]
		_age[i] = _age[last]
		_life[i] = _life[last]
		_kind[i] = _kind[last]
	alive = last


## Writes the live particles to the MultiMesh; hidden when none is alive.
func _publish() -> void:
	if multimesh == null:
		return
	var f := feel
	for i in alive:
		var t := _age[i] / _life[i]
		var b: Basis
		if _kind[i] == KIND_SMOKE:
			var size := lerpf(f.tire_smoke_size_birth_m, f.tire_smoke_size_death_m, t)
			b = Basis.from_scale(Vector3(size, size, size))
		else:
			# The streak runs along the spark's motion relative to what threw it (the
			# viewer rides along), at least twice its width long.
			var streak := (_vel[i] - _ref[i]) * f.sparks_streak_s
			var min_len := f.sparks_width_m * 2.0
			if streak.length() < min_len:
				streak = Vector3.UP * min_len if streak.is_zero_approx() else streak.normalized() * min_len
			b = Basis(streak, Vector3(0.0, f.sparks_width_m, 0.0), Vector3(0.0, 0.0, 1.0))
		multimesh.set_instance_transform(i, Transform3D(b, _pos[i]))
		multimesh.set_instance_custom_data(i, Color(float(_kind[i]), t, 1.0, 0.0))
	multimesh.visible_instance_count = alive
	visible = alive > 0


func _on_origin_shifted(offset: Vector3) -> void:
	for i in alive:
		_pos[i] -= offset


static func _rgb(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)
