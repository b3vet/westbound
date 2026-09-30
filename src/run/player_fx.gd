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
## with wb_output). Both stay hidden (0 draw calls) until the first hit. Every number
## is in FeelTuning's "Damage look" group (data/tuning/feel.tres).
##
## Reduced motion (WP9.3, Settings `reduced_motion`, live): both flickers slow to their
## *_reduced_motion_hz rates, under 3 flashes a second (docs/ACCESSIBILITY.md).
##
## WP7.4 (juice): it also carries the run's JuiceFx (speed lines, tire smoke, barrier
## sparks: src/fx/juice_fx.gd) and CarFxEvents (publishes hard_braking_changed and
## barrier_scrape: src/fx/car_fx_events.gd) as children, created once and bound to the
## same car, so the run needs no extra wiring.

const SHADER := preload("res://src/run/damage_fx.gdshader")
const SMOKE_NODE := &"HoodSmoke"
const LAMP_NODE := &"DeadLamp"
const LAMP_PATH := ^"Lights/headlight_L"
const MARKER_SMOKE := &"smoke_hood"
## Transparent pass order: above the sky layers (-100..-97, docs/CONTRACTS.md §13).
const RENDER_PRIORITY := 2

## Knuth's multiplicative hash for the flicker pattern (visual only, no gameplay RNG).
const _HASH_MUL := 2654435761
const _HASH_SHIFT := 13
const _HASH_MASK := 0xFF

var car: PlayerCar
## The look's numbers (FeelTuning "Damage look"); the default tuning's when unset.
var feel: FeelTuning
var damaged: bool = false
var ghost: bool = false

## The camera mode (from Settings, then Events.camera_mode_changed): the hood smoke
## hides in FeelTuning.smoke_hidden_camera_modes (hood, cockpit).
var camera_mode: StringName = &""
var _smoke: CPUParticles3D
var _lamp: MeshInstance3D
var _lamp_mat: ShaderMaterial
var _ghost_left_s: float = 0.0
var _t: float = 0.0
var _visual_was_visible: bool = true
var _lamp_level: float = -1.0
var _reduced_motion: bool = false
## WP7.4: the juice layer and the feel-event adapter (children, created on entering the tree).
var juice: JuiceFx
var fx_events: CarFxEvents


func _enter_tree() -> void:
	camera_mode = StringName(str(Settings.get_value(&"camera_mode")))
	_reduced_motion = bool(Settings.get_value(&"reduced_motion"))
	_connect(Events.settings_changed, _on_settings_changed)
	_connect(Events.hit, _on_hit)
	_connect(Events.ghost_started, _on_ghost_started)
	_connect(Events.ghost_ended, stop_ghost)
	_connect(Events.run_started, _on_run_started)
	_connect(Events.camera_mode_changed, _on_camera_mode_changed)
	_add_juice()


func _exit_tree() -> void:
	_disconnect(Events.hit, _on_hit)
	_disconnect(Events.ghost_started, _on_ghost_started)
	_disconnect(Events.ghost_ended, stop_ghost)
	_disconnect(Events.run_started, _on_run_started)
	_disconnect(Events.camera_mode_changed, _on_camera_mode_changed)
	_disconnect(Events.settings_changed, _on_settings_changed)


## Attaches the effect nodes to `player_car`'s model (call again after the model
## changes, e.g. the dev CAR button). Keeps the damage state.
func bind(player_car: PlayerCar) -> void:
	stop_ghost()
	car = player_car
	_smoke = null
	_lamp = null
	if juice != null:
		juice.bind(player_car)
		fx_events.bind(player_car)
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
			box.position.z - _feel().lamp_offset_m)
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
		car.visual.visible = _visual_was_visible and car.body_visible
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
			car.visual.visible = car.body_visible and int(_t * ghost_hz() * 2.0) % 2 == 0
	if damaged and _lamp_mat != null:
		var f := _feel()
		var step := int(_t * (f.lamp_flicker_reduced_motion_hz if _reduced_motion else f.lamp_flicker_hz))
		var lit := float(((step * _HASH_MUL) >> _HASH_SHIFT) & _HASH_MASK) < f.lamp_lit_share * float(_HASH_MASK)
		var level := 1.0 if lit else 0.0
		if level != _lamp_level:
			_lamp_level = level
			_lamp_mat.set_shader_parameter(&"level", level)


## The ghost flicker's rate now (hidden/shown cycles per second).
func ghost_hz() -> float:
	return _feel().ghost_flicker_reduced_motion_hz if _reduced_motion else _feel().ghost_flicker_hz


func _on_settings_changed(key: StringName) -> void:
	if key == &"reduced_motion":
		_reduced_motion = bool(Settings.get_value(&"reduced_motion"))


func _apply_damage() -> void:
	if _smoke != null:
		var smoke_on := damaged and not _feel().smoke_hidden_camera_modes.has(camera_mode)
		_smoke.visible = smoke_on
		_smoke.emitting = smoke_on
	if _lamp != null:
		_lamp.visible = damaged


func _make_smoke() -> CPUParticles3D:
	var f := _feel()
	var p := CPUParticles3D.new()
	p.name = SMOKE_NODE
	var q := float(Quality.particle_scale) if is_inside_tree() else 1.0
	p.amount = maxi(roundi(float(f.smoke_particles) * q), 1)
	p.lifetime = f.smoke_lifetime_s
	p.local_coords = true
	p.emitting = false
	p.visible = false
	p.direction = f.smoke_direction.normalized()
	p.spread = f.smoke_spread_deg
	p.initial_velocity_min = f.smoke_speed_min_mps
	p.initial_velocity_max = f.smoke_speed_max_mps
	p.gravity = Vector3(0.0, f.smoke_rise_mps2, 0.0)
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, f.smoke_scale_birth / f.smoke_scale_death))
	grow.add_point(Vector2(1.0, 1.0))
	p.scale_amount_min = f.smoke_scale_death
	p.scale_amount_max = f.smoke_scale_death
	p.scale_amount_curve = grow
	var fade := Gradient.new()
	fade.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	fade.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	p.color_ramp = fade
	var quad := QuadMesh.new()
	quad.size = Vector2(f.smoke_size_m, f.smoke_size_m)
	p.mesh = quad
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.render_priority = RENDER_PRIORITY
	mat.set_shader_parameter(&"mode", 0)
	p.material_override = mat
	return p


func _make_lamp(lamp_node: Node3D) -> MeshInstance3D:
	var f := _feel()
	var size := f.lamp_fallback_size_m
	var offset := Vector3(0.0, 0.0, -f.lamp_offset_m)
	var lamp_mesh := lamp_node as MeshInstance3D
	if lamp_mesh != null and lamp_mesh.mesh != null:
		var box := lamp_mesh.get_aabb()
		size = Vector2(maxf(box.size.x, f.lamp_fallback_size_m.y), maxf(box.size.y, f.lamp_fallback_size_m.y))
		offset = box.get_center() + Vector3(0.0, 0.0, -box.size.z * 0.5 - f.lamp_offset_m)
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


func _on_camera_mode_changed(mode: StringName) -> void:
	camera_mode = mode
	_apply_damage()


func _on_run_started(_mode: StringName, _seed: int) -> void:
	reset()


## WP7.4: JuiceFx and CarFxEvents, once, sharing this node's FeelTuning.
func _add_juice() -> void:
	if juice != null:
		return
	juice = JuiceFx.new()
	juice.feel = _feel()
	add_child(juice)
	fx_events = CarFxEvents.new()
	fx_events.feel = _feel()
	add_child(fx_events)
	if car != null:
		juice.bind(car)
		fx_events.bind(car)


func _feel() -> FeelTuning:
	if feel == null:
		feel = Tuning.load_default().feel
	return feel


static func _connect(sig: Signal, fn: Callable) -> void:
	if not sig.is_connected(fn):
		sig.connect(fn)


static func _disconnect(sig: Signal, fn: Callable) -> void:
	if sig.is_connected(fn):
		sig.disconnect(fn)
