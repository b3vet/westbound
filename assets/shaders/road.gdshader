// Road surface + markings (geometry-based markings; see world_common conventions:
// asphalt uses tint class 1 (road tone), lane lines tint class 2, reflectors emissive class 1).
// Starter version; WP1.3 owns and extends it.
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

#include "res://assets/shaders/world_common.gdshaderinc"

varying vec3 v_lit;
varying vec3 v_world_pos;

void vertex() {
	vec3 world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 albedo = wb_albedo(COLOR.rgb, UV2.y);
	v_lit = wb_light(albedo, world_normal) + wb_emissive(albedo, UV2.x);
}

void fragment() {
	vec3 c = v_lit + wb_player_light(v_lit, v_world_pos);
	ALBEDO = wb_apply_fog(c, length(v_world_pos - CAMERA_POSITION_WORLD));
}
