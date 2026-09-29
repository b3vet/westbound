// Road surface + markings (geometry-based markings; see world_common conventions:
// asphalt uses tint class 1 (road tone), lane lines tint class 2, reflectors
// emissive class 1, retro-reflective in the player's headlights). Owned by WP1.3;
// must stay identical to world.gdshader apart from comments (road chunks merge
// their surfaces on that basis, WP4.6).
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque, fog_disabled;

#include "res://assets/shaders/world_common.gdshaderinc"

varying vec3 v_lit;
varying vec3 v_world_pos;
varying vec3 v_fog_col;
// Retro-reflective faces (emissive class 1): the linear albedo, 0 elsewhere.
varying vec3 v_retro;
varying vec3 v_world_normal;

void vertex() {
	vec3 world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 albedo = wb_albedo(COLOR.rgb, UV2.y);
	v_lit = wb_light(albedo, world_normal) + wb_emissive(albedo, UV2.x);
	v_retro = UV2.x == WB_EMISSIVE_REFLECTOR ? albedo : vec3(0.0);
	v_world_normal = world_normal;
	// Fog color varies slowly with direction: per vertex. The factor is per fragment.
	v_fog_col = wb_fog_color_dir(normalize(v_world_pos - CAMERA_POSITION_WORLD));
}

void fragment() {
	vec3 c = v_lit + wb_player_light(v_lit, v_world_pos);
	if (v_retro.r + v_retro.g + v_retro.b > 0.0) {
		c += wb_retro_light(v_retro, v_world_pos, v_world_normal);
	}
	float fog = wb_fog_factor(length(v_world_pos - CAMERA_POSITION_WORLD));
	ALBEDO = wb_output(mix(c, v_fog_col, fog));
}
