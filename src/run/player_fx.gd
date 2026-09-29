class_name PlayerFx
extends Node3D
## The player car's hit visuals. Spec: Lives, hits and crashes → First hit ("the
## player flickers translucent" during the 2.0 s ghost; Damage: "smoke from the hood
## and one flickering headlight on the placeholder models" for the rest of the run).
##
## A listener only (Architecture rule 8): it reacts to Events.hit, ghost_started,
## ghost_ended and run_started and never touches gameplay state. It does not edit the
## car's own scripts (CarVisual / CarModel): it toggles the CarVisual node's
## visibility for the ghost flicker and adds its own two nodes to the car model:
##   - HoodSmoke: one CPUParticles3D (1 draw call; count scaled by
##     Quality.particle_scale) at the model's smoke_hood marker, in local coords, so
##     the puffs stream back over the windshield;
##   - DeadLamp: one small quad over headlight_L that flickers between a dead lamp and
##     a sputtering flare (the damage shader's lamp mode, set per frame).
## No lights, no StandardMaterial3D: both use src/run/damage_fx.gdshader (unlit, ends
## with wb_output). Both stay hidden (0 draw calls) until the first hit.

const SHADER := preload("res://src/run/damage_fx.gdshader")
const SMOKE_NODE := &"HoodSmoke"
const LAMP_NODE := &"DeadLamp"
const LAMP_PATH := ^"Lights/headlight_L"
const MARKER_SMOKE := &"smoke_hood"
## Transparent pass order: above the sky layers (-100..-97, docs/CONTRACTS.md §13).
const RENDER_PRIORITY := 2

# ---- pending tuning (feel.tres, WP7.4 owns it): visual-only numbers, see docs/RUN.md
## Ghost flicker: visible/hidden toggles at this rate ("flickers translucent").
const GHOST_FLICKER_HZ := 12.0   # lint: allow-number pending tuning (feel)
## Hood smoke: particles at medium quality, lifetime, speed back/up, puff size.
const SMOKE_PARTICLES := 10
const SMOKE_LIFETIME_S := 0.9   # lint: allow-number pending tuning (feel)
const SMOKE_VELOCITY_MPS := Vector2(1.5, 3.5)   # min, max
const SMOKE_DIRECTION := Vector3(0.0, 0.8, 1.0)   # up and back (+Z is the car's rear)
const SMOKE_SPREAD_DEG := 18.0   # lint: allow-number pending tuning (feel)
const SMOKE_RISE_MPS2 := 1.2   # lint: allow-number pending tuning (feel)
const SMOKE_SIZE_M := 0.55   # lint: allow-number pending tuning (feel)
const SMOKE_GROW := Vector2(0.6, 1.8)   # scale at birth, at death
## Dead headlight: flicker steps per second and the share of steps that are lit.
const LAMP_FLICKER_HZ := 14.0   # lint: allow-number pending tuning (feel)
const LAMP_LIT_SHARE := 0.35   # lint: allow-number pending tuning (feel)
const LAMP_SIZE_M := Vector2(0.34, 0.16)   # fallback when the lamp has no mesh
const LAMP_OFFSET_M := 0.02   # lint: allow-number pending tuning: in front of the lamp face
# ----

## Knuth's multiplicative hash for the flicker pattern (visual only, no gameplay RNG).
const _HASH_MUL := 2654435761
const _HASH_SHIFT := 13
const _HASH_MASK := 0xFF

var car: PlayerCar
var damaged: bool = false
var ghost: bool = false

var _smoke: CPUParticles3D
var _lamp: MeshInstance3D
var _lamp_mat: ShaderMaterial
var _ghost_left_s: float = 0.0
var _t: float = 0.0
var _visual_was_visible: bool = true
var _lamp_level: float = -1.0


func _enter_tree() -> void:
	_connect(Events.hit, _on_hit)
	_connect(Events.ghost_started, _on_ghost_started)
	_connect(Events.ghost_ended, stop_ghost)
	_connect(Events.run_started, _on_run_started)


func _exit_tree() -> void:
	_disconnect(Events.hit, _on_hit)
	_disconnect(Events.ghost_started, _on_ghost_started)
	_disconnect(Events.ghost_ended, stop_ghost)
	_disconnect(Events.run_started, _on_run_started)


## Attaches the effect nodes to `player_car`'s model (call again after the model
## changes, e.g. the dev CAR button). Keeps the damage state.
func bind(player_car: PlayerCar) -> void:
	stop_ghost()
	car = player_car
	_smoke = null
	_lamp = null
	if car == null or car.model == null or car.model.root == null:
		return
	var model := car.model
	var smoke_parent: Node3D = model.marker(MARKER_SMOKE)
	if smoke_parent == null:
		smoke_parent = model.root
	_smoke = _make_smoke()
	smoke_parent.add_child(_smoke)
	var lamp_node := model.root.get_node_or_null(LAMP_PATH) as Node3D
	_lamp = _make_lamp(lamp_node)
	if lamp_node != null:
		lamp_node.add_child(_lamp)
	else:
		model.root.add_child(_lamp)
		var box := model.body_aabb
		_lamp.position = Vector3(box.position.x + box.size.x * 0.25, box.get_center().y,
			box.position.z - LAMP_OFFSET_M)
	_apply_damage()


## New run: no damage, no ghost.
func reset() -> void:
	damaged = false
	stop_ghost()
	_apply_damage()


func set_damaged(on: bool) -> void:
	damaged = on
	_apply_damage()


## Ghost flicker for `duration_s` (ends early on stop_ghost()).
func start_ghost(duration_s: float) -> void:
	if car == null or car.visual == null:
		return
	if not ghost:
		_visual_was_visible = car.visual.visible
	ghost = true
	_ghost_left_s = duration_s
	_t = 0.0


func stop_ghost() -> void:
	if ghost and car != null and is_instance_valid(car) and car.visual != null:
		car.visual.visible = _visual_was_visible
	ghost = false
	_ghost_left_s = 0.0


func get_smoke() -> CPUParticles3D:
	return _smoke


func get_lamp() -> MeshInstance3D:
	return _lamp


func _process(delta: float) -> void:
	advance(delta)


## One visual step (tests call it directly).
func advance(delta: float) -> void:
	_t += delta
	if ghost:
		_ghost_left_s -= delta
		if _ghost_left_s <= 0.0:
			stop_ghost()
		elif car != null and car.visual != null:
			car.visual.visible = int(_t * GHOST_FLICKER_HZ * 2.0) % 2 == 0
	if damaged and _lamp_mat != null:
		var step := int(_t * LAMP_FLICKER_HZ)
		var lit := float(((step * _HASH_MUL) >> _HASH_SHIFT) & _HASH_MASK) < LAMP_LIT_SHARE * float(_HASH_MASK)
		var level := 1.0 if lit else 0.0
		if level != _lamp_level:
			_lamp_level = level
			_lamp_mat.set_shader_parameter(&"level", level)


func _apply_damage() -> void:
	if _smoke != null:
		_smoke.visible = damaged
		_smoke.emitting = damaged
	if _lamp != null:
		_lamp.visible = damaged


func _make_smoke() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.name = SMOKE_NODE
	var q := float(Quality.particle_scale) if is_inside_tree() else 1.0
	p.amount = maxi(roundi(float(SMOKE_PARTICLES) * q), 1)
	p.lifetime = SMOKE_LIFETIME_S
	p.local_coords = true
	p.emitting = false
	p.visible = false
	p.direction = SMOKE_DIRECTION.normalized()
	p.spread = SMOKE_SPREAD_DEG
	p.initial_velocity_min = SMOKE_VELOCITY_MPS.x
	p.initial_velocity_max = SMOKE_VELOCITY_MPS.y
	p.gravity = Vector3(0.0, SMOKE_RISE_MPS2, 0.0)
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, SMOKE_GROW.x / SMOKE_GROW.y))
	grow.add_point(Vector2(1.0, 1.0))
	p.scale_amount_min = SMOKE_GROW.y
	p.scale_amount_max = SMOKE_GROW.y
	p.scale_amount_curve = grow
	var fade := Gradient.new()
	fade.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	fade.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	p.color_ramp = fade
	var quad := QuadMesh.new()
	quad.size = Vector2(SMOKE_SIZE_M, SMOKE_SIZE_M)
	p.mesh = quad
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.render_priority = RENDER_PRIORITY
	mat.set_shader_parameter(&"mode", 0)
	p.material_override = mat
	return p


func _make_lamp(lamp_node: Node3D) -> MeshInstance3D:
	var size := LAMP_SIZE_M
	var offset := Vector3(0.0, 0.0, -LAMP_OFFSET_M)
	var lamp_mesh := lamp_node as MeshInstance3D
	if lamp_mesh != null and lamp_mesh.mesh != null:
		var box := lamp_mesh.get_aabb()
		size = Vector2(maxf(box.size.x, LAMP_SIZE_M.y), maxf(box.size.y, LAMP_SIZE_M.y))
		offset = box.get_center() + Vector3(0.0, 0.0, -box.size.z * 0.5 - LAMP_OFFSET_M)
	var mi := MeshInstance3D.new()
	mi.name = LAMP_NODE
	var quad := QuadMesh.new()
	quad.size = size
	mi.mesh = quad
	mi.position = offset
	mi.rotation.y = PI   # the quad faces +Z; the lamp faces forward (-Z)
	_lamp_mat = ShaderMaterial.new()
	_lamp_mat.shader = SHADER
	_lamp_mat.render_priority = RENDER_PRIORITY
	_lamp_mat.set_shader_parameter(&"mode", 1)
	_lamp_mat.set_shader_parameter(&"level", 0.0)
	_lamp_level = 0.0
	mi.material_override = _lamp_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	return mi


func _on_hit(_source: StringName, lives_left: int) -> void:
	if lives_left > 0:
		set_damaged(true)


func _on_ghost_started(duration_s: float) -> void:
	start_ghost(duration_s)


func _on_run_started(_mode: StringName, _seed: int) -> void:
	reset()


static func _connect(sig: Signal, fn: Callable) -> void:
	if not sig.is_connected(fn):
		sig.connect(fn)


static func _disconnect(sig: Signal, fn: Callable) -> void:
	if sig.is_connected(fn):
		sig.disconnect(fn)
