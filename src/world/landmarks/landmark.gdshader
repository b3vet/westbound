// Checkpoint landmarks and warning signs (WP5.3): the world material (world.gdshader,
// docs/CONTRACTS.md §13) plus two things it cannot do.
//   1. Bending. Builds are authored in road space (x = d, y = height, z = -(s - s0))
//      and bent along the road here, through `stations` sampled at placement
//      (xyz = reference line relative to the node, w = world heading). A 360 m bridge
//      on a 1,200 m curve follows the road without rebuilding its mesh. Rigid builds
//      (signs) set station_count = 0 and use the node transform.
//   2. Sign text. UV (-1 = none) addresses a line of the shared text atlas (R8
//      coverage) through line_rect[]; text is lit, fogged and graded exactly like the
//      panel it sits on, so it matches on both renderers.
// Faces with emissive class 1 (reflector) are retro-reflective (spec: World → Night
// lighting): they glow more with the color script's reflector ramp and take more of
// the player's fake headlight.
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque, fog_disabled;

#include "res://assets/shaders/world_common.gdshaderinc"

// Landmarks.STATION_MAX.
const int STATION_MAX = 80;
const int LINE_MAX = 4;

uniform vec4 stations[STATION_MAX];
uniform int station_count = 0;
// Template s of station 0 (-z) and 1 / station spacing.
uniform float station_s0 = 0.0;
uniform float station_inv_step = 0.0;

uniform sampler2D text_atlas : hint_default_black, filter_linear_mipmap, repeat_disable;
// Per text line: atlas region (u0, v0, du, dv).
uniform vec4 line_rect[LINE_MAX];
// Lettering color (sRGB, like vertex colors).
uniform vec3 text_color = vec3(0.94, 0.93, 0.89);
uniform float retro_emissive_gain = 1.6;
uniform float retro_light_gain = 2.5;
// Share of full sunlight a reflective face gets whatever way it faces (sheeting is
// sky-lit; the player drives into the sun, so every sign face is on the shadow side).
uniform float retro_day_fill = 0.55;

varying vec3 v_lit;
varying vec3 v_lit_text;
varying vec3 v_world_pos;
varying vec3 v_fog_col;
varying vec2 v_text_uv;
varying float v_retro;

void vertex() {
	vec3 p = VERTEX;
	vec3 n = NORMAL;
	if (station_count > 1) {
		float f = (-p.z - station_s0) * station_inv_step;
		int i = clamp(int(floor(f)), 0, station_count - 2);
		float t = f - float(i);
		vec4 a = stations[i];
		vec4 b = stations[i + 1];
		vec3 base = mix(a.xyz, b.xyz, t);
		float h = mix(a.w, b.w, t);
		vec3 right = vec3(cos(h), 0.0, sin(h));
		vec3 back = vec3(-sin(h), 0.0, cos(h));
		p = base + right * p.x + vec3(0.0, p.y, 0.0);
		n = right * n.x + vec3(0.0, n.y, 0.0) + back * n.z;
		VERTEX = p;
		NORMAL = n;
	}
	vec3 world_normal = normalize((MODEL_MATRIX * vec4(n, 0.0)).xyz);
	v_world_pos = (MODEL_MATRIX * vec4(p, 1.0)).xyz;
	float retro = UV2.x == WB_EMISSIVE_REFLECTOR ? 1.0 : 0.0;
	v_retro = retro;
	float glow = mix(1.0, retro_emissive_gain, retro);
	vec3 sun_n = normalize(vec3(wb_sun_dir.x, max(wb_sun_dir.y, WB_LIGHT_MIN_SIN), wb_sun_dir.z));
	float fill = retro * retro_day_fill;
	vec3 albedo = wb_albedo(COLOR.rgb, UV2.y);
	v_lit = mix(wb_light(albedo, world_normal), wb_light(albedo, sun_n), fill) + wb_emissive(albedo, UV2.x) * glow;
	vec3 ink = wb_albedo(text_color, WB_TINT_NONE);
	v_lit_text = mix(wb_light(ink, world_normal), wb_light(ink, sun_n), fill) + wb_emissive(ink, UV2.x) * glow;
	v_text_uv = vec2(-1.0);
	if (UV.x >= 0.0) {
		int line = clamp(int(floor(UV.y * 0.5)), 0, LINE_MAX - 1);
		vec4 r = line_rect[line];
		float v = UV.y - 2.0 * float(line);
		v_text_uv = r.xy + vec2(UV.x, 1.0 - v) * r.zw;
	}
	v_fog_col = wb_fog_color_dir(normalize(v_world_pos - CAMERA_POSITION_WORLD));
}

void fragment() {
	// Sampled in uniform control flow (mipmaps need screen-space derivatives).
	float cov = texture(text_atlas, clamp(v_text_uv, vec2(0.0), vec2(1.0))).r * step(0.0, v_text_uv.x);
	vec3 c = mix(v_lit, v_lit_text, cov);
	c += wb_player_light(c, v_world_pos) * (1.0 + v_retro * retro_light_gain);
	float fog = wb_fog_factor(length(v_world_pos - CAMERA_POSITION_WORLD));
	ALBEDO = wb_output(mix(c, v_fog_col, fog));
}
