// Daily Drive ghost car (WP8.4; spec: Core loop → Modes at launch, "a translucent ghost
// car"; Performance budget → Materials: custom unlit / single-light vertex-lit only).
// One merged mesh, one draw (GhostCar builds it): body, wheels and lamps in one surface.
//   UV.x   part class: 0 body and wheels, 1 head / tail lamp, 2 brake lamp
//   COLOR  the lamp's own color (sRGB; lamps only)
// Look: a pale tint, vertex-lit by the one sun light (so the shape reads) with a
// view-fresnel rim, alpha-blended; lamps light up with the ghost's recorded flags.
// It fades into the fog like the world and thins out close to the camera (a ghost on
// top of the player's car stays out of the way). depth_draw_always: the nearest
// faces win, so the ghost does not show its own inside.
// Renderer parity: linear math, colors authored in sRGB linearized here, the result
// through wb_output(); the blend over the scene differs a little between renderers
// (Compatibility blends sRGB-encoded values), lifted like the other light alpha
// layers (fog cards): judged by eye (docs/CONTRACTS.md §13).
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_always, cull_back, fog_disabled, shadows_disabled;

#include "res://assets/shaders/world_common.gdshaderinc"

const float CLASS_LAMP = 1.0;
const float CLASS_BRAKE = 2.0;
const float CLASS_HALF_STEP = 0.5;

// The ghost's tint (sRGB) and how much of it glows on its own (the rest is sun-lit).
uniform vec3 tint = vec3(0.62, 0.86, 1.0);
uniform float self_lit = 0.55;
// Opacity: faces seen head-on, plus the rim at grazing angles.
uniform float body_alpha = 0.22;
uniform float rim_alpha = 0.5;
uniform float rim_power = 2.5;
uniform float rim_gain = 0.6;
// Lamps: opacity and brightness while lit (switched by lamps_on / brake_on, 0 or 1).
uniform float lamp_alpha = 0.85;
uniform float lamp_gain = 2.0;
uniform float lamps_on = 0.0;
uniform float brake_on = 0.0;
// Close to the camera the ghost thins to near_factor (full beyond near_end_m).
uniform float near_start_m = 5.0;
uniform float near_end_m = 14.0;
uniform float near_factor = 0.35;
// Compatibility alpha lift toward 1/2.2 (as fog_card.gdshader; 0.6 matched the Mobile
// look of the snap review: a light tint over the dark road).
uniform float compat_lift = 0.6;

varying vec3 v_color;
varying vec3 v_lamp;
varying float v_class;
varying vec3 v_world_pos;
varying vec3 v_fog_col;

void vertex() {
	vec3 world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 t = wb_srgb_to_linear(tint);
	vec3 lit = wb_light(t, world_normal);
	v_color = mix(lit, t, self_lit);
	v_lamp = wb_srgb_to_linear(COLOR.rgb) * lamp_gain;
	v_class = UV.x;
	v_fog_col = wb_fog_color_dir(normalize(v_world_pos - CAMERA_POSITION_WORLD));
}

void fragment() {
	vec3 n = normalize(NORMAL);
	float fres = pow(1.0 - clamp(dot(n, VIEW), 0.0, 1.0), rim_power);
	vec3 c = v_color * (1.0 + fres * rim_gain);
	float a = body_alpha + fres * rim_alpha;
	float on = 0.0;
	if (v_class > CLASS_BRAKE - CLASS_HALF_STEP) {
		on = brake_on;
	} else if (v_class > CLASS_LAMP - CLASS_HALF_STEP) {
		on = lamps_on;
	}
	float dist = length(v_world_pos - CAMERA_POSITION_WORLD);
	// The body thins near the camera; a lit lamp stays readable.
	a *= mix(near_factor, 1.0, smoothstep(near_start_m, near_end_m, dist));
	c = mix(c, v_lamp, on);
	a = mix(a, lamp_alpha, on);
	float fog = wb_fog_factor(dist);
	c = mix(c, v_fog_col, fog);
	a *= 1.0 - fog;
	a = clamp(a, 0.0, 1.0);
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	a = mix(a, pow(a, 1.0 / WB_BLEND_GAMMA), compat_lift);
#endif
	ALBEDO = wb_output(c);
	ALPHA = a;
}
