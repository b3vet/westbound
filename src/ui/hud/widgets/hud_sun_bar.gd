class_name HudSunBar
extends HudWidget
## Top-centre: the thin horizon bar with the sun's height and the distance to the next
## checkpoint. Spec: Sky timeline and sun clock → HUD ("a thin horizon bar at the top
## edge shows the sun's height and the distance to the next checkpoint"); Night (×2).
##
## Redraws when the sun marker moves a whole pixel, the distance changes by 0.1 km
## (or mile), or night/dawn flips.

const LABEL_SUN := "SUN"
const LABEL_NIGHT := "NIGHT ×2"
const LABEL_DAWN := "DAWN"
const LABEL_NEXT := "NEXT CHECKPOINT"
const UNIT_KM := "KM"
const UNIT_MI := "MI"
const MARKER_FACETS := 8
const TICKS := 4

var _sun_px: int = -1
var _dist_key: int = -2
var _night: bool = false
var _dawn: bool = false
var _miles: bool = false
var _dist_text: String = ""
var _height: float = 1.0
var _track_rect: Rect2 = Rect2()
func set_sun(height: float) -> void:
	_height = clampf(height, 0.0, 1.0)
	var px := roundi(_height * _track_rect.size.x)
	if px == _sun_px:
		return
	_sun_px = px
	changes += 1
	_plate_redraw()


func set_phase(night: bool, dawn: bool) -> void:
	if night == _night and dawn == _dawn:
		return
	_night = night
	_dawn = dawn
	_value_changed()


func set_checkpoint(metres: float, miles: bool) -> void:
	var key := HudFormat.distance_key(metres, miles)
	if key == _dist_key and miles == _miles:
		return
	_dist_key = key
	_miles = miles
	_dist_text = HudFormat.tenths_text(key) if key >= 0 else ""
	_text_changed()


## The distance text shown ("" when no checkpoint is planned).
func checkpoint_text() -> String:
	return _dist_text


func _restyled() -> void:
	_track_rect = _track()
	_sun_px = roundi(_height * _track_rect.size.x)
	_plate_redraw()


func _track() -> Rect2:
	var t := style.tuning
	var pad := style.px(t.panel_padding_px)
	var lw := HudDraw.text_width(style.label, LABEL_NIGHT, style.size_label) + style.px(t.spacing_grid_px)
	var h := style.px(t.sun_track_px)
	var r := style.px(t.sun_marker_px) + style.edge_w * 2.0
	var cy := pad + HudDraw.cap_height(style.size_label) * 0.5
	return Rect2(pad + lw + r, cy - h * 0.5, size.x - pad * 2.0 - lw - r * 2.0, h)


func _paint_plate(m: HudMesh) -> void:
	var s := style
	var t := s.tuning
	m.panel(Rect2(Vector2.ZERO, size), s.bevel_panel, s.panel_fill, s.edge_idle, s.edge_w)
	var track := _track_rect
	m.rect(track, Color(s.ink, 1.0))
	var fill_w := float(_sun_px)
	if fill_w > 0.0 and not _night:
		m.rect(Rect2(track.position, Vector2(fill_w, track.size.y)), s.hot.lerp(s.gold, _height))
	var tick := s.edge_w * 2.0
	for i in range(1, TICKS):
		var x := track.position.x + track.size.x * float(i) / float(TICKS)
		m.rect(Rect2(x - s.edge_w * 0.5, track.position.y - tick, s.edge_w, track.size.y + tick * 2.0), s.edge_idle)
	m.rect(Rect2(track.position.x, track.end.y, track.size.x, s.edge_w * 0.5), s.edge_idle)
	var c := Vector2(track.position.x + fill_w, track.get_center().y)
	var r := s.px(t.sun_marker_px)
	if _night:
		m.ngon(c, r, MARKER_FACETS, s.panel, s.accent, s.edge_w)
	else:
		m.ngon(c, r + s.edge_w * 2.0, MARKER_FACETS, s.ink)
		m.ngon(c, r, MARKER_FACETS, s.gold, s.gold, s.edge_w * 0.5)


func _paint() -> void:
	var s := style
	var t := s.tuning
	var pad := s.px(t.panel_padding_px)
	var gap := s.px(t.spacing_grid_px)
	var base := pad + HudDraw.cap_height(s.size_label)
	var label := LABEL_SUN
	var label_color := s.gold
	if _night:
		label = LABEL_NIGHT
		label_color = s.accent
	elif _dawn:
		label = LABEL_DAWN
	HudDraw.text(self, s.label, Vector2(pad, base), label, s.size_label, label_color)
	if _dist_text.is_empty():
		return
	var y2 := size.y - pad
	var unit := UNIT_MI if _miles else UNIT_KM
	var cell := s.digit_cell(s.body, s.size_small)
	var w_label := HudDraw.text_width(s.label, LABEL_NEXT, s.size_label)
	var w_num := HudDraw.number_width(s.body, _dist_text, s.size_small, cell)
	var w_unit := HudDraw.text_width(s.label, unit, s.size_label)
	var x0 := (size.x - (w_label + gap + w_num + gap * 0.5 + w_unit)) * 0.5
	HudDraw.text(self, s.label, Vector2(x0, y2), LABEL_NEXT, s.size_label, s.muted)
	x0 += w_label + gap
	x0 += HudDraw.number(self, s.body, Vector2(x0, y2), _dist_text, s.size_small, cell, s.text)
	HudDraw.text(self, s.label, Vector2(x0 + gap * 0.5, y2), unit, s.size_label, s.muted)
