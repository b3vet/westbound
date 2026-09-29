// Low fog layers (WP6.4b, valley fog biome). Spec: World → Biomes ("low fog layers in
// valleys (cards)"), Color script (the mist is the fog color with the sun's
// in-scatter, a touch brighter), Performance budget (one alpha-blended draw call, no
// depth writes). Mesh: src/world/fog_cards/fog_cards.gd.
//
//   UV       (across 0 near edge .. 1 far edge, along 0 .. 1)
//   COLOR.a  the bank's opacity (layer alpha x valley factor)
//
// Opacity = COLOR.a x soft edges x value-noise breakup (absolute world XZ via
// origin_xz, so the pattern does not jump on an origin shift) x a near fade (clear
// around the camera: the mist never veils the player or the road beside them) x a
// midday thinning (the mist is thickest at dawn, dusk and night).
// Blending toward a light color: Mobile blends linear values, Compatibility the
// sRGB-encoded ones, where the same alpha lightens less over darker ground.
// fog_alpha() lifts the alpha on Compatibility to match a mid-dark background; the
// residue is judged by eye like the other alpha effects (docs/CONTRACTS.md §13).
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

#include "res://assets/shaders/world_common.gdshaderinc"

uniform float softness = 0.3;
uniform float brightness = 1.06;
uniform float noise_scale_m = 70.0;
uniform float noise_depth = 0.55;
uniform float near_clear_m = 25.0;
uniform float near_fade_m = 70.0;
// Opacity with a high sun (fog burns off by midday), reached at sun elevation sine
// midday_sun_y; full opacity at or below the horizon (dawn, dusk, night).
uniform float midday_factor = 0.5;
uniform float midday_sun_y = 0.5;
// Absolute world XZ of the floating origin (FogCards sets it).
uniform vec2 origin_xz = vec2(0.0);

// Compatibility alpha lift: blend exponent toward 1/2.2 (0 = none, 1 = full lift,
// right for a black background). 0.2 was tuned with tools/parity.sh on the valley
// preview across the chase and high views; seen from high above by day, mist over
// bright meadows stays ~15 at p99.9 (an alpha layer, judged by eye).
const float FOG_COMPAT_LIFT = 0.2;

varying vec3 v_world_pos;

float fog_hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float fog_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = fog_hash(i);
	float b = fog_hash(i + vec2(1.0, 0.0));
	float c = fog_hash(i + vec2(0.0, 1.0));
	float d = fog_hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fog_alpha(float a) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return mix(a, pow(clamp(a, 0.0, 1.0), 1.0 / WB_BLEND_GAMMA), FOG_COMPAT_LIFT);
#else
	return a;
#endif
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 e = min(UV, vec2(1.0) - UV);
	float edge = smoothstep(0.0, softness, e.x) * smoothstep(0.0, softness * 0.5, e.y);
	vec2 wp = (v_world_pos.xz + origin_xz) / max(noise_scale_m, 1.0);
	float n = fog_noise(wp) * 0.65 + fog_noise(wp * 2.3 + 11.0) * 0.35;
	float breakup = 1.0 - noise_depth * (1.0 - n);
	vec3 to_frag = v_world_pos - CAMERA_POSITION_WORLD;
	float dist = length(to_frag);
	float near = smoothstep(near_clear_m, near_clear_m + near_fade_m, dist);
	float day = mix(1.0, midday_factor, smoothstep(0.0, midday_sun_y, wb_sun_dir.y));
	vec3 col = wb_fog_color_dir(to_frag / max(dist, 0.001)) * brightness;
	ALBEDO = wb_output(col);
	ALPHA = fog_alpha(clamp(COLOR.a * edge * breakup * near * day, 0.0, 1.0));
}
