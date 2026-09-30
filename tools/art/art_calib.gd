class_name ArtCalib
extends RefCounted
## Calibration assets for the game-side art pipeline (docs/ART_PRODUCTION.md §5 P0, G9;
## WP-ART-G). Built in code as Godot scenes that follow the Blender agent's technical
## contract (§3: names, materials by name, frames, shared wheel meshes, markers), then
## written as .glb with GLTFDocument, so the import path (G1) and the converters (G2,
## G3) are proven end to end before the first real asset:
##   calib_car      a box car: every convention node, every light, an interior
##                  (Cabin, SteeringWheel, Gauges), all six markers, one Body face per
##                  palette colour as trim_<name>, the three paint shades, glass,
##                  every lamp material; shared tire and rim meshes (left wheels turned)
##   calib_car_lod1 its LOD1: one Body object with the same slots
##   calib_rim      a garage rim authored at radius 1.0 (G5)
##   calib_traffic  a sedan-sized traffic model with every part (G3), and its LOD1
##   calib_swatch   one quad per palette name and one per emissive suffix (G2)
## The materials are StandardMaterial3D only because glTF needs a material to carry a
## name: the game replaces every one by name. Tools/tests only; allocates.

## The calibration car's body (m): it has its own CarDef (tests/art/fixtures), never in
## the roster.
const CAR_LENGTH := 4.5
const CAR_WIDTH := 1.9
const CAR_HEIGHT := 1.3
const CAR_WHEELBASE := 2.7
const CAR_SILL_Y := 0.22
const CAR_BELT_Y := 0.78
const WHEEL_R := 0.34
const TIRE_W := 0.26
const TRACK_HALF := 0.78
const RIM_FRAC := 0.65
const RIM_SPOKES := 5
const WHEEL_SIDES := 16
## Swatch tiles on the flanks (m).
const TILE_H := 0.16
const TILE_Y := 0.4
const PROUD := 0.005
const LAMP_PROUD := 0.015
## Driver's eye (car frame): left seat.
const EYE := Vector3(-0.36, 1.12, 0.15)
const STEER_TILT_RAD := 0.35

## Traffic calibration (sedan type: data/vehicle_types/sedan.tres).
const TRAFFIC_TYPE := &"sedan"
const T_LENGTH := 4.8
const T_WIDTH := 1.85
const T_HEIGHT := 1.45
const T_WHEEL_R := 0.33
## Traffic calibration: hub positions (x magnitude, z magnitude) and lamp height.
const T_AXLE_Z := 1.45
## Prop swatch: quads per row, and the emissive suffixes shown on a `white` quad each.
const SWATCH_ROW := 10
const SWATCH_SUFFIXES: Array[String] = ["reflector", "lamp", "window"]
const SWATCH_SUFFIX_BASE := "white"

var palette: ArtPalette
var _mats := {}


func _init(p: ArtPalette = null) -> void:
	palette = p if p != null else ArtPalette.new()


# ---------------------------------------------------------------- Output

## Writes `root` as a binary glTF (.glb) at `path` (res:// or absolute). Returns OK or an error.
static func write_glb(root: Node, path: String) -> Error:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(root, state)
	if err != OK:
		return err
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	return doc.write_to_filesystem(state, path)


## Reads a .glb / .gltf into a scene (res:// or an absolute path, e.g. in the gdignored
## art/ folder). The caller frees it. null on failure.
static func read_glb(path: String) -> Node:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(ProjectSettings.globalize_path(path), state) != OK:
		return null
	return doc.generate_scene(state)


# ---------------------------------------------------------------- Materials and faces

## A named material (StandardMaterial3D; albedo = the name's colour for an honest
## preview, like the Blender Base Color).
func mat(material_name: String, preview: Color = Color.WHITE) -> Material:
	if _mats.has(material_name):
		return _mats[material_name]
	var m := StandardMaterial3D.new()
	m.resource_name = material_name
	m.albedo_color = preview
	_mats[material_name] = m
	return m


## Surfaces keyed by material name, committed into one ArrayMesh.
class Builder extends RefCounted:
	var calib: ArtCalib
	var tools := {}
	var order: Array[String] = []

	func _init(c: ArtCalib) -> void:
		calib = c

	func st(material_name: String) -> SurfaceTool:
		if not tools.has(material_name):
			var s := SurfaceTool.new()
			s.begin(Mesh.PRIMITIVE_TRIANGLES)
			tools[material_name] = s
			order.append(material_name)
		return tools[material_name]

	## Convex polygon facing `outward` (any vector on its front side), flat, UV from
	## `uvs` (or zero).
	func face(material_name: String, pts: PackedVector3Array, outward: Vector3,
			uvs: PackedVector2Array = PackedVector2Array()) -> void:
		var s := st(material_name)
		var n := (pts[2] - pts[0]).cross(pts[1] - pts[0])
		if n.length_squared() <= 0.0:
			return
		n = n.normalized()
		var flip := n.dot(outward) < 0.0
		if flip:
			n = -n
		for i in range(1, pts.size() - 1):
			var ids := PackedInt32Array([0, i, i + 1]) if not flip else PackedInt32Array([0, i + 1, i])
			for k in ids:
				s.set_normal(n)
				s.set_uv(uvs[k] if k < uvs.size() else Vector2.ZERO)
				s.add_vertex(pts[k])

	func quad(material_name: String, a: Vector3, b: Vector3, c: Vector3, d: Vector3, outward: Vector3) -> void:
		face(material_name, PackedVector3Array([a, b, c, d]), outward)

	func box(material_name: String, center: Vector3, size: Vector3, top_name: String = "") -> void:
		var h := size * 0.5
		var t := material_name if top_name.is_empty() else top_name
		var x0 := center.x - h.x
		var x1 := center.x + h.x
		var y0 := center.y - h.y
		var y1 := center.y + h.y
		var z0 := center.z - h.z
		var z1 := center.z + h.z
		quad(t, Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3.UP)
		quad(material_name, Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x1, y0, z1), Vector3.RIGHT)
		quad(material_name, Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x0, y1, z1), Vector3(x0, y0, z1), Vector3.LEFT)
		quad(material_name, Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3.BACK)
		quad(material_name, Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x0, y1, z0), Vector3.FORWARD)
		quad(material_name, Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1), Vector3.DOWN)

	## A cylinder around the X axis from x0 to x1 (flat sides), with both caps.
	func cylinder_x(material_name: String, cap_name: String, x0: float, x1: float, center: Vector2,
			radius: float, sides: int) -> void:
		for k in sides:
			var a0 := TAU * float(k) / float(sides)
			var a1 := TAU * float(k + 1) / float(sides)
			var p0 := Vector2(cos(a0), sin(a0)) * radius + center
			var p1 := Vector2(cos(a1), sin(a1)) * radius + center
			var mid := (p0 + p1) * 0.5 - center
			quad(material_name, Vector3(x0, p0.x, p0.y), Vector3(x1, p0.x, p0.y), Vector3(x1, p1.x, p1.y),
				Vector3(x0, p1.x, p1.y), Vector3(0.0, mid.x, mid.y))
			face(cap_name, PackedVector3Array([Vector3(x1, center.x, center.y), Vector3(x1, p0.x, p0.y),
				Vector3(x1, p1.x, p1.y)]), Vector3.RIGHT)
			face(cap_name, PackedVector3Array([Vector3(x0, center.x, center.y), Vector3(x0, p0.x, p0.y),
				Vector3(x0, p1.x, p1.y)]), Vector3.LEFT)

	## A disc in the plane x = `x`, facing `out_sign` X.
	func disc_x(material_name: String, x: float, center: Vector2, radius: float, sides: int, out_sign: float) -> void:
		for k in sides:
			var a0 := TAU * float(k) / float(sides)
			var a1 := TAU * float(k + 1) / float(sides)
			face(material_name, PackedVector3Array([Vector3(x, center.x, center.y),
				Vector3(x, center.x + cos(a0) * radius, center.y + sin(a0) * radius),
				Vector3(x, center.x + cos(a1) * radius, center.y + sin(a1) * radius)]), Vector3(out_sign, 0.0, 0.0))

	func commit() -> ArrayMesh:
		var mesh := ArrayMesh.new()
		for n in order:
			var s: SurfaceTool = tools[n]
			s.commit(mesh)
			var i := mesh.get_surface_count() - 1
			mesh.surface_set_material(i, calib.mat(n, calib.preview_color(n)))
		return mesh


## The colour a material name previews with (its palette colour when it has one).
func preview_color(material_name: String) -> Color:
	for prefix: String in ["trim_", "glass_", "interior_", "fixed_", "wheel_", "head_", "rear_", "brake_", "blinkL_", "blinkR_"]:
		if material_name.begins_with(prefix):
			var c := StringName(material_name.trim_prefix(prefix))
			if palette.has_name(c):
				return palette.color(c)
	var base := StringName(material_name.get_slice("__", 0))
	return palette.color(base) if palette.has_name(base) else Color.WHITE


static func _node(parent: Node, node_name: String, pos: Vector3 = Vector3.ZERO) -> Node3D:
	var n := Node3D.new()
	n.name = node_name
	n.position = pos
	parent.add_child(n)
	return n


static func _mesh_node(parent: Node, node_name: String, mesh: Mesh, xf: Transform3D = Transform3D.IDENTITY) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.transform = xf
	parent.add_child(mi)
	return mi


# ---------------------------------------------------------------- Car

## Every palette name, each once (the swatch strip).
func swatch_names() -> Array[StringName]:
	return palette.all_names()


## The calibration car as the Blender export would bring it (root Car_CalibCar).
func build_car() -> Node3D:
	var root := Node3D.new()
	root.name = "Car_CalibCar"
	var half_l := CAR_LENGTH * 0.5
	# Body: lower box in paint, paint_shade sills, paint_dark bumpers, a glass cabin with
	# a trim roof, and a strip of swatches along both flanks.
	var b := Builder.new(self)
	var lower_h := CAR_BELT_Y - CAR_SILL_Y
	b.box("paint", Vector3(0.0, CAR_SILL_Y + lower_h * 0.5, 0.0), Vector3(CAR_WIDTH, lower_h, CAR_LENGTH - 0.3))
	b.box("paint_dark", Vector3(0.0, CAR_SILL_Y + lower_h * 0.4, -half_l + 0.075), Vector3(CAR_WIDTH, lower_h * 0.8, 0.15))
	b.box("paint_dark", Vector3(0.0, CAR_SILL_Y + lower_h * 0.4, half_l - 0.075), Vector3(CAR_WIDTH, lower_h * 0.8, 0.15))
	b.box("paint_shade", Vector3(0.0, CAR_SILL_Y + 0.04, 0.0), Vector3(CAR_WIDTH + 0.01, 0.08, CAR_LENGTH - 1.9))
	var cabin_h := CAR_HEIGHT - CAR_BELT_Y - 0.06
	b.box("glass", Vector3(0.0, CAR_BELT_Y + cabin_h * 0.5, 0.1), Vector3(CAR_WIDTH * 0.84, cabin_h, 2.0))
	b.box("glass_roof_slate", Vector3(0.0, CAR_BELT_Y + cabin_h * 0.5, 1.2), Vector3(CAR_WIDTH * 0.8, cabin_h * 0.8, 0.2))
	b.box("trim_ink", Vector3(0.0, CAR_HEIGHT - 0.03, 0.1), Vector3(CAR_WIDTH * 0.82, 0.06, 1.9))
	var names := swatch_names()
	for i in names.size():
		var c := swatch_tile_center(i, names.size())
		var h := swatch_tile_half(names.size())
		b.quad("trim_" + String(names[i]), c + Vector3(0.0, -h.x, -h.y), c + Vector3(0.0, h.x, -h.y),
			c + Vector3(0.0, h.x, h.y), c + Vector3(0.0, -h.x, h.y), Vector3(signf(c.x), 0.0, 0.0))
	_mesh_node(root, "Body", b.commit())

	# Lights: lenses 1.5 cm proud of the front (-Z) and rear (+Z) faces.
	var lights := _node(root, "Lights")
	var front_z := -half_l - LAMP_PROUD
	var rear_z := half_l + LAMP_PROUD
	var lamp_y := CAR_SILL_Y + lower_h * 0.62
	for spec: Array in [
		["headlight_L", "lamp_head", -0.62, lamp_y, front_z, Vector2(0.34, 0.12)],
		["headlight_R", "lamp_head", 0.62, lamp_y, front_z, Vector2(0.34, 0.12)],
		["taillight_L", "lamp_tail", -0.66, lamp_y, rear_z, Vector2(0.34, 0.12)],
		["taillight_R", "lamp_tail", 0.66, lamp_y, rear_z, Vector2(0.34, 0.12)],
		["brake_L", "signal_brake", -0.3, lamp_y, rear_z, Vector2(0.16, 0.09)],
		["brake_R", "signal_brake", 0.3, lamp_y, rear_z, Vector2(0.16, 0.09)],
		["blinker_FL", "signal_blinker", -0.86, lamp_y, front_z, Vector2(0.14, 0.09)],
		["blinker_FR", "signal_blinker", 0.86, lamp_y, front_z, Vector2(0.14, 0.09)],
		["blinker_RL", "signal_blinker", -0.88, lamp_y - 0.12, rear_z, Vector2(0.14, 0.09)],
		["blinker_RR", "signal_blinker", 0.88, lamp_y - 0.12, rear_z, Vector2(0.14, 0.09)],
		["reverse", "signal_reverse", 0.0, lamp_y - 0.12, rear_z, Vector2(0.2, 0.08)],
	]:
		var lb := Builder.new(self)
		var sz: Vector2 = spec[5]
		var z: float = spec[4]
		var out := Vector3.FORWARD if z < 0.0 else Vector3.BACK
		lb.quad(String(spec[1]), Vector3(-sz.x * 0.5, -sz.y * 0.5, 0.0), Vector3(sz.x * 0.5, -sz.y * 0.5, 0.0),
			Vector3(sz.x * 0.5, sz.y * 0.5, 0.0), Vector3(-sz.x * 0.5, sz.y * 0.5, 0.0), out)
		_mesh_node(lights, String(spec[0]), lb.commit(), Transform3D(Basis.IDENTITY, Vector3(spec[2], spec[3], z)))

	# Wheels: one tire mesh and one rim mesh for all four (linked duplicates); the rim
	# faces +X; left wheels turn both 180 degrees about the up axis.
	var tb := Builder.new(self)
	# A vertex at the bottom touches the ground; max(size.y, size.z) / 2 = WHEEL_R.
	tb.cylinder_x("trim_ink", "trim_asphalt", -TIRE_W * 0.5, TIRE_W * 0.5, Vector2.ZERO, WHEEL_R, WHEEL_SIDES)
	var tire := tb.commit()
	var rim := build_rim_mesh(WHEEL_R * RIM_FRAC, TIRE_W * 0.5 + 0.01)
	var wheel_base_half := CAR_WHEELBASE * 0.5
	for spec: Array in [["FL", -1.0, -1.0], ["FR", 1.0, -1.0], ["RL", -1.0, 1.0], ["RR", 1.0, 1.0]]:
		var w := _node(root, "Wheel_" + String(spec[0]),
			Vector3(float(spec[1]) * TRACK_HALF, WHEEL_R, float(spec[2]) * wheel_base_half))
		var turn := Basis(Vector3.UP, PI) if float(spec[1]) < 0.0 else Basis.IDENTITY
		_mesh_node(w, "Tire_" + String(spec[0]), tire, Transform3D(turn, Vector3.ZERO))
		_mesh_node(w, "Rim_" + String(spec[0]), rim, Transform3D(turn, Vector3.ZERO))

	_build_interior(root)

	var markers := _node(root, "Markers")
	_node(markers, "cam_cockpit", EYE)
	_node(markers, "cam_hood", Vector3(0.0, CAR_BELT_Y + 0.12, -half_l + CAR_LENGTH * 0.22))
	_node(markers, "smoke_hood", Vector3(0.0, CAR_BELT_Y, -half_l + CAR_LENGTH * 0.22))
	_node(markers, "exhaust_L", Vector3(-0.5, CAR_SILL_Y + 0.08, half_l))
	_node(markers, "exhaust_R", Vector3(0.5, CAR_SILL_Y + 0.08, half_l))
	_node(markers, "shadow", Vector3.ZERO)
	return root


## The centre of swatch tile `i` of `count` on the Body's flanks (left side first; each
## tile faces outward, PROUD off the side).
static func swatch_tile_center(i: int, count: int) -> Vector3:
	var per_side := ceili(float(count) / 2.0)
	var span := CAR_LENGTH - 0.6
	var tile_w := span / float(per_side)
	var side := -1.0 if i < per_side else 1.0
	var z0 := -span * 0.5 + tile_w * float(i % per_side)
	return Vector3(side * (CAR_WIDTH * 0.5 + PROUD), TILE_Y + TILE_H * 0.5, z0 + tile_w * 0.45)


## Half height (x) and half length (y) of a swatch tile.
static func swatch_tile_half(count: int) -> Vector2:
	var per_side := ceili(float(count) / 2.0)
	return Vector2(TILE_H * 0.5, (CAR_LENGTH - 0.6) / float(per_side) * 0.45)


## The centre of the prop swatch's quad `i` (1 m tiles, rows of SWATCH_ROW, facing +Z).
static func swatch_quad_center(i: int) -> Vector3:
	return Vector3(float(i % SWATCH_ROW) * 1.1 + 0.5, floorf(float(i) / float(SWATCH_ROW)) * 1.1 + 0.5, 0.0)


## The prop swatch's material names in quad order.
func swatch_prop_names(prefer_set: StringName = &"") -> Array[String]:
	var names: Array[String] = []
	for n in palette.all_names(prefer_set):
		names.append(String(n))
	for suffix in SWATCH_SUFFIXES:
		names.append(SWATCH_SUFFIX_BASE + "__" + suffix)
	return names


## Rim geometry: a face disc at x = `x` facing +X with spokes (trim materials only).
func build_rim_mesh(radius: float, x: float) -> ArrayMesh:
	var b := Builder.new(self)
	b.disc_x("trim_steel", x, Vector2.ZERO, radius, WHEEL_SIDES, 1.0)
	var sx := x + 0.008
	for k in RIM_SPOKES:
		var a := TAU * float(k) / float(RIM_SPOKES)
		var dir := Vector2(cos(a), sin(a))
		var side := Vector2(-sin(a), cos(a)) * radius * 0.12
		var tip := dir * radius * 0.9
		b.quad("trim_steel_dark", Vector3(sx, side.x, side.y), Vector3(sx, -side.x, -side.y),
			Vector3(sx, tip.x - side.x, tip.y - side.y), Vector3(sx, tip.x + side.x, tip.y + side.y), Vector3.RIGHT)
	b.disc_x("trim_ink", sx + 0.004, Vector2.ZERO, radius * 0.18, 8, 1.0)
	return b.commit()


## A garage rim file (G5, §4.1.4): authored at radius 1.0, face toward +X on x = 0.
func build_rim() -> Node3D:
	var root := Node3D.new()
	root.name = "Rim_Calib"
	_mesh_node(root, "Rim", build_rim_mesh(1.0, 0.0))
	return root


func _build_interior(root: Node3D) -> void:
	var interior := _node(root, "Interior")
	var ib := Builder.new(self)
	var half := CAR_WIDTH * 0.4
	var dash_z := EYE.z - 0.66
	var dash_y := EYE.y - 0.26
	# Dash top (faces up, toward the eye) and its face toward the driver.
	ib.quad("interior_asphalt", Vector3(-half, dash_y, dash_z - 0.35), Vector3(half, dash_y, dash_z - 0.35),
		Vector3(half, dash_y, dash_z), Vector3(-half, dash_y, dash_z), Vector3.UP)
	ib.quad("interior_steel_dark", Vector3(-half, dash_y - 0.3, dash_z), Vector3(half, dash_y - 0.3, dash_z),
		Vector3(half, dash_y, dash_z), Vector3(-half, dash_y, dash_z), Vector3.BACK)
	# Roof liner (faces down), door tops (face inward), a cream accent stripe on the dash.
	ib.quad("interior_roof_slate", Vector3(-half, CAR_HEIGHT - 0.08, -0.8), Vector3(half, CAR_HEIGHT - 0.08, -0.8),
		Vector3(half, CAR_HEIGHT - 0.08, 1.0), Vector3(-half, CAR_HEIGHT - 0.08, 1.0), Vector3.DOWN)
	for side: float in [-1.0, 1.0]:
		ib.quad("interior_asphalt", Vector3(side * half, CAR_BELT_Y - 0.2, -0.8), Vector3(side * half, CAR_BELT_Y, -0.8),
			Vector3(side * half, CAR_BELT_Y, 1.0), Vector3(side * half, CAR_BELT_Y - 0.2, 1.0), Vector3(-side, 0.0, 0.0))
	ib.quad("interior_cream", Vector3(-half, dash_y + 0.002, dash_z - 0.05), Vector3(half, dash_y + 0.002, dash_z - 0.05),
		Vector3(half, dash_y + 0.002, dash_z - 0.02), Vector3(-half, dash_y + 0.002, dash_z - 0.02), Vector3.UP)
	# Centre-stack screen on the dash face.
	ib.quad("interior_screen", Vector3(-0.09, dash_y - 0.12, dash_z + 0.005), Vector3(0.09, dash_y - 0.12, dash_z + 0.005),
		Vector3(0.09, dash_y - 0.05, dash_z + 0.005), Vector3(-0.09, dash_y - 0.05, dash_z + 0.005), Vector3.BACK)
	_mesh_node(interior, "Cabin", ib.commit())
	# Steering wheel: origin at the hub, local +Z along the column toward the driver,
	# tilted about X; rim, three spokes, a cream mark at 12 o'clock.
	var sb := Builder.new(self)
	var r := 0.18
	var tube := 0.02
	var segs := 20
	for k in segs:
		var a0 := TAU * float(k) / float(segs)
		var a1 := TAU * float(k + 1) / float(segs)
		var m := "interior_cream" if absf(wrapf(a0 + TAU / float(segs) * 0.5 - PI * 0.5, -PI, PI)) < 0.2 else "interior_ink"
		var p0 := Vector3(cos(a0) * r, sin(a0) * r, 0.0)
		var p1 := Vector3(cos(a1) * r, sin(a1) * r, 0.0)
		var q0 := p0 * ((r - tube) / r)
		var q1 := p1 * ((r - tube) / r)
		sb.quad(m, q0 + Vector3(0, 0, tube), q1 + Vector3(0, 0, tube), p1 + Vector3(0, 0, tube), p0 + Vector3(0, 0, tube), Vector3.BACK)
		sb.quad(m, p0, p1, p1 + Vector3(0, 0, tube), p0 + Vector3(0, 0, tube), (p0 + p1) * 0.5)
	for a: float in [0.0, PI, PI * 1.5]:
		var d := Vector3(cos(a), sin(a), 0.0)
		var s := Vector3(-sin(a), cos(a), 0.0) * 0.02
		sb.quad("interior_ink", s + Vector3(0, 0, tube), -s + Vector3(0, 0, tube), d * (r - tube) - s + Vector3(0, 0, tube),
			d * (r - tube) + s + Vector3(0, 0, tube), Vector3.BACK)
	var sw_pos := Vector3(EYE.x, EYE.y - 0.38, EYE.z - 0.55)
	_mesh_node(interior, "SteeringWheel", sb.commit(), Transform3D(Basis(Vector3.RIGHT, -STEER_TILT_RAD), sw_pos))
	# Gauges: one quad, 2.6 : 1, facing the eye, UV 0-1 (v down).
	var gb := Builder.new(self)
	var gw := 0.14
	var gh := gw * 2.0 / 2.6
	var gz := dash_z + 0.01
	var gy := dash_y - 0.02
	gb.face("gauges", PackedVector3Array([Vector3(EYE.x - gw, gy - gh, gz), Vector3(EYE.x + gw, gy - gh, gz),
		Vector3(EYE.x + gw, gy, gz), Vector3(EYE.x - gw, gy, gz)]), Vector3.BACK,
		PackedVector2Array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]))
	_mesh_node(interior, "Gauges", gb.commit())


## The car's LOD1: one Body object, same slots, wheels merged in at rest.
func build_car_lod1() -> Node3D:
	var root := Node3D.new()
	root.name = "Car_CalibCar"
	var b := Builder.new(self)
	var lower_h := CAR_BELT_Y - CAR_SILL_Y
	b.box("paint", Vector3(0.0, CAR_SILL_Y + lower_h * 0.5, 0.0), Vector3(CAR_WIDTH, lower_h, CAR_LENGTH))
	var cabin_h := CAR_HEIGHT - CAR_BELT_Y
	b.box("glass", Vector3(0.0, CAR_BELT_Y + cabin_h * 0.5, 0.1), Vector3(CAR_WIDTH * 0.84, cabin_h, 2.0), "trim_ink")
	for spec: Array in [[-1.0, -1.0], [1.0, -1.0], [-1.0, 1.0], [1.0, 1.0]]:
		var cx := float(spec[0]) * TRACK_HALF
		b.cylinder_x("trim_ink", "trim_steel", cx - TIRE_W * 0.5, cx + TIRE_W * 0.5,
			Vector2(WHEEL_R, float(spec[1]) * CAR_WHEELBASE * 0.5), WHEEL_R, 8)
	_mesh_node(root, "Body", b.commit())
	return root


## The calibration CarDef (tests/art/fixtures/calib_car/calib_car.tres).
static func car_def(model_path: String) -> CarDef:
	var c := CarDef.new()
	c.id = &"calib_car"
	c.display_name = "CALIBRATION"
	c.model_scene_path = model_path
	c.length_m = CAR_LENGTH
	c.width_m = CAR_WIDTH
	c.height_m = CAR_HEIGHT
	c.wheelbase_m = CAR_WHEELBASE
	c.default_paint = Color(0.1, 0.58, 0.6)
	return c


# ---------------------------------------------------------------- Traffic

## A sedan-sized traffic model with every part (§3.7): Body, four wheel meshes with their
## origins at the hubs, glow_front / glow_rear Empties.
func build_traffic(lod1: bool = false) -> Node3D:
	var root := Node3D.new()
	root.name = "Traffic_calib_traffic"
	var b := Builder.new(self)
	var hl := T_LENGTH * 0.5
	var hw := T_WIDTH * 0.5
	var sill := 0.3
	var belt := 0.85
	b.box("paint", Vector3(0.0, (sill + belt) * 0.5, 0.0), Vector3(T_WIDTH, belt - sill, T_LENGTH - 0.3))
	b.box("fixed_asphalt", Vector3(0.0, sill + 0.15, -hl + 0.075), Vector3(T_WIDTH, 0.3, 0.15))
	b.box("asphalt", Vector3(0.0, sill + 0.15, hl - 0.075), Vector3(T_WIDTH, 0.3, 0.15))
	if not lod1:
		b.box("paint_shade", Vector3(0.0, sill + 0.03, 0.0), Vector3(T_WIDTH + 0.01, 0.06, T_LENGTH - 2.0))
		b.box("paint_dark", Vector3(0.0, belt + 0.01, -1.4), Vector3(T_WIDTH * 0.9, 0.02, 1.2))
	b.box("glass_roof_slate", Vector3(0.0, (belt + T_HEIGHT) * 0.5, 0.2), Vector3(T_WIDTH * 0.84, T_HEIGHT - belt, 2.2),
		"paint")
	var lamp_y := belt - 0.15
	var front := -hl - 0.04
	var rear := hl + 0.04
	for spec: Array in [
		["head_cream", -0.6, front, Vector3.FORWARD], ["head_cream", 0.6, front, Vector3.FORWARD],
		["rear_reflector_red", -0.62, rear, Vector3.BACK], ["rear_reflector_red", 0.62, rear, Vector3.BACK],
		["blinkL_reflector_amber", -0.85, front, Vector3.FORWARD], ["blinkR_reflector_amber", 0.85, front, Vector3.FORWARD],
		["blinkL_reflector_amber", -0.85, rear, Vector3.BACK], ["blinkR_reflector_amber", 0.85, rear, Vector3.BACK],
		["brake_reflector_red", 0.0, rear, Vector3.BACK],
	]:
		var x: float = spec[1]
		var z: float = spec[2]
		var y := belt + 0.3 if String(spec[0]).begins_with("brake") else lamp_y
		b.quad(String(spec[0]), Vector3(x - 0.12, y - 0.06, z), Vector3(x + 0.12, y - 0.06, z),
			Vector3(x + 0.12, y + 0.06, z), Vector3(x - 0.12, y + 0.06, z), spec[3])
	_mesh_node(root, "Body", b.commit())
	var wb := Builder.new(self)
	var sides := 8 if not lod1 else 6
	# An even side count puts a vertex at the bottom, on the ground.
	wb.cylinder_x("wheel_ink", "wheel_steel", -0.12, 0.12, Vector2.ZERO, T_WHEEL_R, sides)
	var wheel := wb.commit()
	var axle := T_AXLE_Z
	for spec: Array in [["Wheel_FL", -1.0, -1.0], ["Wheel_FR", 1.0, -1.0], ["Wheel_RL", -1.0, 1.0], ["Wheel_RR", 1.0, 1.0]]:
		_mesh_node(root, String(spec[0]), wheel, Transform3D(Basis.IDENTITY,
			Vector3(float(spec[1]) * (hw - 0.12), T_WHEEL_R, float(spec[2]) * axle)))
	_node(root, "glow_front", Vector3(0.6, lamp_y, front))
	_node(root, "glow_rear", Vector3(0.62, lamp_y, rear))
	return root


# ---------------------------------------------------------------- Props

## One ground-standing quad per palette name, plus one per emissive suffix (§3.3.4):
## a 1 m tile grid facing +Z (toward approaching traffic, §3.1), in rows of 10.
func build_swatch(prefer_set: StringName = &"") -> Node3D:
	var root := Node3D.new()
	root.name = "calib_swatch"
	var b := Builder.new(self)
	var names := swatch_prop_names(prefer_set)
	for i in names.size():
		var c := swatch_quad_center(i)
		b.quad(names[i], c + Vector3(-0.5, -0.5, 0.0), c + Vector3(0.5, -0.5, 0.0), c + Vector3(0.5, 0.5, 0.0),
			c + Vector3(-0.5, 0.5, 0.0), Vector3.BACK)
	_mesh_node(root, "calib_swatch", b.commit())
	return root
