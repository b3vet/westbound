class_name HudMinSpeed
extends HudWidget
## The minimum-speed strip above the speedometer. Spec: Scoring → Multiplier
## ("Minimum speed (100 km/h). Below it, the HUD shows TOO SLOW with a speed bar");
## UI → HUD elements ("The minimum-speed bar appears only when speed nears or drops
## below 100 km/h"). Words, not color alone: TOO SLOW is spelled out.
##
## Visible below hud.min_speed_bar_show_below_kmh (hidden again above it plus the
## hysteresis), and always while TOO SLOW. The bar fills to the minimum-speed mark.
## Pulses only while TOO SLOW.

const LABEL_MIN := "MIN SPEED"
const LABEL_TOO_SLOW := "TOO SLOW"
const LABEL_MIN_PREFIX := "MIN "

var _fill_px: int = -1
var _too_slow: bool = false
var _min_value: int = -1
var _min_text: String = ""
var _clock: float = 0.0
var _frac: float = 0.0
var _bar_w: float = 1.0


## Visibility rule: shown below the threshold, hidden above threshold + hysteresis,
## unchanged in between; always shown while too slow.
static func should_show(t: HudTuning, speed_kmh: float, too_slow: bool, shown: bool) -> bool:
	if too_slow:
		return true
	if speed_kmh < t.min_speed_bar_show_below_kmh:
		return true
	if speed_kmh > t.min_speed_bar_show_below_kmh + t.min_speed_bar_hysteresis_kmh:
		return false
	return shown


func too_slow_shown() -> bool:
	return visible and _too_slow


func set_state(frac: float, too_slow: bool, min_value: int) -> void:
	_frac = clampf(frac, 0.0, 1.0)
	var px := roundi(_frac * _bar_w)
	if px == _fill_px and too_slow == _too_slow and min_value == _min_value:
		return
	var text := min_value != _min_value or too_slow != _too_slow
	if min_value != _min_value:
		_min_value = min_value
		_min_text = LABEL_MIN_PREFIX + str(min_value)
	if too_slow != _too_slow:
		_clock = 0.0
	_fill_px = px
	_too_slow = too_slow
	if text:
		_value_changed()
	else:
		changes += 1
		_plate_redraw()


func animate(dt: float) -> bool:
	if not (visible and _too_slow):
		return false
	_clock += dt
	_plate_redraw()
	return true


func _restyled() -> void:
	_bar_w = maxf(1.0, _bar_rect().size.x)
	_fill_px = roundi(_frac * _bar_w)


func _bar_rect() -> Rect2:
	var s := style
	var pad := s.px(s.tuning.panel_padding_px)
	var gap := s.px(s.tuning.spacing_grid_px)
	var left := HudDraw.text_width(s.display, LABEL_TOO_SLOW, s.size_small)
	var right := HudDraw.text_width(s.label, LABEL_MIN_PREFIX + "000", s.size_label)
	var h := s.px(s.tuning.sun_track_px)
	return Rect2(Vector2(pad + left + gap, (size.y - h) * 0.5), Vector2(size.x - pad * 2.0 - left - right - gap * 2.0, h))


func _pulse() -> float:
	if not _too_slow:
		return 1.0
	return lerpf(PULSE_MIN, 1.0, 0.5 + 0.5 * cos(TAU * style.tuning.too_slow_pulse_hz * _clock))


## Shapes pulse while TOO SLOW; the words stay steady (readable, no text redraws).
func _paint_plate(m: HudMesh) -> void:
	var s := style
	var gap := s.px(s.tuning.spacing_grid_px)
	var pulse := _pulse()
	var edge := Color(s.hot, pulse) if _too_slow else s.edge_idle
	m.panel(Rect2(Vector2.ZERO, size), s.bevel_control, s.panel_fill, edge, s.edge_w)
	var bar := _bar_rect()
	m.rect(bar, Color(s.ink, 1.0))
	m.rect(Rect2(bar.position, Vector2(float(_fill_px), bar.size.y)), Color(s.hot, pulse) if _too_slow else s.accent)
	m.rect(Rect2(bar.position.x, bar.end.y, bar.size.x, s.edge_w * 0.5), s.edge_idle)
	m.rect(Rect2(bar.end.x - s.edge_w, bar.position.y - gap * 0.5, s.edge_w * 2.0, bar.size.y + gap), s.text)


func _paint() -> void:
	var s := style
	var t := s.tuning
	var pad := s.px(t.panel_padding_px)
	var gap := s.px(t.spacing_grid_px)
	var cy := size.y * 0.5
	var bar := _bar_rect()
	HudDraw.text(self, s.label, Vector2(bar.end.x + gap, cy + HudDraw.cap_height(s.size_label) * 0.5),
			_min_text, s.size_label, s.text if _too_slow else s.muted)
	if _too_slow:
		HudDraw.text(self, s.display, Vector2(pad, cy + HudDraw.cap_height(s.size_small) * 0.5),
				LABEL_TOO_SLOW, s.size_small, s.hot)
	else:
		HudDraw.text(self, s.label, Vector2(pad, cy + HudDraw.cap_height(s.size_label) * 0.5),
				LABEL_MIN, s.size_label, s.muted)


const PULSE_MIN := 0.45   # lint: allow-number pulse floor
