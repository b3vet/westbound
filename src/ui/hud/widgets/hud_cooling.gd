class_name HudCooling
extends HudWidget
## The "cooling" icon, top-right under the pause button (WP9.1). Spec: Performance budget
## → Adaptive governor ("A small 'cooling' icon shows while it is active"); Design system
## (faceted small controls: the control bevel, idle neon edge); Accessibility → color
## independence (a shape, the snowflake, not a color). docs/QUALITY.md, docs/HUD.md.
##
## Shown by the Hud while Quality.is_cooling() (the governor holds a thermal step; see
## QualityTuning.cooling_icon_any_reason). One plate (one draw call) with a snowflake:
## three strokes through the centre with a small V near each end. Static: it never
## redraws while shown. Never takes touches.

## Spokes (three strokes through the centre make six).
const SPOKES := 6
## The glyph's radius as a share of the icon's half size, the V's position along a spoke
## and its arm length (shares of the radius), the stroke width (share of the icon).
const GLYPH_RADIUS := 0.72   # lint: allow-number glyph proportion
const V_AT := 0.62   # lint: allow-number glyph proportion
const V_ARM := 0.3   # lint: allow-number glyph proportion
const STROKE := 0.09   # lint: allow-number glyph proportion
const V_ANGLE := PI / 4.0   # lint: allow-number glyph proportion


## The icon's side at the current text size (the lives icon's size).
static func side_px(hud: HudTuning, text_scale: float) -> float:
	return hud.lives_icon_px * text_scale


func _paint_plate(m: HudMesh) -> void:
	var s := style
	m.panel(Rect2(Vector2.ZERO, size), s.bevel_control, s.panel_fill, s.edge_idle, s.edge_w)
	var c := size * 0.5
	var r := minf(size.x, size.y) * 0.5 * GLYPH_RADIUS
	var w := maxf(minf(size.x, size.y) * STROKE, s.edge_w)
	var ink := s.text
	for i in SPOKES:
		var a := TAU * float(i) / float(SPOKES) - PI * 0.5
		var dir := Vector2(cos(a), sin(a))
		m.line(c, c + dir * r, w, ink)
		var at := c + dir * r * V_AT
		var arm := r * V_ARM
		m.line(at, at + dir.rotated(V_ANGLE) * arm, w, ink)
		m.line(at, at + dir.rotated(-V_ANGLE) * arm, w, ink)
