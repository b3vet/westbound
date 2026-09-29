// Cockpit interior (plan D11, WP4.7; docs/COCKPIT.md): dash, pillars, header, doors,
// mirror, hood cowl and the steering wheel. The shared world lighting from
// world_common.gdshaderinc (single sun, vertex-lit, colors from the color script),
// plus a sky fill: inside a cabin most light arrives as diffuse skylight through the
// glass, so every face gets albedo x wb_sky_horizon x sky_fill. That keeps the faces
// turned toward the driver (away from a sun ahead) readable at every sky_t while
// still following the color script from day to night. No fog: it is under 2 m away.
//
// Look contract (docs/CONTRACTS.md §13): COLOR.rgb is sRGB albedo (linearized here),
// UV2.x is the emissive class (wb_emissive), linear math, ALBEDO = wb_output(linear).
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque, fog_disabled, shadows_disabled;

#include "res://assets/shaders/world_common.gdshaderinc"

// Skylight share on every face (x wb_sky_horizon).
uniform float sky_fill = 0.35;

varying vec3 v_lit;

void vertex() {
	vec3 world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 albedo = wb_srgb_to_linear(COLOR.rgb);
	v_lit = wb_light(albedo, world_normal) + albedo * wb_sky_horizon.rgb * sky_fill
			+ wb_emissive(albedo, UV2.x);
}

void fragment() {
	ALBEDO = wb_output(v_lit);
}
