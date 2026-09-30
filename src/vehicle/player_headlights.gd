class_name PlayerHeadlights
extends Node3D
## The player's headlights (WP5.4). Spec: World → Night lighting ("Player headlights:
## a cone decal on the road, plus a 'fake light' uniform (position and direction) in
## the shared world shader that brightens nearby surfaces"; "Reflectors and signs:
## retro-reflective material that brightens when inside the player's headlight
## cone"); plan decision D8 (a manual high-beam toggle instead of traffic high-beam
## reactions). docs/NIGHT.md.
##
##   lights.setup(ctx, road, origin)          # world-system API (CONTRACTS §13)
##   lights.sky = sky                          # the only writer of the wb_* globals
##   lights.bind(car)                          # after the car is (re)built
##   lights.high_beam = hub.high_beam          # any time
##   lights.update_view(car.state.s)           # once per frame, before the sky pushes
##
## Every frame:
##   - Fake light: SkyRig.set_player_light(lamp position, beam axis x reach, beam gain)
##     from the car's physics-interpolated transform (the drawn pose). The sky
##     multiplies the gain by the color script's headlight ramp (0 by day). The axis
##     length carries the reach: 1 for low beams, NightTuning.high_beam_reach for high
##     beams (world_common.gdshaderinc divides distances by it).
##   - Cone decal: one additive strip on the road ahead of the lamps
##     (assets/shaders/light_decal.gdshader, materials/light_cone.tres), 1 draw call.
##     Its rows are sampled from the RoadPath along the car's heading, so it follows
##     grades and curves; it is longer, wider and brighter with high beams.
##     Hidden (no draw call) while the headlight ramp is below
##     NightTuning.visible_min_ramp, while `enabled` is off (the crash cinematic) or
##     without a car.
## The car model's own lamp quads follow the same ramp in vehicle.gdshader (lamp
## slot); high beams don't change them (car_visual.gd has no lamp-level hook yet).
##
## Allocation-free per frame (no objects; the row buffers are preallocated and
## alternate so the material never shares the buffer being written).

const MATERIAL := preload("res://assets/shaders/materials/light_cone.tres")
## Rows of the strip (light_decal.gdshader MAX_ROWS): cone_segments + 1 at most.
const MAX_ROWS := 17
const HEADLIGHT_L := &"headlight_L"
const HEADLIGHT_R := &"headlight_R"
## Margin around the cone for its bounds (m).
const BOUNDS_MARGIN_M := 10.0

## Night numbers; defaults to Tuning.night when it exists, else NightTuning.load_default().
var tuning: NightTuning
## Receives the fake light (SkyRig.set_player_light). Null: nothing is pushed.
var sky: SkyRig
## D8: manual high beams (longer, brighter cone and fake light). Visual only.
var high_beam: bool = false
## Off: the cone is hidden (the fake light keeps following the car).
var enabled: bool = true
var car: PlayerCar

## The values pushed last frame (tests, dev HUD).
var light_pos := Vector3.ZERO
var light_dir := Vector3.FORWARD
var light_gain: float = 0.0
## The headlight ramp read last frame.
var ramp: float = 0.0

var _road: RoadPath
var _origin: FloatingOrigin
var _mesh_instance: MeshInstance3D
var _material: ShaderMaterial
var _rows: Array[PackedVector4Array] = []
var _rows_r: Array[PackedVector4Array] = []
var _buffer: int = 0
var _segments: int = 1
var _smp := RoadSample.new()
## Lamp center in the car's frame (-Z forward), and how far ahead of the car's origin.
var _lamp_local := Vector3.ZERO
var _pitch_dir := Vector3.FORWARD


func _init() -> void:
	# Placed in _process from the car's interpolated pose; never interpolate again.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	top_level = true


## World-system API (CONTRACTS §13). Builds the cone mesh once; later calls rebind.
func setup(ctx: RunContext, road: RoadPath, origin: FloatingOrigin) -> void:
	_road = road
	_origin = origin
	if tuning == null:
		var t: Variant = ctx.tuning.get(&"night") if ctx != null and ctx.tuning != null else null
		tuning = t as NightTuning if t is NightTuning else NightTuning.load_default()
	if _mesh_instance == null:
		_build()


## The car whose lamps these are (after setup; again whenever the car is rebuilt).
func bind(player_car: PlayerCar) -> void:
	car = player_car
	if car == null:
		return
	if car.road != null:
		_road = car.road
	if car.origin != null:
		_origin = car.origin
	_lamp_local = lamp_center(car)
	var pitch := deg_to_rad(tuning.beam_pitch_deg)
	_pitch_dir = Vector3(0.0, -sin(pitch), -cos(pitch))


## World-system API: once per frame, after the car moved and before SkyRig pushes.
func update_view(_focus_s: float) -> void:
	ramp = sky.current().emissive_headlight if sky != null else 0.0
	if car == null or not is_instance_valid(car) or _road == null:
		_mesh_instance.visible = false
		return
	var xf := car.get_global_transform_interpolated() if car.is_inside_tree() else car.transform
	light_pos = xf * _lamp_local
	light_dir = (xf.basis * _pitch_dir).normalized() * tuning.beam_reach(high_beam)
	light_gain = tuning.beam_gain(high_beam)
	if sky != null:
		sky.set_player_light(light_pos, light_dir, light_gain)
	var lit := enabled and is_finite(ramp) and ramp >= tuning.visible_min_ramp
	if lit:
		_update_cone(xf)
	if _mesh_instance.visible != lit:
		_mesh_instance.visible = lit


## True while the cone decal is drawn.
func cone_visible() -> bool:
	return _mesh_instance != null and _mesh_instance.visible and is_inside_tree()


## Current cone length ahead of the lamps (m).
func cone_length_m() -> float:
	return tuning.cone_length_m(high_beam)


## The cone's row end points (node space) last written: left (side 0) and right.
func cone_row(row: int, right: bool) -> Vector3:
	var buf := _rows_r[_buffer] if right else _rows[_buffer]
	var v := buf[clampi(row, 0, MAX_ROWS - 1)]
	return Vector3(v.x, v.y, v.z)


func cone_rows() -> int:
	return _segments + 1


func cone_node() -> MeshInstance3D:
	return _mesh_instance


## Center of the car's headlights in the car's own frame: the headlight_L/R nodes of
## its model (mesh centers), else the front of the body at the fallback lamp height.
static func lamp_center(player_car: PlayerCar, fallback_height_m: float = -1.0) -> Vector3:
	var sum := Vector3.ZERO
	var n := 0
	if player_car.model != null:
		for key: StringName in [HEADLIGHT_L, HEADLIGHT_R]:
			var lamp: Node3D = player_car.model.light.get(key)
			if lamp != null:
				sum += _center_in(player_car, lamp)
				n += 1
	if n > 0:
		return sum / float(n)
	var h := fallback_height_m
	if h < 0.0:
		h = NightTuning.load_default().fallback_lamp_height_m
	var half := player_car.car.length_m * 0.5 if player_car.car != null else 0.0
	return Vector3(0.0, h, -half)


static func _center_in(root: Node3D, node: Node3D) -> Vector3:
	var local := Vector3.ZERO
	var mi := node as MeshInstance3D
	if mi != null and mi.mesh != null:
		local = mi.mesh.get_aabb().get_center()
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		var n3 := n as Node3D
		if n3 != null:
			xf = n3.transform * xf
		n = n.get_parent()
	return xf * local


# ---------------------------------------------------------------- Cone

func _build() -> void:
	_segments = clampi(tuning.cone_segments, 1, MAX_ROWS - 1)
	for _k in 2:
		var l := PackedVector4Array()
		l.resize(MAX_ROWS)
		var r := PackedVector4Array()
		r.resize(MAX_ROWS)
		_rows.append(l)
		_rows_r.append(r)
	_material = MATERIAL.duplicate() as ShaderMaterial
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "Cone"
	_mesh_instance.mesh = build_strip_mesh(_segments, maxf(tuning.high_cone_length_m, tuning.low_cone_length_m)
		+ BOUNDS_MARGIN_M)
	_mesh_instance.material_override = _material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh_instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_mesh_instance.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_mesh_instance.visible = false
	add_child(_mesh_instance)


## Rows are sampled in road space from the car's tick state (s, d, yaw) and written
## relative to the car's tick position; the node sits at the interpolated position.
func _update_cone(xf: Transform3D) -> void:
	var st := car.state
	var ox := 0.0
	var oy := 0.0
	var oz := 0.0
	if _origin != null:
		ox = _origin.origin_x
		oy = _origin.origin_y
		oz = _origin.origin_z
	var base := car.global_transform.origin if car.is_inside_tree() else car.transform.origin
	var ahead0 := -_lamp_local.z + tuning.cone_start_m
	var length := tuning.cone_length_m(high_beam) - tuning.cone_start_m
	var w0 := tuning.cone_near_width_m * 0.5
	var w1 := tuning.cone_far_width_m(high_beam) * 0.5
	var cy := cos(st.yaw)
	var sy := sin(st.yaw)
	var lift := tuning.cone_lift_m
	_buffer = 1 - _buffer
	var left := _rows[_buffer]
	var right := _rows_r[_buffer]
	for i in _segments + 1:
		var f := float(i) / float(_segments)
		var x := ahead0 + length * f
		var w := lerpf(w0, w1, f)
		_road.sample_into(st.s + x * cy, _smp)
		var d := st.d + x * sy
		var up := _smp.up * lift
		var pl := _smp.local_point(d - w, ox, oy, oz) + up - base
		var pr := _smp.local_point(d + w, ox, oy, oz) + up - base
		left[i] = Vector4(pl.x, pl.y, pl.z, 0.0)
		right[i] = Vector4(pr.x, pr.y, pr.z, 0.0)
	_material.set_shader_parameter(&"rows_left", left)
	_material.set_shader_parameter(&"rows_right", right)
	_material.set_shader_parameter(&"gain", tuning.high_cone_strength if high_beam else 1.0)
	transform = Transform3D(Basis.IDENTITY, xf.origin)


## The strip: (segments + 1) rows of two vertices, VERTEX = (side 0/1, 0, row),
## UV = (side, row / segments). Bounds cover `reach_m` around the node.
static func build_strip_mesh(segments: int, reach_m: float) -> ArrayMesh:
	var v := PackedVector3Array()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()
	for i in segments + 1:
		for side in 2:
			v.append(Vector3(float(side), 0.0, float(i)))
			uv.append(Vector2(float(side), float(i) / float(segments)))
	for i in segments:
		var b := i * 2
		idx.append_array([b, b + 1, b + 2, b + 2, b + 1, b + 3])
	var normals := PackedVector3Array()
	normals.resize(v.size())
	normals.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.custom_aabb = AABB(Vector3(-reach_m, -reach_m, -reach_m), Vector3.ONE * (2.0 * reach_m))
	return mesh
