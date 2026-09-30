// World material with lit windows (WP6.4b, city buildings). Spec: World → Biomes ("City
// at night: skyline ..."; every biome must look good across the whole color script),
// Night lighting (no real lights: emissive surfaces driven by the color script).
// Identical to world.gdshader (vertex-lit, fogged, player fake light, retro faces)
// plus one emissive class:
//
//   UV2.x = 4  window: the albedo is the glass by day (COLOR.rgb, like any face); at
//              night it adds `window_glow` (linear, per material) x the street-lamp ramp
//              (wb_emissive_streetlamp), x UV2.y (0..1 per face: dim to bright rooms).
//              UV2.y is not a tint class for these faces.
//
// Other faces follow docs/CONTRACTS.md §13 exactly. Buildings keep one draw call per
// mesh (MultiMesh pools), whatever their material.
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque, fog_disabled;

#include "res://assets/shaders/world_common.gdshaderinc"

const float WB_EMISSIVE_WINDOW = 4.0;

// Night glow of lit windows (linear RGB).
uniform vec3 window_glow = vec3(1.0, 0.6, 0.28);

varying vec3 v_lit;
varying vec3 v_world_pos;
varying vec3 v_fog_col;
varying vec3 v_retro;
varying vec3 v_world_normal;

void vertex() {
	vec3 world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	bool window = UV2.x == WB_EMISSIVE_WINDOW;
	vec3 albedo = wb_albedo(COLOR.rgb, window ? WB_TINT_NONE : UV2.y);
	v_lit = wb_light(albedo, world_normal) + wb_emissive(albedo, UV2.x);
	if (window) {
		v_lit += window_glow * (wb_emissive_streetlamp * UV2.y);
	}
	v_retro = UV2.x == WB_EMISSIVE_REFLECTOR ? albedo : vec3(0.0);
	v_world_normal = world_normal;
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
