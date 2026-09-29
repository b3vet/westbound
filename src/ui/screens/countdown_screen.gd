class_name CountdownScreen
extends RunScreen
## The run's countdown: 3-2-1-GO in big speed-tilted Chakra Petch, with gyro
## calibration. Spec: UI → Screens ("In run: countdown (gyro calibration happens
## here)"); Controls → Gyro steering ("Neutral is captured during the 3-2-1 countdown
## at run start"; web: iOS Safari asks for motion permission from a user gesture);
## Design system (speed tilt, accent). docs/SCREENS.md → Countdown.
##
## Driven by show_step(n) (RunScreens forwards Events.countdown_tick: 3, 2, 1, 0 = GO).
## Each number punches in (scale + fade); GO turns the accent, holds, fades, and the
## screen hides itself. In gyro mode a card asks the player to hold the phone in
## driving position: `recalibrate` is emitted on every step (the neutral follows the
## hold during the countdown) and once more at GO, which locks it. On the web with
## gyro, where iOS needs a tap for motion permission, set_hold(true) shows
## TAP TO ENABLE TILT STEERING; the first tap anywhere (the browser grants the
## permission inside that tap, WebMotionSource) emits `motion_tap`.

signal recalibrate()
signal motion_tap()

const TILT_SHADER := preload("res://src/ui/theme/speed_tilt.gdshader")
const TEXT_GO := "GO"
const TEXT_GYRO_TITLE := "TILT STEERING"
## "HOLD YOUR PHONE IN DRIVING POSITION" on two lines (a narrow card at any text size).
const TEXT_GYRO_HOLD := "HOLD YOUR PHONE"
const TEXT_GYRO_HOLD_2 := "IN DRIVING POSITION"
const TEXT_GYRO_DONE := "CALIBRATED"
const TEXT_GYRO_DONE_2 := "NEUTRAL LOCKED"
const TEXT_TAP := "TAP TO ENABLE TILT STEERING"
const TEXT_TAP_NOTE := "YOUR BROWSER WILL ASK FOR MOTION ACCESS"
const TEXT_LEG := "LEG %d OF %d"

## The step shown now (3, 2, 1; 0 = GO; -1 = none).
var step: int = -1
var gyro: bool = false
var holding: bool = false
## Steps in a countdown (hud.countdown_from): how many calibration segments light.
var steps_total: int = 3
## Recalibrations requested since the screen was built (tests).
var recalibrations: int = 0

var _number: ScreenText
var _leg_chip: ScreenPanel
var _leg: ScreenText
var _objective: ScreenText
var _card: ScreenPanel
var _card_title: ScreenText
var _card_text: ScreenText
var _card_text2: ScreenText
var _card_bar: CalibrationBar
var _tap: Control
var _tap_panel: ScreenPanel
var _tap_text: ScreenText
var _tap_note: ScreenText
var _tapped: bool = false


## Slanted segments that light up as the countdown calibrates (one per step).
class CalibrationBar:
	extends Control
	var style: HudStyle
	var total: int = 3
	var lit: int = 0
	var done: bool = false
	var _mesh := HudMesh.new()

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_state(lit_count: int, is_done: bool) -> void:
		if lit_count != lit or is_done != done:
			lit = lit_count
			done = is_done
			queue_redraw()

	func _draw() -> void:
		if style == null or total <= 0:
			return
		var t := style.tuning
		var on := style.gold if done else style.accent
		var off := Color(style.muted, Units.pct_to_frac(t.panel_edge_alpha_pct) * 0.5)
		_mesh.begin()
		_mesh.segments(Rect2(Vector2.ZERO, size), total, t.segment_gap_px * 2.0, 1.0,
				Units.pct_to_frac(t.segment_lean_pct), lit, on, on, total, off)
		_mesh.flush(self)


func _init() -> void:
	super._init()
	name = "Countdown"
	_leg_chip = ScreenPanel.new()
	_leg_chip.small_bevel = true
	add_child(_leg_chip)
	_leg = ScreenText.make("", ScreenText.Face.LABEL, 20, ScreenText.Ink.TEXT)
	_leg_chip.add_child(_leg)
	_objective = ScreenText.make("", ScreenText.Face.LABEL, 13, ScreenText.Ink.ACCENT)
	_leg_chip.add_child(_objective)
	_number = ScreenText.make("", ScreenText.Face.DISPLAY, 190, ScreenText.Ink.TEXT)
	_number.outline = true
	_number.tabular = true
	_number.align = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_number)

	_card = ScreenPanel.new()
	_card.edge = ScreenPanel.Edge.ACCENT
	add_child(_card)
	_card_title = ScreenText.make(TEXT_GYRO_TITLE, ScreenText.Face.LABEL, 13, ScreenText.Ink.ACCENT)
	_card.add_child(_card_title)
	_card_text = ScreenText.make(TEXT_GYRO_HOLD, ScreenText.Face.LABEL, 20, ScreenText.Ink.TEXT)
	_card.add_child(_card_text)
	_card_text2 = ScreenText.make(TEXT_GYRO_HOLD_2, ScreenText.Face.LABEL, 20, ScreenText.Ink.TEXT)
	_card.add_child(_card_text2)
	_card_bar = CalibrationBar.new()
	_card.add_child(_card_bar)
	_card.visible = false

	_tap = Control.new()
	_tap.name = "TapCatcher"
	_tap.mouse_filter = Control.MOUSE_FILTER_STOP
	_tap.gui_input.connect(_on_tap_input)
	add_child(_tap)
	_tap_panel = ScreenPanel.new()
	_tap_panel.edge = ScreenPanel.Edge.ACCENT
	_tap.add_child(_tap_panel)
	_tap_text = ScreenText.make(TEXT_TAP, ScreenText.Face.LABEL, 24, ScreenText.Ink.TEXT)
	_tap_panel.add_child(_tap_text)
	_tap_note = ScreenText.make(TEXT_TAP_NOTE, ScreenText.Face.LABEL, 13, ScreenText.Ink.MUTED)
	_tap_panel.add_child(_tap_note)
	_tap.visible = false


func _restyled() -> void:
	_number.size_px = tuning.font_countdown_px
	_number.use_tilt(TILT_SHADER, tuning.speed_tilt_rad())
	_card_bar.style = style
	_card_bar.total = steps_total
	_layout()


## The leg line above the number ("LEG 1 OF 8" and the leg objective, if any).
func set_leg(leg_index: int, legs_total: int, objective: String) -> void:
	_leg.text = TEXT_LEG % [leg_index, legs_total] if leg_index > 0 else ""
	_objective.text = objective
	_layout()


## Gyro steering is in use: show the calibration card.
func set_gyro(on: bool) -> void:
	gyro = on
	_card.visible = on and not holding
	_refresh_card()


## Waiting for the motion-permission tap (web + gyro).
func set_hold(on: bool) -> void:
	holding = on
	_tapped = false
	_tap.visible = on
	_number.visible = not on
	_card.visible = gyro and not on
	if on:
		step = steps_total
		_layout()
		if visible:
			slide_in(_tap_panel, tuning.screen_slide_px, tuning.screen_fade_in_s, 0.0)


## Shows countdown step `n` (3, 2, 1; 0 = GO). Opens the screen if needed.
func show_step(n: int) -> void:
	step = n
	if not visible or not is_open():
		_open = true
		_show()
		modulate.a = 1.0
	if holding:
		return
	kill_tweens()
	_number.visible = true
	_number.text = TEXT_GO if n == 0 else str(n)
	_number.set_ink(ScreenText.Ink.ACCENT if n == 0 else ScreenText.Ink.TEXT)
	_layout()
	var from := Units.pct_to_frac(tuning.countdown_punch_scale_pct)
	punch(_number, from, tuning.countdown_punch_s)
	if gyro:
		recalibrations += 1
		recalibrate.emit()
	_refresh_card()
	if n == 0:
		var tw := new_tween()
		tw.tween_interval(tuning.countdown_go_hold_s)
		tw.tween_property(self, ^"modulate:a", 0.0, tuning.countdown_go_fade_s)
		tw.tween_callback(_go_done)


## The number shown again without its punch (resuming a paused countdown).
func show_still() -> void:
	_open = true
	_show()
	modulate.a = 1.0
	_number.modulate.a = 1.0
	_number.scale = Vector2.ONE


## Stops every transition where it would settle (snaps): the step fully shown.
func freeze() -> void:
	kill_tweens()
	modulate.a = 1.0
	for c: Control in [_number, _tap_panel]:
		c.modulate.a = 1.0
		c.scale = Vector2.ONE


func _go_done() -> void:
	step = -1
	_open = false
	visible = false
	modulate.a = 1.0


func number_text() -> String:
	return _number.text if _number.visible else ""


func card_visible() -> bool:
	return _card.visible


func tap_visible() -> bool:
	return _tap.visible


func _refresh_card() -> void:
	if not gyro:
		return
	var lit := clampi(steps_total - step + 1, 0, steps_total) if step > 0 else steps_total
	if step < 0:
		lit = 0
	_card_bar.set_state(lit, step == 0)
	_card_text.text = TEXT_GYRO_DONE if step == 0 else TEXT_GYRO_HOLD
	_card_text2.text = TEXT_GYRO_DONE_2 if step == 0 else TEXT_GYRO_HOLD_2
	_card_text.set_ink(ScreenText.Ink.GOLD if step == 0 else ScreenText.Ink.TEXT)
	_card.edge = ScreenPanel.Edge.GOLD if step == 0 else ScreenPanel.Edge.ACCENT
	_card.queue_redraw()
	_layout()


func _on_tap_input(event: InputEvent) -> void:
	var tap := (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed) \
			or (event is InputEventMouseButton and (event as InputEventMouseButton).pressed)
	if tap and holding and not _tapped:
		_tapped = true
		accept_event()
		motion_tap.emit()


func _unhandled_key_input(event: InputEvent) -> void:
	if holding and not _tapped and event.is_pressed():
		_tapped = true
		motion_tap.emit()


func _layout() -> void:
	if style == null:
		return
	var g := tuning.spacing_grid_px
	var cx := safe.get_center().x
	# The number: centred above the middle, where the road is empty during the countdown.
	var ns := _number.get_combined_minimum_size()
	var nh := ns.y
	var nw := maxf(ns.x, float(_number.font_px()) * NUMBER_BOX_EM)
	var ny := safe.position.y + safe.size.y * NUMBER_Y - nh * 0.5
	_number.position = Vector2(cx - nw * 0.5, ny)
	_number.size = Vector2(nw, nh)
	# The info column, left-anchored at mid height (clear of the car and the HUD
	# corners): the leg line and objective, then the gyro calibration card.
	var a := safe.grow(-margin())
	var pad := tuning.panel_padding_px * style.ts
	var ls := _leg.get_combined_minimum_size()
	var os := _objective.get_combined_minimum_size()
	var ts := _card_title.get_combined_minimum_size()
	var tx := _card_text.get_combined_minimum_size()
	var widest := 0.0
	for t: String in [TEXT_GYRO_HOLD, TEXT_GYRO_HOLD_2, TEXT_GYRO_DONE, TEXT_GYRO_DONE_2]:
		widest = maxf(widest, HudDraw.text_width(style.label, t, _card_text.font_px()))
	var bar_h := tuning.boost_bar_height_px
	var cw := maxf(widest, ts.x) + pad * 2.0
	var ch := pad + ts.y + tx.y * 2.0 + g + bar_h + pad
	# The leg chip: LEG n OF 8, the objective (if any) under it.
	_leg_chip.visible = not _leg.text.is_empty()
	var oh := os.y if not _objective.text.is_empty() else 0.0
	var chip := Vector2(maxf(ls.x, os.x) + pad * 2.0, ls.y + oh + g)
	var col_h := (chip.y if _leg_chip.visible else 0.0) + (g * 2.0 + ch if _card.visible else 0.0)
	var y := ny + nh * 0.5 - col_h * 0.5
	_leg_chip.position = Vector2(a.position.x, y)
	_leg_chip.size = chip
	_leg.position = Vector2(pad, g * 0.5)
	_leg.size = ls
	_objective.position = Vector2(pad, g * 0.5 + ls.y)
	_objective.size = os
	if _leg_chip.visible:
		y += chip.y + g * 2.0
	_card.size = Vector2(cw, ch)
	_card.position = Vector2(a.position.x, y)
	_card_title.position = Vector2(pad, pad)
	_card_title.size = ts
	_card_text.position = Vector2(pad, pad + ts.y)
	_card_text.size = tx
	_card_text2.position = Vector2(pad, pad + ts.y + tx.y)
	_card_text2.size = _card_text2.get_combined_minimum_size()
	_card_bar.position = Vector2(pad, pad + ts.y + tx.y * 2.0 + g)
	_card_bar.size = Vector2(cw - pad * 2.0, bar_h)
	# Tap prompt: the whole screen catches the tap; the card sits where the number would.
	_tap.position = Vector2.ZERO
	_tap.size = full.size
	var ps := _tap_text.get_combined_minimum_size()
	var pn := _tap_note.get_combined_minimum_size()
	var pw := maxf(ps.x, pn.x) + pad * 4.0
	var ph := maxf(tuning.touch_target_px, pad * 2.0 + ps.y + pn.y)
	_tap_panel.size = Vector2(pw, ph)
	_tap_panel.position = Vector2(cx - pw * 0.5, safe.position.y + safe.size.y * NUMBER_Y - ph * 0.5)
	_tap_text.position = Vector2(pad * 2.0, (ph - ps.y - pn.y) * 0.5)
	_tap_text.size = ps
	_tap_note.position = Vector2(pad * 2.0, _tap_text.position.y + ps.y)
	_tap_note.size = pn


## The number's centre line (share of the safe height) and its box (ems).
const NUMBER_Y := 0.4   # lint: allow-number layout proportion
const NUMBER_BOX_EM := 1.3   # lint: allow-number layout proportion
