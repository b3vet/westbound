// Shared world shading (spec: Performance budget → Materials, Fog; World → Color script).
// One sun, lighting evaluated per vertex, distance fog, all colors from the color
// script via global uniforms (declared in project.godot [shader_globals], pushed
// once per frame by the sky/color-script system). Looks identical on the Mobile
// and Compatibility renderers: everything is computed here, nothing uses engine
// lights, shadows or environment effects.
//
// Vertex conventions for world meshes (road, props, landmarks):
//   COLOR.rgb  albedo (authored in sRGB; converted with wb_albedo())
//   UV2.x      emissive class: 0 none, 1 reflector, 2 street lamp, 3 vehicle light
//   UV2.y      tint class:     0 none, 1 road surface (x wb_road_tone), 2 lane line (x wb_lane_line_tint)
#ifndef WB_WORLD_COMMON
#define WB_WORLD_COMMON

global uniform vec4 wb_sky_zenith : source_color;
global uniform vec4 wb_sky_horizon : source_color;
global uniform vec3 wb_sun_dir;
global uniform vec4 wb_sun_disc_color : source_color;
global uniform float wb_sun_disc_size;
global uniform float wb_sun_glow;
global uniform float wb_stars;
global uniform vec4 wb_cloud_lit : source_color;
global uniform vec4 wb_cloud_shadow : source_color;
global uniform vec4 wb_fog_color : source_color;
global uniform float wb_fog_start;
global uniform float wb_fog_end;
global uniform vec4 wb_horizon_tint_0 : source_color;
global uniform vec4 wb_horizon_tint_1 : source_color;
global uniform vec4 wb_horizon_tint_2 : source_color;
global uniform vec4 wb_horizon_tint_3 : source_color;
global uniform vec4 wb_ambient : source_color;
global uniform vec4 wb_sun_light_color : source_color;
global uniform float wb_sun_light_energy;
global uniform vec4 wb_shadow_tint : source_color;
global uniform vec4 wb_road_tone : source_color;
global uniform vec4 wb_lane_line_tint : source_color;
global uniform float wb_emissive_headlight;
global uniform float wb_emissive_streetlamp;
global uniform float wb_emissive_reflector;
global uniform vec3 wb_player_light_pos;
global uniform vec3 wb_player_light_dir;
global uniform float wb_player_light_strength;
global uniform vec3 wb_biome_tint_offset;

const float WB_EMISSIVE_NONE = 0.0;
const float WB_EMISSIVE_REFLECTOR = 1.0;
const float WB_EMISSIVE_STREETLAMP = 2.0;
const float WB_EMISSIVE_VEHICLE = 3.0;
const float WB_TINT_NONE = 0.0;
const float WB_TINT_ROAD = 1.0;
const float WB_TINT_LANE_LINE = 2.0;

vec3 wb_srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

// Vertex color -> linear albedo, with tint class and biome offset applied.
vec3 wb_albedo(vec3 vertex_srgb, float tint_class) {
	vec3 c = wb_srgb_to_linear(vertex_srgb);
	if (tint_class == WB_TINT_ROAD) {
		c *= wb_road_tone.rgb;
	} else if (tint_class == WB_TINT_LANE_LINE) {
		c *= wb_lane_line_tint.rgb;
	}
	return max(c + wb_biome_tint_offset, vec3(0.0));
}

// Single-light vertex lighting: ambient + sun (N.L), shadow side tinted.
vec3 wb_light(vec3 albedo, vec3 world_normal) {
	float ndl = max(dot(normalize(world_normal), normalize(wb_sun_dir)), 0.0);
	vec3 shade = mix(wb_shadow_tint.rgb * wb_ambient.rgb, wb_ambient.rgb, ndl);
	return albedo * (shade + wb_sun_light_color.rgb * wb_sun_light_energy * ndl);
}

// Emissive boost by class, driven by the color script's night ramps.
vec3 wb_emissive(vec3 albedo, float emissive_class) {
	float k = 0.0;
	if (emissive_class == WB_EMISSIVE_REFLECTOR) { k = wb_emissive_reflector; }
	else if (emissive_class == WB_EMISSIVE_STREETLAMP) { k = wb_emissive_streetlamp; }
	else if (emissive_class == WB_EMISSIVE_VEHICLE) { k = wb_emissive_headlight; }
	return albedo * k;
}

// Player "fake light": brightens surfaces inside the headlight cone at night.
vec3 wb_player_light(vec3 albedo, vec3 world_pos) {
	vec3 to_p = world_pos - wb_player_light_pos;
	float dist = length(to_p);
	float cone = smoothstep(0.85, 0.97, dot(to_p / max(dist, 0.001), normalize(wb_player_light_dir)));
	float falloff = 1.0 / (1.0 + dist * dist * 0.002);
	return albedo * wb_player_light_strength * cone * falloff;
}

float wb_fog_factor(float dist) {
	return smoothstep(wb_fog_start, wb_fog_end, dist);
}

vec3 wb_apply_fog(vec3 color, float dist) {
	return mix(color, wb_fog_color.rgb, wb_fog_factor(dist));
}

#endif
