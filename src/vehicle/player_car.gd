class_name PlayerCar
extends Node3D
## The player's car: controller -> physics at 120 Hz -> world transform. Spec: Car
## physics and feel; Architecture rules 5 and 8 (road space first, controller
## abstraction); Performance budget → Shadows (blob shadow). docs/CONTRACTS.md §2, §4.
##
##   var car := PLAYER_CAR_SCENE.instantiate() as PlayerCar
##   add_child(car)
##   car.setup(ctx, road, origin, car_def)
##   car.place_at(0.0, road.lane_center_d(1, 0.0), Units.kmh_to_mps(100.0))
##   car.controller = PlayerController.new(...)    # swappable between ticks
##
## Per physics tick (_physics_process, or the owner calls tick(dt) when self_tick is
## off so run.gd can keep the contract's tick order):
##   1. controller.update(dt, state, input)   (null controller = zero input: coasting)
##   2. VehiclePhysics.step(state, input, dt, params, road)
##   3. place the node from road space: RoadSample.local_point(d) relative to the
##      floating origin (the flat cross-section puts the surface at the reference
##      height), yaw = godot_yaw(state.yaw), pitch = VehiclePhysics.surface_pitch
##   4. CarVisual.tick (roll, pitch, wheels, lights; visual only) and the blob shadow.
## Physics interpolation smooths rendering between ticks. On Events.origin_shifted the
## car re-places itself and calls reset_physics_interpolation().
## The tick path allocates nothing (no arrays, strings or objects; Vector3/Basis are
## values).

const BLOB_SHADOW_SCENE := preload("res://src/vehicle/blob_shadow.tscn")

## Tick from _physics_process. Turn off when the owner calls tick() itself.
@export var self_tick: bool = true

## Owned simulation state; VehiclePhysics writes it.
var state := VehicleState.new()
var params: VehicleParams
## The last input written by the controller.
var input := VehicleInput.new()
## Swappable between ticks at runtime. The swap never touches `state`; the new
## controller gets on_attached(state) and the old one on_detached().
var controller: VehicleController:
	set(value):
		if value == controller:
			return
		if controller != null:
			controller.on_detached()
		controller = value
		if controller != null:
			controller.on_attached(state)
var car: CarDef
var road: RoadPath
var origin: FloatingOrigin
var model: CarModel
var visual: CarVisual
## False while a camera hides the body (cockpit). Effects that toggle the visual
## (the ghost flicker) respect it.
var body_visible: bool = true
var shadow: BlobShadow

var _sample := RoadSample.new()
var _placed := false


## Builds the physics params (VehicleParams.build, ~0.35 s) unless `prebuilt_params`
## is given, loads the car model (CarModel, stubbing missing convention nodes) under
## the CarVisual, applies the car's default paint, and places the car at s = 0, d = 0
## at rest (call place_at next).
func setup(ctx: RunContext, road_path: RoadPath, floating_origin: FloatingOrigin, car_def: CarDef,
		prebuilt_params: VehicleParams = null) -> void:
	car = car_def
	road = road_path
	origin = floating_origin
	params = prebuilt_params if prebuilt_params != null else VehicleParams.build(ctx.tuning, car_def)
	_ensure_children()
	if model != null and is_instance_valid(model.root):
		model.root.free()
	model = CarModel.load_model(car_def.model_scene_path, car_def)
	model.apply_paint(car_def.default_paint)
	visual.add_child(model.root)
	visual.bind(model, ctx.tuning.vehicle)
	if not Events.origin_shifted.is_connected(_on_origin_shifted):
		Events.origin_shifted.connect(_on_origin_shifted)
	place_at(0.0, 0.0, 0.0)


## Teleports the car to road coordinates at speed v along the lane (gearbox in the
## right gear, body settled) without interpolating from the old spot.
func place_at(s: float, d: float, v_mps: float) -> void:
	VehiclePhysics.place(state, params, s, d, v_mps)
	input.clear()
	_place()
	if visual != null:
		visual.reset()
	reset_physics_interpolation()


func _physics_process(delta: float) -> void:
	if self_tick:
		tick(delta)


## One 120 Hz tick: controller, physics, placement, visual. Allocation-free.
func tick(dt: float) -> void:
	if params == null or road == null:
		return
	if controller != null:
		controller.update(dt, state, input)
	else:
		input.clear()
	VehiclePhysics.step(state, input, dt, params, road)
	_place()
	visual.tick(dt, state, input)


## Render-space velocity (m/s) for the camera and audio: forward speed along the car's
## world heading plus the lateral slip velocity, climbing with the road grade.
func world_velocity() -> Vector3:
	var h := _sample.heading + state.yaw
	var fwd := Vector3(sin(h), 0.0, -cos(h))
	var right := Vector3(cos(h), 0.0, sin(h))
	var along := state.v * cos(state.yaw) - state.v_lat * sin(state.yaw)
	return fwd * state.v + right * state.v_lat + Vector3.UP * (along * _sample.grade)


## Shows or hides the drawn body (the CarVisual with the model, and the blob shadow),
## for the cockpit camera (CameraRig, plan D11). View only: physics, placement and the
## visual's tick carry on.
func set_body_visible(on: bool) -> void:
	body_visible = on
	if visual != null:
		visual.visible = on
	if shadow != null:
		shadow.visible = on


## The road sample at state.s used for the last placement. Read-only.
func road_sample() -> RoadSample:
	return _sample


func _place() -> void:
	if road == null:
		return
	road.sample_into(state.s, _sample)
	var ox := 0.0
	var oy := 0.0
	var oz := 0.0
	if origin != null:
		ox = origin.origin_x
		oy = origin.origin_y
		oz = origin.origin_z
	var b := Basis(Vector3.UP, _sample.godot_yaw(state.yaw)) \
		* Basis(Vector3.RIGHT, VehiclePhysics.surface_pitch(_sample))
	transform = Transform3D(b, _sample.local_point(state.d, ox, oy, oz))
	if shadow != null and car != null:
		shadow.place(_sample, state.d, state.yaw, car.length_m, car.width_m, origin)
	_placed = true


func _on_origin_shifted(_offset: Vector3) -> void:
	if not _placed:
		return
	_place()
	reset_physics_interpolation()


func _ensure_children() -> void:
	visual = get_node_or_null(^"CarVisual") as CarVisual
	if visual == null:
		visual = CarVisual.new()
		visual.name = "CarVisual"
		add_child(visual)
	shadow = get_node_or_null(^"BlobShadow") as BlobShadow
	if shadow == null:
		shadow = BLOB_SHADOW_SCENE.instantiate() as BlobShadow
		shadow.name = "BlobShadow"
		add_child(shadow)
	# The shadow is placed in render space (not relative to the car).
	shadow.top_level = true


func _exit_tree() -> void:
	if Events.origin_shifted.is_connected(_on_origin_shifted):
		Events.origin_shifted.disconnect(_on_origin_shifted)


func _enter_tree() -> void:
	if car != null and not Events.origin_shifted.is_connected(_on_origin_shifted):
		Events.origin_shifted.connect(_on_origin_shifted)
