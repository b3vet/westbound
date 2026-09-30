// Vehicle material (spec: Cars → Car shader: "vertex-lit with one light, plus a matcap
// lookup for paint sheen (one texture read). Paint color and optional livery mask are
// shader parameters, so recoloring costs nothing. No PBR."). Owned by WP2.1.
//
// One shader, one material per slot (assets/shaders/materials/vehicle_*.tres):
//   slot 0 paint   albedo = paint_color (sRGB param) x COLOR.r (a linear shade
//                  multiplier baked by the import script; 1 = pure paint), optional
//                  livery mask (UV) mixing in livery_color; matcap sheen + sky fresnel
//   slot 1 trim    albedo = COLOR.rgb (sRGB); tires, rims, grilles, bumpers
//   slot 2 glass   albedo = COLOR.rgb (sRGB); strong sky fresnel + sheen
//   slot 3 lamp    head/tail lamps: a lit lens by day, full emissive as the color
//                  script's wb_emissive_headlight ramp comes up at night
//   slot 4 signal  brake, blinkers, reverse: full emissive; car_visual shows the node
//                  only while the light is on (no draw call while off)
// Lighting, fog and the renderer-parity rules come from world_common.gdshaderinc
// (docs/CONTRACTS.md §13): linear math, colors authored in sRGB are linearized here,
// and the shader ends with ALBEDO = wb_output(linear).
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque, fog_disabled, shadows_disabled;

#include "res://assets/shaders/world_common.gdshaderinc"

const int SLOT_PAINT = 0;
const int SLOT_TRIM = 1;
const int SLOT_GLASS = 2;
const int SLOT_LAMP = 3;
const int SLOT_SIGNAL = 4;

uniform int slot = 0;
// Paint color in sRGB (no source_color: converted here so both renderers agree).
uniform vec3 paint_color = vec3(0.9, 0.2, 0.15);
// Matcap (view-space normal -> highlight intensity; raw values, no color conversion).
uniform sampler2D matcap : hint_default_black, filter_linear, repeat_disable;
// Matcap highlight strength (x the sun light color and energy).
uniform float sheen = 0.35;
// Sky reflection at grazing angles (x wb_sky_horizon), and the fresnel exponent.
uniform float sky_reflect = 0.25;
uniform float fresnel_power = 3.0;
// Optional livery: mask (UV, red channel) mixes livery_color (sRGB) over the paint.
uniform bool use_livery = false;
uniform sampler2D livery_mask : hint_default_black, filter_linear;
uniform vec3 livery_color = vec3(1.0);
// Lamps: lens albedo while off = COLOR x lens_factor; night ramp gain.
uniform float lens_factor = 0.45;
uniform float lamp_night_gain = 1.6;
// Emissive color multiplier (lamps and signals).
uniform float emissive_gain = 1.0;

varying vec3 v_albedo;
varying vec3 v_shade;
varying float v_up;
varying vec3 v_world_pos;
varying vec3 v_fog_col;
varying vec3 v_emit;
varying float v_on;

void vertex() {
	vec3 world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 albedo;
	if (slot == SLOT_PAINT) {
		albedo = wb_srgb_to_linear(paint_color) * COLOR.r;
	} else {
		albedo = wb_srgb_to_linear(COLOR.rgb);
	}
	v_emit = vec3(0.0);
	v_on = 0.0;
	if (slot == SLOT_LAMP) {
		v_emit = albedo * emissive_gain;
		v_on = clamp(wb_emissive_headlight * lamp_night_gain, 0.0, 1.0);
		albedo *= lens_factor;
	} else if (slot == SLOT_SIGNAL) {
		v_emit = albedo * emissive_gain;
		v_on = 1.0;
	}
	v_albedo = albedo;
	// wb_light is linear in the albedo: light a white surface, multiply per fragment
	// (so the livery can change the albedo there).
	v_shade = wb_light(vec3(1.0), world_normal);
	// Surfaces facing up reflect the sky; vertical ones only a little.
	v_up = 0.5 + 0.5 * world_normal.y;
	v_fog_col = wb_fog_color_dir(normalize(v_world_pos - CAMERA_POSITION_WORLD));
}

void fragment() {
	vec3 albedo = v_albedo;
	if (slot == SLOT_PAINT && use_livery) {
		float m = texture(livery_mask, UV).r;
		albedo = mix(albedo, wb_srgb_to_linear(livery_color) * COLOR.r, m);
	}
	vec3 c = albedo * v_shade;
	// Paint sheen: one matcap read on the view-space normal, lit by the sun color,
	// plus a sky-colored fresnel rim. NORMAL and VIEW are view space here.
	vec3 n = normalize(NORMAL);
	float hi = texture(matcap, vec2(n.x, -n.y) * 0.5 + 0.5).r;
	float fres = pow(1.0 - clamp(dot(n, VIEW), 0.0, 1.0), fresnel_power);
	c += hi * sheen * wb_sun_light_color.rgb * wb_sun_light_energy;
	c += fres * v_up * sky_reflect * wb_sky_horizon.rgb;
	c = mix(c, v_emit, v_on);
	float fog = wb_fog_factor(length(v_world_pos - CAMERA_POSITION_WORLD));
	ALBEDO = wb_output(mix(c, v_fog_col, fog));
}
