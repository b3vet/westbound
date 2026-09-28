// Stars: tiny camera-facing quads of fixed pixel size, opaque, drawn just inside
// the dome (spec: World → Sky, "stars that fade in at night"). Each quad shows
// the sky color behind it plus the star, so no blending is needed (blending
// differs between the renderers' color spaces). Sky hides the node by day.
// Mesh: VERTEX = star direction, UV = quad corner (-1..1), COLOR.r = brightness,
// COLOR.g = twinkle phase.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, fog_disabled, world_vertex_coords, shadows_disabled;

#include "res://assets/shaders/sky_common.gdshaderinc"

uniform float size_px = 2.0;
uniform float twinkle_hz = 0.7;
uniform float twinkle_depth = 0.35;
// Stars fade out toward the horizon haze over this dir.y range.
uniform vec2 horizon_fade = vec2(0.03, 0.25);

varying vec3 v_color;

void vertex() {
	vec3 dir = wb_sky_dir(VERTEX, NODE_POSITION_WORLD);
	vec3 world = CAMERA_POSITION_WORLD + dir * wb_fog_end * WB_SKY_RADIUS_FRAC;
	vec4 clip = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(world, 1.0));
	clip.xy += UV * size_px / VIEWPORT_SIZE * clip.w;
	POSITION = clip;
	float tw = 1.0 - twinkle_depth * (0.5 + 0.5 * sin(TIME * twinkle_hz * 6.2831853 + COLOR.g * 6.2831853));
	float star = COLOR.r * tw * wb_stars * smoothstep(horizon_fade.x, horizon_fade.y, dir.y);
	v_color = wb_sky_color(dir) + vec3(star);
}

void fragment() {
	ALBEDO = wb_output(v_color);
	ALPHA = 1.0;
}
