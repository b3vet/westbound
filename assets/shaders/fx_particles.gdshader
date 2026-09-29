// Tire smoke and barrier sparks (WP7.4). Spec: Audio, haptics and game feel →
// Particles ("tire smoke on hard braking, and sparks on barrier scrapes"); Performance
// budget (particles clamped per tier, unlit effects only, no real lights).
//
// One pooled MultiMesh (FxParticles, src/fx/fx_particles.gd) of unit quads in world
// space (the node sits at the origin; FxParticles moves the particles on
// Events.origin_shifted). Per instance:
//   INSTANCE_CUSTOM.r  kind: 0 smoke, 1 spark     .g  age 0..1     .b  opacity scale
//   transform origin   the particle's position
//   smoke: basis x length = puff size (m); a camera-facing quad, lit by the single sun
//          like a horizontal surface, soft round edge.
//   spark: basis x = the streak (world m, along the velocity); basis y length = width;
//          a camera-facing ribbon along it, bright (emissive, not lit), hot to cool.
// Both fade in fog and end with wb_output (renderer parity, docs/CONTRACTS.md §13).
// Blend mix (smoke must darken as well as lighten); sparks are opaque in their core.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled,
	skip_vertex_transform;

#include "res://assets/shaders/world_common.gdshaderinc"

uniform vec3 smoke_color = vec3(0.78, 0.78, 0.8);
uniform float smoke_alpha = 0.45;
uniform vec3 hot_color = vec3(1.0, 0.93, 0.62);
uniform vec3 cool_color = vec3(1.0, 0.45, 0.12);
// Shape (not tuning): spark brightness above white-hot, the smoke puff's soft edge
// (radius where it is fully opaque) and the streak tail's opacity.
uniform float spark_gain = 1.3;
uniform float smoke_core = 0.2;
uniform float spark_tail = 0.2;

varying vec3 v_world;
varying float v_kind;
varying float v_age;
varying float v_scale;

void vertex() {
	vec4 ic = INSTANCE_CUSTOM;
	v_kind = ic.r;
	v_age = ic.g;
	v_scale = ic.b;
	vec3 c = MODEL_MATRIX[3].xyz;
	vec3 world;
	if (ic.r < 0.5) {
		float size = length(MODEL_MATRIX[0].xyz);
		world = c + (INV_VIEW_MATRIX[0].xyz * VERTEX.x + INV_VIEW_MATRIX[1].xyz * VERTEX.y) * size;
	} else {
		vec3 axis = MODEL_MATRIX[0].xyz;
		float width = length(MODEL_MATRIX[1].xyz);
		vec3 side = cross(axis, CAMERA_POSITION_WORLD - c);
		float sl = length(side);
		side = sl > 1e-6 ? side / sl : INV_VIEW_MATRIX[1].xyz;
		world = c + axis * VERTEX.x + side * (width * VERTEX.y);
	}
	v_world = world;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
}

void fragment() {
	float fog = wb_fog_factor(length(v_world - CAMERA_POSITION_WORLD));
	vec3 col;
	float a;
	if (v_kind < 0.5) {
		float r = length(UV * 2.0 - 1.0);
		float fade = 1.0 - v_age;
		a = smoothstep(1.0, smoke_core, r) * smoke_alpha * fade * fade * v_scale;
		col = wb_light(wb_srgb_to_linear(smoke_color), vec3(0.0, 1.0, 0.0));
	} else {
		float across = abs(UV.y * 2.0 - 1.0);
		a = (1.0 - across * across) * mix(spark_tail, 1.0, UV.x) * (1.0 - v_age * v_age) * v_scale;
		col = mix(wb_srgb_to_linear(hot_color), wb_srgb_to_linear(cool_color), v_age) * spark_gain;
	}
	ALBEDO = wb_output(col);
	ALPHA = clamp(a * (1.0 - fog), 0.0, 1.0);
}
