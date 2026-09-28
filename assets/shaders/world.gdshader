// Default world material: props, landmarks, barriers (vertex-lit, fogged, unlit pipeline).
// Conventions and color spaces in world_common.gdshaderinc. Owned by WP1.3.
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque, fog_disabled;

#include "res://assets/shaders/world_common.gdshaderinc"

varying vec3 v_lit;
varying vec3 v_world_pos;
varying vec3 v_fog_col;

void vertex() {
	vec3 world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 albedo = wb_albedo(COLOR.rgb, UV2.y);
	v_lit = wb_light(albedo, world_normal) + wb_emissive(albedo, UV2.x);
	// Fog color varies slowly with direction: per vertex. The factor is per fragment.
	v_fog_col = wb_fog_color_dir(normalize(v_world_pos - CAMERA_POSITION_WORLD));
}

void fragment() {
	vec3 c = v_lit + wb_player_light(v_lit, v_world_pos);
	float fog = wb_fog_factor(length(v_world_pos - CAMERA_POSITION_WORLD));
	ALBEDO = wb_output(mix(c, v_fog_col, fog));
}
