// Water beside the road (WP6.4b: the coast's ocean, the valley's river). Spec: World →
// Biomes (coastal highway: "the sun sinks into the sea"), Color script (every biome
// looks right across it), Performance budget (custom vertex/fragment-lit shader, no
// engine lights or reflections). Mesh and vertex channels: src/world/ocean/water_ribbon.gd.
//
//   COLOR.rgb  albedo, sRGB (shore sand / foam / shallow -> deep water)
//   COLOR.a    water weight: 1 water (waves, sky reflection, sun path), 0 land (shore,
//              slope, islets)
//   UV.x       distance from the waterline (m): waves ramp in over wave_ramp_m
//   UV2.x      water: wave phase (rad), hashed per vertex from its absolute row and
//              column; land: the §13 emissive class (the islet lighthouse's lantern)
//   NORMAL     the road's up vector at the row (the bob axis)
//
// Faceted low-poly water: every vertex bobs on its own phase, and the fragment takes
// the flat normal of its (animated) triangle from the screen-space derivatives of the
// world position, so facets tilt and glint. Lighting is the shared single-sun model;
// the "reflection" is the shared sky model sampled in the reflected direction (sky
// gradient + the sun's halo), weighted by Fresnel: the sun path glitters because each
// facet reflects a different part of the sun's lobes. All math is linear and ends in
// wb_output(), identical on both renderers.
//
// Depth pull: the strip lies a little above the ground ribbon; far away that gap is
// below depth precision, so the vertex moves toward the camera along its view ray by
// depth_pull_frac of its distance (same pixel, nearer depth).
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque, fog_disabled, shadows_disabled, skip_vertex_transform;

#include "res://assets/shaders/sky_common.gdshaderinc"

uniform float time_s = 0.0;
uniform float wave_height_m = 0.3;
uniform float wave_ramp_m = 14.0;
uniform float wave_period_s = 3.5;
uniform float sky_reflect = 0.7;
uniform float sun_path_gain = 2.2;
uniform float depth_pull_frac = 0.004;

// Schlick Fresnel for water (F0 ~ 0.02) and its exponent.
const float WATER_F0 = 0.02;
const float WATER_FRESNEL_EXP = 5.0;
// The sky seen in reflections never dips below this elevation (dir.y).
const float WATER_REFLECT_MIN_Y = 0.02;
// Sun reflection lobes, exp2((cos - 1) * k): sparkles (tight) and the path (broad).
const float WATER_SPARK_K = 900.0;
const float WATER_PATH_K = 60.0;
const float WATER_PATH_WEIGHT = 0.25;

varying vec3 v_world_pos;
varying vec3 v_albedo;
varying float v_water;
varying vec3 v_emit;

void vertex() {
	float ramp = COLOR.a * clamp(UV.x / max(wave_ramp_m, 0.001), 0.0, 1.0);
	vec3 p = VERTEX + NORMAL * (wave_height_m * ramp * sin(TAU * time_s / max(wave_period_s, 0.001) + UV2.x));
	v_world_pos = (MODEL_MATRIX * vec4(p, 1.0)).xyz;
	v_albedo = wb_albedo(COLOR.rgb, WB_TINT_NONE);
	v_water = COLOR.a;
	v_emit = COLOR.a < 0.5 ? wb_emissive(v_albedo, UV2.x) : vec3(0.0);
	VERTEX = (MODELVIEW_MATRIX * vec4(p, 1.0)).xyz * (1.0 - depth_pull_frac);
	NORMAL = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 n = normalize(cross(dFdx(v_world_pos), dFdy(v_world_pos)));
	if (n.y < 0.0) {
		n = -n;
	}
	vec3 lit = wb_light(v_albedo, n) + v_emit;
	vec3 to_frag = v_world_pos - CAMERA_POSITION_WORLD;
	float dist = length(to_frag);
	vec3 view_dir = to_frag / max(dist, 0.001);
	vec3 r = reflect(view_dir, n);
	r = normalize(vec3(r.x, max(r.y, WATER_REFLECT_MIN_Y), r.z));
	float cos_v = clamp(dot(-view_dir, n), 0.0, 1.0);
	float fresnel = WATER_F0 + (1.0 - WATER_F0) * pow(1.0 - cos_v, WATER_FRESNEL_EXP);
	vec3 c = mix(lit, wb_sky_color(r), clamp(fresnel * sky_reflect, 0.0, 1.0) * v_water);
	float rs = dot(r, wb_sun_dir);
	float lobe = exp2((rs - 1.0) * WATER_SPARK_K) + WATER_PATH_WEIGHT * exp2((rs - 1.0) * WATER_PATH_K);
	c += wb_sun_disc_color.rgb * (lobe * wb_sun_glow * sun_path_gain * v_water);
	c = mix(c, wb_fog_color_dir(view_dir), wb_fog_factor(dist));
	ALBEDO = wb_output(c);
}
