// Horizon silhouettes: up to 4 layered cards (0 = nearest .. 3 = farthest) in one
// mesh and one draw call (spec: World → Sky, "3-4 layered silhouette cards
// (mountains, mesas, city skyline) ... tinted toward the fog color ... scroll with
// parallax"). No textures: each ring's top edge is displaced per vertex from a
// procedural height field sampled at a *virtual* distance, so the silhouette is
// faceted low-poly by construction.
//
// Parallax: layer k samples its height field at the absolute point
// camera + dir * layer_distance_m[k]. Driving moves the samples through the field,
// so near layers slide by faster than far ones and turning keeps them fixed in
// world directions. `origin_xz` (set by Sky from the FloatingOrigin) makes the
// sample positions absolute, so an origin shift does not move the horizon.
//
// Mesh (built by src/sun/sky.gd): per layer a ring strip, farthest layer first in
// index order (no depth writes: later triangles draw over earlier ones);
// VERTEX = horizontal unit direction, UV.x = layer index, UV.y = 0 bottom / 1 top.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, fog_disabled, world_vertex_coords, shadows_disabled;

#include "res://assets/shaders/sky_common.gdshaderinc"

const float STYLE_NONE = 0.0;
const float STYLE_HILLS = 1.0;
const float STYLE_MESAS = 2.0;
const float STYLE_MOUNTAINS = 3.0;
const float STYLE_SKYLINE = 4.0;

// Per layer (x = layer 0 .. w = layer 3). Styles as above; biomes set them later.
uniform vec4 layer_style = vec4(1.0, 2.0, 3.0, 3.0);
uniform vec4 layer_distance_m = vec4(3000.0, 7000.0, 16000.0, 40000.0);
uniform vec4 layer_height_m = vec4(90.0, 380.0, 1000.0, 3600.0);
// Horizontal size of the features in each height field.
uniform vec4 layer_feature_m = vec4(900.0, 2600.0, 5000.0, 14000.0);
// How much of the sun halo washes over each layer.
uniform vec4 layer_glow = vec4(0.25, 0.35, 0.45, 0.55);
// Seed offset per layer so layers do not share a field.
uniform vec4 layer_seed = vec4(11.0, 37.0, 71.0, 113.0);
// Base of the cards, below the horizon (dir.y), and the haze at the base.
uniform float base_depth = 0.012;
uniform float base_haze = 0.9;
// Absolute world XZ of the floating origin (Sky sets it).
uniform vec2 origin_xz = vec2(0.0);

varying vec3 v_color;

// Hash without sine: stable for large inputs and identical on every renderer.
float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm3(vec2 p) {
	return value_noise(p) * 0.57 + value_noise(p * 2.03 + 17.0) * 0.29 + value_noise(p * 4.11 + 41.0) * 0.14;
}

// Height 0..1 of style `style` at field position p (in feature units).
float silhouette(float style, vec2 p, float seed) {
	p += vec2(seed, seed * 1.7);
	if (style == STYLE_HILLS) {
		return fbm3(p) * 0.85 + 0.15;
	} else if (style == STYLE_MESAS) {
		// Flat tops, steep sides, low rubble in between.
		float n = fbm3(p);
		float top = smoothstep(0.5, 0.56, n) * (0.8 + 0.2 * value_noise(p * 3.0));
		return max(top, n * 0.3);
	} else if (style == STYLE_MOUNTAINS) {
		// Ridged: sharp peaks.
		float r = 1.0 - abs(2.0 * fbm3(p) - 1.0);
		return r * r;
	} else if (style == STYLE_SKYLINE) {
		// Blocks: piecewise-constant towers in clusters.
		vec2 cell = floor(p * 12.0);
		float cluster = smoothstep(0.3, 0.55, value_noise(p * 0.5));
		float tower = hash12(cell + seed);
		float gap = step(0.25, hash12(cell * 1.31 + 7.0));
		return (0.12 + 0.88 * tower * tower) * gap * cluster + 0.04;
	}
	return 0.0;
}

vec3 layer_tint(int layer) {
	if (layer == 0) { return wb_horizon_tint_0.rgb; }
	if (layer == 1) { return wb_horizon_tint_1.rgb; }
	if (layer == 2) { return wb_horizon_tint_2.rgb; }
	return wb_horizon_tint_3.rgb;
}

void vertex() {
	int layer = int(UV.x + 0.5);
	float style = layer_style[layer];
	vec3 flat_dir = normalize(vec3(VERTEX.x - NODE_POSITION_WORLD.x, 0.0, VERTEX.z - NODE_POSITION_WORLD.z));
	float elev = -base_depth;
	if (UV.y > 0.5 && style != STYLE_NONE) {
		vec2 sample_xz = CAMERA_POSITION_WORLD.xz + origin_xz + flat_dir.xz * layer_distance_m[layer];
		float h = silhouette(style, sample_xz / layer_feature_m[layer], layer_seed[layer]);
		elev = h * layer_height_m[layer] / layer_distance_m[layer];
	}
	vec3 dir = normalize(vec3(flat_dir.x, elev, flat_dir.z));
	VERTEX = CAMERA_POSITION_WORLD + dir * wb_fog_end * WB_SKY_RADIUS_FRAC;
	vec3 c = layer_tint(layer);
	// Haze at the base melts the card into the fog and the dome below the horizon.
	c = mix(c, wb_fog_color_dir(dir), UV.y > 0.5 ? 0.0 : base_haze);
	v_color = c + wb_sun_disc_color.rgb * wb_sun_halo(dir) * layer_glow[layer];
}

void fragment() {
	ALBEDO = wb_output(v_color);
	ALPHA = 1.0;
}
