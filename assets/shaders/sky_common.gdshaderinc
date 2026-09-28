// Sky model shared by the dome, stars, horizon cards and clouds (spec: World →
// Sky). Everything sky-side sits "at infinity": meshes are unit directions that
// the vertex shader places around the camera at WB_SKY_RADIUS_FRAC x the fog end
// (render mode world_vertex_coords; the node transform only needs a position).
// The fog end tracks the view distance and the camera far plane sits just past
// it, so the sky is inside the far plane and behind all visible world geometry;
// uniform scaling around the camera does not change the image.
//
// Draw order: the sky parts are opaque (ALPHA = 1) but live in the transparent
// pass (blend_mix, depth_draw_never), ordered by material render_priority:
// dome < stars < horizon < clouds, all drawn after the world and depth-tested
// against it. They never write depth, so they cannot z-fight each other or the
// Compatibility renderer's depth prepass (which, for surfaces this close to the
// far plane, rejected scattered dome pixels and let the clear color through).
// World transparent effects (glow sprites, particles) must use a higher priority.
#ifndef WB_SKY_COMMON
#define WB_SKY_COMMON

#include "res://assets/shaders/world_common.gdshaderinc"

// Zenith/horizon blend: pow(elevation, exp) (< 1 keeps the horizon color low).
const float WB_SKY_GRADIENT_EXP = 0.5;
// The sun disc is this much brighter than its color (the brightest channel clips
// toward white: a hot core).
const float WB_SUN_DISC_BOOST = 1.6;
// Height (in dir.y) of the haze band where the sky melts into the fog color.
const float WB_SKY_HAZE_BAND = 0.07;
// Soft edge of the sun disc, as a fraction of its radius.
const float WB_SUN_DISC_EDGE = 0.25;
// The disc is cut by the horizon over this dir.y range.
const float WB_SUN_HORIZON_CUT = 0.002;
const float WB_SKY_RADIUS_FRAC = 0.99;

// Unit direction of a sky vertex (the mesh is built around the node origin).
vec3 wb_sky_dir(vec3 world_vertex, vec3 node_pos) {
	return normalize(world_vertex - node_pos);
}

// Sky color (linear) in a unit direction, without the sun disc.
vec3 wb_sky_color(vec3 dir) {
	float h = dir.y;
	// Blend in sqrt space (~perceptual): a linear-light blend of a blue zenith and
	// a warm horizon turns grey-lavender in between.
	float t = pow(clamp(h, 0.0, 1.0), WB_SKY_GRADIENT_EXP);
	vec3 g = mix(sqrt(wb_sky_horizon.rgb), sqrt(wb_sky_zenith.rgb), t);
	vec3 grad = g * g;
	// At and below the horizon the sky is exactly the fog color (+ in-scatter),
	// so fogged geometry and the ground edge vanish into it.
	float haze = 1.0 - smoothstep(0.0, WB_SKY_HAZE_BAND, h);
	vec3 c = mix(grad, wb_fog_color.rgb, haze);
	return c + wb_sun_disc_color.rgb * wb_sun_halo(dir) * mix(1.0, WB_FOG_HALO, haze);
}

// Sun disc coverage 0..1 in a unit direction (cut by the horizon).
float wb_sun_disc(vec3 dir) {
	float r = max(wb_sun_disc_size, 1e-4);
	// 1 - cos(a) ~ a^2 / 2 for small angles: no acos per pixel.
	float edge = 0.5 * r * r;
	float d = 1.0 - dot(dir, wb_sun_dir);
	float disc = 1.0 - smoothstep(edge * (1.0 - WB_SUN_DISC_EDGE), edge * (1.0 + WB_SUN_DISC_EDGE), d);
	return disc * smoothstep(-WB_SUN_HORIZON_CUT, WB_SUN_HORIZON_CUT, dir.y);
}

#endif
