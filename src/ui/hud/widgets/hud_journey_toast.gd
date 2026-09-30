class_name HudJourneyToast
extends HudWidget
## The "JOURNEY COMPLETE" banner (WP6.5). Spec: The journey goal ("'Journey complete'
## is recorded"; the road then continues), UI → Screens (toasts never pause play),
## Design system (gold for celebrations). docs/HUD.md → Journey complete.
##
##   ┌──────────────────────────────────────────┐
##   │            JOURNEY COMPLETE              │
##   │   THE COAST  ·  JOURNEY BONUS +50,000    │
##   └──────────────────────────────────────────┘
##
## Shown on Events.journey_complete, centred over the top of the play area (never in
## the middle third or the thumb zones), for hud.journey_toast_s: a fade and grow in, a
## hold, a fade out (modulate and scale only: it draws once; no grow with reduced motion,
## WP9.3). Takes no touches. One plate
## + two fonts = three draw calls.

const TITLE := "JOURNEY COMPLETE"
const EPS := 1e-6   # lint: allow-number divide guard

var _subtitle: String = ""
var _t: float = -1.0


## Shows the banner from the start with `subtitle` ("" = title only).
func show_complete(subtitle: String) -> void:
	_subtitle = subtitle
	_t = 0.0
	modulate.a = 0.0
	visible = true
	_value_changed()


func dismiss() -> void:
	_t = -1.0
	visible = false


func showing() -> bool:
	return _t >= 0.0


func title_text() -> String:
	return TITLE


func subtitle_text() -> String:
	return _subtitle


func animate(dt: float) -> bool:
	if _t < 0.0:
		return false
	var t := style.tuning
	_t += dt
	var total := t.journey_toast_s
	if _t >= total:
		_t = -1.0
		visible = false
		return false
	var a := 1.0
	if _t < t.journey_toast_in_s:
		a = _t / maxf(t.journey_toast_in_s, EPS)
	elif _t > total - t.journey_toast_out_s:
		a = (total - _t) / maxf(t.journey_toast_out_s, EPS)
	modulate.a = clampf(a, 0.0, 1.0)
	var k := lerpf(t.journey_toast_grow_from, 1.0, smoothstep(0.0, 1.0, clampf(_t / maxf(t.journey_toast_in_s, EPS), 0.0, 1.0)))
	if style.reduced_motion:
		k = 1.0   # WP9.3: fades only
	pivot_offset = size * 0.5
	scale = Vector2(k, k)
	return false


func _paint_plate(m: HudMesh) -> void:
	var s := style
	m.panel(Rect2(Vector2.ZERO, size), s.bevel_panel, s.panel_fill, s.gold, s.edge_w * 2.0)
	m.rect(Rect2(Vector2(s.bevel_panel + s.edge_w, s.edge_w), s.tuning.accent_tab_size_px), s.accent)


func _title_size() -> int:
	return roundi(float(style.size_event) * style.tuning.journey_toast_title_scale)


func _paint() -> void:
	var s := style
	var pad := s.px(s.tuning.panel_padding_px)
	var gap := s.px(s.tuning.spacing_grid_px)
	var ts := _title_size()
	var inner := size.x - pad * 2.0
	var w := HudDraw.text_width(s.display, TITLE, ts)
	if w > inner and w > 0.0:
		ts = maxi(roundi(float(ts) * inner / w), s.size_small)
		w = HudDraw.text_width(s.display, TITLE, ts)
	var y := pad + HudDraw.cap_height(ts)
	HudDraw.text(self, s.display, Vector2((size.x - w) * 0.5, y), TITLE, ts, s.gold, s.outline_px, s.outline)
	if _subtitle.is_empty():
		return
	var ss := s.size_small
	var ws := HudDraw.text_width(s.label, _subtitle, ss)
	if ws > inner:
		ss = s.size_label
		ws = HudDraw.text_width(s.label, _subtitle, ss)
	HudDraw.text(self, s.label, Vector2((size.x - ws) * 0.5, y + gap + HudDraw.cap_height(ss)), _subtitle, ss, s.text)


## True when the title fits at its full size (tests: text fit).
func fits_title() -> bool:
	if style == null:
		return true
	var pad := style.px(style.tuning.panel_padding_px)
	return HudDraw.text_width(style.display, TITLE, _title_size()) <= size.x - pad * 2.0
