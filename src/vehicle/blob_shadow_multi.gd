class_name BlobShadowMulti
extends MultiMeshInstance3D
## Blob shadows for many vehicles in one draw call (traffic: 60+). Spec: Performance
## budget → Shadows and Draw calls. Same quad and shader as BlobShadow; per-instance
## strength goes in INSTANCE_CUSTOM.x (0 hides an instance).
##
##   shadows.setup(count)
##   shadows.place(i, sample, d, yaw, length_m, width_m, origin)   # per frame, per slot
##   shadows.hide_instance(i)                                      # free slot
##
## Allocation-free after setup(). The owner re-places instances every frame, so a
## floating-origin shift needs no extra handling.

## Height above the road surface.
@export var lift_m: float = 0.04
## Extra footprint around the body, as a fraction of its length and width.
@export var margin_frac: float = 0.18

var _material: ShaderMaterial
var _hidden := Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO)


## Allocates `count` instances, all hidden.
func setup(count: int) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = BlobShadow.shared_mesh()
	mm.instance_count = count
	multimesh = mm
	if _material == null:
		_material = BlobShadow.shared_material().duplicate() as ShaderMaterial
		_material.set_shader_parameter(&"use_instance_custom", true)
	material_override = _material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	for i in count:
		hide_instance(i)


func capacity() -> int:
	return multimesh.instance_count if multimesh != null else 0


func place(i: int, sample: RoadSample, d: float, yaw: float, length_m: float, width_m: float,
		floating_origin: FloatingOrigin = null, strength: float = 1.0) -> void:
	multimesh.set_instance_transform(i, BlobShadow.shadow_transform(
			sample, d, yaw, length_m, width_m, floating_origin, lift_m, margin_frac))
	multimesh.set_instance_custom_data(i, Color(strength, 0.0, 0.0, 0.0))


func hide_instance(i: int) -> void:
	multimesh.set_instance_transform(i, _hidden)
	multimesh.set_instance_custom_data(i, Color(0.0, 0.0, 0.0, 0.0))
