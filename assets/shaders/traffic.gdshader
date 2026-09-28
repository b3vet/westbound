// Traffic vehicle material (WP3.1). Spec: Traffic → Visuals ("vehicles are pooled per
// model with shared materials; the color is a per-instance uniform"; brake lights,
// blinkers, hazards, headlights and taillights, all emissive; wheels spin, bodies roll
// and pitch); Cameras → Glare rule (sun-colored rim strongest when backlit;
// taillights and brake lights always emissive); Performance budget (single-light
// vertex lighting, no PBR). One shader, one material (materials/traffic.tres) shared by
// every traffic model; TrafficView draws each model with one MultiMesh.
//
// Vertex conventions (tools/traffic_models/traffic_mesh_builder.gd):
//   COLOR.rgb  sRGB albedo; for PART_PAINT a shade multiplier on the instance paint
//   UV.x       part: 0 fixed, 1 paint, 2 glass, 3 wheel, 4 headlamp, 5 rear lamp
//              (tail, brake-bright when braking), 6 brake-only, 7 blinker L, 8 blinker R
//   UV2        wheel hub (y, z) in model space (spin axis X)
// Per instance (MultiMesh custom data; 16-bit floats on Compatibility, so everything
// is small or an integer below 2048):
//   INSTANCE_CUSTOM.r  wheel angle (rad, rolling forward)
//   INSTANCE_CUSTOM.g  body roll (rad, + leans left)     .b  body pitch (rad, + nose up)
//   INSTANCE_CUSTOM.a  light bits + 32 * paint slot     (TrafficLights.pack())
// Renderer parity (docs/CONTRACTS.md §13): linear math, sRGB inputs converted here,
// ALBEDO = wb_output(linear).
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque, fog_disabled, shadows_disabled;

#include "res://assets/shaders/world_common.gdshaderinc"

const int PART_PAINT = 1;
const int PART_GLASS = 2;
const int PART_WHEEL = 3;
const int PART_HEAD = 4;
const int PART_REAR = 5;
const int PART_BRAKE = 6;
const int PART_BLINK_L = 7;
const int PART_BLINK_R = 8;
// TrafficLights.BIT_*.
const int BIT_BRAKE = 1;
const int BIT_BRAKE_STRONG = 2;
const int BIT_BLINK_L = 4;
const int BIT_BLINK_R = 8;
const int BIT_HEAD = 16;
const int PALETTE_STRIDE = 32;
const int PALETTE_SIZE = 64;

// Body motion pivot height (m): roll and pitch turn the body about this axis height.
uniform float pivot_height = 0.5;
// Lamp lens albedo while unlit (x the lens color, lit by the sun).
uniform float lens_factor = 0.55;
// Emissive levels (0 = lens only, 1 = full lamp color, > 1 pushes toward a hot core).
uniform float tail_day_level = 0.6;
uniform float tail_night_level = 0.9;
uniform float brake_level = 1.25;
uniform float brake_strong_level = 1.8;
uniform float blinker_level = 1.4;
uniform float head_level = 1.5;
// How much of the level above 1 turns the lamp toward white.
uniform float hot_core = 0.35;
// Sky reflection at grazing angles: paint and glass.
uniform float paint_sky_reflect = 0.18;
uniform float glass_sky_reflect = 0.55;
uniform float fresnel_power = 3.0;
// Sun rim (glare rule): sun-colored rim at grazing angles, weighted by how much the
// camera looks toward the sun (backlit).
uniform float rim_gain = 1.1;
uniform float rim_power = 2.0;
uniform float rim_backlit_power = 2.0;
// Backlit fill: faces toward the camera get this much of the sun color when backlit,
// so silhouettes against a low sun keep their shape.
uniform float backlit_fill = 0.25;

// Paint colors (sRGB): the biome traffic palette, then the models' fixed palettes.
uniform vec4 palette[64];

varying vec3 v_lit;
varying vec3 v_world_pos;
varying vec3 v_fog_col;
varying vec3 v_emit;
varying float v_on;

void vertex() {
	int part = int(UV.x + 0.5);
	int packed = int(INSTANCE_CUSTOM.a + 0.5);
	int bits = packed % PALETTE_STRIDE;
	int slot = clamp(packed / PALETTE_STRIDE, 0, PALETTE_SIZE - 1);
	vec3 v = VERTEX;
	vec3 n = NORMAL;
	if (part == PART_WHEEL) {
		// Rolling forward (-Z): the top of the wheel moves toward -Z.
		float a = -INSTANCE_CUSTOM.r;
		float ca = cos(a);
		float sa = sin(a);
		vec2 p = v.yz - UV2;
		v.yz = UV2 + vec2(p.x * ca - p.y * sa, p.x * sa + p.y * ca);
		n.yz = vec2(n.y * ca - n.z * sa, n.y * sa + n.z * ca);
	} else {
		// Sprung body: pitch about X, then roll about Z, around the pivot height.
		float pc = cos(INSTANCE_CUSTOM.b);
		float ps = sin(INSTANCE_CUSTOM.b);
		float rc = cos(INSTANCE_CUSTOM.g);
		float rs = sin(INSTANCE_CUSTOM.g);
		vec3 q = v - vec3(0.0, pivot_height, 0.0);
		q.yz = vec2(q.y * pc - q.z * ps, q.y * ps + q.z * pc);
		q.xy = vec2(q.x * rc - q.y * rs, q.x * rs + q.y * rc);
		v = q + vec3(0.0, pivot_height, 0.0);
		n.yz = vec2(n.y * pc - n.z * ps, n.y * ps + n.z * pc);
		n.xy = vec2(n.x * rc - n.y * rs, n.x * rs + n.y * rc);
	}
	VERTEX = v;
	NORMAL = n;

	vec3 world_normal = normalize((MODEL_MATRIX * vec4(n, 0.0)).xyz);
	v_world_pos = (MODEL_MATRIX * vec4(v, 1.0)).xyz;
	vec3 to_frag = normalize(v_world_pos - CAMERA_POSITION_WORLD);

	vec3 albedo;
	if (part == PART_PAINT) {
		albedo = wb_srgb_to_linear(palette[slot].rgb) * COLOR.r;
	} else {
		albedo = wb_srgb_to_linear(COLOR.rgb);
	}

	// Lamps.
	float level = 0.0;
	bool braking = (bits & BIT_BRAKE) != 0;
	bool strong = (bits & BIT_BRAKE_STRONG) != 0;
	if (part == PART_HEAD) {
		level = (bits & BIT_HEAD) != 0 ? head_level : 0.0;
	} else if (part == PART_REAR) {
		// Glare rule: always lit; brighter with the headlights on; brake-bright when braking.
		level = (bits & BIT_HEAD) != 0 ? tail_night_level : tail_day_level;
		if (braking) {
			level = strong ? brake_strong_level : brake_level;
		}
	} else if (part == PART_BRAKE) {
		level = braking ? (strong ? brake_strong_level : brake_level) : 0.0;
	} else if (part == PART_BLINK_L) {
		level = (bits & BIT_BLINK_L) != 0 ? blinker_level : 0.0;
	} else if (part == PART_BLINK_R) {
		level = (bits & BIT_BLINK_R) != 0 ? blinker_level : 0.0;
	}
	v_on = clamp(level, 0.0, 1.0);
	v_emit = mix(albedo, vec3(1.0), clamp((level - 1.0) * hot_core, 0.0, 1.0));
	if (part >= PART_HEAD) {
		albedo *= lens_factor;
	}

	// Single-sun vertex lighting plus sky fresnel.
	vec3 c = wb_light(albedo, world_normal);
	float facing = clamp(dot(world_normal, -to_frag), 0.0, 1.0);
	float fres = pow(1.0 - facing, fresnel_power);
	float up = 0.5 + 0.5 * world_normal.y;
	if (part == PART_GLASS) {
		c += fres * up * glass_sky_reflect * wb_sky_horizon.rgb + glass_sky_reflect * 0.25 * up * wb_sky_zenith.rgb;
	} else if (part == PART_PAINT) {
		c += fres * up * paint_sky_reflect * wb_sky_horizon.rgb;
	}
	// Glare rule: sun rim, strongest when the camera looks toward the sun.
	float backlit = pow(max(dot(to_frag, wb_sun_dir), 0.0), rim_backlit_power);
	vec3 sun = wb_sun_light_color.rgb * wb_sun_light_energy;
	c += sun * backlit * (pow(1.0 - facing, rim_power) * rim_gain + facing * backlit_fill * albedo);
	v_lit = c;
	v_fog_col = wb_fog_color_dir(to_frag);
}

void fragment() {
	vec3 c = v_lit + wb_player_light(v_lit, v_world_pos);
	c = mix(c, v_emit, v_on);
	float fog = wb_fog_factor(length(v_world_pos - CAMERA_POSITION_WORLD));
	ALBEDO = wb_output(mix(c, v_fog_col, fog));
}
