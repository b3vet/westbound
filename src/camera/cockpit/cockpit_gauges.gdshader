// Cockpit binnacle gauges (plan D11, WP4.7; docs/COCKPIT.md): speedometer (left half
// of the quad) and tachometer (right half) drawn procedurally, one draw call, no
// textures. The needles follow `speed_frac` / `rpm_frac` (0..1 of full scale), set by
// Cockpit.update_from() from VehicleState.
//
// Look contract (docs/CONTRACTS.md §13): colors authored in sRGB and linearized here,
// linear math, lit by the shared single-light vertex lighting (wb_light), and the
// marks and needles glow on the color script's headlight ramp at night
// (wb_emissive_headlight). Ends with ALBEDO = wb_output(linear) for renderer parity.
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque, fog_disabled, shadows_disabled;

#include "res://assets/shaders/world_common.gdshaderinc"

uniform float speed_frac = 0.0;
uniform float rpm_frac = 0.0;
// Tachometer red band start (fraction of full scale).
uniform float redline_frac = 0.875;
// Quad width / height (set by Cockpit from the mesh).
uniform float aspect = 2.6;
// Colors in sRGB (no source_color: converted here so both renderers agree).
uniform vec3 face_color = vec3(0.025, 0.026, 0.03);
uniform vec3 mark_color = vec3(0.88, 0.88, 0.84);
uniform vec3 needle_color = vec3(1.0, 0.4, 0.1);
uniform vec3 redline_color = vec3(0.95, 0.14, 0.08);
// Backlight: always on a little (daylight readability under the visor), plus the
// night ramp.
uniform float backlight = 0.35;
uniform float night_glow = 1.3;
// Dial layout in units of the quad height: radius, needle length, tick band.
uniform float dial_radius = 0.42;
uniform float needle_len = 0.36;
uniform float tick_inner = 0.3;
uniform float tick_major_inner = 0.26;
uniform float tick_outer = 0.37;
uniform float line_half = 0.012;
uniform float needle_half = 0.016;
uniform float hub_radius = 0.045;
uniform float sweep_deg = 240.0;
uniform float speed_ticks = 16.0;
uniform float rpm_ticks = 8.0;

varying vec3 v_shade;

void vertex() {
	vec3 world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_shade = wb_light(vec3(1.0), world_normal);
}

// Anti-aliased "inside" for a signed distance (negative inside), aa = pixel size.
float cover(float sd, float aa) {
	return 1.0 - smoothstep(-aa, aa, sd);
}

// One dial at p (quad-height units, y up, origin at the dial centre).
// Returns (marks, red marks, needle + hub).
vec3 dial(vec2 p, float frac, float ticks, float red_from, float aa) {
	float sweep = radians(sweep_deg);
	float r = length(p);
	float ang = atan(p.x, p.y);   // clockwise from 12 o'clock
	// Ticks: nearest tick angle, distance along the arc.
	float t = clamp(floor((ang + sweep * 0.5) / sweep * ticks + 0.5), 0.0, ticks);
	float tick_ang = t / ticks * sweep - sweep * 0.5;
	float across = abs(sin(ang - tick_ang)) * r;
	float major = 1.0 - step(0.5, mod(t, 2.0));
	float inner = mix(tick_inner, tick_major_inner, major);
	float in_band = cover(inner - r, aa) * cover(r - tick_outer, aa);
	float in_sweep = cover(abs(ang) - sweep * 0.5 - 0.02, aa);
	float tick = cover(across - line_half * mix(1.0, 1.6, major), aa) * in_band * in_sweep;
	float ring = cover(abs(r - dial_radius) - line_half, aa);
	float red = step(red_from, t / ticks - 0.001) * tick;
	// Needle: a bar from slightly behind the centre to needle_len.
	float na = frac * sweep - sweep * 0.5;
	vec2 nd = vec2(sin(na), cos(na));
	float along = dot(p, nd);
	float off = abs(p.x * nd.y - p.y * nd.x);
	float needle = cover(off - needle_half * (1.0 - 0.6 * clamp(along / needle_len, 0.0, 1.0)), aa)
			* cover(-hub_radius - along, aa) * cover(along - needle_len, aa);
	float hub = cover(r - hub_radius, aa);
	return vec3(max(tick - red, 0.0) + ring, red, max(needle, hub));
}

void fragment() {
	vec2 q = vec2(UV.x * aspect, 1.0 - UV.y);   // quad-height units, y up
	float aa = max(length(fwidth(q)) * 0.7, 1e-4);
	vec3 left = dial(q - vec2(aspect * 0.25, 0.5), speed_frac, speed_ticks, 2.0, aa);
	vec3 right = dial(q - vec2(aspect * 0.75, 0.5), rpm_frac, rpm_ticks, redline_frac, aa);
	vec3 m = max(left, right);
	vec3 face = wb_srgb_to_linear(face_color);
	vec3 mark = wb_srgb_to_linear(mark_color);
	vec3 red = wb_srgb_to_linear(redline_color);
	vec3 needle = wb_srgb_to_linear(needle_color);
	vec3 albedo = face;
	albedo = mix(albedo, mark, clamp(m.x, 0.0, 1.0));
	albedo = mix(albedo, red, clamp(m.y, 0.0, 1.0));
	albedo = mix(albedo, needle, clamp(m.z, 0.0, 1.0));
	float lit_marks = clamp(m.x + m.y + m.z, 0.0, 1.0);
	float glow = backlight + wb_emissive_headlight * night_glow;
	vec3 c = albedo * v_shade + albedo * lit_marks * glow;
	ALBEDO = wb_output(c);
}
