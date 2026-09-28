// Blob shadow (spec: Performance budget → Shadows: "a blob shadow decal under every
// vehicle, no shadow maps"). A horizontal quad (UV 0..1) under the vehicle, darkening
// what is below with a soft rounded-rectangle falloff. Alpha-blended, no depth write,
// faded by the shared distance fog. Works for single MeshInstance3D shadows and for
// MultiMesh traffic shadows (per-instance strength in INSTANCE_CUSTOM.x).
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back, shadows_disabled;

#include "res://assets/shaders/world_common.gdshaderinc"

// Darkening color (linear) and peak opacity at the center.
uniform vec3 shadow_color = vec3(0.02, 0.02, 0.04);
uniform float strength : hint_range(0.0, 1.0) = 0.6;
// Fraction of the half-extent over which the edge fades out.
uniform float softness : hint_range(0.01, 1.0) = 0.45;
// Superellipse exponent: 2 = ellipse, higher = boxier (car footprint).
uniform float boxiness : hint_range(2.0, 8.0) = 4.0;
// True for MultiMesh instances: INSTANCE_CUSTOM.x scales the strength.
uniform bool use_instance_custom = false;

varying vec3 v_world_pos;
varying float v_strength;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_strength = strength * (use_instance_custom ? INSTANCE_CUSTOM.x : 1.0);
}

void fragment() {
	vec2 p = abs(UV * 2.0 - 1.0);
	float r = pow(pow(p.x, boxiness) + pow(p.y, boxiness), 1.0 / boxiness);
	float falloff = 1.0 - smoothstep(1.0 - softness, 1.0, r);
	float fog = wb_fog_factor(length(v_world_pos - CAMERA_POSITION_WORLD));
	ALBEDO = shadow_color;
	ALPHA = v_strength * falloff * (1.0 - fog);
}
