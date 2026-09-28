// Sky dome: zenith/horizon gradient, haze band, sun disc and halo (spec: World →
// Sky). Unit-sphere mesh placed around the camera; covers the whole frame so the
// engine clear color (which differs between renderers) never shows.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, fog_disabled, world_vertex_coords, shadows_disabled;

#include "res://assets/shaders/sky_common.gdshaderinc"

varying vec3 v_dir;

void vertex() {
	v_dir = wb_sky_dir(VERTEX, NODE_POSITION_WORLD);
	VERTEX = CAMERA_POSITION_WORLD + v_dir * wb_fog_end * WB_SKY_RADIUS_FRAC;
}

void fragment() {
	vec3 dir = normalize(v_dir);
	vec3 sky = wb_sky_color(dir);
	vec3 c = mix(sky, max(sky, wb_sun_disc_color.rgb * WB_SUN_DISC_BOOST), wb_sun_disc(dir));
	ALBEDO = wb_output(c);
	ALPHA = 1.0;
}
