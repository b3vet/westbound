extends Node3D
## Look review scene (WP1.3). Spec: World → Color script, Sky, Night lighting;
## Cameras → Glare rule. Sky + horizon + a static divided-highway strip with the
## road material, farmland ground and a few world-material props and traffic
## boxes, to judge fog, lighting and the palette across the whole color script.
##
##   tools/snap.sh src/sun/dev/look_preview.tscn --renderer=both \
##       --sweep=sky_t:0,0.2,0.38,0.5,0.58,0.66,0.85 --cam=chase
##
## snap_setup options: --sky_t=<0..1>, --cam=chase|far|hood|overhead|sky|side|back,
## --heading_deg=<road heading, default 20: the sun sits 20 deg left of the axis>,
## --ui=true (show the sky_t slider), --night_lights=<player fake-light gain>,
## --hide=Clouds,Horizon,GenProps,GenGround,GenRoad (debugging).
## Everything here is preview geometry (not the WP1.2 road or WP1.4 props).

const WORLD_MAT := preload("res://assets/shaders/materials/world.tres")
const ROAD_MAT := preload("res://assets/shaders/materials/road.tres")

## Road heading in degrees (world heading: 0 faces -Z / due west).
@export var heading_deg: float = 20.0
@export var road_ahead_m: float = 1100.0
@export var road_behind_m: float = 120.0
@export var road_step_m: float = 20.0
@export var ground_radius_m: float = 1100.0
@export var field_size_m: float = 90.0

# Cross-section (docs/CONTRACTS.md §2, default road tuning).
const MEDIAN_HALF := 0.5
const LANES_LEFT := 1.7
const LANE_W := 3.6
const LANES := 3
const LANES_RIGHT := LANES_LEFT + LANE_W * LANES
const SHOULDER_OUT := LANES_RIGHT + 3.0
const GUARDRAIL := SHOULDER_OUT + 0.5
const LINE_W := 0.15
const DASH_M := 3.0
const DASH_GAP_M := 9.0

const C_WHITE := Color(1, 1, 1)
const C_BARRIER := Color("#b9b7ae")
const C_RAIL := Color("#9aa1a8")
const C_POLE := Color("#6f757c")
const C_LAMP := Color("#ffd9a0")
const C_REFLECTOR := Color("#ffb347")
const C_FIELDS: Array[Color] = [Color("#c9a75a"), Color("#8f9a4c"), Color("#b58f55"), Color("#a3a35e"), Color("#7c8a45")]
const C_SHOULDER_DIRT := Color("#8a7a62")

@onready var _camera: Camera3D = $Camera3D
@onready var _sky: SkyRig = $Sky
@onready var _slider: CanvasLayer = $SkyTSlider

var _fwd: Vector3
var _right: Vector3


func _ready() -> void:
	_build()
	_place_camera(&"chase")


func snap_setup(args: Dictionary) -> void:
	if args.has("heading_deg"):
		heading_deg = float(args["heading_deg"])
		for c in get_children():
			if c.name.begins_with("Gen"):
				c.free()
		_build()
	_sky.sky_t = float(args.get("sky_t", _sky.sky_t))
	_slider.visible = bool(args.get("ui", false))
	var gain := float(args.get("night_lights", 1.0))
	_place_camera(StringName(str(args.get("cam", "chase"))))
	_sky.set_player_light(_camera.global_position - Vector3.UP, _fwd, gain)
	# --hide=Clouds,Horizon,GenProps,...: hide sky parts or preview meshes (debugging).
	for n: String in str(args.get("hide", "")).split(",", false):
		var node := get_node_or_null(NodePath(n))
		if node == null:
			node = _sky.get_node_or_null(NodePath(n))
		if node is Node3D:
			(node as Node3D).visible = false
	_sky.push_now()


# ---------------------------------------------------------------- Camera

func _place_camera(mode: StringName) -> void:
	var lane1 := LANES_LEFT + LANE_W * 1.5
	var eye: Vector3
	var target: Vector3
	match mode:
		&"far":
			eye = _pt(-13.0, lane1, 5.0)
			target = _pt(30.0, lane1, 1.0)
		&"hood":
			eye = _pt(0.8, lane1, 1.25)
			target = _pt(60.0, lane1, 1.0)
		&"overhead":
			eye = _pt(-7.0, lane1, 16.0)
			target = _pt(28.0, lane1, 0.0)
		&"sky":
			eye = _pt(0.0, lane1, 2.0)
			target = _pt(40.0, lane1, 22.0)
		&"side":
			eye = _pt(0.0, lane1, 2.5)
			target = _pt(0.0, lane1 + 60.0, 2.0)
		&"back":
			eye = _pt(8.0, lane1, 2.6)
			target = _pt(-30.0, lane1, 1.0)
		_:
			eye = _pt(-7.0, lane1, 2.7)
			target = _pt(22.0, lane1, 1.0)
	_camera.look_at_from_position(eye, target, Vector3.UP)
	_camera.fov = 62.0
	if has_node(^"/root/Quality"):
		Quality.apply_far_plane(_camera)


func _pt(s: float, d: float, y: float = 0.0) -> Vector3:
	return _fwd * s + _right * d + Vector3.UP * y


# ---------------------------------------------------------------- Geometry

func _build() -> void:
	var h := deg_to_rad(heading_deg)
	_fwd = SkyRig.heading_dir(h)
	_right = SkyRig.heading_dir(h + PI * 0.5)
	var road := MeshKit.new()
	var props := MeshKit.new()
	var ground := MeshKit.new()
	_build_road(road, props)
	_build_ground(ground)
	_build_props(props)
	_add_mesh("GenRoad", road.commit(), ROAD_MAT)
	_add_mesh("GenProps", props.commit(), WORLD_MAT)
	_add_mesh("GenGround", ground.commit(), WORLD_MAT)


func _add_mesh(node_name: String, mesh: ArrayMesh, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _build_road(road: MeshKit, props: MeshKit) -> void:
	var s := -road_behind_m
	while s < road_ahead_m:
		var s1 := s + road_step_m
		# Asphalt: both carriageways, median strip included (tint class 1).
		for side: float in [-1.0, 1.0]:
			road.quad_flat(_pt(s, side * MEDIAN_HALF), _pt(s1, side * MEDIAN_HALF),
					_pt(s1, side * SHOULDER_OUT), _pt(s, side * SHOULDER_OUT), C_WHITE, 0.0, 1.0)
			# Solid edge lines (tint class 2), slightly raised.
			for d: float in [LANES_LEFT, LANES_RIGHT]:
				_line(road, s, s1, side * d)
		# Dirt verge beyond the shoulders.
		for side: float in [-1.0, 1.0]:
			road.quad_flat(_pt(s, side * SHOULDER_OUT, -0.02), _pt(s1, side * SHOULDER_OUT, -0.02),
					_pt(s1, side * (GUARDRAIL + 3.0), -0.04), _pt(s, side * (GUARDRAIL + 3.0), -0.04),
					C_SHOULDER_DIRT, 0.0, 0.0)
		s = s1
	# Dashed lane lines.
	var ds := -road_behind_m
	while ds < road_ahead_m:
		for side: float in [-1.0, 1.0]:
			for lane: int in range(1, LANES):
				_line(road, ds, ds + DASH_M, side * (LANES_LEFT + LANE_W * lane))
		ds += DASH_M + DASH_GAP_M
	# Median barrier, guardrails, reflectors, light poles (world material).
	var up := Vector3.UP
	var bs := -road_behind_m
	while bs < road_ahead_m:
		var mid := bs + road_step_m * 0.5
		props.box(_basis_at(_pt(mid, 0.0, 0.45)), Vector3(0.6, 0.9, road_step_m), C_BARRIER)
		for side: float in [-1.0, 1.0]:
			props.box(_basis_at(_pt(mid, side * GUARDRAIL, 0.65)), Vector3(0.12, 0.3, road_step_m), C_RAIL)
		bs += road_step_m
	var rs := -road_behind_m
	while rs < road_ahead_m:
		for side: float in [-1.0, 1.0]:
			props.box(_basis_at(_pt(rs, side * 0.32, 0.7)), Vector3(0.05, 0.12, 0.12), C_REFLECTOR, 1.0)
			props.box(_basis_at(_pt(rs, side * (GUARDRAIL - 0.08), 0.75)), Vector3(0.05, 0.12, 0.12), C_REFLECTOR, 1.0)
			props.box(_basis_at(_pt(rs, side * GUARDRAIL, 0.4)), Vector3(0.15, 0.8, 0.15), C_RAIL)
		rs += 25.0
	var ps := 0.0
	while ps < road_ahead_m:
		var base := _pt(ps, SHOULDER_OUT + 1.0)
		props.box(_basis_at(base + up * 5.0), Vector3(0.25, 10.0, 0.25), C_POLE)
		props.box(_basis_at(base + up * 10.0 - _right * 1.2), Vector3(2.6, 0.18, 0.3), C_POLE)
		props.box(_basis_at(base + up * 9.85 - _right * 2.3), Vector3(0.8, 0.12, 0.45), C_LAMP, 2.0)
		ps += 50.0


func _line(road: MeshKit, s0: float, s1: float, d: float) -> void:
	var y := 0.01
	road.quad_flat(_pt(s0, d - LINE_W, y), _pt(s1, d - LINE_W, y), _pt(s1, d + LINE_W, y),
			_pt(s0, d + LINE_W, y), C_WHITE, 0.0, 2.0)


func _build_ground(ground: MeshKit) -> void:
	var n := int(ceil(ground_radius_m / field_size_m))
	var y := -0.05
	for i in range(-n, n):
		for j in range(-n, n):
			var x0 := i * field_size_m
			var z0 := j * field_size_m
			var c := C_FIELDS[absi(i * 7 + j * 13) % C_FIELDS.size()]
			ground.quad_flat(Vector3(x0, y, z0), Vector3(x0 + field_size_m, y, z0),
					Vector3(x0 + field_size_m, y, z0 + field_size_m), Vector3(x0, y, z0 + field_size_m),
					c, 0.0, 0.0)


func _build_props(props: MeshKit) -> void:
	# Farm buildings, silos, trees and a billboard on the right; more across the median.
	props.box(_basis_at(_pt(140.0, 40.0, 4.0)), Vector3(14.0, 8.0, 22.0), Color("#a8453a"))
	props.roof(_basis_at(_pt(140.0, 40.0, 8.0)), Vector3(14.0, 4.0, 22.0), Color("#5d5550"))
	props.prism(_pt(165.0, 34.0), 8, 3.2, 16.0, Color("#c8c8c0"))
	props.prism(_pt(172.0, 34.0), 8, 3.2, 13.0, Color("#b8b8b0"))
	props.prism(_pt(420.0, -60.0), 8, 4.0, 22.0, Color("#c0beb4"))
	for k in 14:
		var s := 60.0 + k * 37.0
		var d := 24.0 + float((k * 5) % 7) * 3.0
		props.tree(_pt(s, d), 2.5 + float(k % 3), 7.0 + float(k % 4) * 1.5, Color("#4d6b3a"))
		props.tree(_pt(s + 18.0, -d - 6.0), 2.0 + float(k % 2), 6.0 + float(k % 3) * 2.0, Color("#56733f"))
	# Billboard.
	props.box(_basis_at(_pt(90.0, 22.0, 4.0)), Vector3(0.4, 8.0, 0.4), C_POLE)
	props.box(_basis_at(_pt(90.0, 22.0, 9.0)), Vector3(12.0, 4.5, 0.4), Color("#2fb6c8"))
	props.box(_basis_at(_pt(90.0, 22.0, 9.0) - _fwd * 0.25), Vector3(10.0, 2.0, 0.1), Color("#ffe9b0"), 2.0)
	# Traffic: the player car, cars ahead, a truck, oncoming cars (emissive class 3).
	_car(props, 0.0, LANES_LEFT + LANE_W * 1.5, Color("#e8463a"), 1.0)
	_car(props, 30.0, LANES_LEFT + LANE_W * 0.5, Color("#2d6fd6"), 1.0)
	_car(props, 55.0, LANES_LEFT + LANE_W * 2.5, Color("#e8e4d8"), 1.0)
	_truck(props, 85.0, LANES_LEFT + LANE_W * 1.5)
	_car(props, 140.0, LANES_LEFT + LANE_W * 0.5, Color("#f2c230"), 1.0)
	_car(props, 40.0, -(LANES_LEFT + LANE_W * 0.5), Color("#4a4f5c"), -1.0)
	_car(props, 110.0, -(LANES_LEFT + LANE_W * 1.5), Color("#9b2d3a"), -1.0)


func _car(props: MeshKit, s: float, d: float, col: Color, dir: float) -> void:
	var f := _fwd * dir
	var b := _basis_at(_pt(s, d, 0.55), dir)
	props.box(b, Vector3(1.85, 0.7, 4.4), col)
	props.box(_basis_at(_pt(s, d, 1.2) - f * 0.3, dir), Vector3(1.6, 0.55, 2.2), Color("#1d2230"))
	# Tail lights (red) at the back, headlights (warm white) at the front.
	for side: float in [-0.65, 0.65]:
		var lateral := _right * side * dir
		props.box(_basis_at(_pt(s, d, 0.7) - f * 2.22 + lateral, dir), Vector3(0.4, 0.14, 0.05), Color("#ff2a2a"), 3.0)
		props.box(_basis_at(_pt(s, d, 0.62) + f * 2.22 + lateral, dir), Vector3(0.36, 0.14, 0.05), Color("#fff1c8"), 3.0)


func _truck(props: MeshKit, s: float, d: float) -> void:
	props.box(_basis_at(_pt(s, d, 2.3)), Vector3(2.5, 3.6, 12.0), Color("#dcdad2"))
	props.box(_basis_at(_pt(s + 7.4, d, 1.7)), Vector3(2.45, 2.6, 2.6), Color("#2c5a8a"))
	for side: float in [-1.05, 1.05]:
		props.box(_basis_at(_pt(s - 6.02, d + side, 0.9)), Vector3(0.3, 0.2, 0.05), Color("#ff2a2a"), 3.0)


## Transform at `pos`, facing the road direction (or against it for dir < 0).
func _basis_at(pos: Vector3, dir: float = 1.0) -> Transform3D:
	var z := -_fwd * dir
	var x := Vector3.UP.cross(z).normalized()
	return Transform3D(Basis(x, Vector3.UP, z), pos)


## Flat-shaded mesh builder using the world vertex conventions (§13):
## COLOR = sRGB albedo, UV2 = (emissive class, tint class), per-face normals.
class MeshKit:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uv2 := PackedVector2Array()

	func tri(a: Vector3, b: Vector3, c: Vector3, col: Color, emissive: float = 0.0, tint: float = 0.0) -> void:
		var n := (c - a).cross(b - a).normalized()
		for v: Vector3 in [a, b, c]:
			verts.append(v)
			normals.append(n)
			colors.append(col)
			uv2.append(Vector2(emissive, tint))

	## Quad a-b-c-d, wound so the normal faces up (Godot front faces are clockwise).
	func quad_flat(a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color, emissive: float, tint: float) -> void:
		var n := (c - a).cross(b - a)
		if n.y < 0.0:
			tri(a, c, b, col, emissive, tint)
			tri(a, d, c, col, emissive, tint)
		else:
			tri(a, b, c, col, emissive, tint)
			tri(a, c, d, col, emissive, tint)

	func box(xf: Transform3D, size: Vector3, col: Color, emissive: float = 0.0) -> void:
		var h := size * 0.5
		var p: Array[Vector3] = []
		for i in 8:
			p.append(xf * Vector3(h.x * (1 if i & 1 else -1), h.y * (1 if i & 2 else -1), h.z * (1 if i & 4 else -1)))
		var faces := [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]
		for f: Array in faces:
			_face(p[f[0]], p[f[1]], p[f[2]], p[f[3]], xf.origin, col, emissive)

	## Gable roof along the box's local Z.
	func roof(xf: Transform3D, size: Vector3, col: Color) -> void:
		var h := size * 0.5
		var a := xf * Vector3(-h.x, 0, -h.z)
		var b := xf * Vector3(h.x, 0, -h.z)
		var c := xf * Vector3(h.x, 0, h.z)
		var d := xf * Vector3(-h.x, 0, h.z)
		var r0 := xf * Vector3(0, size.y, -h.z)
		var r1 := xf * Vector3(0, size.y, h.z)
		var center := xf * Vector3(0, size.y * 0.5, 0)
		_face(a, d, r1, r0, center, col, 0.0)
		_face(b, r0, r1, c, center, col, 0.0)
		_tri_out(a, r0, b, center, col)
		_tri_out(d, c, r1, center, col)

	## Upright n-sided prism (silo) with a flat top.
	func prism(base: Vector3, sides: int, radius: float, height: float, col: Color) -> void:
		var center := base + Vector3.UP * height * 0.5
		var top := base + Vector3.UP * height
		for i in sides:
			var a0 := TAU * float(i) / float(sides)
			var a1 := TAU * float(i + 1) / float(sides)
			var p0 := base + Vector3(cos(a0), 0, sin(a0)) * radius
			var p1 := base + Vector3(cos(a1), 0, sin(a1)) * radius
			_face(p0, p1, p1 + Vector3.UP * height, p0 + Vector3.UP * height, center, col, 0.0)
			_tri_out(top, p0 + Vector3.UP * height, p1 + Vector3.UP * height, center, col)

	## Low-poly tree: trunk + two stacked cones.
	func tree(base: Vector3, radius: float, height: float, col: Color) -> void:
		var trunk_h := height * 0.25
		box(Transform3D(Basis(), base + Vector3.UP * trunk_h * 0.5), Vector3(0.4, trunk_h, 0.4), Color("#5a4632"))
		_cone(base + Vector3.UP * trunk_h, radius, height * 0.5, col)
		_cone(base + Vector3.UP * (trunk_h + height * 0.3), radius * 0.7, height * 0.45, col.lightened(0.06))

	func _cone(base: Vector3, radius: float, height: float, col: Color) -> void:
		var apex := base + Vector3.UP * height
		var sides := 6
		var center := base + Vector3.UP * height * 0.3
		for i in sides:
			var a0 := TAU * float(i) / float(sides)
			var a1 := TAU * float(i + 1) / float(sides)
			var p0 := base + Vector3(cos(a0), 0, sin(a0)) * radius
			var p1 := base + Vector3(cos(a1), 0, sin(a1)) * radius
			_tri_out(p0, p1, apex, center, col)

	## Quad oriented so its normal points away from `inside`.
	func _face(a: Vector3, b: Vector3, c: Vector3, d: Vector3, inside: Vector3, col: Color, emissive: float) -> void:
		var n := (c - a).cross(b - a)
		if n.dot((a + c) * 0.5 - inside) < 0.0:
			tri(a, c, b, col, emissive)
			tri(a, d, c, col, emissive)
		else:
			tri(a, b, c, col, emissive)
			tri(a, c, d, col, emissive)

	func _tri_out(a: Vector3, b: Vector3, c: Vector3, inside: Vector3, col: Color) -> void:
		var n := (c - a).cross(b - a)
		if n.dot((a + b + c) / 3.0 - inside) < 0.0:
			tri(a, c, b, col)
		else:
			tri(a, b, c, col)

	func commit() -> ArrayMesh:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_TEX_UV2] = uv2
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		return mesh
