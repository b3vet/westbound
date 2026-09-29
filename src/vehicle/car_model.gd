class_name CarModel
extends RefCounted
## A car model resolved against the modular car convention (spec: Cars, garage,
## progression and art pipeline → Modular car convention; Art pipeline steps 3-4).
##
## Code depends only on the convention, never on a specific model:
##
##   Car_<name>            Node3D root. Faces -Z, Y up, meters, origin on the ground
##                         at the center between the axles.
##     Body                MeshInstance3D; surfaces/material slots paint, trim, glass
##     Lights              headlight_L/R, taillight_L/R, brake_L/R,
##                         blinker_FL/FR/RL/RR, reverse (emissive meshes)
##     Wheel_FL, Wheel_FR  steer pivots at the hub centers, each with Rim + Tire
##     Wheel_RL, Wheel_RR  (Rim + Tire)
##     Interior            optional: dashboard, seats, SteeringWheel
##     Markers             cam_cockpit, cam_hood, exhaust_L/R, smoke_hood, shadow
##     Damage              optional (Phase 4)
##     CollisionBox        CollisionShape3D, the body bounds inset by
##                         lives.collision_inset_m (disabled; for the crash hand-off)
##
## Missing nodes are stubbed from the body bounds: wheels as simple cylinders at the
## arch positions, lights as small emissive quads on the front and rear faces, markers
## at plausible spots. The import script (assets/cars/car_import.gd) runs the same
## conform() at import time with per-model hints, so imported placeholder models are
## already complete; at runtime conform() only fills gaps.
##
##   var model := CarModel.load_model(car.model_scene_path, car)
##   add_child(model.root)
##   model.apply_paint(car.default_paint)
##
## Everything here runs at load time (it may allocate); nothing runs per tick.
##
## Draw calls (WP4.6; spec Performance budget → draw calls): merge_draw_surfaces()
## (CarVisual.bind calls it) folds the per-part meshes into as few draws as the
## materials allow, without changing a pixel:
##   Lights/MergedLamps   headlight_L/R + taillight_L/R (one lamp surface, always on)
##   Lights/MergedBrakes  brake_L + brake_R (one signal surface; CarVisual switches it)
##   MergedWheels<k>      one MultiMesh per distinct tire + rim pair: every wheel in one
##                        draw; CarVisual writes the instances (spin, steer) per tick
## The convention nodes stay (positions, markers, tests, the crash hand-off) but the
## merged ones are hidden: after the merge, switch the brake lights through
## `brakes_mesh` and hide all lamps through `lamps_mesh`; for a single-lamp effect
## (e.g. WP4.1's flickering headlight) `split_light(&"headlight_L")` takes that lamp
## back out as its own node (one more draw). Blinkers and reverse stay
## separate, hidden until used. Body keeps one surface per material (paint, trim,
## glass): the vehicle shader's slot is a uniform, so those cannot share a draw.

const VEHICLE_SHADER := preload("res://assets/shaders/vehicle.gdshader")
const MAT_PAINT := "res://assets/shaders/materials/vehicle_paint.tres"
const MAT_TRIM := "res://assets/shaders/materials/vehicle_trim.tres"
const MAT_GLASS := "res://assets/shaders/materials/vehicle_glass.tres"
const MAT_LAMP := "res://assets/shaders/materials/vehicle_lamp.tres"
const MAT_SIGNAL := "res://assets/shaders/materials/vehicle_signal.tres"

## Material slot ids (the vehicle shader's `slot` uniform).
enum Slot { PAINT, TRIM, GLASS, LAMP, SIGNAL }
const SLOT_NAMES: Array[StringName] = [&"paint", &"trim", &"glass", &"lamp", &"signal"]

const BODY := &"Body"
const LIGHTS := &"Lights"
const INTERIOR := &"Interior"
const STEERING_WHEEL := &"SteeringWheel"
const MARKERS := &"Markers"
const DAMAGE := &"Damage"
const RIM := &"Rim"
const TIRE := &"Tire"
const COLLISION_BOX := &"CollisionBox"

const WHEEL_NAMES: Array[StringName] = [&"Wheel_FL", &"Wheel_FR", &"Wheel_RL", &"Wheel_RR"]
const LIGHT_NAMES: Array[StringName] = [
	&"headlight_L", &"headlight_R", &"taillight_L", &"taillight_R", &"brake_L", &"brake_R",
	&"blinker_FL", &"blinker_FR", &"blinker_RL", &"blinker_RR", &"reverse",
]
const MARKER_NAMES: Array[StringName] = [
	&"cam_cockpit", &"cam_hood", &"exhaust_L", &"exhaust_R", &"smoke_hood", &"shadow",
]

# Stub defaults (art-pipeline placeholders, not gameplay tuning). Fractions of the
# body bounds unless noted. Models override them with import hints.
## Wheel radius as a fraction of the body length (cool_drive: 0.30 m on a 4.0 m car).
const STUB_WHEEL_RADIUS_FRAC := 0.075
## Hub offset from the center line, fraction of the half-width.
const STUB_WHEEL_TRACK_FRAC := 0.78
## Hub offset from the axle center, fraction of the half-length.
const STUB_WHEEL_BASE_FRAC := 0.59
## Tire width as a fraction of the body width.
const STUB_TIRE_WIDTH_FRAC := 0.13
## Rim radius as a fraction of the wheel radius.
const STUB_RIM_RADIUS_FRAC := 0.62
const STUB_WHEEL_SEGMENTS := 12
const STUB_RIM_SPOKES := 5
## Stub light quads: size (m) and spots (fractions of the half-width / height).
const STUB_LAMP_SIZE := Vector2(0.34, 0.12)
const STUB_SIGNAL_SIZE := Vector2(0.14, 0.09)
const STUB_HEADLIGHT_X_FRAC := 0.66
const STUB_HEADLIGHT_Y_FRAC := 0.5
const STUB_TAILLIGHT_X_FRAC := 0.7
const STUB_TAILLIGHT_Y_FRAC := 0.58
const STUB_BRAKE_X_FRAC := 0.38
const STUB_BLINKER_X_FRAC := 0.9
const STUB_REVERSE_X_FRAC := 0.12
## Surface search band around a light spot (m) and how far the quad sits off it (m).
const STUB_SURFACE_BAND_M := Vector2(0.14, 0.1)
const STUB_LIGHT_STANDOFF_M := 0.015
## Marker spots.
const STUB_DRIVER_X_FRAC := 0.36
const STUB_EYE_Y_FRAC := 0.8
const STUB_HOOD_Z_FRAC := 0.22
const STUB_HOOD_CAM_LIFT_M := 0.12
## The hood camera clears the body top across this share of the half-width (fenders,
## scoops; mirrors excluded).
const STUB_HOOD_HALF_WIDTH_FRAC := 0.8
const STUB_EXHAUST_X_FRAC := 0.55
const STUB_EXHAUST_Y_FRAC := 0.22
## Stub body (no model at all): lower box height fraction and cabin size fractions.
const STUB_BODY_SILL_FRAC := 0.55
const STUB_CABIN_FRAC := Vector3(0.82, 0.45, 0.5)
## Light colors (sRGB; the vehicle shader linearizes COLOR).
const COLOR_HEADLIGHT := Color(1.0, 0.95, 0.82)
const COLOR_TAILLIGHT := Color(0.85, 0.04, 0.04)
const COLOR_BRAKE := Color(1.0, 0.12, 0.08)
const COLOR_BLINKER := Color(1.0, 0.55, 0.05)
const COLOR_REVERSE := Color(0.95, 0.96, 1.0)
const COLOR_TIRE := Color(0.07, 0.07, 0.08)
const COLOR_RIM := Color(0.56, 0.56, 0.58)
const COLOR_SPOKE := Color(0.2, 0.2, 0.21)
const COLOR_TRIM := Color(0.12, 0.12, 0.13)
const COLOR_GLASS := Color(0.08, 0.1, 0.13)

## Most draw calls a merged car may take with its switched lights off (body paint,
## trim and glass, the merged lamps, the wheels). Spec: Performance budget → draw
## calls; checked for every car by tests/unit/test_car_visual.gd.
const MERGED_DRAW_SURFACES_MAX := 5
const MERGED_LAMPS := &"MergedLamps"
const MERGED_BRAKES := &"MergedBrakes"
const MERGED_WHEELS_PREFIX := "MergedWheels"
## Lights folded into MergedLamps / MergedBrakes.
const LAMP_NAMES: Array[StringName] = [&"headlight_L", &"headlight_R", &"taillight_L", &"taillight_R"]
const BRAKE_NAMES: Array[StringName] = [&"brake_L", &"brake_R"]
## Wheels share a MultiMesh only when their rim sits on the tire the same way (m).
const WHEEL_MATCH_EPS := 1e-4  # lint: allow-number geometric tolerance, not a tuning value


## One MultiMesh drawing every wheel that has the same tire and rim meshes (one draw).
## Instance k is wheel `wheel[k]`; its transform in root space is
## parent_xf[k] * pivot * spin * tire_rest[k] (CarVisual writes it per tick).
class WheelDraw extends RefCounted:
	var node: MultiMeshInstance3D
	var mm: MultiMesh
	var wheel: PackedInt32Array = PackedInt32Array()
	## Root-space transform of the wheel pivot's parent (identity for a root child).
	var parent_xf: Array[Transform3D] = []
	## The Tire node's rest transform in its pivot's space.
	var tire_rest: Array[Transform3D] = []
	## The transform last written to each instance (a CPU copy: the renderer keeps the
	## real buffer, which headless runs cannot read back).
	var written: Array[Transform3D] = []


## One merged surface being assembled (merge_meshes).
class _MergeGroup extends RefCounted:
	var material: Material
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var indices := PackedInt32Array()
	var has_uv := false
	var has_uv2 := false

var root: Node3D
var body: MeshInstance3D
var lights: Node3D
## Light nodes by convention name (every LIGHT_NAMES entry after conform).
var light: Dictionary = {}
## Wheel pivots in WHEEL_NAMES order (FL, FR, RL, RR), with their Rim and Tire.
var wheels: Array[Node3D] = []
var rims: Array[Node3D] = []
var tires: Array[Node3D] = []
var interior: Node3D
var steering_wheel: Node3D
var markers: Node3D
var damage: Node3D
var collision_shape: CollisionShape3D
var wheel_radius_m: float = 0.0
## Body bounds in root space.
var body_aabb: AABB
## Collision box in root space (body bounds inset on each side).
var collision_box: AABB
## Convention paths that conform() had to create for this instance.
var stubbed: PackedStringArray = []
## Set by merge_draw_surfaces(); the merged draws (null / empty when a part was missing).
var merged: bool = false
var lamps_mesh: MeshInstance3D
var brakes_mesh: MeshInstance3D
var wheel_draws: Array[WheelDraw] = []


## Loads a model scene, conforms it to the convention and resolves its nodes. An empty
## path or a scene that fails to load gives a full stub built from the CarDef's body
## dimensions (so a car always renders).
static func load_model(path: String, car: CarDef = null) -> CarModel:
	var node: Node3D = null
	if not path.is_empty() and ResourceLoader.exists(path):
		var scene := load(path) as PackedScene
		if scene != null:
			var inst := scene.instantiate()
			node = inst as Node3D
			if node == null and inst != null:
				inst.free()
	if node == null:
		if not path.is_empty():
			push_warning("CarModel: cannot load %s; using a stub body" % path)
		node = build_stub_root(car)
	return from_root(node, car)


## Conforms `node` in place (stubbing what is missing) and resolves its nodes.
static func from_root(node: Node3D, car: CarDef = null) -> CarModel:
	var m := CarModel.new()
	m.stubbed = conform(node, car)
	m._resolve(node)
	return m


## Brings `node` up to the convention, creating whatever is missing. Returns the paths
## it created. `hints` (import-time, per model) may set wheel_radius_frac,
## wheel_track_frac, wheel_base_frac and wheel_offset_z_frac. `inset_m` < 0 uses
## lives.collision_inset_m from the default tuning. Allocates; load/import time only.
static func conform(node: Node3D, car: CarDef = null, hints: Dictionary = {},
		inset_m: float = -1.0) -> PackedStringArray:
	var made := PackedStringArray()
	var body_node := _find_or_adopt_body(node, car, made)
	var bounds := body_bounds(node, body_node)
	var lights_node := _ensure_child(node, LIGHTS, made)
	for n in LIGHT_NAMES:
		if lights_node.get_node_or_null(NodePath(n)) == null:
			_stub_light(lights_node, n, bounds, body_node, node)
			made.append("%s/%s" % [LIGHTS, n])
	_stub_wheels(node, bounds, hints, made)
	var markers_node := _ensure_child(node, MARKERS, made)
	for n in MARKER_NAMES:
		if markers_node.get_node_or_null(NodePath(n)) == null:
			var mk := Marker3D.new()
			mk.name = n
			mk.position = _marker_spot(n, bounds, body_node, node)
			markers_node.add_child(mk)
			made.append("%s/%s" % [MARKERS, n])
	if node.get_node_or_null(NodePath(COLLISION_BOX)) == null:
		if inset_m < 0.0:
			inset_m = Tuning.load_default().lives.collision_inset_m
		var cs := CollisionShape3D.new()
		cs.name = COLLISION_BOX
		var box := BoxShape3D.new()
		var cb := inset_box(bounds, inset_m)
		box.size = cb.size
		cs.shape = box
		cs.position = cb.get_center()
		cs.disabled = true
		node.add_child(cs)
		made.append(COLLISION_BOX)
	return made


## The body bounds inset by `inset_m` on each side (plan view and top; the bottom stays
## on the ground).
static func inset_box(bounds: AABB, inset_m: float) -> AABB:
	var p := bounds.position + Vector3(inset_m, 0.0, inset_m)
	var s := bounds.size - Vector3(inset_m * 2.0, inset_m, inset_m * 2.0)
	return AABB(p, s.max(Vector3.ZERO))


## Body bounds in `node`'s space (all Body surfaces).
static func body_bounds(node: Node3D, body_node: MeshInstance3D) -> AABB:
	if body_node == null or body_node.mesh == null:
		return AABB()
	return _xform_to(node, body_node) * body_node.mesh.get_aabb()


## Triangle count of a mesh (all surfaces, LOD0).
static func triangle_count(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var corners := 0
	var am := mesh as ArrayMesh
	for i in mesh.get_surface_count():
		if am != null:
			var n := am.surface_get_array_index_len(i)
			corners += n if n > 0 else am.surface_get_array_len(i)
		else:
			var arrays := mesh.surface_get_arrays(i)
			var idx: Variant = arrays[Mesh.ARRAY_INDEX]
			corners += (idx as PackedInt32Array).size() if idx != null \
				else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	@warning_ignore("integer_division")
	return corners / 3


## Recolors the paint slot: every Body surface whose material is the vehicle shader in
## the paint slot gets its own material copy with `paint_color` (sRGB).
func apply_paint(color: Color) -> void:
	if body == null or body.mesh == null:
		return
	for i in body.mesh.get_surface_count():
		var mat := body.get_active_material(i) as ShaderMaterial
		if mat == null or mat.shader != VEHICLE_SHADER:
			continue
		if int(mat.get_shader_parameter(&"slot")) != Slot.PAINT:
			continue
		var own := mat
		if body.get_surface_override_material(i) != mat:
			own = mat.duplicate() as ShaderMaterial
			body.set_surface_override_material(i, own)
		own.set_shader_parameter(&"paint_color", Vector3(color.r, color.g, color.b))


func marker(marker_name: StringName) -> Marker3D:
	return markers.get_node_or_null(NodePath(marker_name)) as Marker3D if markers != null else null


func body_triangles() -> int:
	return triangle_count(body.mesh) if body != null else 0


## Missing convention paths (after conform this is empty for a valid model).
func missing_nodes() -> PackedStringArray:
	var out := PackedStringArray()
	for p in required_paths():
		if root.get_node_or_null(NodePath(p)) == null:
			out.append(p)
	return out


static func required_paths() -> PackedStringArray:
	var out := PackedStringArray([BODY, LIGHTS, MARKERS, COLLISION_BOX])
	for n in LIGHT_NAMES:
		out.append("%s/%s" % [LIGHTS, n])
	for n in WHEEL_NAMES:
		out.append(n)
		out.append("%s/%s" % [n, RIM])
		out.append("%s/%s" % [n, TIRE])
	for n in MARKER_NAMES:
		out.append("%s/%s" % [MARKERS, n])
	return out


## A complete stand-in root for a car with no model: a paint box and a glass cabin
## sized from the CarDef (or plausible defaults); conform() adds the rest.
static func build_stub_root(car: CarDef) -> Node3D:
	var length := car.length_m if car != null else 4.5
	var width := car.width_m if car != null else 1.9
	var height := car.height_m if car != null else 1.3
	var n := Node3D.new()
	n.name = "Car_Stub"
	var sill := height * STUB_BODY_SILL_FRAC
	var r := length * STUB_WHEEL_RADIUS_FRAC
	var lower_h := sill - r * 0.5
	var mesh := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_box(st, Vector3(0.0, r * 0.5 + lower_h * 0.5, 0.0), Vector3(width, lower_h, length), Color.WHITE)
	_commit_slot(st, mesh, Slot.PAINT)
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cabin := Vector3(width * STUB_CABIN_FRAC.x, height * STUB_CABIN_FRAC.y, length * STUB_CABIN_FRAC.z)
	_add_box(st, Vector3(0.0, sill + cabin.y * 0.5, length * 0.04), cabin, COLOR_GLASS)
	_commit_slot(st, mesh, Slot.GLASS)
	var b := MeshInstance3D.new()
	b.name = BODY
	b.mesh = mesh
	n.add_child(b)
	return n


# ---------------------------------------------------------------- Draw-call merge

## Folds the lamps, the brake lights and the wheels into merged draws (see the header).
## Idempotent; load time (allocates). Leaves a group alone when one of its parts is
## missing or has no mesh.
func merge_draw_surfaces() -> void:
	if merged or root == null:
		return
	merged = true
	lamps_mesh = _merge_lights(LAMP_NAMES, MERGED_LAMPS)
	brakes_mesh = _merge_lights(BRAKE_NAMES, MERGED_BRAKES)
	_merge_wheels()


## Takes one merged head/tail lamp back out of `lamps_mesh` and returns its own
## (visible) node, for a per-lamp effect such as a flicker. Costs one draw while
## split. Load/event time (rebuilds the merged mesh); null if it is not a merged lamp.
func split_light(light_name: StringName) -> MeshInstance3D:
	if lamps_mesh == null or not LAMP_NAMES.has(light_name):
		return null
	var mi := light.get(light_name) as MeshInstance3D
	if mi == null or mi.visible:
		return mi
	var parts: Array[MeshInstance3D] = []
	var xforms: Array[Transform3D] = []
	for n in LAMP_NAMES:
		var other := light.get(n) as MeshInstance3D
		if other != null and n != light_name and not other.visible:
			parts.append(other)
			xforms.append(_xform_to(lights, other))
	lamps_mesh.mesh = merge_meshes(parts, xforms) if not parts.is_empty() else null
	mi.visible = true
	return mi


## Draw calls this model issues as it stands: the surfaces of every visible mesh (a
## MultiMesh counts once), before frustum culling. Load time and tests.
func draw_surface_count() -> int:
	return _count_draws(root) if root != null else 0


## Merges the surfaces of `parts` (each placed by the matching `xforms` entry into the
## result's space) into one ArrayMesh with one surface per distinct active material,
## in first-seen order. Keeps positions, normals (turned like the vehicle shader turns
## them: basis, then normalized), colors (white where missing) and UVs; drops
## tangents and LODs. Triangle surfaces only. Load time (allocates).
static func merge_meshes(parts: Array[MeshInstance3D], xforms: Array[Transform3D]) -> ArrayMesh:
	var groups: Array[_MergeGroup] = []
	for p in parts.size():
		var mi := parts[p]
		var xf := xforms[p]
		for s in mi.mesh.get_surface_count():
			if mi.mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
				push_warning("CarModel.merge_meshes: %s surface %d is not triangles; skipped" % [mi.name, s])
				continue
			var mat := mi.get_active_material(s)
			var g: _MergeGroup = null
			for cand in groups:
				if cand.material == mat:
					g = cand
			if g == null:
				g = _MergeGroup.new()
				g.material = mat
				groups.append(g)
			_append_surface(g, mi.mesh.surface_get_arrays(s), xf)
	var mesh := ArrayMesh.new()
	for g in groups:
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = g.verts
		arrays[Mesh.ARRAY_NORMAL] = g.normals
		arrays[Mesh.ARRAY_COLOR] = g.colors
		if g.has_uv:
			arrays[Mesh.ARRAY_TEX_UV] = g.uvs
		if g.has_uv2:
			arrays[Mesh.ARRAY_TEX_UV2] = g.uv2s
		arrays[Mesh.ARRAY_INDEX] = g.indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, g.material)
	return mesh


static func _append_surface(g: _MergeGroup, arrays: Array, xf: Transform3D) -> void:
	var base := g.verts.size()
	var verts := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var n := verts.size()
	for v in verts:
		g.verts.append(xf * v)
	var normals: Variant = arrays[Mesh.ARRAY_NORMAL]
	if normals != null:
		for nv: Vector3 in normals as PackedVector3Array:
			g.normals.append((xf.basis * nv).normalized())
	else:
		for i in n:
			g.normals.append(Vector3.UP)
	var colors: Variant = arrays[Mesh.ARRAY_COLOR]
	if colors != null:
		g.colors.append_array(colors as PackedColorArray)
	else:
		for i in n:
			g.colors.append(Color.WHITE)
	_append_uv(g.uvs, arrays[Mesh.ARRAY_TEX_UV], n)
	g.has_uv = g.has_uv or arrays[Mesh.ARRAY_TEX_UV] != null
	_append_uv(g.uv2s, arrays[Mesh.ARRAY_TEX_UV2], n)
	g.has_uv2 = g.has_uv2 or arrays[Mesh.ARRAY_TEX_UV2] != null
	var idx: Variant = arrays[Mesh.ARRAY_INDEX]
	if idx != null:
		for i: int in idx as PackedInt32Array:
			g.indices.append(base + i)
	else:
		for i in n:
			g.indices.append(base + i)


static func _append_uv(out: PackedVector2Array, uv: Variant, n: int) -> void:
	if uv != null:
		out.append_array(uv as PackedVector2Array)
	else:
		for i in n:
			out.append(Vector2.ZERO)


## Merges the named lights into one mesh under Lights and hides the originals.
func _merge_lights(names: Array[StringName], node_name: StringName) -> MeshInstance3D:
	if lights == null:
		return null
	var parts: Array[MeshInstance3D] = []
	var xforms: Array[Transform3D] = []
	var on := false
	for n in names:
		var mi := light.get(n) as MeshInstance3D
		if mi == null or mi.mesh == null:
			return null
		parts.append(mi)
		xforms.append(_xform_to(lights, mi))
		on = on or mi.visible
	var out := MeshInstance3D.new()
	out.name = node_name
	out.mesh = merge_meshes(parts, xforms)
	out.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	out.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	out.visible = on
	lights.add_child(out)
	for mi in parts:
		mi.visible = false
	return out


## Groups the wheels by tire mesh, rim mesh, materials and rim placement; each group
## becomes one MultiMesh (one draw) under root, and its Tire/Rim nodes are hidden.
func _merge_wheels() -> void:
	wheel_draws.clear()
	var keys: Array[Array] = []
	for i in WHEEL_NAMES.size():
		var w := wheels[i]
		var t := tires[i] as MeshInstance3D
		var r := rims[i] as MeshInstance3D
		# Only a Tire (and Rim) spun straight under its pivot can be drawn by instance.
		if w == null or t == null or t.mesh == null or t.get_parent() != w:
			continue
		if r != null and (r.mesh == null or r.get_parent() != w):
			continue
		var rim_rel := t.transform.affine_inverse() * r.transform if r != null else Transform3D.IDENTITY
		var wd: WheelDraw = null
		for k in keys.size():
			if _same_wheel(keys[k], t, r, rim_rel):
				wd = wheel_draws[k]
		if wd == null:
			wd = WheelDraw.new()
			var parts: Array[MeshInstance3D] = [t]
			var xforms: Array[Transform3D] = [Transform3D.IDENTITY]
			if r != null:
				parts.append(r)
				xforms.append(rim_rel)
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			# Compatibility multiplies vertex COLOR by the instance color, which reads
			# zero without colors (CONTRACTS §13 quirks): carry white.
			mm.use_colors = true
			# Spin can reach ~2 rad per tick: interpolate by slerp, not a basis lerp.
			mm.physics_interpolation_quality = MultiMesh.INTERP_QUALITY_HIGH
			mm.mesh = merge_meshes(parts, xforms)
			wd.mm = mm
			wheel_draws.append(wd)
			keys.append([t, r, rim_rel])
		wd.wheel.append(i)
		wd.parent_xf.append(_xform_to(root, w.get_parent() as Node3D))
		wd.tire_rest.append(t.transform)
	for k in wheel_draws.size():
		var wd := wheel_draws[k]
		wd.mm.instance_count = wd.wheel.size()
		for j in wd.wheel.size():
			wd.mm.set_instance_color(j, Color.WHITE)
			wd.written.append(wd.parent_xf[j] * wheels[wd.wheel[j]].transform * wd.tire_rest[j])
			wd.mm.set_instance_transform(j, wd.written[j])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "%s%d" % [MERGED_WHEELS_PREFIX, k]
		mmi.multimesh = wd.mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		root.add_child(mmi)
		wd.node = mmi
		for i in wd.wheel:
			tires[i].visible = false
			if rims[i] != null:
				rims[i].visible = false


## True when tire `t` / rim `r` (rim placed at rim_rel on the tire) draw exactly like
## the wheel recorded in `key` ([tire, rim, rim_rel]).
static func _same_wheel(key: Array, t: MeshInstance3D, r: MeshInstance3D, rim_rel: Transform3D) -> bool:
	var kt := key[0] as MeshInstance3D
	var kr := key[1] as MeshInstance3D
	var krel: Transform3D = key[2]
	if kt.mesh != t.mesh or (kr == null) != (r == null) or not _same_materials(kt, t):
		return false
	if r != null and (kr.mesh != r.mesh or not _same_materials(kr, r)):
		return false
	return (krel.origin - rim_rel.origin).length() <= WHEEL_MATCH_EPS \
		and (krel.basis.x - rim_rel.basis.x).length() <= WHEEL_MATCH_EPS \
		and (krel.basis.y - rim_rel.basis.y).length() <= WHEEL_MATCH_EPS \
		and (krel.basis.z - rim_rel.basis.z).length() <= WHEEL_MATCH_EPS


static func _same_materials(a: MeshInstance3D, b: MeshInstance3D) -> bool:
	for s in a.mesh.get_surface_count():
		if a.get_active_material(s) != b.get_active_material(s):
			return false
	return true


static func _count_draws(n: Node) -> int:
	var n3 := n as Node3D
	if n3 != null and not n3.visible:
		return 0
	var c := 0
	var mi := n as MeshInstance3D
	if mi != null and mi.mesh != null:
		c += mi.mesh.get_surface_count()
	var mmi := n as MultiMeshInstance3D
	if mmi != null and mmi.multimesh != null and mmi.multimesh.mesh != null \
			and mmi.multimesh.instance_count > 0:
		c += mmi.multimesh.mesh.get_surface_count()
	for ch in n.get_children():
		c += _count_draws(ch)
	return c


# ---------------------------------------------------------------- Resolve

func _resolve(node: Node3D) -> void:
	root = node
	body = node.get_node_or_null(NodePath(BODY)) as MeshInstance3D
	lights = node.get_node_or_null(NodePath(LIGHTS)) as Node3D
	light.clear()
	if lights != null:
		for n in LIGHT_NAMES:
			var l := lights.get_node_or_null(NodePath(n)) as Node3D
			if l != null:
				light[n] = l
	wheels.clear()
	rims.clear()
	tires.clear()
	for n in WHEEL_NAMES:
		var w := node.get_node_or_null(NodePath(n)) as Node3D
		wheels.append(w)
		rims.append(w.get_node_or_null(NodePath(RIM)) as Node3D if w != null else null)
		tires.append(w.get_node_or_null(NodePath(TIRE)) as Node3D if w != null else null)
	interior = node.get_node_or_null(NodePath(INTERIOR)) as Node3D
	steering_wheel = interior.find_child(STEERING_WHEEL, true, false) as Node3D if interior != null else null
	markers = node.get_node_or_null(NodePath(MARKERS)) as Node3D
	damage = node.get_node_or_null(NodePath(DAMAGE)) as Node3D
	collision_shape = node.get_node_or_null(NodePath(COLLISION_BOX)) as CollisionShape3D
	body_aabb = body_bounds(node, body)
	if collision_shape != null and collision_shape.shape is BoxShape3D:
		var sz := (collision_shape.shape as BoxShape3D).size
		collision_box = AABB(collision_shape.position - sz * 0.5, sz)
	wheel_radius_m = _wheel_radius(wheels[0], tires[0])


static func _wheel_radius(wheel: Node3D, tire: Node3D) -> float:
	var mi := tire as MeshInstance3D
	if mi != null and mi.mesh != null:
		var a := mi.mesh.get_aabb()
		return maxf(a.size.y, a.size.z) * 0.5
	return wheel.position.y if wheel != null else 0.0


# ---------------------------------------------------------------- Stubbing

static func _find_or_adopt_body(node: Node3D, car: CarDef, made: PackedStringArray) -> MeshInstance3D:
	var b := node.get_node_or_null(NodePath(BODY)) as MeshInstance3D
	if b != null:
		return b
	# Adopt the largest direct MeshInstance3D child as the body.
	var best: MeshInstance3D = null
	var best_size := -1.0
	for c in node.get_children():
		var mi := c as MeshInstance3D
		if mi != null and mi.mesh != null and mi.mesh.get_aabb().get_volume() > best_size:
			best = mi
			best_size = mi.mesh.get_aabb().get_volume()
	if best != null:
		best.name = BODY
		made.append(BODY)
		return best
	var stub := build_stub_root(car)
	b = stub.get_node(NodePath(BODY)) as MeshInstance3D
	stub.remove_child(b)
	stub.free()
	node.add_child(b)
	made.append(BODY)
	return b


static func _ensure_child(node: Node3D, child_name: StringName, made: PackedStringArray) -> Node3D:
	var c := node.get_node_or_null(NodePath(child_name)) as Node3D
	if c == null:
		c = Node3D.new()
		c.name = child_name
		node.add_child(c)
		made.append(child_name)
	return c


static func _stub_wheels(node: Node3D, bounds: AABB, hints: Dictionary, made: PackedStringArray) -> void:
	var length := bounds.size.z
	var r := length * float(hints.get("wheel_radius_frac", STUB_WHEEL_RADIUS_FRAC))
	var track := bounds.size.x * 0.5 * float(hints.get("wheel_track_frac", STUB_WHEEL_TRACK_FRAC))
	var base := length * 0.5 * float(hints.get("wheel_base_frac", STUB_WHEEL_BASE_FRAC))
	var center_z := bounds.get_center().z + length * float(hints.get("wheel_offset_z_frac", 0.0))
	var tire_w := bounds.size.x * STUB_TIRE_WIDTH_FRAC
	var tire_mesh: ArrayMesh = null
	var rim_mesh: ArrayMesh = null
	for i in WHEEL_NAMES.size():
		var wn := WHEEL_NAMES[i]
		var left := i % 2 == 0
		var front := i < 2
		var w := node.get_node_or_null(NodePath(wn)) as Node3D
		if w == null:
			w = Node3D.new()
			w.name = wn
			w.position = Vector3(-track if left else track, r, center_z - base if front else center_z + base)
			node.add_child(w)
			made.append(wn)
		# Rim geometry faces +X (outward on the right); left wheels turn it around.
		var outward := Basis(Vector3.UP, PI) if left else Basis.IDENTITY
		if w.get_node_or_null(NodePath(TIRE)) == null:
			if tire_mesh == null:
				tire_mesh = build_tire_mesh(r, tire_w)
			var t := MeshInstance3D.new()
			t.name = TIRE
			t.mesh = tire_mesh
			t.basis = outward
			w.add_child(t)
			made.append("%s/%s" % [wn, TIRE])
		if w.get_node_or_null(NodePath(RIM)) == null:
			if rim_mesh == null:
				rim_mesh = build_rim_mesh(r * STUB_RIM_RADIUS_FRAC, tire_w)
			var rm := MeshInstance3D.new()
			rm.name = RIM
			rm.mesh = rim_mesh
			rm.basis = outward
			w.add_child(rm)
			made.append("%s/%s" % [wn, RIM])


## Flat-shaded tire: a cylinder around X, `width` wide, tread and both sidewalls.
static func build_tire_mesh(radius: float, width: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := STUB_WHEEL_SEGMENTS
	var hx := width * 0.5
	for k in n:
		var a0 := TAU * float(k) / float(n)
		var a1 := TAU * float(k + 1) / float(n)
		var p0 := Vector3(0.0, cos(a0) * radius, sin(a0) * radius)
		var p1 := Vector3(0.0, cos(a1) * radius, sin(a1) * radius)
		var o := Vector3(hx, 0.0, 0.0)
		_add_quad(st, p0 - o, p1 - o, p1 + o, p0 + o, COLOR_TIRE)
		_add_tri(st, Vector3(hx, 0.0, 0.0), p1 + o, p0 + o, COLOR_TIRE)
		_add_tri(st, Vector3(-hx, 0.0, 0.0), p0 - o, p1 - o, COLOR_TIRE)
	var mesh := ArrayMesh.new()
	_commit_slot(st, mesh, Slot.TRIM)
	return mesh


## Flat-shaded rim face just outside the tire's outer (+X) sidewall, with spokes so the
## spin reads.
static func build_rim_mesh(radius: float, tire_width: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := STUB_WHEEL_SEGMENTS
	var x := tire_width * 0.5 + STUB_LIGHT_STANDOFF_M * 0.5
	var c := Vector3(x, 0.0, 0.0)
	for k in n:
		var a0 := TAU * float(k) / float(n)
		var a1 := TAU * float(k + 1) / float(n)
		_add_tri(st, c, Vector3(x, cos(a1) * radius, sin(a1) * radius),
			Vector3(x, cos(a0) * radius, sin(a0) * radius), COLOR_RIM)
	var sx := x + STUB_LIGHT_STANDOFF_M
	var half := radius * 0.12
	for k in STUB_RIM_SPOKES:
		var a := TAU * float(k) / float(STUB_RIM_SPOKES)
		var dir := Vector3(0.0, cos(a), sin(a))
		var side := Vector3(0.0, -sin(a), cos(a)) * half
		var tip := dir * radius * 0.92
		_add_quad(st, Vector3(sx, 0.0, 0.0) + side, Vector3(sx, 0.0, 0.0) - side,
			Vector3(sx, tip.y, tip.z) - side, Vector3(sx, tip.y, tip.z) + side, COLOR_SPOKE)
	var mesh := ArrayMesh.new()
	_commit_slot(st, mesh, Slot.TRIM)
	return mesh


static func _stub_light(parent: Node3D, light_name: StringName, bounds: AABB,
		body_node: MeshInstance3D, node: Node3D) -> void:
	var half_w := bounds.size.x * 0.5
	var h := bounds.size.y
	var y0 := bounds.position.y
	var front := true
	var x := 0.0
	var y := y0 + h * STUB_HEADLIGHT_Y_FRAC
	var size := STUB_LAMP_SIZE
	var col := COLOR_HEADLIGHT
	var slot := Slot.LAMP
	match light_name:
		&"headlight_L", &"headlight_R":
			x = half_w * STUB_HEADLIGHT_X_FRAC
		&"taillight_L", &"taillight_R":
			front = false
			x = half_w * STUB_TAILLIGHT_X_FRAC
			y = y0 + h * STUB_TAILLIGHT_Y_FRAC
			col = COLOR_TAILLIGHT
		&"brake_L", &"brake_R":
			front = false
			x = half_w * STUB_BRAKE_X_FRAC
			y = y0 + h * STUB_TAILLIGHT_Y_FRAC
			size = STUB_SIGNAL_SIZE
			col = COLOR_BRAKE
			slot = Slot.SIGNAL
		&"blinker_FL", &"blinker_FR":
			x = half_w * STUB_BLINKER_X_FRAC
			size = STUB_SIGNAL_SIZE
			col = COLOR_BLINKER
			slot = Slot.SIGNAL
		&"blinker_RL", &"blinker_RR":
			front = false
			x = half_w * STUB_BLINKER_X_FRAC
			y = y0 + h * STUB_TAILLIGHT_Y_FRAC
			size = STUB_SIGNAL_SIZE
			col = COLOR_BLINKER
			slot = Slot.SIGNAL
		&"reverse":
			front = false
			x = half_w * STUB_REVERSE_X_FRAC
			y = y0 + h * STUB_TAILLIGHT_Y_FRAC
			size = STUB_SIGNAL_SIZE
			col = COLOR_REVERSE
			slot = Slot.SIGNAL
	var s := String(light_name)
	if s.ends_with("L"):   # _L, blinker_FL / blinker_RL: the left side is -X
		x = -x
	var z := _surface_z(body_node, node, x, y, front, bounds)
	z += -STUB_LIGHT_STANDOFF_M if front else STUB_LIGHT_STANDOFF_M
	var mi := MeshInstance3D.new()
	mi.name = light_name
	mi.mesh = _light_quad(size, col, front, slot)
	mi.position = Vector3(x, y, z)
	# Switched lights (brake, blinkers, reverse) start off; car_visual turns them on.
	mi.visible = slot != Slot.SIGNAL
	parent.add_child(mi)


## Front-most (or rear-most) body z near (x, y), searched in the body's vertices; the
## bounds' face when nothing is near.
static func _surface_z(body_node: MeshInstance3D, node: Node3D, x: float, y: float,
		front: bool, bounds: AABB) -> float:
	var best := bounds.position.z if front else bounds.end.z
	if body_node == null or body_node.mesh == null:
		return best
	var xf := _xform_to(node, body_node)
	var found := false
	var z_best := 0.0
	for i in body_node.mesh.get_surface_count():
		var verts := body_node.mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX] as PackedVector3Array
		for v in verts:
			var p := xf * v
			if absf(p.x - x) > STUB_SURFACE_BAND_M.x or absf(p.y - y) > STUB_SURFACE_BAND_M.y:
				continue
			if not found or (front and p.z < z_best) or (not front and p.z > z_best):
				z_best = p.z
				found = true
	return z_best if found else best


## Top of the body across |x| <= half_x near z (hood and fender height for the hood
## markers, so the hood camera clears the fenders and sees the road).
static func _surface_top(body_node: MeshInstance3D, node: Node3D, half_x: float, z: float, bounds: AABB) -> float:
	if body_node == null or body_node.mesh == null:
		return bounds.end.y
	var xf := _xform_to(node, body_node)
	var top := -INF
	for i in body_node.mesh.get_surface_count():
		var verts := body_node.mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX] as PackedVector3Array
		for v in verts:
			var p := xf * v
			if absf(p.x) <= half_x and absf(p.z - z) <= STUB_SURFACE_BAND_M.x:
				top = maxf(top, p.y)
	return top if top > -INF else bounds.end.y


static func _marker_spot(marker_name: StringName, bounds: AABB, body_node: MeshInstance3D, node: Node3D) -> Vector3:
	var c := bounds.get_center()
	var half_w := bounds.size.x * 0.5
	var front_z := bounds.position.z
	var hood_z := front_z + bounds.size.z * STUB_HOOD_Z_FRAC
	var hood_half := half_w * STUB_HOOD_HALF_WIDTH_FRAC
	match marker_name:
		&"cam_cockpit":
			return Vector3(-half_w * STUB_DRIVER_X_FRAC, bounds.position.y + bounds.size.y * STUB_EYE_Y_FRAC, c.z)
		&"cam_hood":
			return Vector3(0.0, _surface_top(body_node, node, hood_half, hood_z, bounds) + STUB_HOOD_CAM_LIFT_M, hood_z)
		&"smoke_hood":
			return Vector3(0.0, _surface_top(body_node, node, STUB_SURFACE_BAND_M.x, hood_z, bounds), hood_z)
		&"exhaust_L", &"exhaust_R":
			var x := half_w * STUB_EXHAUST_X_FRAC
			return Vector3(-x if marker_name == &"exhaust_L" else x,
				bounds.position.y + bounds.size.y * STUB_EXHAUST_Y_FRAC, bounds.end.z)
	return Vector3(0.0, 0.0, c.z)


static func _light_quad(size: Vector2, col: Color, front: bool, slot: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var a := Vector3(-hx, -hy, 0.0)
	var b := Vector3(hx, -hy, 0.0)
	var c := Vector3(hx, hy, 0.0)
	var d := Vector3(-hx, hy, 0.0)
	if front:
		_add_quad(st, b, a, d, c, col)   # faces -Z (forward)
	else:
		_add_quad(st, a, b, c, d, col)   # faces +Z (backward)
	var mesh := ArrayMesh.new()
	_commit_slot(st, mesh, slot)
	return mesh


# ---------------------------------------------------------------- Geometry helpers

static func slot_material(slot: int) -> Material:
	match slot:
		Slot.PAINT:
			return load(MAT_PAINT) as Material
		Slot.GLASS:
			return load(MAT_GLASS) as Material
		Slot.LAMP:
			return load(MAT_LAMP) as Material
		Slot.SIGNAL:
			return load(MAT_SIGNAL) as Material
	return load(MAT_TRIM) as Material


## Commits the SurfaceTool as a new named surface of `mesh` with the slot's material.
static func _commit_slot(st: SurfaceTool, mesh: ArrayMesh, slot: int) -> void:
	st.commit(mesh)
	var i := mesh.get_surface_count() - 1
	mesh.surface_set_name(i, SLOT_NAMES[slot])
	mesh.surface_set_material(i, slot_material(slot))


## One flat-shaded triangle, front face seen with a, b, c clockwise (Godot's winding).
static func _add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	var n := (c - a).cross(b - a).normalized()
	for p: Vector3 in [a, b, c]:
		st.set_normal(n)
		st.set_color(col)
		st.add_vertex(p)


## Quad a-b-c-d, counter-clockwise seen from its front (split into two clockwise tris).
static func _add_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	_add_tri(st, a, c, b, col)
	_add_tri(st, a, d, c, col)


static func _add_box(st: SurfaceTool, center: Vector3, size: Vector3, col: Color) -> void:
	var h := size * 0.5
	var p := PackedVector3Array([
		center + Vector3(-h.x, -h.y, -h.z), center + Vector3(h.x, -h.y, -h.z),
		center + Vector3(h.x, h.y, -h.z), center + Vector3(-h.x, h.y, -h.z),
		center + Vector3(-h.x, -h.y, h.z), center + Vector3(h.x, -h.y, h.z),
		center + Vector3(h.x, h.y, h.z), center + Vector3(-h.x, h.y, h.z),
	])
	_add_quad(st, p[1], p[0], p[3], p[2], col)   # -Z
	_add_quad(st, p[4], p[5], p[6], p[7], col)   # +Z
	_add_quad(st, p[0], p[4], p[7], p[3], col)   # -X
	_add_quad(st, p[5], p[1], p[2], p[6], col)   # +X
	_add_quad(st, p[3], p[7], p[6], p[2], col)   # +Y
	_add_quad(st, p[0], p[1], p[5], p[4], col)   # -Y


## Transform of `n` relative to `ancestor` (works outside the scene tree).
static func _xform_to(ancestor: Node3D, n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != ancestor:
		var n3 := cur as Node3D
		if n3 != null:
			xf = n3.transform * xf
		cur = cur.get_parent()
	return xf
