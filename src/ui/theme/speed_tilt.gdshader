// Speed tilt: skews a canvas item like italic type leaning forward. Spec: UI, HUD and
// design system → Design system ("the logo, chain and multiplier readouts and
// celebrations are skewed about −7° with a small canvas_item shader").
// Vertex-only (the fragment is the renderer's default), so it draws the same on the
// Mobile and Compatibility renderers. tilt_rad comes from hud.speed_tilt_deg; the
// skew is about the local line y = pivot_y (usually the item's vertical middle).
shader_type canvas_item;

uniform float tilt_rad = -0.12217;
uniform float pivot_y = 0.0;

void vertex() {
	VERTEX.x += (VERTEX.y - pivot_y) * tan(tilt_rad);
}
