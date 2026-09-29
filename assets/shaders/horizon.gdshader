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
// Biome crossfade (WP6.4a): per layer the silhouette height morphs from set a
// (layer_style / layer_height_m) to set b (layer_style_b / layer_height_b_m) with
// layer_mix, as BiomeDirector drives across a checkpoint.
//
// Heat shimmer (WP6.4a, desert): the top edge of the far layers wobbles by a tiny,
// travelling elevation ripple, faded by the sun's height (none at night) and by
// heat_shimmer (0..1). A vertex effect on cards that already exist: no extra pass,
// no screen reads, identical on both renderers (TIME, no derivatives).
//
// Mesh (built by src/sun/sky.gd): per layer a ring strip, farthest layer first in
// index order (no depth writes: later triangles draw over earlier ones);
// VERTEX = horizontal unit direction, UV.x = layer index, UV.y = 0 bottom / 1 top.
//
// Biome extensions (WP6.4b; one shader since WP6.4c: HorizonSetDef.apply_blend writes
// these uniforms, all zero = the plain silhouettes above):
//   - STYLE_ISLANDS: sparse humps on a flat sea horizon.
//   - STYLE_HEADLANDS: broad capes with steep ends.
//   - layer_land (per layer, -1..1): > 0 keeps the silhouette on the land side of
//     `sea_dir` (world XZ toward the sea, set by WaterRibbon), < 0 on the sea side, with
//     a soft boundary; |layer_land| < 1 fades the mask (crossfades).
//   - layer_mist (per layer): the lower fraction of the card fades toward the fog color
//     (valley fog lying between the ridges).
//   - layer_windows (per layer): lit-window density on skylines at night
//     (x wb_emissive_streetlamp; window_color is linear).
// The bottom vertex of a column evaluates the silhouette only for a layer with mist or
// windows (its fragments need the top), so plain layers cost what they always did.
// Everything is linear math ending in wb_output(): identical on both renderers.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, fog_disabled, world_vertex_coords, shadows_disabled;

#include "res://assets/shaders/sky_common.gdshaderinc"

const float STYLE_NONE = 0.0;
const float STYLE_HILLS = 1.0;
const float STYLE_MESAS = 2.0;
const float STYLE_MOUNTAINS = 3.0;
const float STYLE_SKYLINE = 4.0;
const float STYLE_ISLANDS = 5.0;
const float STYLE_HEADLANDS = 6.0;

// Per layer (x = layer 0 .. w = layer 3). Styles as above; biomes set them later.
uniform vec4 layer_style = vec4(1.0, 2.0, 3.0, 3.0);
uniform vec4 layer_distance_m = vec4(3000.0, 7000.0, 16000.0, 40000.0);
uniform vec4 layer_height_m = vec4(90.0, 380.0, 1000.0, 3600.0);
// Crossfade target set and progress (0 = only the set above).
uniform vec4 layer_style_b = vec4(1.0, 2.0, 3.0, 3.0);
uniform vec4 layer_height_b_m = vec4(90.0, 380.0, 1000.0, 3600.0);
uniform float layer_mix = 0.0;
// Heat shimmer: amount (0..1), per-layer weight (far layers shimmer most), peak
// elevation ripple (radians), ripples around the horizon, travel speed (rad/s),
// and the sun heights (dir.y) over which it fades in.
uniform float heat_shimmer = 0.0;
uniform vec4 shimmer_layer_weight = vec4(0.35, 1.0, 0.8, 0.6);
uniform float shimmer_amplitude = 0.0016;
uniform float shimmer_ripples = 180.0;
// A second, slower ripple beats against the first (whole numbers: no seam behind).
uniform float shimmer_ripples_b = 67.0;
uniform float shimmer_speed = 7.0;
uniform vec2 shimmer_sun_fade = vec2(0.03, 0.2);
// The heat also lifts the base haze toward the sky's horizon colour (a mirage band).
uniform float shimmer_mirage = 0.35;
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
// WP6.4b extensions (see above).
uniform vec4 layer_land = vec4(0.0);
uniform vec4 layer_mist = vec4(0.0);
uniform vec4 layer_windows = vec4(0.0);
uniform vec2 sea_dir = vec2(0.0);
// Half-width (in dot(dir, sea_dir)) of the land/sea boundary.
uniform float sea_softness = 0.18;
uniform vec3 window_color = vec3(1.0, 0.62, 0.3);
// Window grid in radians (azimuth, elevation) and the lit share of a cell.
uniform vec2 window_size = vec2(0.0034, 0.0026);
uniform float window_fill = 0.55;

varying vec3 v_color;
varying vec3 v_fog;
varying float v_elev;
varying float v_top;
varying float v_layer;
varying vec2 v_az_seed;

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
	} else if (style == STYLE_ISLANDS) {
		// Sparse humps: only the peaks of the noise rise above the sea.
		float n = fbm3(p);
		return sqrt(max(n - 0.52, 0.0) / 0.48);
	} else if (style == STYLE_HEADLANDS) {
		// Broad capes with steep ends, a little relief on top.
		float cape = smoothstep(0.35, 0.5, fbm3(p * 0.7));
		return cape * (0.55 + 0.45 * fbm3(p * 2.5)) + 0.03;
	}
	return 0.0;
}

// Height multiplier of a land-only (land > 0) or sea-only (land < 0) layer; |land| < 1
// fades the mask toward 1 (no mask).
float land_mask(float land, vec3 flat_dir) {
	if (land == 0.0 || dot(sea_dir, sea_dir) < 0.25) {
		return 1.0;
	}
	float on_land = 1.0 - smoothstep(-sea_softness, sea_softness, dot(flat_dir.xz, sea_dir));
	return mix(1.0, land > 0.0 ? on_land : 1.0 - on_land, min(abs(land), 1.0));
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
	float style_b = layer_style_b[layer];
	vec3 flat_dir = normalize(vec3(VERTEX.x - NODE_POSITION_WORLD.x, 0.0, VERTEX.z - NODE_POSITION_WORLD.z));
	float top = -base_depth;
	float heat = heat_shimmer * smoothstep(shimmer_sun_fade.x, shimmer_sun_fade.y, wb_sun_dir.y);
	// A mist or window layer also evaluates the top at the bottom vertex (its fragments
	// need it); plain layers only at the top vertex.
	bool needs_top = UV.y > 0.5 || layer_mist[layer] > 0.0 || layer_windows[layer] > 0.0;
	if (needs_top && (style != STYLE_NONE || style_b != STYLE_NONE)) {
		vec2 sample_xz = CAMERA_POSITION_WORLD.xz + origin_xz + flat_dir.xz * layer_distance_m[layer];
		vec2 p = sample_xz / layer_feature_m[layer];
		float h = silhouette(style, p, layer_seed[layer]) * layer_height_m[layer];
		if (layer_mix > 0.0) {
			float hb = silhouette(style_b, p, layer_seed[layer]) * layer_height_b_m[layer];
			h = mix(h, hb, layer_mix);
		}
		h *= land_mask(layer_land[layer], flat_dir);
		top = h / layer_distance_m[layer];
		if (heat > 0.0) {
			float az = atan(flat_dir.x, -flat_dir.z);
			float ripple = sin(az * shimmer_ripples + TIME * shimmer_speed)
					* sin(az * shimmer_ripples_b - TIME * shimmer_speed * 0.61);
			top += heat * shimmer_layer_weight[layer] * shimmer_amplitude * ripple;
		}
	}
	float elev = UV.y > 0.5 ? top : -base_depth;
	vec3 dir = normalize(vec3(flat_dir.x, elev, flat_dir.z));
	VERTEX = CAMERA_POSITION_WORLD + dir * wb_fog_end * WB_SKY_RADIUS_FRAC;
	vec3 c = layer_tint(layer);
	v_fog = wb_fog_color_dir(dir);
	// Haze at the base melts the card into the fog and the dome below the horizon.
	c = mix(c, v_fog, UV.y > 0.5 ? 0.0 : base_haze);
	// Mirage: the hot air near the ground shows the sky, lifting the haze at the base.
	c = mix(c, wb_sky_horizon.rgb, UV.y > 0.5 ? 0.0 : heat * shimmer_mirage * shimmer_layer_weight[layer]);
	v_color = c + wb_sun_disc_color.rgb * wb_sun_halo(dir) * layer_glow[layer];
	v_elev = elev;
	v_top = top;
	v_layer = float(layer);
	v_az_seed = vec2(atan(flat_dir.x, -flat_dir.z), layer_seed[layer]);
}

void fragment() {
	int layer = int(v_layer + 0.5);
	vec3 c = v_color;
	float mist = layer_mist[layer];
	if (mist > 0.0) {
		// Low fog between the ridges: the lower `mist` of the card melts into the fog.
		float up = clamp((v_elev + base_depth) / max(v_top + base_depth, 0.0001), 0.0, 1.0);
		c = mix(c, v_fog, 1.0 - smoothstep(0.0, mist, up));
	}
	float wd = layer_windows[layer] * wb_emissive_streetlamp;
	if (wd > 0.0 && v_elev > 0.0) {
		vec2 g = vec2(v_az_seed.x / window_size.x, v_elev / window_size.y);
		vec2 cell = floor(g);
		vec2 f = fract(g);
		float pane = step(0.2, f.x) * step(f.x, 0.8) * step(0.25, f.y) * step(f.y, 0.75);
		float lit = step(1.0 - window_fill * wd, hash12(cell + v_az_seed.y));
		// No windows in the top row of a tower (roofs).
		float roof = 1.0 - step(v_top - window_size.y, v_elev);
		c += window_color * (pane * lit * roof * wd);
	}
	ALBEDO = wb_output(c);
	ALPHA = 1.0;
}
