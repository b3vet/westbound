// Additive glow sprites and headlight pools (WP3.1). Spec: Performance budget →
// Night lighting ("emissive geometry, additive glow sprites and road decals only"),
// Post-processing ("'Glow' is faked with sprites"), Transparency ("clamped in screen
// size"); World → Night lighting (traffic headlights: emissive quads, additive glow
// sprites and a light-cone decal on the road; rear lights with glow sprites).
//
// One MultiMesh for every traffic vehicle (TrafficView): each instance is a lamp PAIR
// (front or rear) of one vehicle and uses that vehicle's own transform (model frame:
// -Z forward, +X right, Y up, origin on the road under the body center). Its mesh has
// two camera-facing quads (VERTEX.x = -1 left lamp, +1 right lamp; UV = corner) and one
// ground quad ahead of the pair (UV2.x = 1: the headlight pool; VERTEX.z = distance
// ahead of the lamps, negative).
//   INSTANCE_CUSTOM.r  kind_l + 8 * kind_r + 64 * front   (TrafficLights.KIND_*, exact)
//   INSTANCE_CUSTOM.g  lamp half spacing (m)   .b  lamp height (m)   .a  lamp z (m)
// Sprites keep a clamped screen size, fade when the lamp faces away and in fog, and are
// pulled toward the camera so the car's own body never clips them. Unlit lamps
// collapse to a point (no fragments). Transparent pass priority 1 (> the sky's -97).
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled,
	skip_vertex_transform;

#include "res://assets/shaders/world_common.gdshaderinc"

const int KIND_HEAD = 1;
const int KIND_COUNT = 6;
// TrafficLights.GLOW_KIND_STRIDE / GLOW_FRONT.
const int KIND_STRIDE = 8;
const int FRONT_CODE = 64;
const float GLOW_FLOOR = 0.002;

// Per kind (TrafficLights.KIND_*), in one vec4 array: [kind] = color (sRGB) with
// intensity in alpha, [KIND_COUNT + kind].x = sprite size (m).
uniform vec4 kind_look[12];
// Screen-size clamp (pixels of the rendered viewport).
uniform float min_px = 3.0;
uniform float max_px = 80.0;
// Sprites move this far toward the camera (m) to clear the body they sit on.
uniform float pull_m = 0.35;
// Fade by how directly the lamp faces the camera: cos of the fully faded and full angles.
uniform float face_min = -0.25;
uniform float face_max = 0.55;
// Sprite brightness by day relative to night (a sunlit scene needs less).
uniform float day_gain = 0.7;
// Headlight pool on the road (sRGB color, strength), shown with the night ramp.
uniform vec3 pool_color = vec3(1.0, 0.92, 0.75);
uniform float pool_strength = 0.22;
uniform float pool_lift_m = 0.05;

// Renderer parity for additive blending (see glow_output): Compatibility adds in its
// display-encoded buffer, so it needs the linear level the sprites land on: a typical
// car body or road level, darker at night.
uniform float blend_background_day = 0.05;
uniform float blend_background_night = 0.02;

varying vec3 v_color;
varying float v_night;
varying vec3 v_world;
varying vec2 v_uv;
varying float v_pool;

// Additive output. Mobile adds linear light and takes it as is. On Compatibility the
// buffer value that displays linear light L is wb_output(L), so over a background of
// linear level bg the sprite adds wb_output(bg + c) - wb_output(bg) (see
// blend_background_*; the pools use the road's own radiance).
vec3 glow_output(vec3 linear_add, vec3 bg) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return max(wb_output(bg + linear_add) - wb_output(bg), vec3(0.0));
#else
	return wb_output(linear_add);
#endif
}


void vertex() {
	vec4 ic = INSTANCE_CUSTOM;
	int code = int(ic.r + 0.5);
	int kl = code % KIND_STRIDE;
	int kr = (code / KIND_STRIDE) % KIND_STRIDE;
	bool front = code >= FRONT_CODE;
	vec3 fwd = -normalize(MODEL_MATRIX[2].xyz);
	float night = clamp(wb_emissive_headlight, 0.0, 1.0);
	v_night = night;
	v_uv = UV;
	v_pool = UV2.x;
	if (UV2.x > 0.5) {
		// Headlight pool on the road ahead of a front pair with a headlight on.
		bool on = front && (kl == KIND_HEAD || kr == KIND_HEAD) && night > 0.0;
		vec3 world = (MODEL_MATRIX * vec4(VERTEX.x, pool_lift_m, ic.a + VERTEX.z, 1.0)).xyz;
		v_world = world;
		float fog = wb_fog_factor(length(world - CAMERA_POSITION_WORLD));
		v_color = wb_srgb_to_linear(pool_color) * pool_strength * night * (1.0 - fog);
		if (!on) {
			world = MODEL_MATRIX[3].xyz;
		}
		VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	} else {
		float side = VERTEX.x;
		int kind = clamp(side < 0.0 ? kl : kr, 0, KIND_COUNT - 1);
		vec3 center = (MODEL_MATRIX * vec4(side * ic.g, ic.b, ic.a, 1.0)).xyz;
		vec3 to_cam = CAMERA_POSITION_WORLD - center;
		float dist = max(length(to_cam), 0.001);
		float face = smoothstep(face_min, face_max, dot(front ? fwd : -fwd, to_cam / dist));
		vec4 kc = kind_look[kind];
		float gain = mix(day_gain, 1.0, night);
		v_color = wb_srgb_to_linear(kc.rgb) * kc.a * face * gain * (1.0 - wb_fog_factor(dist));
		vec3 cv = (VIEW_MATRIX * vec4(center, 1.0)).xyz;
		cv += normalize(-cv) * pull_m;
		float depth = max(-cv.z, 0.05);
		// abs(): the projection may flip Y.
		float px_per_m = abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y * 0.5 / depth;
		float size = clamp(kind_look[KIND_COUNT + kind].x * px_per_m, min_px, max_px) / px_per_m;
		vec2 corner = UV * 2.0 - 1.0;
		VERTEX = cv + vec3(corner * size * 0.5, 0.0);
		if (kind == 0 || face <= 0.0) {
			VERTEX = cv;
		}
	}
}

void fragment() {
	float a;
	if (v_pool > 0.5) {
		// Across (u) falls off to the edges; along (v) fades in near the car and out far away.
		float u = v_uv.x * 2.0 - 1.0;
		a = (1.0 - u * u) * (1.0 - v_uv.y) * smoothstep(0.0, 0.2, v_uv.y);
	} else {
		float r = length(v_uv * 2.0 - 1.0);
		float halo = max(1.0 - r, 0.0);
		a = halo * halo + 0.6 * pow(halo, 8.0);
	}
	vec3 c = v_color * a;
	// Nothing below one 8-bit step: Compatibility's output curve would lift zero slightly
	// and the additive quads would show as faint boxes.
	if (max(c.r, max(c.g, c.b)) < GLOW_FLOOR) {
		discard;
	}
	vec3 bg = vec3(mix(blend_background_day, blend_background_night, v_night));
	if (v_pool > 0.5) {
		// The road under the pool, shaded as road.gdshader does (light, fake light, fog).
		vec3 road = wb_light(wb_albedo(vec3(1.0), WB_TINT_ROAD), vec3(0.0, 1.0, 0.0));
		road += wb_player_light(road, v_world);
		vec3 to_frag = v_world - CAMERA_POSITION_WORLD;
		bg = mix(road, wb_fog_color_dir(normalize(to_frag)), wb_fog_factor(length(to_frag)));
	}
	ALBEDO = glow_output(c, bg);
}
