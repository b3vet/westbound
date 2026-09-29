class_name HorizonSetDef
extends Resource
## One biome's horizon silhouette set (BiomeDef.horizon_set names it, BiomeDef.horizon_def
## holds it). Spec: World → Sky ("3-4 layered silhouette cards (mountains, mesas, city
## skyline) at increasing distance, tinted toward the fog color ... parallax"), Biomes.
## Per layer (x = nearest .. w = farthest) the same parameters as horizon.gdshader,
## plus the WP6.4b extensions of horizon_biomes.gdshader (sea-side masks, low mist,
## lit skyline windows).
##
##   set.apply(sky_horizon_material)   # switches to horizon_biomes.gdshader if needed
##
## Styles: SkyRig.HorizonStyle values, plus ISLANDS and HEADLANDS below.

const SHADER_PATH := "res://assets/shaders/horizon_biomes.gdshader"
const STYLE_NONE := 0
const STYLE_HILLS := 1
const STYLE_MESAS := 2
const STYLE_MOUNTAINS := 3
const STYLE_SKYLINE := 4
const STYLE_ISLANDS := 5
const STYLE_HEADLANDS := 6

@export var id: StringName = &""
@export var layer_style: Vector4 = Vector4(STYLE_HILLS, STYLE_MESAS, STYLE_MOUNTAINS, STYLE_MOUNTAINS)
@export var layer_distance_m: Vector4 = Vector4(3000.0, 7000.0, 16000.0, 40000.0)
@export var layer_height_m: Vector4 = Vector4(90.0, 380.0, 1000.0, 3600.0)
@export var layer_feature_m: Vector4 = Vector4(900.0, 2600.0, 5000.0, 14000.0)
@export var layer_glow: Vector4 = Vector4(0.25, 0.35, 0.45, 0.55)
@export var layer_seed: Vector4 = Vector4(11.0, 37.0, 71.0, 113.0)
@export var base_haze: float = 0.9
@export_group("WP6.4b extensions")
## 0 all around, 1 land side only, -1 sea side only (needs a sea direction).
@export var layer_land: Vector4 = Vector4.ZERO
## Lower fraction of each card that melts into the fog (valley mist).
@export var layer_mist: Vector4 = Vector4.ZERO
## Lit-window density at night per layer (skylines).
@export var layer_windows: Vector4 = Vector4.ZERO
## Night window color (sRGB; converted to linear when applied).
@export var window_color: Color = Color(1.0, 0.82, 0.58)
## Width of the land/sea boundary on the horizon (in the dot product with sea_dir).
@export var sea_softness: float = 0.18


## True when a layer needs horizon_biomes.gdshader (the base shader lacks it).
func needs_extended_shader() -> bool:
	for i in 4:
		if layer_style[i] > STYLE_SKYLINE or layer_land[i] != 0.0 or layer_mist[i] > 0.0 \
				or layer_windows[i] > 0.0:
			return true
	return false


## Writes the set into the sky's horizon material (SkyRig's `Horizon` node's own
## material). Switches the shader to horizon_biomes.gdshader when the set needs it;
## that shader is a superset of horizon.gdshader, so switching back is never needed.
## The extension uniforms are always reset, so a plain set clears a previous one's.
func apply(mat: ShaderMaterial) -> void:
	if needs_extended_shader() and mat.shader.resource_path != SHADER_PATH:
		mat.shader = load(SHADER_PATH) as Shader
	mat.set_shader_parameter(&"layer_style", layer_style)
	mat.set_shader_parameter(&"layer_distance_m", layer_distance_m)
	mat.set_shader_parameter(&"layer_height_m", layer_height_m)
	mat.set_shader_parameter(&"layer_feature_m", layer_feature_m)
	mat.set_shader_parameter(&"layer_glow", layer_glow)
	mat.set_shader_parameter(&"layer_seed", layer_seed)
	mat.set_shader_parameter(&"base_haze", base_haze)
	mat.set_shader_parameter(&"layer_land", layer_land)
	mat.set_shader_parameter(&"layer_mist", layer_mist)
	mat.set_shader_parameter(&"layer_windows", layer_windows)
	var w := window_color.srgb_to_linear()
	mat.set_shader_parameter(&"window_color", Vector3(w.r, w.g, w.b))
	mat.set_shader_parameter(&"sea_softness", sea_softness)
