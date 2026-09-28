// Cloud cards: flat low-poly shapes on a sphere around the camera, lit with the
// sun color (spec: World → Sky, "flat cloud cards lit with the sun color"). One
// mesh, one draw call; they drift slowly in azimuth.
// Mesh (built by src/sun/sky.gd): VERTEX = point on/near the unit sphere,
// UV.x = -1..1 across the card, UV.y = 0 bottom .. 1 top, COLOR.r = shade jitter.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, fog_disabled, world_vertex_coords, shadows_disabled;

#include "res://assets/shaders/sky_common.gdshaderinc"

// Azimuth drift, radians per second.
uniform float drift_rad_per_s = 0.002;
// How much of the sun halo lights the cards, and the extra warm rim near the sun.
uniform float glow = 0.6;
// Sun elevation (dir.y) below which the undersides take the light (sunset).
uniform float underlight_below = 0.3;
// Cards near the horizon fade toward the sky's horizon color.
uniform float horizon_haze = 0.6;
uniform float horizon_haze_height = 0.25;

varying vec3 v_color;

void vertex() {
	vec3 p = VERTEX - NODE_POSITION_WORLD;
	float a = TIME * drift_rad_per_s;
	float ca = cos(a);
	float sa = sin(a);
	p = vec3(ca * p.x - sa * p.z, p.y, sa * p.x + ca * p.z);
	vec3 dir = normalize(p);
	VERTEX = CAMERA_POSITION_WORLD + p * wb_fog_end * WB_SKY_RADIUS_FRAC;

	// Light: tops by day, undersides when the sun is low; the side facing the
	// sun is brighter.
	float low = 1.0 - smoothstep(0.0, underlight_below, wb_sun_dir.y);
	float lit = mix(UV.y, 1.0 - UV.y * 0.7, low);
	vec2 sun_h = normalize(wb_sun_dir.xz + vec2(1e-4, 0.0));
	float facing = dot(normalize(dir.xz + vec2(1e-4, 0.0)), sun_h) * 0.5 + 0.5;
	lit = clamp(lit * (0.55 + 0.45 * facing) + (COLOR.r - 0.5) * 0.2, 0.0, 1.0);
	vec3 c = mix(wb_cloud_shadow.rgb, wb_cloud_lit.rgb, lit);
	float haze = (1.0 - smoothstep(0.0, horizon_haze_height, dir.y)) * horizon_haze;
	c = mix(c, wb_sky_color(dir), haze);
	v_color = c + wb_sun_disc_color.rgb * wb_sun_halo(dir) * glow;
}

void fragment() {
	ALBEDO = wb_output(v_color);
	ALPHA = 1.0;
}
