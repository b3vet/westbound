// Horizon silhouettes with the biome extensions of WP6.4b (coast, city, valley fog).
// A superset of horizon.gdshader: the same mesh (src/sun/sky.gd build_horizon_mesh),
// uniforms, styles 0-4 and output, so SkyRig can use either (HorizonSetDef.apply
// switches the Horizon material's shader and sets the set's uniforms). Spec: World →
// Sky ("3-4 layered silhouette cards (mountains, mesas, city skyline) ... tinted toward
// the fog color ... scroll with parallax"), Biomes (coast headlands and islands, city
// skyline, valley hills with low fog), Night lighting (lit windows, no real lights).
//
// Additions:
//   - STYLE_ISLANDS: sparse humps on a flat sea horizon.
//   - STYLE_HEADLANDS: capes and cliffs, steep toward the sea.
//   - layer_land (per layer): 0 all around; 1 only on the land side, -1 only on the sea
//     side of `sea_dir` (world XZ toward the sea, set by WaterRibbon), with a soft
//     boundary: headlands fall into the sea ahead, islands sit only over the water.
//   - layer_mist (per layer): the lower fraction of the card fades toward the fog
//     color (valley fog lying between hill ridges).
//   - layer_windows (per layer): lit-window density on skyline layers at night
//     (x wb_emissive_streetlamp; window_color is linear).
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

uniform vec4 layer_style = vec4(1.0, 2.0, 3.0, 3.0);
uniform vec4 layer_distance_m = vec4(3000.0, 7000.0, 16000.0, 40000.0);
uniform vec4 layer_height_m = vec4(90.0, 380.0, 1000.0, 3600.0);
uniform vec4 layer_feature_m = vec4(900.0, 2600.0, 5000.0, 14000.0);
uniform vec4 layer_glow = vec4(0.25, 0.35, 0.45, 0.55);
uniform vec4 layer_seed = vec4(11.0, 37.0, 71.0, 113.0);
uniform float base_depth = 0.012;
uniform float base_haze = 0.9;
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

float silhouette(float style, vec2 p, float seed) {
	p += vec2(seed, seed * 1.7);
	if (style == STYLE_HILLS) {
		return fbm3(p) * 0.85 + 0.15;
	} else if (style == STYLE_MESAS) {
		float n = fbm3(p);
		float top = smoothstep(0.5, 0.56, n) * (0.8 + 0.2 * value_noise(p * 3.0));
		return max(top, n * 0.3);
	} else if (style == STYLE_MOUNTAINS) {
		float r = 1.0 - abs(2.0 * fbm3(p) - 1.0);
		return r * r;
	} else if (style == STYLE_SKYLINE) {
		vec2 cell = floor(p * 12.0);
		float cluster = smoothstep(0.3, 0.55, value_noise(p * 0.5));
		float tower = hash12(cell + seed);
		float gap = step(0.25, hash12(cell * 1.31 + 7.0));
		return (0.12 + 0.88 * tower * tower) * gap * cluster + 0.04;
	} else if (style == STYLE_ISLANDS) {
		// Sparse humps: only the peaks of the noise rise above the sea.
		float n = fbm3(p);
		float h = max(n - 0.52, 0.0) / 0.48;
		return sqrt(h);
	} else if (style == STYLE_HEADLANDS) {
		// Broad capes with steep ends: a smoothed ridge field cut into terraces.
		float n = fbm3(p * 0.7);
		float cape = smoothstep(0.35, 0.5, n);
		return cape * (0.55 + 0.45 * fbm3(p * 2.5)) + 0.03;
	}
	return 0.0;
}

vec3 layer_tint(int layer) {
	if (layer == 0) { return wb_horizon_tint_0.rgb; }
	if (layer == 1) { return wb_horizon_tint_1.rgb; }
	if (layer == 2) { return wb_horizon_tint_2.rgb; }
	return wb_horizon_tint_3.rgb;
}

// Height multiplier of a land-only (land > 0) or sea-only (land < 0) layer.
float land_mask(float land, vec3 flat_dir) {
	if (land == 0.0 || dot(sea_dir, sea_dir) < 0.25) {
		return 1.0;
	}
	float seaward = dot(flat_dir.xz, sea_dir);
	float on_land = 1.0 - smoothstep(-sea_softness, sea_softness, seaward);
	return land > 0.0 ? on_land : 1.0 - on_land;
}

float top_elevation(int layer, vec3 flat_dir, vec2 camera_xz) {
	float style = layer_style[layer];
	if (style == STYLE_NONE) {
		return -base_depth;
	}
	vec2 sample_xz = camera_xz + origin_xz + flat_dir.xz * layer_distance_m[layer];
	float h = silhouette(style, sample_xz / layer_feature_m[layer], layer_seed[layer]);
	h *= land_mask(layer_land[layer], flat_dir);
	return h * layer_height_m[layer] / layer_distance_m[layer];
}

void vertex() {
	int layer = int(UV.x + 0.5);
	vec3 flat_dir = normalize(vec3(VERTEX.x - NODE_POSITION_WORLD.x, 0.0, VERTEX.z - NODE_POSITION_WORLD.z));
	float top = top_elevation(layer, flat_dir, CAMERA_POSITION_WORLD.xz);
	float elev = UV.y > 0.5 ? top : -base_depth;
	vec3 dir = normalize(vec3(flat_dir.x, elev, flat_dir.z));
	VERTEX = CAMERA_POSITION_WORLD + dir * wb_fog_end * WB_SKY_RADIUS_FRAC;
	vec3 c = layer_tint(layer);
	v_fog = wb_fog_color_dir(dir);
	c = mix(c, v_fog, UV.y > 0.5 ? 0.0 : base_haze);
	v_color = c + wb_sun_disc_color.rgb * wb_sun_halo(dir) * layer_glow[layer];
	v_elev = elev;
	v_top = top;
	v_layer = float(layer);
	v_az_seed = vec2(atan(flat_dir.x, -flat_dir.z), layer_seed[layer]);
}

void fragment() {
	int layer = int(v_layer + 0.5);
	vec3 c = v_color;
	float span = max(v_top + base_depth, 0.0001);
	float up = clamp((v_elev + base_depth) / span, 0.0, 1.0);
	float mist = layer_mist[layer];
	if (mist > 0.0) {
		// Low fog between the ridges: the lower `mist` of the card melts into the fog.
		c = mix(c, v_fog, 1.0 - smoothstep(0.0, mist, up));
	}
	float wd = layer_windows[layer] * wb_emissive_streetlamp;
	if (wd > 0.0 && v_elev > 0.0) {
		vec2 g = vec2(v_az_seed.x / window_size.x, v_elev / window_size.y);
		vec2 cell = floor(g);
		vec2 f = fract(g);
		float pane = step(0.2, f.x) * step(f.x, 0.8) * step(0.25, f.y) * step(f.y, 0.75);
		float lit = step(1.0 - window_fill * wd, hash12(cell + v_az_seed.y));
		// No windows in the top row of a tower (roofs) or in the base haze.
		float roof = 1.0 - step(v_top - window_size.y, v_elev);
		c += window_color * (pane * lit * roof * wd);
	}
	ALBEDO = wb_output(c);
	ALPHA = 1.0;
}
