class_name ColorKey
extends Resource
## One keyframe of the color script (data/color_script.tres). Spec: World →
## Color script ("Each keyframe sets ..."), Core loop → Sky timeline.
##
## `key` names the keyframe; its position on sky_t is NOT stored here: it comes
## from SunTuning.sky_t_<key> (the single source for the clock and the palette).
## Colors are authored in sRGB, as picked in the inspector; Sky converts them to
## linear once per frame when it pushes the shader globals.
##
## Defaults are "unset" markers (NAN floats, zero-alpha magenta colors) so a
## keyframe that forgets a channel fails ColorScript.validate() instead of
## silently inheriting a class default.

const UNSET_COLOR := Color(1, 0, 1, 0)

## morning, afternoon, golden_hour, sunset, dusk, night or dawn.
@export var key: StringName = &""
## Sun elevation above the horizon in degrees (negative = below it, at night).
## The azimuth is fixed (due west, world heading 0).
@export var sun_elevation_deg: float = NAN

@export_group("Sky")
@export var sky_zenith: Color = UNSET_COLOR
@export var sky_horizon: Color = UNSET_COLOR
@export var sun_disc_color: Color = UNSET_COLOR
## Angular radius of the sun disc.
@export var sun_disc_size_deg: float = NAN
## Halo strength around the sun (dome, horizon, clouds and fog in-scatter).
@export var sun_glow: float = NAN
## Star visibility 0..1.
@export var stars: float = NAN
@export var cloud_lit: Color = UNSET_COLOR
@export var cloud_shadow: Color = UNSET_COLOR

@export_group("Atmosphere")
@export var fog_color: Color = UNSET_COLOR
## Fog start and end as fractions of the quality tier's view distance
## (Quality.view_distance_m), so fog end tracks the far plane on every tier.
@export var fog_start_frac: float = NAN
@export var fog_end_frac: float = NAN
## Horizon silhouette layers, 0 = nearest .. 3 = farthest (closest to the fog).
@export var horizon_tint_0: Color = UNSET_COLOR
@export var horizon_tint_1: Color = UNSET_COLOR
@export var horizon_tint_2: Color = UNSET_COLOR
@export var horizon_tint_3: Color = UNSET_COLOR

@export_group("Lighting")
@export var ambient: Color = UNSET_COLOR
@export var sun_light_color: Color = UNSET_COLOR
@export var sun_light_energy: float = NAN
## Multiplies the ambient on faces turned away from the sun.
@export var shadow_tint: Color = UNSET_COLOR

@export_group("Surfaces")
## Asphalt albedo (road vertex color is white; tint class 1).
@export var road_tone: Color = UNSET_COLOR
## Lane-line albedo (tint class 2).
@export var lane_line_tint: Color = UNSET_COLOR

@export_group("Lights")
## Emissive multipliers per class; they ramp up from dusk.
@export var emissive_headlight: float = NAN
@export var emissive_streetlamp: float = NAN
@export var emissive_reflector: float = NAN

@export_group("UI")
## The design system's accent ("the sky's neon"). Not a shader global:
## read it from Sky.get_accent() / Sky.accent_changed.
@export var ui_accent: Color = UNSET_COLOR
