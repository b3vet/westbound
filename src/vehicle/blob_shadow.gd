class_name BlobShadow
extends MeshInstance3D
## Blob shadow under one vehicle (spec: Performance budget → Shadows; no shadow maps).
## A soft rounded-rectangle quad on the road surface, sized from the vehicle footprint
## and following the road's elevation and grade. The owner (player car, crash car,
## dev scenes) calls place() every frame after moving the vehicle, so floating-origin
## shifts need no extra handling here. For traffic use BlobShadowMulti (one draw call
## for every shadow).
##
##   shadow.place(sample, d, yaw, length_m, width_m, origin)

const SHADER: Shader = preload("res://assets/shaders/blob_shadow.gdshader")

## Height above the road surface (keeps it off the asphalt in the depth buffer).
@export var lift_m: float = 0.04
## Extra footprint around the body, as a fraction of its length and width.
@export var margin_frac: float = 0.18

static var _shared_mesh: PlaneMesh
static var _shared_material: ShaderMaterial


func _ready() -> void:
	if mesh == null:
		mesh = shared_mesh()
	if material_override == null:
		material_override = shared_material()
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED


## Places the shadow under a vehicle at road coordinates (s of `sample`, d) with a
## right-positive relative yaw, sized from its body length and width.
func place(sample: RoadSample, d: float, yaw: float, length_m: float, width_m: float,
		floating_origin: FloatingOrigin = null) -> void:
	transform = shadow_transform(sample, d, yaw, length_m, width_m, floating_origin, lift_m, margin_frac)


## Transform of a unit shadow quad (PlaneMesh 1 x 1, facing up) under a vehicle.
## Position in 64-bit relative to the floating origin (none = absolute).
## Allocation-free; shared with BlobShadowMulti.
static func shadow_transform(sample: RoadSample, d: float, yaw: float, length_m: float,
		width_m: float, floating_origin: FloatingOrigin, lift: float, margin: float) -> Transform3D:
	var ox := 0.0
	var oy := 0.0
	var oz := 0.0
	if floating_origin != null:
		ox = floating_origin.origin_x
		oy = floating_origin.origin_y
		oz = floating_origin.origin_z
	var up := sample.up
	# Right-positive yaw turns the nose right: a negative rotation about up in Godot.
	var x := sample.right.rotated(up, -yaw) * (width_m * (1.0 + margin))
	var z := (-sample.tangent).rotated(up, -yaw) * (length_m * (1.0 + margin))
	var p := sample.local_point(d, ox, oy, oz) + up * lift
	return Transform3D(Basis(x, up, z), p)


static func shared_mesh() -> PlaneMesh:
	if _shared_mesh == null:
		_shared_mesh = PlaneMesh.new()
		_shared_mesh.size = Vector2.ONE
	return _shared_mesh


static func shared_material() -> ShaderMaterial:
	if _shared_material == null:
		_shared_material = ShaderMaterial.new()
		_shared_material.shader = SHADER
	return _shared_material
