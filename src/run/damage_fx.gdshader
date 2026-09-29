// Player damage look (WP4.1). Spec: Lives, hits and crashes → First hit → Damage
// ("smoke from the hood and one flickering headlight on the placeholder models");
// Performance budget (no real lights, unlit effects only).
//
// mode 0 = hood smoke puff: a camera-facing particle quad (CPUParticles3D, local
//          coords; per-particle alpha and size come from the emitter's COLOR / scale),
//          lit by the single sun light like a horizontal surface, soft round edge,
//          faded by the shared fog.
// mode 1 = the flickering headlight: a small quad over the left lamp that switches
//          between a dead lamp (dark) and a sputtering flare (bright), set per frame
//          by PlayerFx through `level`.
// Both end with wb_output() (renderer parity, docs/CONTRACTS.md §13). Transparent
// pass priority is set above the sky's -97 by the material.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

#include "res://assets/shaders/world_common.gdshaderinc"

uniform int mode = 0;
// Smoke albedo (sRGB) and peak opacity.
uniform vec3 smoke_color = vec3(0.42, 0.42, 0.44);
uniform float smoke_alpha = 0.55;
// Lamp colors (sRGB): dead and lit; `level` 0..1 picks between them.
uniform vec3 lamp_dead = vec3(0.06, 0.06, 0.07);
uniform vec3 lamp_lit = vec3(1.0, 0.95, 0.82);
uniform float lamp_gain = 1.6;
uniform float level = 0.0;

varying vec3 v_world;
varying float v_alpha;

void vertex() {
	v_alpha = COLOR.a;
	if (mode == 0) {
		// Particle billboard: keep the instance position and scale, face the camera.
		mat4 bill = mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
		bill = bill * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
			vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
			vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
			vec4(0.0, 0.0, 0.0, 1.0));
		MODELVIEW_MATRIX = VIEW_MATRIX * bill;
		v_world = MODEL_MATRIX[3].xyz;
	} else {
		v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	}
}

void fragment() {
	float fog = wb_fog_factor(length(v_world - CAMERA_POSITION_WORLD));
	if (mode == 0) {
		float r = length(UV * 2.0 - 1.0);
		float a = smoothstep(1.0, 0.3, r) * smoke_alpha * v_alpha * (1.0 - fog);
		vec3 c = wb_light(wb_srgb_to_linear(smoke_color), vec3(0.0, 1.0, 0.0));
		ALBEDO = wb_output(c);
		ALPHA = a;
	} else {
		vec3 dead = wb_light(wb_srgb_to_linear(lamp_dead), vec3(0.0, 1.0, 0.0));
		vec3 lit = wb_srgb_to_linear(lamp_lit) * lamp_gain;
		vec3 c = mix(dead, lit, clamp(level, 0.0, 1.0));
		ALBEDO = wb_output(wb_apply_fog(c, length(v_world - CAMERA_POSITION_WORLD)));
		ALPHA = 1.0 - fog;
	}
}
