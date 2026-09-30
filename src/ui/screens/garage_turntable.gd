class_name GarageTurntable
extends Control
## The garage's turntable (WP8.2): the car on a slowly turning disc, drawn under the live
## sky palette. Spec: Garage and progression ("The garage shows the car on a turntable
## with the current sky palette"); Car shader; Rendering budget (no lights, no PBR, the
## project's shaders only); Accessibility (reduced motion). docs/GARAGE.md → Turntable.
##
## A SubViewport with its own World3D (transparent, so the title's live attract drive
## shows behind it, under the garage's dim) holding a Camera3D, the car (CarModel with
## the look applied, draws merged like in a run) and a disc. No light nodes and no
## environment: the vehicle shader (the disc uses its trim slot) reads the `wb_*` shader
## globals the title's SkyRig writes at its held sky, so the car looks exactly as it does
## on the road at that hour. The viewport renders only while `active` (the garage open),
## at the canvas's physical resolution (capped); a drag spins the car (emulated mouse
## events, never a raw touch index). The disc spins at turntable_spin_deg_s, held still
## under reduced motion.

var tuning: ProgressionTuning
var viewport: SubViewport
var view: TextureRect
var camera: Camera3D
var pivot: Node3D
var disc: MeshInstance3D
var shadow: MeshInstance3D
## The car on the disc (null: nothing, e.g. a placeholder slot).
var model: CarModel
var car: CarDef
var look: CarLook
## Disc yaw (radians).
var yaw: float = 0.0
var active: bool = false
## Reduced motion: no idle spin (a drag still turns it).
var still: bool = false
## Car models built so far (tests: an unchanged look never rebuilds).
var builds: int = 0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	clip_contents = false
	viewport = SubViewport.new()
	viewport.name = "TurntableViewport"
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.handle_input_locally = false
	viewport.gui_disable_input = true
	viewport.audio_listener_enable_3d = false
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(viewport)
	view = TextureRect.new()
	view.name = "TurntableView"
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.stretch_mode = TextureRect.STRETCH_SCALE
	view.texture = viewport.get_texture()
	add_child(view)
	camera = Camera3D.new()
	camera.name = "TurntableCamera"
	viewport.add_child(camera)
	pivot = Node3D.new()
	pivot.name = "Pivot"
	viewport.add_child(pivot)
	disc = MeshInstance3D.new()
	disc.name = "Disc"
	disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pivot.add_child(disc)
	shadow = MeshInstance3D.new()
	shadow.name = "Shadow"
	shadow.mesh = BlobShadow.shared_mesh()
	shadow.material_override = BlobShadow.shared_material()
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shadow.visible = false
	pivot.add_child(shadow)


func setup(t: ProgressionTuning) -> void:
	tuning = t
	camera.fov = t.turntable_fov_deg
	camera.position = Vector3(0.0, t.turntable_camera_height_m, t.turntable_camera_distance_m)
	camera.look_at_from_position(camera.position, Vector3(0.0, t.turntable_look_height_m, 0.0), Vector3.UP)
	camera.near = CAMERA_NEAR_M
	camera.far = t.turntable_camera_distance_m * CAMERA_FAR_MULT
	disc.mesh = build_disc(t)
	reset_yaw()
	_resize()


## Shows `car_def` in `car_look` (paint and rims). Rebuilds the model only when the car or
## its rims change; a paint change recolours it in place.
func show_car(car_def: CarDef, car_look: CarLook) -> void:
	var lk := car_look if car_look != null else CarLook.factory(car_def)
	if model != null and car == car_def and look != null and lk.rim == look.rim:
		model.apply_paint(lk.paint)
		look = lk
		return
	_clear_model()
	car = car_def
	look = lk
	if car_def == null:
		return
	model = CarModel.load_model(car_def.model_scene_path, car_def)
	model.apply_rim(lk.rim)
	model.apply_paint(lk.paint)
	model.merge_draw_surfaces()
	pivot.add_child(model.root)
	builds += 1
	var margin := 1.0 + SHADOW_MARGIN
	shadow.transform = Transform3D(Basis.from_scale(Vector3(car_def.width_m * margin, 1.0, car_def.length_m * margin)),
			Vector3(0.0, SHADOW_LIFT_M, 0.0))
	shadow.visible = true


## An empty disc (a placeholder slot: no car yet).
func show_nothing() -> void:
	_clear_model()
	car = null
	look = null


func has_car() -> bool:
	return model != null


## Renders while on (the garage open); off draws nothing and costs nothing.
func set_active(on: bool) -> void:
	active = on
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	set_process(on)
	if on:
		_resize()


func reset_yaw() -> void:
	yaw = deg_to_rad(tuning.turntable_start_yaw_deg) if tuning != null else 0.0
	pivot.rotation.y = yaw


func _ready() -> void:
	set_process(active)


func _process(delta: float) -> void:
	if not active or still or tuning == null:
		return
	yaw = wrapf(yaw + deg_to_rad(tuning.turntable_spin_deg_s) * delta, -PI, PI)
	pivot.rotation.y = yaw


func _gui_input(event: InputEvent) -> void:
	var mm := event as InputEventMouseMotion
	if mm != null and (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0 and tuning != null:
		yaw = wrapf(yaw + deg_to_rad(tuning.turntable_drag_deg_per_px) * mm.relative.x, -PI, PI)
		pivot.rotation.y = yaw
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_resize()


## The viewport at the canvas's physical pixel size (capped at turntable_max_pixel_scale).
func _resize() -> void:
	view.position = Vector2.ZERO
	view.size = size
	var k := 1.0
	if is_inside_tree():
		k = clampf(get_global_transform_with_canvas().get_scale().x * get_tree().root.get_final_transform().get_scale().x,
				1.0, tuning.turntable_max_pixel_scale if tuning != null else 1.0)
	var px := Vector2i(maxi(roundi(size.x * k), 1), maxi(roundi(size.y * k), 1))
	if viewport.size != px:
		viewport.size = px


func _clear_model() -> void:
	if model != null and is_instance_valid(model.root):
		model.root.free()
	model = null
	shadow.visible = false


## The disc: a flat-shaded cylinder (top at y = 0, the car's ground) with a lighter ring
## near its edge, in the vehicle shader's trim slot (vertex colours, lit by the sky's sun).
static func build_disc(t: ProgressionTuning) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := maxi(t.turntable_disc_segments, 3)
	var r := t.turntable_disc_radius_m
	var ri := r * t.turntable_ring_frac
	var h := t.turntable_disc_height_m
	for k in n:
		var a0 := TAU * float(k) / float(n)
		var a1 := TAU * float(k + 1) / float(n)
		var i0 := Vector3(sin(a0) * ri, 0.0, cos(a0) * ri)
		var i1 := Vector3(sin(a1) * ri, 0.0, cos(a1) * ri)
		var o0 := Vector3(sin(a0) * r, 0.0, cos(a0) * r)
		var o1 := Vector3(sin(a1) * r, 0.0, cos(a1) * r)
		_tri(st, Vector3.ZERO, i0, i1, Vector3.UP, t.turntable_disc_color)
		_tri(st, i0, o0, o1, Vector3.UP, t.turntable_ring_color)
		_tri(st, i0, o1, i1, Vector3.UP, t.turntable_ring_color)
		var side := Vector3(sin((a0 + a1) * 0.5), 0.0, cos((a0 + a1) * 0.5))
		var d := Vector3(0.0, -h, 0.0)
		_tri(st, o0, o0 + d, o1 + d, side, t.turntable_disc_color)
		_tri(st, o0, o1 + d, o1, side, t.turntable_disc_color)
	var mesh := ArrayMesh.new()
	st.commit(mesh)
	mesh.surface_set_material(0, CarModel.slot_material(CarModel.Slot.TRIM))
	return mesh


## One flat triangle; a, b, c run counter-clockwise seen from its front, so they are
## emitted a, c, b (Godot's front faces wind clockwise).
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, n: Vector3, col: Color) -> void:
	for p: Vector3 in [a, c, b]:
		st.set_normal(n)
		st.set_color(col)
		st.add_vertex(p)


const CAMERA_NEAR_M := 0.1   # lint: allow-number camera clip plane
const CAMERA_FAR_MULT := 4.0   # lint: allow-number camera clip plane
## The blob shadow: lift over the disc (m) and its margin around the body (the run's).
const SHADOW_LIFT_M := 0.02   # lint: allow-number depth offset
const SHADOW_MARGIN := 0.18   # lint: allow-number matches BlobShadow.margin_frac
