// Traffic sandbox debug boxes (dev only; the real vehicles are WP3.1's TrafficView).
// Vertex-lit like world.gdshader, but the color comes per instance from a MultiMesh:
//   INSTANCE_CUSTOM.rgb  albedo, authored in sRGB
//   INSTANCE_CUSTOM.a    glow: 0 = lit and fogged (bodies), 1 = full bright, unfogged
//                        (brake lights, blinkers, headlights), so lights read at range.
// Ends with wb_output() like every world shader (renderer parity, CONTRACTS §13).
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque, fog_disabled;

#include "res://assets/shaders/world_common.gdshaderinc"

varying vec3 v_lit;
varying vec3 v_world_pos;
varying vec3 v_fog_col;
varying float v_glow;

void vertex() {
	vec3 world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 albedo = wb_srgb_to_linear(INSTANCE_CUSTOM.rgb);
	v_glow = INSTANCE_CUSTOM.a;
	v_lit = mix(wb_light(albedo, world_normal), albedo, v_glow);
	v_fog_col = wb_fog_color_dir(normalize(v_world_pos - CAMERA_POSITION_WORLD));
}

void fragment() {
	float fog = wb_fog_factor(length(v_world_pos - CAMERA_POSITION_WORLD)) * (1.0 - v_glow);
	ALBEDO = wb_output(mix(v_lit, v_fog_col, fog));
}
