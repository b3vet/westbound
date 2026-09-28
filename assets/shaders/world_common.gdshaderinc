// Shared world shading (spec: Performance budget → Materials, Fog; World → Color
// script, Sky). One sun, lighting evaluated per vertex, distance fog, all colors
// from the color script via global uniforms (declared in project.godot
// [shader_globals], pushed once per frame by src/sun/sky.gd). Nothing uses engine
// lights, shadows or environment effects.
//
// Color spaces (docs/CONTRACTS.md §13, renderer parity):
//   - Every color global holds a LINEAR value. The color script is authored in
//     sRGB and Sky converts once per frame on the CPU. Godot passes global
//     uniforms through untouched on both renderers, so they carry no
//     `source_color` hint here (the hint would suggest a conversion that does
//     not happen).
//   - COLOR.rgb (vertex color) is authored in sRGB; wb_albedo() linearizes it.
//   - All math is linear. Every shader ends with ALBEDO = wb_output(linear).
//     wb_output() hides the one renderer difference: Mobile treats ALBEDO as
//     linear and encodes to sRGB exactly; Compatibility treats ALBEDO as sRGB
//     (SHADER_IS_SRGB) and runs it through approximate sRGB->linear->sRGB round
//     trips (once in the scene shader, once more in the post copy that every
//     render scale < 1 uses). wb_output() pre-inverts those round trips.
//
// Vertex conventions for world meshes (road, props, landmarks):
//   COLOR.rgb  albedo (authored in sRGB; converted with wb_albedo())
//   UV2.x      emissive class: 0 none, 1 reflector, 2 street lamp, 3 vehicle light
//   UV2.y      tint class:     0 none, 1 road surface (x wb_road_tone), 2 lane line (x wb_lane_line_tint)
//   NORMAL     required; flat shading = duplicated vertices per face
#ifndef WB_WORLD_COMMON
#define WB_WORLD_COMMON

global uniform vec4 wb_sky_zenith;
global uniform vec4 wb_sky_horizon;
global uniform vec3 wb_sun_dir;
global uniform vec4 wb_sun_disc_color;
global uniform float wb_sun_disc_size;
global uniform float wb_sun_glow;
global uniform float wb_stars;
global uniform vec4 wb_cloud_lit;
global uniform vec4 wb_cloud_shadow;
global uniform vec4 wb_fog_color;
global uniform float wb_fog_start;
global uniform float wb_fog_end;
global uniform vec4 wb_horizon_tint_0;
global uniform vec4 wb_horizon_tint_1;
global uniform vec4 wb_horizon_tint_2;
global uniform vec4 wb_horizon_tint_3;
global uniform vec4 wb_ambient;
global uniform vec4 wb_sun_light_color;
global uniform float wb_sun_light_energy;
global uniform vec4 wb_shadow_tint;
global uniform vec4 wb_road_tone;
global uniform vec4 wb_lane_line_tint;
global uniform float wb_emissive_headlight;
global uniform float wb_emissive_streetlamp;
global uniform float wb_emissive_reflector;
global uniform vec3 wb_player_light_pos;
global uniform vec3 wb_player_light_dir;
global uniform float wb_player_light_strength;
global uniform vec3 wb_biome_tint_offset;

const float WB_EMISSIVE_NONE = 0.0;
const float WB_EMISSIVE_REFLECTOR = 1.0;
const float WB_EMISSIVE_STREETLAMP = 2.0;
const float WB_EMISSIVE_VEHICLE = 3.0;
const float WB_TINT_NONE = 0.0;
const float WB_TINT_ROAD = 1.0;
const float WB_TINT_LANE_LINE = 2.0;

// Sun halo shape: exp2((cos(angle) - 1) * k). Tight core and wide haze.
const float WB_HALO_TIGHT = 160.0;
const float WB_HALO_WIDE = 9.0;
const float WB_HALO_TIGHT_WEIGHT = 0.6;
// Lowest elevation (sine) the world light comes from (see wb_light).
const float WB_LIGHT_MIN_SIN = 0.2;
// How much of the halo lights the fog (in-scatter toward the sun).
const float WB_FOG_HALO = 0.8;
// Player fake light cone (cos of the inner/outer edge) and distance falloff.
const float WB_PLAYER_CONE_OUTER = 0.85;
const float WB_PLAYER_CONE_INNER = 0.97;
const float WB_PLAYER_FALLOFF = 0.002;

// ---------------------------------------------------------------- Color space

vec3 wb_srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

vec3 wb_linear_to_srgb(vec3 c) {
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
// Inverse of the Compatibility renderer's round trip g(x) = l2s_a(s2l_a(x)),
// where s2l_a / l2s_a are the approximations in drivers/gles3/shaders/
// tonemap_inc.glsl (Godot 4.7): s2l_a(x) = x*(x*(x*A + B) + C) and
// l2s_a(x) = max(1.055*x^(5/12) - 0.055, 0). Two Newton steps on the cubic
// keep the result within 1/255 of the Mobile renderer's exact encode.
const float WB_S2L_A = 0.305306011;
const float WB_S2L_B = 0.682171111;
const float WB_S2L_C = 0.012522878;

vec3 wb_compat_roundtrip_inverse(vec3 y) {
	vec3 z = pow((max(y, vec3(0.0)) + 0.055) / 1.055, vec3(2.4));
	vec3 x = wb_linear_to_srgb(z);
	for (int i = 0; i < 2; i++) {
		vec3 p = x * (x * (x * WB_S2L_A + WB_S2L_B) + WB_S2L_C);
		vec3 dp = x * (3.0 * WB_S2L_A * x + 2.0 * WB_S2L_B) + WB_S2L_C;
		x = max(x - (p - z) / dp, vec3(0.0));
	}
	return x;
}
#endif

// Final color of every world/sky shader: pass the LINEAR result, assign to ALBEDO.
vec3 wb_output(vec3 linear_color) {
	vec3 c = clamp(linear_color, vec3(0.0), vec3(1.0));
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	// Target the same display value as Mobile's exact sRGB encode. The game always
	// renders 3D below native resolution (every quality tier), so Compatibility
	// applies its round trip twice: scene shader, then the post copy.
	vec3 display = wb_linear_to_srgb(c);
	return wb_compat_roundtrip_inverse(wb_compat_roundtrip_inverse(display));
#else
	return c;
#endif
}

// ---------------------------------------------------------------- Surfaces

// Vertex color -> linear albedo, with tint class and biome offset applied.
vec3 wb_albedo(vec3 vertex_srgb, float tint_class) {
	vec3 c = wb_srgb_to_linear(vertex_srgb);
	if (tint_class == WB_TINT_ROAD) {
		c *= wb_road_tone.rgb;
	} else if (tint_class == WB_TINT_LANE_LINE) {
		c *= wb_lane_line_tint.rgb;
	}
	return max(c + wb_biome_tint_offset, vec3(0.0));
}

// Single-light vertex lighting: ambient + sun (N.L), shadow side tinted. The
// light never comes from below WB_LIGHT_MIN_SIN (sine of its elevation): after
// sunset the same light is the moon/sky light, colored by the color script.
vec3 wb_light(vec3 albedo, vec3 world_normal) {
	vec3 l = normalize(vec3(wb_sun_dir.x, max(wb_sun_dir.y, WB_LIGHT_MIN_SIN), wb_sun_dir.z));
	float ndl = max(dot(normalize(world_normal), l), 0.0);
	vec3 shade = mix(wb_shadow_tint.rgb * wb_ambient.rgb, wb_ambient.rgb, ndl);
	return albedo * (shade + wb_sun_light_color.rgb * wb_sun_light_energy * ndl);
}

// Emissive boost by class, driven by the color script's night ramps.
vec3 wb_emissive(vec3 albedo, float emissive_class) {
	float k = 0.0;
	if (emissive_class == WB_EMISSIVE_REFLECTOR) { k = wb_emissive_reflector; }
	else if (emissive_class == WB_EMISSIVE_STREETLAMP) { k = wb_emissive_streetlamp; }
	else if (emissive_class == WB_EMISSIVE_VEHICLE) { k = wb_emissive_headlight; }
	return albedo * k;
}

// Player "fake light": brightens surfaces inside the headlight cone at night.
vec3 wb_player_light(vec3 albedo, vec3 world_pos) {
	vec3 to_p = world_pos - wb_player_light_pos;
	float dist = length(to_p);
	float cone = smoothstep(WB_PLAYER_CONE_OUTER, WB_PLAYER_CONE_INNER,
			dot(to_p / max(dist, 0.001), normalize(wb_player_light_dir)));
	float falloff = 1.0 / (1.0 + dist * dist * WB_PLAYER_FALLOFF);
	return albedo * wb_player_light_strength * cone * falloff;
}

// ---------------------------------------------------------------- Sky and fog

// Sun halo (0..~1) for a unit view direction. Shared by the dome, horizon,
// clouds and fog so fogged geometry melts into the sky around the sun.
float wb_sun_halo(vec3 dir) {
	float c = dot(dir, wb_sun_dir);
	float tight = exp2((c - 1.0) * WB_HALO_TIGHT);
	float wide = exp2((c - 1.0) * WB_HALO_WIDE);
	return mix(wide, tight, WB_HALO_TIGHT_WEIGHT) * wb_sun_glow;
}

// Fog color seen in a unit view direction (fog + sun in-scatter).
vec3 wb_fog_color_dir(vec3 dir) {
	return wb_fog_color.rgb + wb_sun_disc_color.rgb * wb_sun_halo(dir) * WB_FOG_HALO;
}

float wb_fog_factor(float dist) {
	return smoothstep(wb_fog_start, wb_fog_end, dist);
}

vec3 wb_apply_fog(vec3 color, float dist) {
	return mix(color, wb_fog_color.rgb, wb_fog_factor(dist));
}

// Fog with the sun in-scatter; `to_frag` = fragment world pos - camera pos.
vec3 wb_apply_fog_dir(vec3 color, vec3 to_frag) {
	float dist = length(to_frag);
	return mix(color, wb_fog_color_dir(to_frag / max(dist, 0.001)), wb_fog_factor(dist));
}

#endif
