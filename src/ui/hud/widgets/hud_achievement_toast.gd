class_name HudAchievementToast
extends HudWidget
## The achievement unlock toast (WP8.3). Spec: Garage and progression (Achievements); UI →
## Screens (toasts never pause play); Design system (faceted panel, neon edge, gold for
## celebrations); Accessibility (the header names the event: colour is never the only
## cue). The leg toast's style (HudLegToast, HudJourneyToast). docs/ACHIEVEMENTS.md → Toast.
##
##   ┌─────────────────────────────┐
##   │ ACHIEVEMENT UNLOCKED        │
##   │ 300 CLUB                    │
##   └─────────────────────────────┘
##
## Placed by HudAchievementLayer. Shown for achievements.toast_s of real time: a fade in,
## a hold, a fade out (modulate only: it draws once per unlock). Unlocks that arrive
## while one shows wait their turn (up to toast_queue_max); all of them wait while the
## HUD's JOURNEY COMPLETE banner is up (`held`). Takes no touches. One plate +
## two fonts = three draw calls; hidden, it draws nothing.

const HEADER := "ACHIEVEMENT UNLOCKED"
const EPS := 1e-6   # lint: allow-number divide guard

var tuning: AchievementTuning
## Waits (hidden, its clock stopped) while true: the layer holds it under the HUD's
## JOURNEY COMPLETE banner.
var held: bool = false
## The title on show and the ones waiting.
var _title: String = ""
var _queue := PackedStringArray()
var _t: float = -1.0


func _init() -> void:
	super._init()
	visible = false


## Shows `title` now, or after the ones on show and waiting (dropped past the queue's
## size: the save has it anyway).
func show_unlock(title: String) -> void:
	if showing() or held:
		if _queue.size() < maxi(tuning.toast_queue_max if tuning != null else 0, 0):
			_queue.append(title)
		return
	_start(title)


func _start(title: String) -> void:
	_title = title
	_t = 0.0
	modulate.a = 0.0
	visible = true
	_value_changed()


func dismiss() -> void:
	_t = -1.0
	_queue.clear()
	visible = false


func showing() -> bool:
	return _t >= 0.0


## A toast on show or waiting (the layer keeps processing).
func busy() -> bool:
	return showing() or not _queue.is_empty()


func title_text() -> String:
	return _title if showing() else ""


func header_text() -> String:
	return HEADER


func queued() -> int:
	return _queue.size()


## Advances by `dt` seconds of real time. While `held` (the HUD's JOURNEY COMPLETE banner
## is up) the toast hides and its clock stops. False: nothing moves (it draws once).
func animate(dt: float) -> bool:
	if tuning == null:
		return false
	if held:
		visible = false
		return false
	if _t < 0.0:
		if not _queue.is_empty():
			_start(_next())
		return false
	visible = true
	var t := tuning
	_t += dt
	if _t >= t.toast_s:
		if not _queue.is_empty():
			_start(_next())
			return false
		_t = -1.0
		visible = false
		return false
	var a := 1.0
	if _t < t.toast_in_s:
		a = _t / maxf(t.toast_in_s, EPS)
	elif _t > t.toast_s - t.toast_out_s:
		a = (t.toast_s - _t) / maxf(t.toast_out_s, EPS)
	modulate.a = clampf(a, 0.0, 1.0)
	return false


func _next() -> String:
	var next := _queue[0]
	_queue.remove_at(0)
	return next


func _paint_plate(m: HudMesh) -> void:
	var s := style
	m.panel(Rect2(Vector2.ZERO, size), s.bevel_panel, s.panel_fill, s.gold, s.edge_w * 2.0)
	m.rect(Rect2(Vector2(s.bevel_panel + s.edge_w, s.edge_w), s.tuning.accent_tab_size_px), s.accent)


func header_size() -> int:
	return maxi(1, roundi(float(tuning.toast_header_px if tuning != null else style.size_label) * style.ts))


func title_size() -> int:
	return maxi(1, roundi(float(style.size_event) * (tuning.toast_title_scale if tuning != null else 1.0)))


## The title's size after fitting the width (never below the small size).
func fitted_title_size() -> int:
	var ts := title_size()
	var inner := size.x - _pad() * 2.0
	var w := HudDraw.text_width(style.display, _title, ts)
	if w > inner and w > 0.0:
		ts = maxi(floori(float(ts) * inner / w), style.size_small)
	return ts


func _pad() -> float:
	return style.px(style.tuning.panel_padding_px)


func _paint() -> void:
	if _title.is_empty():
		return
	var s := style
	var pad := _pad()
	var gap := s.px(s.tuning.spacing_grid_px)
	var hs := header_size()
	var ts := fitted_title_size()
	var block := HudDraw.cap_height(hs) + gap + HudDraw.cap_height(ts)
	var y := maxf((size.y - block) * 0.5, 0.0) + HudDraw.cap_height(hs)
	HudDraw.text(self, s.label, Vector2(pad, y), HEADER, hs, s.accent)
	y += gap + HudDraw.cap_height(ts)
	HudDraw.text(self, s.display, Vector2(pad, y), _title, ts, s.gold, s.outline_px, s.outline)


## True when the header and the title fit at their full sizes (tests: text fit).
func fits() -> bool:
	if style == null:
		return true
	var inner := size.x - _pad() * 2.0
	return HudDraw.text_width(style.label, HEADER, header_size()) <= inner \
			and HudDraw.text_width(style.display, _title, title_size()) <= inner
