class_name TrafficMeshBuilder
extends PropMeshBuilder
## Low-poly, flat-shaded traffic vehicle meshes (WP3.1, ART3 start). Spec: Traffic →
## Visuals; Cars → Modular car convention (the traffic version), Art pipeline (palette,
## flat shading, no textures), Traffic vehicle budget (3k tris, one body material plus
## lights, color per instance).
##
## Reuses WP1.4's PropMeshBuilder primitives and adds a PART per vertex, so one mesh
## (one draw call per model with a MultiMesh) carries body, paint, glass, spinning
## wheels and every lamp group, each switched per instance by the traffic shader.
##
## Vertex conventions (assets/shaders/traffic.gdshader reads them):
##   COLOR.rgb  sRGB albedo (fixed parts); for PART_PAINT a shade multiplier (1 = paint)
##   UV.x       part (PART_*)
##   UV2        wheel hub (y, z) in model space for PART_WHEEL (the spin axis is X)
##   NORMAL     flat (duplicated vertices per face)
## Model frame: -Z forward, +X right, Y up, meters; origin on the ground at the center
## of the body box (TrafficState s, d is the box center).

## Parts: the runtime's ids (TrafficLights.PART_*), so shader, view and models agree.
const PART_FIXED := TrafficLights.PART_FIXED
const PART_PAINT := TrafficLights.PART_PAINT
const PART_GLASS := TrafficLights.PART_GLASS
const PART_WHEEL := TrafficLights.PART_WHEEL
const PART_HEAD := TrafficLights.PART_HEAD
const PART_REAR := TrafficLights.PART_REAR
const PART_BRAKE := TrafficLights.PART_BRAKE
const PART_BLINK_L := TrafficLights.PART_BLINK_L
const PART_BLINK_R := TrafficLights.PART_BLINK_R
const TRAFFIC_MATERIAL := "res://assets/shaders/materials/traffic.tres"

## Current part and wheel hub for everything added next.
var part: int = PART_FIXED
var hub := Vector2.ZERO

var _uv := PackedVector2Array()


func face(points: PackedVector3Array, outward: Vector3, color_name: StringName,
		emissive: int = EMISSIVE_NONE) -> void:
	var n0 := _v.size()
	super.face(points, outward, color_name, emissive)
	for i in range(n0, _v.size()):
		_uv.append(Vector2(float(part), 0.0))
		_uv2[i] = hub if part == PART_WHEEL else Vector2.ZERO


## Runs `fn` with `p` as the current part.
func with_part(p: int, fn: Callable) -> void:
	var old := part
	part = p
	fn.call()
	part = old


# ---------------------------------------------------------------- Shapes

## A convex side profile extruded across the car. `profile` points are (fwd, y) with
## fwd > 0 toward the nose (model z = -fwd), in order around the outline. Each point has
## its own half width (tumblehome: narrower at the top); the outline must be convex.
## `edge_colors[i]` colors the strip from point i to i+1 ("" = `color`); `edge_parts`
## likewise (-1 = the current part). Sides use `side_color` / `side_part`.
func loft(profile: PackedVector2Array, half_w: PackedFloat32Array, color: StringName,
		side_color: StringName = &"", edge_colors: Array[StringName] = [], edge_parts: PackedInt32Array = [],
		side_part: int = -1, with_sides: bool = true, x_center: float = 0.0) -> void:
	var n := profile.size()
	var old := part
	var centroid := Vector2.ZERO
	for p in profile:
		centroid += p
	centroid /= float(n)
	for i in n:
		var j := (i + 1) % n
		var a := profile[i]
		var b := profile[j]
		var col := color
		if i < edge_colors.size() and edge_colors[i] != &"":
			col = edge_colors[i]
		part = edge_parts[i] if i < edge_parts.size() and edge_parts[i] >= 0 else old
		var mid := (a + b) * 0.5 - centroid
		quad(Vector3(x_center - half_w[i], a.y, -a.x), Vector3(x_center + half_w[i], a.y, -a.x),
			Vector3(x_center + half_w[j], b.y, -b.x), Vector3(x_center - half_w[j], b.y, -b.x),
			Vector3(0.0, mid.y, -mid.x), col)
	part = side_part if side_part >= 0 else old
	if with_sides:
		var sc := color if side_color == &"" else side_color
		for sx: float in [-1.0, 1.0]:
			var pts := PackedVector3Array()
			for i in n:
				pts.append(Vector3(x_center + sx * half_w[i], profile[i].y, -profile[i].x))
			face(pts, Vector3(sx, 0.0, 0.0), sc)
	part = old


## Uniform-width loft.
func slab(profile: PackedVector2Array, half_width: float, color: StringName, side_color: StringName = &"",
		edge_colors: Array[StringName] = [], edge_parts: PackedInt32Array = [], side_part: int = -1,
		x_center: float = 0.0) -> void:
	var hw := PackedFloat32Array()
	hw.resize(profile.size())
	hw.fill(half_width)
	loft(profile, hw, color, side_color, edge_colors, edge_parts, side_part, true, x_center)


## A wheel on the X axis: tire tube plus a hub face with a spoke cross (so the spin
## reads). `x_outer` is the tire's outer face; the tire extends `width` toward the
## center line (x = 0). `both_faces` also puts a hub on the inner face (motorbikes).
func wheel(x_outer: float, y_hub: float, z_hub: float, radius: float, width: float, sides: int,
		both_faces: bool = false, tire: StringName = &"ink", rim: StringName = &"steel",
		spoke: StringName = &"steel_dark") -> void:
	var old_part := part
	part = PART_WHEEL
	hub = Vector2(y_hub, z_hub)
	var out_sign := signf(x_outer) if x_outer != 0.0 else 1.0
	var x_in := x_outer - out_sign * width
	# Circumscribed polygon: the flat bottom face sits exactly `radius` below the hub,
	# so the tire touches the ground.
	var r_poly := radius / cos(PI / float(sides))
	tube(Vector3(x_in, y_hub, z_hub), Vector3(x_outer, y_hub, z_hub), r_poly, r_poly, sides, tire, false)
	_hub_face(x_outer, out_sign, y_hub, z_hub, radius, sides, rim, spoke)
	if both_faces:
		_hub_face(x_in, -out_sign, y_hub, z_hub, radius, sides, rim, spoke)
	part = old_part
	hub = Vector2.ZERO


func _hub_face(x: float, out_sign: float, y_hub: float, z_hub: float, radius: float, sides: int,
		rim: StringName, spoke: StringName) -> void:
	var face_x := x + out_sign * 0.005
	var out := Vector3(out_sign, 0.0, 0.0)
	disc(Vector3(face_x, y_hub, z_hub), out, radius * 0.66, sides, rim)
	var r := radius * 0.6
	var w := radius * 0.15
	var sx := face_x + out_sign * 0.005
	quad(Vector3(sx, y_hub - w, z_hub - r), Vector3(sx, y_hub + w, z_hub - r),
		Vector3(sx, y_hub + w, z_hub + r), Vector3(sx, y_hub - w, z_hub + r), out, spoke)
	quad(Vector3(sx, y_hub - r, z_hub - w), Vector3(sx, y_hub + r, z_hub - w),
		Vector3(sx, y_hub + r, z_hub + w), Vector3(sx, y_hub - r, z_hub + w), out, spoke)


## A flat lamp panel facing +Z (rear) or -Z (front), standing proud of a face at z.
func lamp(center: Vector3, size: Vector2, facing_rear: bool, color_name: StringName, lamp_part: int,
		depth: float = 0.04) -> void:
	var old := part
	part = lamp_part
	var dz := depth if facing_rear else -depth
	box(Vector3(center.x, center.y, center.z + dz * 0.5), Vector3(size.x, size.y, depth), color_name,
		&"", true)
	part = old


# ---------------------------------------------------------------- Output

## One-surface ArrayMesh with the shared traffic material. `meta` becomes resource meta.
func commit(meta: Dictionary = {}) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _v
	arrays[Mesh.ARRAY_NORMAL] = _n
	arrays[Mesh.ARRAY_COLOR] = _c
	arrays[Mesh.ARRAY_TEX_UV] = _uv
	arrays[Mesh.ARRAY_TEX_UV2] = _uv2
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, load(TRAFFIC_MATERIAL))
	for k: String in meta:
		mesh.set_meta(StringName(k), meta[k])
	return mesh


func clear() -> void:
	super.clear()
	_uv = PackedVector2Array()
	part = PART_FIXED
	hub = Vector2.ZERO


## Axis-aligned bounds of everything added so far.
func bounds() -> AABB:
	if _v.is_empty():
		return AABB()
	var box_aabb := AABB(_v[0], Vector3.ZERO)
	for p in _v:
		box_aabb = box_aabb.expand(p)
	return box_aabb
