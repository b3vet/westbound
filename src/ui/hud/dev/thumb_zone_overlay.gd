extends Control
## Dev overlay (plan D14 review): draws what the HUD layout keeps its readouts away
## from, over the HUD. Spec: UI, HUD and design system (the middle third stays clear;
## safe areas); plan D14 (thumb zones). docs/HUD.md → Thumb zones.
##
##   hot fill      the thumb zones (the canvas's lower outer corners, hud.thumb_zone_size_cm)
##   hot outline   the pedals grown by pedal_clearance_px (manual layouts)
##   text outline  the safe area
##   gold outline  the traffic area (the middle third between the top readouts and the
##                 cluster's bottom band) and the cluster's bounds
##
## Used by hud_preview (--zones=true) and hud_run_snap (--zones=true). Never takes input.

const ZONE_FILL := Color(1.0, 0.35, 0.3, 0.28)
const ZONE_EDGE := Color(1.0, 0.35, 0.3, 0.9)
const SAFE_EDGE := Color(0.95, 0.97, 1.0, 0.6)
const AREA_EDGE := Color(1.0, 0.82, 0.29, 0.9)
const LINE_PX := 2.0
## The traffic area as the layout tests define it (tests/ui/test_hud_layout.gd).
const MIDDLE_TOP_FRAC := 0.45
const BOTTOM_BAND_FRAC := 0.2

var hud: Hud


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if hud == null or not is_instance_valid(hud):
		return
	var l := hud.layout
	draw_rect(l.safe, SAFE_EDGE, false, LINE_PX)
	for z in l.thumb_zones:
		draw_rect(z, ZONE_FILL)
		draw_rect(z, ZONE_EDGE, false, LINE_PX)
	for p in l.pedals:
		draw_rect(p.grow(hud.tuning.pedal_clearance_px), ZONE_EDGE, false, LINE_PX)
	var col := l.middle_column()
	var top := l.safe.position.y + l.safe.size.y * MIDDLE_TOP_FRAC
	var band := l.safe.end.y - l.safe.size.y * BOTTOM_BAND_FRAC
	draw_rect(Rect2(col.position.x, top, col.size.x, band - top), AREA_EDGE, false, LINE_PX)
	draw_rect(l.cluster, AREA_EDGE, false, LINE_PX)
