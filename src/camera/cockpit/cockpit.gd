class_name Cockpit
extends Node3D
## Generic procedural cockpit around the driver's-eye camera. Plan deviation D11
## (WP4.7, owner request); spec: Cameras (cockpit mode), Cars → Modular car convention
## (Interior with a SteeringWheel that rotates with steer, Markers/cam_cockpit),
## Performance budget (vertex-lit, no lights, no shadows, few draw calls), World →
## Night lighting (the gauges glow on the color script's headlight ramp). Placeholder
## until the cars have real interiors (ART5). docs/COCKPIT.md.
##
## Built in the seat frame: origin at the driver's eye, -Z forward, +X right, +Y up
## (the car's axes). CameraRig parents it under its own node, which carries the rigid
## seat pose in cockpit mode; the Camera3D (a sibling) carries only the head (look
## direction, head sway, shake). So the cockpit moves exactly with the car and the
## view, and physics interpolation interpolates it with the same parent transform.
##
## Three draw calls:
##   Interior        dash, binnacle shell, hood-coloured cowl, A-pillars, header and
##                   roof liner, door tops, rear-view mirror frame with a static
##                   gradient "glass" (cockpit.gdshader: the shared world lighting
##                   include plus a sky fill, so it follows the color script)
##   SteeringWheel   rim, spokes and hub (same material) on a pivot tilted along the
##                   column; turns with VehicleState.steer_angle x the steering ratio
##   Gauges          one quad (cockpit_gauges.gdshader): speedometer and tachometer
##                   drawn in the fragment shader from two uniforms
## Faces are flat shaded (a vertex per face corner). Static faces are wound toward the
## eye, so the back-face cull keeps only the sides the driver can see.
##
## Geometry numbers below are art proportions (like CarModel's stub constants), in
## meters relative to the eye or as fractions of the CarDef body width. Camera numbers
## (eye position, sway, gauge full scale) live in CameraTuning.

const INTERIOR_SHADER := preload("res://src/camera/cockpit/cockpit.gdshader")
const GAUGE_SHADER := preload("res://src/camera/cockpit/cockpit_gauges.gdshader")

## Cabin half-widths as fractions of the body width: at the dash / doors, at the
## windscreen base, at the roof header.
const CABIN_HALF_FRAC := 0.44
const SCREEN_BASE_HALF_FRAC := 0.41
const ROOF_HALF_FRAC := 0.37
## Dash profile (y, z from the eye), from the windscreen base toward the driver: the
## top surface, a chamfered lip, the upper face, and the lower face sloping back to the
## knees. The crown lifts the top toward the centre (low-poly facets).
const DASH_BASE := Vector2(-0.29, -1.02)
const DASH_TOP_NEAR := Vector2(-0.235, -0.66)
const DASH_LIP := Vector2(-0.255, -0.615)
const DASH_FACE_LOW := Vector2(-0.35, -0.605)
const DASH_KNEE := Vector2(-0.49, -0.46)
const DASH_CROWN_M := 0.012
## Centre-stack screen on the dash face (x on the car's centreline): half-width, top and
## bottom y, and how far it stands proud of the face. Glows on the headlight ramp.
const STACK_HALF_WIDTH_M := 0.09
const STACK_TOP_Y := -0.275
const STACK_BOTTOM_Y := -0.335
const STACK_PROUD_M := 0.008
## Wiper cowl (dark strip at the windscreen base) and the hood (paint), y and z.
const COWL_FRONT := Vector2(-0.31, -1.14)
const HOOD_REAR := Vector2(-0.31, -1.12)
const HOOD_FRONT := Vector2(-0.41, -1.95)
## Hood: centre crease half-width and the drop of the outer edges; its half-width as a
## fraction of the windscreen base.
const HOOD_CREASE_HALF_M := 0.22
const HOOD_EDGE_DROP_M := 0.05
const HOOD_HALF_FRAC := 0.96
## Windscreen top (the header's lower edge, y and z) and the roof liner's back edge.
const HEADER_EDGE := Vector2(0.28, -0.52)
const HEADER_TRIM_M := 0.035
const LINER_BACK := Vector2(0.305, 0.12)
## A-pillar cross-section (m): across the glass, and depth.
const PILLAR_WIDTH_M := 0.06
const PILLAR_DEPTH_M := 0.055
## Door tops: belt line height, sill width, the inner panel's bottom, rear end.
const BELT_Y := -0.28
const SILL_WIDTH_M := 0.09
const DOOR_BOTTOM_Y := -0.7
const DOOR_BACK_Z := 0.35
## Rear-view mirror: centre (y, z; x on the car's centreline), size, frame depth,
## glass inset, stem top.
const MIRROR_CENTER := Vector2(0.175, -0.52)
const MIRROR_SIZE := Vector2(0.19, 0.058)
const MIRROR_DEPTH_M := 0.03
const MIRROR_INSET_M := 0.012
const MIRROR_STEM_WIDTH_M := 0.022
## Binnacle (in front of the driver, x = 0): visor, face (the gauge quad) and cheeks.
const BINNACLE_HALF_WIDTH_M := 0.155
const VISOR_FRONT := Vector2(-0.116, -0.665)
const VISOR_BACK := Vector2(-0.128, -0.79)
const VISOR_LIP_M := 0.01
const GAUGE_BOTTOM := Vector2(-0.248, -0.705)
const GAUGE_TOP := Vector2(-0.142, -0.725)
const GAUGE_HALF_WIDTH_M := 0.14
## Steering wheel: centre (y, z; x = 0), column tilt (rad, face toward the driver
## and up), rim radius and tube radius, hub radius, spoke width, mesh resolution,
## the accent stripe's half-angle at 12 o'clock.
const WHEEL_CENTER := Vector2(-0.42, -0.5)
const WHEEL_TILT_RAD := 0.35
const WHEEL_RADIUS_M := 0.185
const WHEEL_TUBE_M := 0.019
const WHEEL_HUB_M := 0.055
const WHEEL_SPOKE_WIDTH_M := 0.05
const WHEEL_SEGMENTS := 28
const WHEEL_SIDES := 6
const WHEEL_STRIPE_HALF_RAD := 0.12
## Colors (sRGB, like every world mesh's vertex COLOR): a dark neutral interior.
const COL_DASH_TOP := Color(0.3, 0.3, 0.31)
const COL_DASH_FACE := Color(0.22, 0.22, 0.24)
const COL_TRIM := Color(0.24, 0.24, 0.26)
const COL_LINER := Color(0.55, 0.53, 0.5)
const COL_DOOR := Color(0.25, 0.25, 0.27)
const COL_DOOR_TOP := Color(0.34, 0.34, 0.35)
const COL_BINNACLE := Color(0.16, 0.16, 0.18)
const COL_COWL := Color(0.08, 0.08, 0.09)
const COL_WHEEL := Color(0.12, 0.12, 0.13)
const COL_ACCENT := Color(0.9, 0.5, 0.16)
const COL_MIRROR_TOP := Color(0.42, 0.47, 0.56)
const COL_MIRROR_BOTTOM := Color(0.2, 0.2, 0.22)
const COL_DASH_LOW := Color(0.3, 0.3, 0.32)
const COL_STACK := Color(0.1, 0.17, 0.26)
## World emissive class for the centre-stack screen (UV2.x; world_common: 3 = vehicle
## light, on the headlight ramp).
const EMISSIVE_VEHICLE := 3.0

var interior: MeshInstance3D
## The steering wheel pivot (at the wheel centre, local +Z along the column toward the
## driver) and the rim node that turns about it.
var steering_pivot: Node3D
var steering_wheel: MeshInstance3D
var gauges: MeshInstance3D
var gauge_material: ShaderMaterial

var _wheel_ratio: float = 0.0
var _speedo_max_mps: float = 1.0
var _tach_max_rpm: float = 1.0
var _wheel_angle: float = 0.0
var _speed_frac: float = 0.0
var _rpm_frac: float = 0.0


## Gauge and wheel scales: the steering ratio (wheel turn per road-wheel angle), the
## speedometer and tachometer full scale, and where the tachometer's red band starts.
func configure(wheel_ratio: float, speedo_max_mps: float, tach_max_rpm: float, redline_rpm: float) -> void:
	_wheel_ratio = wheel_ratio
	_speedo_max_mps = maxf(speedo_max_mps, 1.0)
	_tach_max_rpm = maxf(tach_max_rpm, 1.0)
	_ensure_nodes()
	gauge_material.set_shader_parameter(&"redline_frac", clampf(redline_rpm / _tach_max_rpm, 0.0, 1.0))
	gauge_material.set_shader_parameter(&"speed_frac", _speed_frac)
	gauge_material.set_shader_parameter(&"rpm_frac", _rpm_frac)


## (Re)builds the meshes for a driver's eye at `eye` (car frame: origin on the ground
## between the axles, -Z forward) in a body `body_size` (width, height, length), with
## the hood in `paint` (sRGB). Load time; allocates.
func build(eye: Vector3, body_size: Vector3, paint: Color) -> void:
	_ensure_nodes()
	interior.mesh = _build_interior(eye, body_size.x, paint)
	var pivot := Transform3D(Basis(Vector3.RIGHT, -WHEEL_TILT_RAD), Vector3(0.0, WHEEL_CENTER.x, WHEEL_CENTER.y))
	steering_pivot.transform = pivot
	steering_wheel.mesh = _build_wheel()
	gauges.mesh = _build_gauges()
	_apply_wheel()
	reset_physics_interpolation()


## Per physics tick (from CameraRig): the wheel follows the steer angle, the needles
## follow the speed and rpm. Allocation-free.
func update_from(steer_angle: float, speed_mps: float, rpm: float) -> void:
	_wheel_angle = steer_angle * _wheel_ratio
	_apply_wheel()
	var sf := clampf(speed_mps / _speedo_max_mps, 0.0, 1.0)
	var rf := clampf(rpm / _tach_max_rpm, 0.0, 1.0)
	if sf != _speed_frac:
		_speed_frac = sf
		gauge_material.set_shader_parameter(&"speed_frac", sf)
	if rf != _rpm_frac:
		_rpm_frac = rf
		gauge_material.set_shader_parameter(&"rpm_frac", rf)


## Current steering wheel turn (rad, + clockwise as the driver sees it = steering right).
func wheel_angle_rad() -> float:
	return _wheel_angle


func speed_frac() -> float:
	return _speed_frac


func rpm_frac() -> float:
	return _rpm_frac


## Surfaces the cockpit draws (one draw call each).
func draw_surface_count() -> int:
	var n := 0
	for mi: MeshInstance3D in [interior, steering_wheel, gauges]:
		if mi != null and mi.mesh != null:
			n += mi.mesh.get_surface_count()
	return n


func _apply_wheel() -> void:
	if steering_wheel != null:
		# Seen from the driver (looking along the column, -Z), steering right turns clockwise.
		steering_wheel.transform = Transform3D(Basis(Vector3.BACK, -_wheel_angle), Vector3.ZERO)


func _ensure_nodes() -> void:
	if interior != null:
		return
	var lit := ShaderMaterial.new()
	lit.shader = INTERIOR_SHADER
	interior = _mesh_node("Interior", lit)
	add_child(interior)
	steering_pivot = Node3D.new()
	steering_pivot.name = "SteeringPivot"
	add_child(steering_pivot)
	steering_wheel = _mesh_node("SteeringWheel", lit)
	steering_pivot.add_child(steering_wheel)
	gauge_material = ShaderMaterial.new()
	gauge_material.shader = GAUGE_SHADER
	gauges = _mesh_node("Gauges", gauge_material)
	add_child(gauges)


static func _mesh_node(node_name: String, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	return mi


# ---------------------------------------------------------------- Interior

func _build_interior(eye: Vector3, width_m: float, paint: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Seat frame: x relative to the eye; the car's centreline is at cx.
	var cx := -eye.x
	var cabin := width_m * CABIN_HALF_FRAC
	var screen := width_m * SCREEN_BASE_HALF_FRAC
	var roof := width_m * ROOF_HALF_FRAC

	# Dash top: four facets across, crowned toward the centre (low-poly look).
	var xs: Array[float] = [-cabin, -cabin * 0.5, 0.0, cabin * 0.5, cabin]
	for j in xs.size() - 1:
		var x0 := xs[j]
		var x1 := xs[j + 1]
		var c0 := _crown(x0, cabin)
		var c1 := _crown(x1, cabin)
		_face(st, [
			Vector3(cx + x0, DASH_TOP_NEAR.x + c0, DASH_TOP_NEAR.y), Vector3(cx + x1, DASH_TOP_NEAR.x + c1, DASH_TOP_NEAR.y),
			Vector3(cx + x1, DASH_BASE.x + c1, DASH_BASE.y), Vector3(cx + x0, DASH_BASE.x + c0, DASH_BASE.y),
		], COL_DASH_TOP)
		_face(st, [
			Vector3(cx + x0, DASH_LIP.x + c0, DASH_LIP.y), Vector3(cx + x1, DASH_LIP.x + c1, DASH_LIP.y),
			Vector3(cx + x1, DASH_TOP_NEAR.x + c1, DASH_TOP_NEAR.y), Vector3(cx + x0, DASH_TOP_NEAR.x + c0, DASH_TOP_NEAR.y),
		], COL_DOOR_TOP)
		# Dash face toward the driver, below the lip, then the knee panel.
		_face(st, [
			Vector3(cx + x0, DASH_LIP.x + c0, DASH_LIP.y), Vector3(cx + x1, DASH_LIP.x + c1, DASH_LIP.y),
			Vector3(cx + x1, DASH_FACE_LOW.x, DASH_FACE_LOW.y), Vector3(cx + x0, DASH_FACE_LOW.x, DASH_FACE_LOW.y),
		], COL_DASH_FACE)
		_face(st, [
			Vector3(cx + x0, DASH_FACE_LOW.x, DASH_FACE_LOW.y), Vector3(cx + x1, DASH_FACE_LOW.x, DASH_FACE_LOW.y),
			Vector3(cx + x1, DASH_KNEE.x, DASH_KNEE.y), Vector3(cx + x0, DASH_KNEE.x, DASH_KNEE.y),
		], COL_DASH_LOW)
	# Centre-stack screen.
	var sz := lerpf(DASH_LIP.y, DASH_FACE_LOW.y, 0.5) + STACK_PROUD_M
	_face(st, [
		Vector3(cx - STACK_HALF_WIDTH_M, STACK_BOTTOM_Y, sz), Vector3(cx + STACK_HALF_WIDTH_M, STACK_BOTTOM_Y, sz),
		Vector3(cx + STACK_HALF_WIDTH_M, STACK_TOP_Y, sz), Vector3(cx - STACK_HALF_WIDTH_M, STACK_TOP_Y, sz),
	], COL_STACK, EMISSIVE_VEHICLE)

	# Wiper cowl and hood (paint) beyond the windscreen base.
	_face(st, [
		Vector3(cx - screen, DASH_BASE.x, DASH_BASE.y), Vector3(cx + screen, DASH_BASE.x, DASH_BASE.y),
		Vector3(cx + screen, COWL_FRONT.x, COWL_FRONT.y), Vector3(cx - screen, COWL_FRONT.x, COWL_FRONT.y),
	], COL_COWL)
	var hood := screen * HOOD_HALF_FRAC
	var hx: Array[float] = [-hood, -HOOD_CREASE_HALF_M, HOOD_CREASE_HALF_M, hood]
	var drop: Array[float] = [HOOD_EDGE_DROP_M, 0.0, 0.0, HOOD_EDGE_DROP_M]
	for j in hx.size() - 1:
		_face(st, [
			Vector3(cx + hx[j], HOOD_REAR.x - drop[j], HOOD_REAR.y),
			Vector3(cx + hx[j + 1], HOOD_REAR.x - drop[j + 1], HOOD_REAR.y),
			Vector3(cx + hx[j + 1], HOOD_FRONT.x - drop[j + 1], HOOD_FRONT.y),
			Vector3(cx + hx[j], HOOD_FRONT.x - drop[j], HOOD_FRONT.y),
		], paint)

	# A-pillars: windscreen base corners up to the header corners.
	for side: float in [-1.0, 1.0]:
		var base := Vector3(cx + side * screen, DASH_BASE.x, DASH_BASE.y)
		var top := Vector3(cx + side * roof, HEADER_EDGE.x, HEADER_EDGE.y)
		_beam(st, base, top, Vector3(-side, 0.0, 0.0), PILLAR_WIDTH_M, PILLAR_DEPTH_M, COL_TRIM)

	# Header trim (windscreen top) and roof liner.
	_face(st, [
		Vector3(cx - roof, HEADER_EDGE.x - HEADER_TRIM_M, HEADER_EDGE.y), Vector3(cx + roof, HEADER_EDGE.x - HEADER_TRIM_M, HEADER_EDGE.y),
		Vector3(cx + roof, HEADER_EDGE.x, HEADER_EDGE.y), Vector3(cx - roof, HEADER_EDGE.x, HEADER_EDGE.y),
	], COL_TRIM)
	_face(st, [
		Vector3(cx - roof, HEADER_EDGE.x, HEADER_EDGE.y), Vector3(cx + roof, HEADER_EDGE.x, HEADER_EDGE.y),
		Vector3(cx + roof, LINER_BACK.x, LINER_BACK.y), Vector3(cx - roof, LINER_BACK.x, LINER_BACK.y),
	], COL_LINER)

	# Door tops (belt line) and inner door panels.
	for side: float in [-1.0, 1.0]:
		var inner := cx + side * cabin
		var outer := cx + side * (cabin + SILL_WIDTH_M)
		_face(st, [
			Vector3(inner, BELT_Y, DASH_BASE.y), Vector3(outer, BELT_Y, DASH_BASE.y),
			Vector3(outer, BELT_Y, DOOR_BACK_Z), Vector3(inner, BELT_Y, DOOR_BACK_Z),
		], COL_DOOR_TOP)
		_face(st, [
			Vector3(inner, BELT_Y, DASH_BASE.y), Vector3(inner, BELT_Y, DOOR_BACK_Z),
			Vector3(inner, DOOR_BOTTOM_Y, DOOR_BACK_Z), Vector3(inner, DOOR_BOTTOM_Y, DASH_BASE.y),
		], COL_DOOR)

	_binnacle_shell(st)
	_mirror(st, Vector3(cx, MIRROR_CENTER.x, MIRROR_CENTER.y))

	var mesh := ArrayMesh.new()
	st.commit(mesh)
	return mesh


static func _crown(x: float, half: float) -> float:
	return DASH_CROWN_M * (1.0 - absf(x) / half)


## Visor over the gauges and its side cheeks down to the dash top (x = 0: the driver).
func _binnacle_shell(st: SurfaceTool) -> void:
	var w := BINNACLE_HALF_WIDTH_M
	var lip := VISOR_FRONT.x - VISOR_LIP_M
	_face(st, [
		Vector3(-w, VISOR_FRONT.x, VISOR_FRONT.y), Vector3(w, VISOR_FRONT.x, VISOR_FRONT.y),
		Vector3(w, VISOR_BACK.x, VISOR_BACK.y), Vector3(-w, VISOR_BACK.x, VISOR_BACK.y),
	], COL_BINNACLE)
	_face(st, [
		Vector3(-w, lip, VISOR_FRONT.y), Vector3(w, lip, VISOR_FRONT.y),
		Vector3(w, VISOR_FRONT.x, VISOR_FRONT.y), Vector3(-w, VISOR_FRONT.x, VISOR_FRONT.y),
	], COL_BINNACLE)
	for side: float in [-1.0, 1.0]:
		_face(st, [
			Vector3(side * w, VISOR_FRONT.x, VISOR_FRONT.y), Vector3(side * w, VISOR_BACK.x, VISOR_BACK.y),
			Vector3(side * w, DASH_LIP.x, VISOR_BACK.y), Vector3(side * w, DASH_LIP.x, VISOR_FRONT.y),
		], COL_BINNACLE)
	# Back plate behind the gauge quad (seen around its edges).
	_face(st, [
		Vector3(-w, DASH_LIP.x, VISOR_BACK.y), Vector3(w, DASH_LIP.x, VISOR_BACK.y),
		Vector3(w, VISOR_BACK.x, VISOR_BACK.y), Vector3(-w, VISOR_BACK.x, VISOR_BACK.y),
	], COL_BINNACLE)


## Frame box turned to face the eye, a gradient "glass" (no render-to-texture), and a
## stem up to the header.
func _mirror(st: SurfaceTool, center: Vector3) -> void:
	var facing := Vector3(-center.x, 0.0, -center.z).normalized()
	var right := Vector3.UP.cross(facing).normalized()
	var up := Vector3.UP
	var hx := MIRROR_SIZE.x * 0.5
	var hy := MIRROR_SIZE.y * 0.5
	var back := -facing * MIRROR_DEPTH_M
	var corners: Array[Vector3] = [
		center - right * hx - up * hy, center + right * hx - up * hy,
		center + right * hx + up * hy, center - right * hx + up * hy,
	]
	_face(st, corners, COL_TRIM)
	for i in 4:
		var a := corners[i]
		var b := corners[(i + 1) % 4]
		_face(st, [a, b, b + back, a + back], COL_TRIM)
	# Glass, just proud of the frame toward the driver: sky-ish top, road-ish bottom.
	var gx := hx - MIRROR_INSET_M
	var gy := hy - MIRROR_INSET_M
	var g := center + facing * (MIRROR_INSET_M * 0.5)
	_face_colors(st, [g - right * gx - up * gy, g + right * gx - up * gy, g + right * gx + up * gy, g - right * gx + up * gy],
		[COL_MIRROR_BOTTOM, COL_MIRROR_BOTTOM, COL_MIRROR_TOP, COL_MIRROR_TOP])
	var stem_top := Vector3(center.x, HEADER_EDGE.x, center.z + MIRROR_DEPTH_M)
	_beam(st, center + up * hy + back * 0.5, stem_top, right, MIRROR_STEM_WIDTH_M, MIRROR_STEM_WIDTH_M, COL_TRIM)


# ---------------------------------------------------------------- Steering wheel

## Rim (a low-poly torus in the pivot's XY plane, accent stripe at 12 o'clock), three
## spokes (9, 3 and 6 o'clock) and the hub. Faces wound outward (the wheel turns).
func _build_wheel() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ring: Array[PackedVector3Array] = []
	var centers: Array[Vector3] = []
	for i in WHEEL_SEGMENTS:
		# Offset half a segment so segment 0 is centred on 12 o'clock (the stripe).
		var a := TAU * (float(i) - 0.5) / float(WHEEL_SEGMENTS)
		var radial := Vector3(sin(a), cos(a), 0.0)
		var c := radial * WHEEL_RADIUS_M
		centers.append(c)
		var pts := PackedVector3Array()
		for k in WHEEL_SIDES:
			var b := TAU * float(k) / float(WHEEL_SIDES)
			pts.append(c + (radial * cos(b) + Vector3.BACK * sin(b)) * WHEEL_TUBE_M)
		ring.append(pts)
	for i in WHEEL_SEGMENTS:
		var i1 := (i + 1) % WHEEL_SEGMENTS
		var mid_a := TAU * float(i) / float(WHEEL_SEGMENTS)
		var col := COL_ACCENT if absf(wrapf(mid_a, -PI, PI)) <= WHEEL_STRIPE_HALF_RAD else COL_WHEEL
		for k in WHEEL_SIDES:
			var k1 := (k + 1) % WHEEL_SIDES
			var quad: Array[Vector3] = [ring[i][k], ring[i1][k], ring[i1][k1], ring[i][k1]]
			var mid := (quad[0] + quad[1] + quad[2] + quad[3]) * 0.25
			var tube_center := (centers[i] + centers[i1]) * 0.5
			_face_toward(st, quad, col, mid - tube_center)
	# Spokes: flat bars from the hub to the rim.
	for dir: Vector3 in [Vector3.LEFT, Vector3.RIGHT, Vector3.DOWN]:
		var across := Vector3.BACK.cross(dir)
		_bar(st, dir * WHEEL_HUB_M * 0.8, dir * (WHEEL_RADIUS_M - WHEEL_TUBE_M * 0.5),
			across * WHEEL_SPOKE_WIDTH_M * 0.5, Vector3.BACK * WHEEL_TUBE_M * 0.5, COL_WHEEL)
	# Hub: a flat octagonal boss facing the driver.
	var hub: Array[Vector3] = []
	for k in 8:
		var a := TAU * (float(k) + 0.5) / 8.0
		hub.append(Vector3(sin(a), cos(a), 0.0) * WHEEL_HUB_M + Vector3.BACK * WHEEL_TUBE_M)
	_face_toward(st, hub, COL_WHEEL, Vector3.BACK)
	var mesh := ArrayMesh.new()
	st.commit(mesh)
	return mesh


## A box bar from `a` to `b` with half-extents `half_across` and `half_depth`, faces
## wound outward.
static func _bar(st: SurfaceTool, a: Vector3, b: Vector3, half_across: Vector3, half_depth: Vector3, col: Color) -> void:
	var c := (a + b) * 0.5
	var corners: Array[Vector3] = [-half_across - half_depth, half_across - half_depth,
		half_across + half_depth, -half_across + half_depth]
	for i in 4:
		var p := corners[i]
		var q := corners[(i + 1) % 4]
		_face_toward(st, [a + p, b + p, b + q, a + q], col, (p + q) * 0.5)
	_face_toward(st, [a + corners[0], a + corners[1], a + corners[2], a + corners[3]], col, a - c)
	_face_toward(st, [b + corners[0], b + corners[1], b + corners[2], b + corners[3]], col, b - c)


# ---------------------------------------------------------------- Gauges

## One quad facing the driver under the binnacle visor. UV: u left -> right, v top ->
## bottom; the shader draws the speedometer in the left half, the tachometer right.
func _build_gauges() -> ArrayMesh:
	var w := GAUGE_HALF_WIDTH_M
	var bot_l := Vector3(-w, GAUGE_BOTTOM.x, GAUGE_BOTTOM.y)
	var bot_r := Vector3(w, GAUGE_BOTTOM.x, GAUGE_BOTTOM.y)
	var top_r := Vector3(w, GAUGE_TOP.x, GAUGE_TOP.y)
	var top_l := Vector3(-w, GAUGE_TOP.x, GAUGE_TOP.y)
	var n := (bot_r - bot_l).cross(top_l - bot_l).normalized()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Clockwise seen from the driver (Godot's front face).
	for v: Array in [[bot_l, Vector2(0.0, 1.0)], [top_l, Vector2(0.0, 0.0)], [top_r, Vector2(1.0, 0.0)],
			[bot_l, Vector2(0.0, 1.0)], [top_r, Vector2(1.0, 0.0)], [bot_r, Vector2(1.0, 1.0)]]:
		st.set_normal(n)
		st.set_color(Color.WHITE)
		st.set_uv(v[1])
		st.add_vertex(v[0])
	var mesh := ArrayMesh.new()
	st.commit(mesh)
	var height := (top_l - bot_l).length()
	gauge_material.set_shader_parameter(&"aspect", (bot_r - bot_l).length() / height)
	return mesh


# ---------------------------------------------------------------- Mesh helpers

## One flat-shaded polygon (3+ corners, convex, in order), wound so it faces the eye.
## `emissive`: the world emissive class (UV2.x).
static func _face(st: SurfaceTool, pts: Array[Vector3], col: Color, emissive: float = 0.0) -> void:
	var c := Vector3.ZERO
	for p in pts:
		c += p
	c /= float(pts.size())
	_face_toward(st, pts, col, -c, emissive)


## Same with a color per corner.
static func _face_colors(st: SurfaceTool, pts: Array[Vector3], cols: Array[Color]) -> void:
	var c := Vector3.ZERO
	for p in pts:
		c += p
	c /= float(pts.size())
	_emit(st, pts, cols, -c)


## One flat-shaded polygon wound so its normal has a positive component along `toward`.
static func _face_toward(st: SurfaceTool, pts: Array[Vector3], col: Color, toward: Vector3,
		emissive: float = 0.0) -> void:
	var cols: Array[Color] = []
	cols.resize(pts.size())
	cols.fill(col)
	_emit(st, pts, cols, toward, emissive)


static func _emit(st: SurfaceTool, pts: Array[Vector3], cols: Array[Color], toward: Vector3,
		emissive: float = 0.0) -> void:
	var n := (pts[1] - pts[0]).cross(pts[2] - pts[0])
	var order := range(pts.size())
	if n.dot(toward) < 0.0:
		order.reverse()
		n = -n
	n = n.normalized()
	# Counter-clockwise seen from the front -> Godot's clockwise triangles (a, c, b).
	for i in range(1, pts.size() - 1):
		for k: int in [order[0], order[i + 1], order[i]]:
			st.set_normal(n)
			st.set_color(cols[k])
			st.set_uv2(Vector2(emissive, 0.0))
			st.add_vertex(pts[k])


## A box beam from `a` to `b`: `across_hint` sets its width direction (made
## perpendicular to the beam), depth is perpendicular to both. Faces face the eye.
static func _beam(st: SurfaceTool, a: Vector3, b: Vector3, across_hint: Vector3, width: float, depth: float, col: Color) -> void:
	var axis := (b - a).normalized()
	var across := (across_hint - axis * across_hint.dot(axis)).normalized() * (width * 0.5)
	var deep := axis.cross(across).normalized() * (depth * 0.5)
	var corners: Array[Vector3] = [-across - deep, across - deep, across + deep, -across + deep]
	for i in 4:
		var p := corners[i]
		var q := corners[(i + 1) % 4]
		_face(st, [a + p, b + p, b + q, a + q], col)
