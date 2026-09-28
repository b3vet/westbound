shader_type spatial;
render_mode unshaded, cull_disabled;
#include "res://assets/shaders/world_common.gdshaderinc"
uniform vec4 u_src : source_color = vec4(0.5, 0.5, 0.5, 1.0);
uniform vec4 u_plain = vec4(0.5, 0.5, 0.5, 1.0);
uniform int mode = 0;
uniform float val = 0.5;
void fragment() {
	vec3 c = vec3(0.0);
	if (mode == 0) { c = vec3(val); }
	else if (mode == 1) { c = COLOR.rgb; }
	else if (mode == 2) { c = wb_road_tone.rgb; }
	else if (mode == 3) { c = u_src.rgb; }
	else if (mode == 4) { c = u_plain.rgb; }
	else if (mode == 5) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
		c = vec3(1.0, 0.0, 0.0);
#elif CURRENT_RENDERER == RENDERER_MOBILE
		c = vec3(0.0, 1.0, 0.0);
#else
		c = vec3(0.0, 0.0, 1.0);
#endif
	}
	else if (mode == 6) { c = wb_ambient.rgb; }
	ALBEDO = mode == 0 ? wb_output(wb_srgb_to_linear(c)) : c;
}
