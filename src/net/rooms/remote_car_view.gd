class_name RemoteCarView
extends Node3D
## Draws the other players' cars: a fixed pool of player car models placed from road space
## once per frame, ghosted. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Players (Ghosting:
## "Players never collide with each other. A remote car turns translucent when within
## 15 m of you and fully ghostly when overlapping"), Client changes → Performance ("remote
## players reuse player car materials with a shared translucent variant for ghosting");
## Architecture rule 7 (world transforms are derived for rendering only). docs/ROOMS_CLIENT.md.
## WP N5.2.
##
## Visual only: nothing here touches physics, hits or scoring (ghosted: remote cars are
## never in HitDetection or the traffic sim). The pool is built once at setup (the car's
## CarModel, merged draws, no CarVisual: no body motion, wheels at rest) and every car is
## hidden until placed; place() only writes a transform and, when the opacity step changes,
## the instances' `transparency` (the engine's per-instance fade over the car's own
## vehicle materials: the translucent variant costs no second material). The paint is the
## crew color (a material copy per car, made when the color changes). Physics
## interpolation is off: the cars move at frame rate.

var road: RoadPath
var origin: FloatingOrigin
var count: int = 0
## Opacity steps the ghost fade snaps to (a change rewrites every instance of the car).
var opacity_steps: float = 20.0
## place() calls that changed a car's transparency (tests: idle cars write nothing).
var fade_writes: int = 0

var _roots: Array[Node3D] = []
var _models: Array[CarModel] = []
var _geo: Array[GeometryInstance3D] = []
## _geo range of car i: _geo_from[i] ..< _geo_from[i + 1].
var _geo_from := PackedInt32Array()
var _opacity := PackedFloat32Array()
var _paint: Array[Color] = []
var _sample := RoadSample.new()


func _init() -> void:
	name = "RemoteCars"
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


## Builds `n` cars of `car_def` (load time; allocates). Call again for a new road.
func setup(road_path: RoadPath, floating_origin: FloatingOrigin, car_def: CarDef, n: int) -> void:
	road = road_path
	origin = floating_origin
	if count == n and not _models.is_empty():
		for i in count:
			hide_car(i)
		return
	for r in _roots:
		r.queue_free()
	_roots.clear()
	_models.clear()
	_geo.clear()
	_paint.clear()
	count = n
	_geo_from.resize(n + 1)
	_opacity.resize(n)
	for i in n:
		var holder := Node3D.new()
		holder.name = "Remote%d" % i
		holder.visible = false
		add_child(holder)
		var m := CarModel.load_model(car_def.model_scene_path, car_def)
		m.merge_draw_surfaces()
		holder.add_child(m.root)
		if m.interior != null:
			m.interior.visible = false
		if m.brakes_mesh != null:
			m.brakes_mesh.visible = false
		_roots.append(holder)
		_models.append(m)
		_paint.append(Color(0.0, 0.0, 0.0, 0.0))
		_geo_from[i] = _geo.size()
		_collect(m.root)
		_opacity[i] = 1.0
	_geo_from[n] = _geo.size()


func _collect(n: Node) -> void:
	var g := n as GeometryInstance3D
	if g != null:
		g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_geo.append(g)
	for c in n.get_children():
		_collect(c)


## Places car i at road coordinates (s unwrapped near the player's, d + right, heading
## relative to the road) with `opacity` (0 hides it) and its brake lights. Allocation-free
## except a paint change.
func place(i: int, s: float, d: float, heading: float, opacity: float, paint: Color, braking: bool = false) -> void:
	if i < 0 or i >= count or road == null:
		return
	var holder := _roots[i]
	if opacity <= 0.0:
		holder.visible = false
		return
	if paint != _paint[i]:
		_paint[i] = paint
		_models[i].apply_paint(paint)
	road.sample_into(s, _sample)
	var ox := origin.origin_x if origin != null else 0.0
	var oy := origin.origin_y if origin != null else 0.0
	var oz := origin.origin_z if origin != null else 0.0
	var b := Basis(Vector3.UP, _sample.godot_yaw(heading)) * Basis(Vector3.RIGHT, VehiclePhysics.surface_pitch(_sample))
	holder.transform = Transform3D(b, _sample.local_point(d, ox, oy, oz))
	holder.visible = true
	var br := _models[i].brakes_mesh
	if br != null and br.visible != braking:
		br.visible = braking
	var q := roundf(clampf(opacity, 0.0, 1.0) * opacity_steps) / opacity_steps
	if q != _opacity[i]:
		_opacity[i] = q
		fade_writes += 1
		for k in range(_geo_from[i], _geo_from[i + 1]):
			_geo[k].transparency = 1.0 - q


func hide_car(i: int) -> void:
	if i >= 0 and i < count:
		_roots[i].visible = false


func hide_all() -> void:
	for i in count:
		_roots[i].visible = false


func is_shown(i: int) -> bool:
	return i >= 0 and i < count and _roots[i].visible


## Car i's opacity as last applied (1 = solid).
func opacity_of(i: int) -> float:
	return _opacity[i] if i >= 0 and i < count else 0.0


## Where car i's nametag hangs (world space), `lift_m` above its origin.
func tag_position(i: int, lift_m: float) -> Vector3:
	return _roots[i].global_position + Vector3.UP * lift_m


## Draw calls one car issues (visible meshes' surfaces; tests and docs).
func draws_per_car() -> int:
	return _models[0].draw_surface_count() if not _models.is_empty() else 0
