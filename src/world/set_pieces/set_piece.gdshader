// Set-piece props (WP6.3): the world material (world.gdshader, docs/CONTRACTS.md §13)
// plus three things it cannot do:
//   1. Text: UV >= 0 addresses the text atlas (R8 coverage, LandmarkTextAtlas). On
//      signs (UV.y < 2) the lettering (`text_color`) is mixed over the face before
//      lighting and fog, so it is lit, fogged and graded exactly like its sign on both
//      renderers. Painted road legends (UV.y - 2 is the atlas v) keep their vertex color
//      (road paint) where the letters are and are cut out elsewhere.
//   2. Retro-reflection with a day fill (emissive class 1: sign faces, cone collars,
//      barrier chevrons, the arrow board's frame): as landmark.gdshader, the faces glow
//      with the reflector ramp, take the player's fake headlight and get a share of full
//      sun whichever way they face (the player drives into the sun).
//   3. Flashing lamps (UV2.x = 4, the arrow board): albedo x flash_gain, a light source
//      whatever the time of day; the view sets flash_gain every frame.
// Everything is linear math before wb_output(): the same on Mobile and Compatibility.
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque, fog_disabled;

#include "res://assets/shaders/world_common.gdshaderinc"

const float WB_EMISSIVE_FLASH = 4.0;

uniform sampler2D text_atlas : hint_default_black, filter_linear_mipmap, repeat_disable;
// Lettering color (sRGB, like vertex colors).
uniform vec3 text_color = vec3(0.11, 0.11, 0.13);
uniform float retro_emissive_gain = 1.6;
uniform float retro_day_fill = 0.55;
// The flashing lamps' brightness this frame (x their albedo).
uniform float flash_gain = 1.0;

varying vec3 v_lit;
varying vec3 v_lit_text;
varying vec3 v_world_pos;
varying vec3 v_fog_col;
varying vec3 v_retro;
varying vec3 v_world_normal;
varying float v_flash;
varying vec3 v_flash_col;

void vertex() {
	vec3 world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = world_normal;
	vec3 albedo = wb_albedo(COLOR.rgb, UV2.y);
	float retro = UV2.x == WB_EMISSIVE_REFLECTOR ? 1.0 : 0.0;
	float glow = mix(1.0, retro_emissive_gain, retro);
	vec3 sun_n = normalize(vec3(wb_sun_dir.x, max(wb_sun_dir.y, WB_LIGHT_MIN_SIN), wb_sun_dir.z));
	float fill = retro * retro_day_fill;
	v_flash = UV2.x == WB_EMISSIVE_FLASH ? 1.0 : 0.0;
	v_flash_col = albedo;
	v_lit = mix(wb_light(albedo, world_normal), wb_light(albedo, sun_n), fill) + wb_emissive(albedo, UV2.x) * glow;
	vec3 ink = wb_albedo(text_color, WB_TINT_NONE);
	v_lit_text = mix(wb_light(ink, world_normal), wb_light(ink, sun_n), fill);
	v_retro = retro > 0.0 ? albedo : vec3(0.0);
	v_fog_col = wb_fog_color_dir(normalize(v_world_pos - CAMERA_POSITION_WORLD));
}

void fragment() {
	vec3 c = v_lit;
	// Sampled everywhere (uniform control flow for the mip derivatives); faces without
	// text use UV (-1, -1), which clamps onto the atlas's black gutter.
	bool painted = UV.y >= 2.0;
	float cover = texture(text_atlas, vec2(UV.x, painted ? UV.y - 2.0 : UV.y)).r;
	if (UV.x >= 0.0) {
		if (painted) {
			if (cover < 0.5) {
				discard;
			}
		} else {
			c = mix(c, v_lit_text, cover);
		}
	}
	c += wb_player_light(c, v_world_pos);
	if (v_retro.r + v_retro.g + v_retro.b > 0.0) {
		c += wb_retro_light(v_retro, v_world_pos, v_world_normal);
	}
	if (v_flash > 0.0) {
		c = v_flash_col * flash_gain;
	}
	float fog = wb_fog_factor(length(v_world_pos - CAMERA_POSITION_WORLD));
	ALBEDO = wb_output(mix(c, v_fog_col, fog));
}
