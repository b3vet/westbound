class_name HorizonSetDef
extends Resource
## A biome's horizon extensions (WP6.4b): what horizon_biomes.gdshader adds to the
## silhouette set of BiomeDef.horizon_layer_style / horizon_layer_height_m (which
## BiomeDirector crossfades through SkyRig.set_horizon_blend, WP6.4a). Spec: World →
## Sky ("3-4 layered silhouette cards (mountains, mesas, city skyline) ... tinted toward
## the fog color ... parallax"), Biomes (coast headlands and islands over the sea, the
## city's lit skyline, the valley's misty ridges), Night lighting.
##
##   HorizonSetDef.apply_blend(sky_horizon_material, from_def, to_def, t)
##
## Per layer (x = nearest .. w = farthest). The styles ISLANDS and HEADLANDS below, used
## in BiomeDef.horizon_layer_style, exist only in horizon_biomes.gdshader (the base
## shader draws them flat).

const SHADER_PATH := "res://assets/shaders/horizon_biomes.gdshader"
## SkyRig.HorizonStyle values, plus the WP6.4b styles.
const STYLE_NONE := 0
const STYLE_HILLS := 1
const STYLE_MESAS := 2
const STYLE_MOUNTAINS := 3
const STYLE_SKYLINE := 4
const STYLE_ISLANDS := 5
const STYLE_HEADLANDS := 6

## The set's name (BiomeDef.horizon_set).
@export var id: StringName = &""
## 1 land side only, -1 sea side only, 0 all around (needs WaterRibbon's sea direction).
@export var layer_land: Vector4 = Vector4.ZERO
## Lower fraction of each card that melts into the fog (valley mist).
@export var layer_mist: Vector4 = Vector4.ZERO
## Lit-window density at night per layer (skylines).
@export var layer_windows: Vector4 = Vector4.ZERO
## Night window color (sRGB; converted to linear when applied).
@export var window_color: Color = Color(1.0, 0.82, 0.58)
## Width of the land/sea boundary on the horizon (in the dot product with sea_dir).
@export var sea_softness: float = 0.18


## Writes the extensions blended from `a` to `b` at `t` (either may be null: none) into
## the sky's Horizon material, switching it to horizon_biomes.gdshader (a superset of
## horizon.gdshader) the first time a set is given. Director rate: call when the
## horizon crossfade moves (BiomeDirector._push_look) and at setup.
static func apply_blend(mat: ShaderMaterial, a: HorizonSetDef, b: HorizonSetDef, t: float) -> void:
	if a == null and b == null and mat.shader.resource_path != SHADER_PATH:
		return
	if mat.shader.resource_path != SHADER_PATH:
		mat.shader = load(SHADER_PATH) as Shader
	var k := clampf(t, 0.0, 1.0)
	mat.set_shader_parameter(&"layer_land", _v(a, &"layer_land").lerp(_v(b, &"layer_land"), k))
	mat.set_shader_parameter(&"layer_mist", _v(a, &"layer_mist").lerp(_v(b, &"layer_mist"), k))
	mat.set_shader_parameter(&"layer_windows", _v(a, &"layer_windows").lerp(_v(b, &"layer_windows"), k))
	var src := b if (k >= 0.5 and b != null) or a == null else a
	var w := src.window_color.srgb_to_linear()
	mat.set_shader_parameter(&"window_color", Vector3(w.r, w.g, w.b))
	mat.set_shader_parameter(&"sea_softness", src.sea_softness)


## This set alone (previews): apply_blend(mat, self, self, 0).
func apply(mat: ShaderMaterial) -> void:
	apply_blend(mat, self, self, 0.0)


static func _v(d: HorizonSetDef, field: StringName) -> Vector4:
	return d.get(field) as Vector4 if d != null else Vector4.ZERO
