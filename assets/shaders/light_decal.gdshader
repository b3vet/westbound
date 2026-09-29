// Additive light decals on the road (WP5.4). Spec: World → Night lighting (no real
// lights): the player's headlight cone decal, traffic headlight light-cone decals and
// street-lamp light-pool decals; Performance budget (emissive geometry, additive
// sprites and road decals only; minimal overdraw). One shader, three materials:
//   materials/light_cone.tres    the player's cone: a strip that follows the road,
//                                its rows set per frame (PlayerHeadlights)
//   materials/traffic_cone.tres  traffic cones: one MultiMesh (HeadlightCones)
//   materials/lamp_pool.tres     street-lamp pools: one MultiMesh (StreetLampPools)
// Brightness follows the color script's emissive ramp (`ramp`), fades in the fog like
// the world shaders and is 0 by day; the nodes hide themselves while the ramp is off.
//
// Shapes (UV):
//   SHAPE_CONE  UV.x side (0 left edge, 1 right edge), UV.y along (0 at the lamps
//               .. 1 at the far end), UV2.x the cone's width at the vertex: the
//               across coordinate is interpolated as (UV.x * width, width) and
//               divided per fragment, so it is exact on the trapezoid (no diagonal
//               seam). Soft edges, a short fade-in, falling off ahead.
//   SHAPE_POOL  UV 0..1 over an ellipse's bounding quad: a soft round pool.
// Road-following strip (use_rows): VERTEX.x = side (0 left, 1 right), VERTEX.z = row;
// the row's end points come from rows_left / rows_right (node space).
// MultiMesh instances (use_instance_custom): INSTANCE_CUSTOM.r scales the brightness.
//
// Renderer parity (docs/CONTRACTS.md §13, additive effects): Mobile adds linear light;
// Compatibility adds in its display-encoded buffer, so the decal adds
// wb_output(bg + c) - wb_output(bg) over the road's own radiance bg (as the glow
// shader's headlight pools do). No COLOR input (Compatibility's MultiMesh quirk).
// Transparent pass priority 1 (> the sky's -97), set in the materials.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

#include "res://assets/shaders/world_common.gdshaderinc"

const int SHAPE_CONE = 0;
const int SHAPE_POOL = 1;
const int RAMP_HEADLIGHT = 0;
const int RAMP_STREETLAMP = 1;
// Rows of the road-following strip (PlayerHeadlights.MAX_ROWS).
const int MAX_ROWS = 17;
// Nothing below one 8-bit step (Compatibility's curve would show faint boxes).
const float DECAL_FLOOR = 0.002;

uniform int shape = 0;
uniform int ramp = 0;
// Light color (sRGB, converted here) and peak strength (linear, x the ramp).
uniform vec3 light_color = vec3(1.0, 0.93, 0.8);
uniform float strength = 0.3;
// Per-draw multiplier (the player's high beams).
uniform float gain = 1.0;
uniform bool use_instance_custom = false;
uniform bool use_rows = false;
uniform vec4 rows_left[17];
uniform vec4 rows_right[17];
// Cone: edge softness across (higher = harder middle), fade-in near the lamps (share
// of the length), where the falloff along starts (share of the length) and its power.
uniform float edge_power = 1.2;
uniform float near_fade = 0.1;
uniform float along_hold = 0.2;
uniform float along_power = 1.4;
// Pool: falloff power toward the rim.
uniform float pool_power = 1.6;

varying vec3 v_color;
varying vec3 v_world;
// (across * width, width): see SHAPE_CONE.
varying vec2 v_across;


void vertex() {
	float width = UV2.x;
	if (use_rows) {
		int r = clamp(int(VERTEX.z + 0.5), 0, MAX_ROWS - 1);
		VERTEX = mix(rows_left[r].xyz, rows_right[r].xyz, VERTEX.x);
		width = length(rows_right[r].xyz - rows_left[r].xyz);
	}
	width = max(width, 0.001);
	v_across = vec2(UV.x * width, width);
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float k = ramp == RAMP_STREETLAMP ? wb_emissive_streetlamp : wb_emissive_headlight;
	float inst = use_instance_custom ? INSTANCE_CUSTOM.r : 1.0;
	v_color = wb_srgb_to_linear(light_color) * (strength * gain * inst * clamp(k, 0.0, 1.0));
}


// Additive output (see the header): the linear light to add over the road radiance bg.
vec3 decal_output(vec3 linear_add, vec3 bg) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return max(wb_output(bg + linear_add) - wb_output(bg), vec3(0.0));
#else
	return wb_output(linear_add);
#endif
}


void fragment() {
	float a;
	if (shape == SHAPE_POOL) {
		vec2 p = UV * 2.0 - 1.0;
		a = pow(max(1.0 - dot(p, p), 0.0), pool_power);
	} else {
		float u = v_across.x / v_across.y * 2.0 - 1.0;
		float v = clamp(UV.y, 0.0, 1.0);
		a = pow(max(1.0 - u * u, 0.0), edge_power) * smoothstep(0.0, near_fade, v)
			* pow(1.0 - smoothstep(along_hold, 1.0, v), along_power);
	}
	vec3 to_frag = v_world - CAMERA_POSITION_WORLD;
	float fog = wb_fog_factor(length(to_frag));
	vec3 c = v_color * (a * (1.0 - fog));
	if (max(c.r, max(c.g, c.b)) < DECAL_FLOOR) {
		discard;
	}
	// The road under the decal, shaded as road.gdshader does (light, fake light, fog).
	vec3 road = wb_light(wb_albedo(vec3(1.0), WB_TINT_ROAD), vec3(0.0, 1.0, 0.0));
	road += wb_player_light(road, v_world);
	vec3 bg = mix(road, wb_fog_color_dir(to_frag / max(length(to_frag), 0.001)), fog);
	ALBEDO = decal_output(c, bg);
}
