class_name HudSunBar
extends HudWidget
## Top-centre: the thin horizon bar with the sun's height and the distance to the next
## checkpoint. Spec: Sky timeline and sun clock → HUD ("a thin horizon bar at the top
## edge shows the sun's height and the distance to the next checkpoint"); Night (×2).
##
## Redraws when the sun marker moves a whole pixel, the distance changes by 0.1 km
## (or mile), or night/dawn flips.
##
## Clock mode (N3.2, the loop test mode and rooms: "the sun bar is replaced by a small
## clock showing time until night or dawn", multiplayer handoff → Time of day): the
## track is the room's cycle (the night's share marked), the marker the time of day, the
## label DAY or NIGHT ×2, and the second line "NIGHT IN 12:34  SECTOR 2.1 KM" (at night "DAWN IN 4:10") (the
## distance to the next sector gantry). The countdown redraws once a second.

const LABEL_SUN := "SUN"
const LABEL_NIGHT := "NIGHT ×2"
const LABEL_DAWN := "DAWN"
const LABEL_NEXT := "NEXT CHECKPOINT"
const LABEL_DAY := "DAY"
const LABEL_NIGHT_IN := "NIGHT IN"
const LABEL_DAWN_IN := "DAWN IN"
const LABEL_SECTOR := "SECTOR"
const CLOCK_FORMAT := "%d:%02d"
const SECONDS_PER_MINUTE := 60
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
var _clock: bool = false
var _day_frac: float = 1.0
var _flip_key: int = -1
var _flip_text: String = ""


## N3.2: clock mode on/off; where in the cycle (0..1), the day's share, and the seconds
## until the night (by day) or the day (at night).
func set_clock(on: bool, cycle_frac: float, day_frac: float, flip_in_s: float) -> void:
	if on != _clock or (on and day_frac != _day_frac):
		_clock = on
		_day_frac = clampf(day_frac, 0.0, 1.0)
		_sun_px = -1
		_value_changed()
	if not on:
		return
	set_sun(cycle_frac)
	var key := maxi(ceili(flip_in_s), 0)
	if key != _flip_key:
		_flip_key = key
		_flip_text = CLOCK_FORMAT % [floori(key / float(SECONDS_PER_MINUTE)), key % SECONDS_PER_MINUTE]
		_text_changed()


func is_clock() -> bool:
	return _clock


## The countdown shown in clock mode ("12:34").
func clock_text() -> String:
	return _flip_text
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
	if _clock:
		# The room's cycle: day gold, the night's share in the accent, the marker = now.
		var day_w := track.size.x * _day_frac
		m.rect(Rect2(track.position, Vector2(day_w, track.size.y)), Color(s.gold, s.tuning.sun_clock_day_alpha))
		m.rect(Rect2(track.position + Vector2(day_w, 0.0), Vector2(track.size.x - day_w, track.size.y)), s.accent)
	elif fill_w > 0.0 and not _night:
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
	var label := LABEL_DAY if _clock else LABEL_SUN
	var label_color := s.gold
	if _night:
		label = LABEL_NIGHT
		label_color = s.accent
	elif _dawn:
		label = LABEL_DAWN
	HudDraw.text(self, s.label, Vector2(pad, base), label, s.size_label, label_color)
	if _clock:
		_paint_clock_line()
		return
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


## Clock mode's second line: "NIGHT IN 12:34   SECTOR 2.1 KM" (the sector part only when
## a gantry is planned).
func _paint_clock_line() -> void:
	var s := style
	var t := s.tuning
	var pad := s.px(t.panel_padding_px)
	var gap := s.px(t.spacing_grid_px)
	var y2 := size.y - pad
	var cell := s.digit_cell(s.body, s.size_small)
	var flip_label := LABEL_DAWN_IN if _night else LABEL_NIGHT_IN
	var unit := UNIT_MI if _miles else UNIT_KM
	var w := HudDraw.text_width(s.label, flip_label, s.size_label) + gap \
		+ HudDraw.number_width(s.body, _flip_text, s.size_small, cell)
	if not _dist_text.is_empty():
		w += gap * 2.0 + HudDraw.text_width(s.label, LABEL_SECTOR, s.size_label) + gap \
			+ HudDraw.number_width(s.body, _dist_text, s.size_small, cell) + gap * 0.5 \
			+ HudDraw.text_width(s.label, unit, s.size_label)
	var x := (size.x - w) * 0.5
	HudDraw.text(self, s.label, Vector2(x, y2), flip_label, s.size_label, s.muted)
	x += HudDraw.text_width(s.label, flip_label, s.size_label) + gap
	x += HudDraw.number(self, s.body, Vector2(x, y2), _flip_text, s.size_small, cell, s.text)
	if _dist_text.is_empty():
		return
	x += gap * 2.0
	HudDraw.text(self, s.label, Vector2(x, y2), LABEL_SECTOR, s.size_label, s.muted)
	x += HudDraw.text_width(s.label, LABEL_SECTOR, s.size_label) + gap
	x += HudDraw.number(self, s.body, Vector2(x, y2), _dist_text, s.size_small, cell, s.text)
	HudDraw.text(self, s.label, Vector2(x + gap * 0.5, y2), unit, s.size_label, s.muted)
