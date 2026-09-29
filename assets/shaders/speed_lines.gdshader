// Speed lines and wind streaks (WP7.4). Spec: Audio, haptics and game feel → Speed
// effects ("speed lines and wind-streak particles above 180 km/h"); Performance budget
// (Transparency: "no large translucent full-screen layers"); plan D16 (nothing covers
// the road in the hood and cockpit cameras).
//
// One static mesh of thin quads (SpeedLines, src/fx/speed_lines.gd), drawn in screen
// space: each quad is one radial streak that runs outward from `inner` (screen radius,
// 0 centre, 1 edge per axis) past the edge, looping with `travel` (streak passes,
// integrated on the CPU from the speed, so slow motion slows them). Per vertex:
//   VERTEX.x  0 tail .. 1 head          VERTEX.y  -1 .. 1 across
//   UV.x      streak angle / TAU        UV.y      phase offset
//   UV2.x     jitter (length, rate)     UV2.y     streak index
// Every `wind_every`-th streak is a wind streak: shorter, wider, fainter and slower.
// Streaks past `visible_count` (the quality clamp) collapse outside the clip volume.
// The quads sit at view depth `depth_m`, so the cockpit's dash and pillars (closer)
// hide them and the car in the outside cameras (farther) stays under them.
// Additive; ends with wb_output via speed_output (renderer parity: CONTRACTS.md §13,
// additive layers are judged by eye).
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled,
	skip_vertex_transform;

#include "res://assets/shaders/world_common.gdshaderinc"

uniform float intensity = 0.0;
uniform float travel = 0.0;
uniform int visible_count = 0;
uniform int wind_every = 3;
uniform float inner = 0.55;
uniform float outer = 1.45;
uniform float length_frac = 0.35;
uniform float width_px = 2.0;
uniform float depth_m = 2.5;
uniform vec3 color = vec3(0.92, 0.95, 1.0);
uniform float strength = 0.22;
uniform float night_gain = 0.45;
// Streak shape (not tuning): the viewport height width_px refers to, the jitter ranges
// of rate and length, the wind streaks' rate, length, width and strength factors, the
// fade-in share of a pass and the head's brightness curve.
uniform float ref_height_px = 720.0;
uniform float rate_jitter = 0.4;
uniform float length_jitter = 0.8;
uniform float wind_rate = 0.6;
uniform float wind_length = 0.45;
uniform float wind_width = 2.5;
uniform float wind_strength = 0.45;
uniform float fade_in = 0.15;
uniform float head_power = 1.5;
// Additive parity (as the glow shader): the linear background level the streaks land
// on, by day and at night.
uniform float blend_background_day = 0.08;
uniform float blend_background_night = 0.02;

varying vec2 v_shape;
varying float v_alpha;
varying float v_night;

vec3 speed_output(vec3 linear_add, vec3 bg) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return max(wb_output(bg + linear_add) - wb_output(bg), vec3(0.0));
#else
	return wb_output(linear_add);
#endif
}

void vertex() {
	float index = UV2.y;
	float jitter = UV2.x;
	bool wind = wind_every > 0 && mod(index + 0.5, float(wind_every)) < 1.0;
	float rate = (1.0 - 0.5 * rate_jitter + rate_jitter * jitter) * (wind ? wind_rate : 1.0);
	float p = fract(travel * rate + UV.y);
	float len = length_frac * (1.0 - 0.5 * length_jitter + length_jitter * jitter)
		* (wind ? wind_length : 1.0) * mix(0.5, 1.0, intensity);
	float head = mix(inner, outer + len, p);
	float tail = max(head - len, inner);
	float r = mix(tail, head, VERTEX.x);
	float a = UV.x * TAU;
	vec2 dir = vec2(cos(a), sin(a));
	vec2 half_px = VIEWPORT_SIZE * 0.5;
	vec2 d_px = normalize(dir * half_px);
	vec2 n_px = vec2(-d_px.y, d_px.x);
	float w = width_px * VIEWPORT_SIZE.y / ref_height_px * (wind ? wind_width : 1.0);
	vec2 pos_px = dir * r * half_px + n_px * VERTEX.y * w * 0.5;
	vec2 ndc = pos_px / half_px;
	vec4 c = PROJECTION_MATRIX * vec4(0.0, 0.0, -depth_m, 1.0);
	POSITION = vec4(ndc * c.w, c.z, c.w);
	if (int(index + 0.5) >= visible_count || intensity <= 0.0) {
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);   // outside the clip volume: no fragments
	}
	v_shape = vec2(VERTEX.x, VERTEX.y);
	v_alpha = smoothstep(0.0, fade_in, p) * intensity * (wind ? wind_strength : 1.0);
	v_night = clamp(wb_emissive_headlight, 0.0, 1.0);
}

void fragment() {
	float across = 1.0 - v_shape.y * v_shape.y;
	float along = pow(clamp(v_shape.x, 0.0, 1.0), head_power);
	float k = v_alpha * across * along * strength * mix(1.0, night_gain, v_night);
	vec3 bg = vec3(mix(blend_background_day, blend_background_night, v_night));
	ALBEDO = speed_output(wb_srgb_to_linear(color) * k, bg);
}
