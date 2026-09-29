extends WBTest
## The gameplay HUD. Spec: UI, HUD and design system → HUD elements (update rule:
## labels change only when their value changes, nothing animates when idle; safe
## areas; text size), Accessibility; Scoring → Score feedback (4-line event stack,
## multiplier up to 999×, glitter, banking count-up), Multiplier (TOO SLOW bar), Boost;
## Lives (icons react to hit / life_restored). CONTRACTS §14 (bind, signals).

const HUD_SCENE := "res://src/ui/hud/hud.tscn"
const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const DT := 1.0 / 60.0
const EPS := 1e-6

var t: Tuning
var hud: Hud
var feed: HudFeed


func before_all() -> void:
	t = Tuning.load_default()


func before_each() -> void:
	Settings.reset_to_defaults()
	hud = (load(HUD_SCENE) as PackedScene).instantiate() as Hud
	hud.auto_process = false
	hud.set_screen(SCREEN, SCREEN)
	tree.root.add_child(hud)
	feed = HudFeed.new()
	feed.top_speed_mps = Units.kmh_to_mps(270.0)
	feed.min_speed_mps = t.scoring.min_speed_mps()
	feed.speed_mps = Units.kmh_to_mps(200.0)
	feed.banked = 1000
	feed.best = 5000
	feed.checkpoint_distance_m = 1234.0


func after_each() -> void:
	if hud != null:
		hud.free()
		hud = null
	Settings.reset_to_defaults()


func _run(seconds: float) -> void:
	var n := ceili(seconds / DT)
	for i in n:
		hud.advance(DT)


func _frames(n: int) -> void:
	for i in n:
		await tree.process_frame


func _kmh(v: float) -> float:
	return Units.kmh_to_mps(v)


# ---------------------------------------------------------------- Binding

func test_unbound_hud_runs_without_errors() -> void:
	_run(0.5)
	Events.scored.emit(Events.CLOSE_PASS, 450, 12.0, 0.3)
	Events.chain_banked.emit(900, Events.REASON_CASH_OUT, 1900)
	Events.hit.emit(Events.HIT_TRAFFIC, 1)
	Events.life_restored.emit(2)
	Events.hesitated.emit()
	_run(3.0)
	await _frames(2)
	eq(hud.displayed_banked(), 1900, "the count-up works from the event alone")
	eq(hud.event_line_count(), 0, "lines aged out")
	hud.bind(null)
	_run(0.1)


func test_bind_shows_feed_values() -> void:
	feed.chain = 48200
	feed.multiplier = 12.44
	hud.bind(feed)
	hud.advance(DT)
	eq(hud.speed_text(), "200")
	eq(hud.chain_text(), "48,200")
	eq(hud.multiplier_text(), "12.4×")
	eq(hud.checkpoint_text(), "1.2")
	eq(hud.displayed_banked(), 1000, "banked shows at once on bind (no count-up)")
	check(not hud.counting_up())


func test_units_setting_switches_to_mph() -> void:
	hud.bind(feed)
	hud.advance(DT)
	Settings.set_value(&"units", &"mph")
	hud.advance(DT)
	eq(hud.speed_text(), str(roundi(Units.kmh_to_mph(200.0))), "mph")
	eq(hud.checkpoint_text(), HudFormat.tenths_text(HudFormat.distance_key(1234.0, true)), "miles")


# ---------------------------------------------------------------- Update rule

func test_labels_change_only_when_the_shown_value_changes() -> void:
	hud.bind(feed)
	hud.advance(DT)
	await _frames(2)
	var c0 := hud.change_count()
	var r0 := hud.redraw_count()
	_run(0.5)
	await _frames(3)
	eq(hud.change_count(), c0, "no value changes while idle")
	eq(hud.redraw_count(), r0, "nothing redraws while idle")
	feed.speed_mps += _kmh(0.2)
	feed.sun_height -= 1e-5
	hud.advance(DT)
	eq(hud.change_count(), c0, "sub-unit changes are not shown")
	feed.speed_mps = _kmh(201.0)
	hud.advance(DT)
	check(hud.change_count() > c0, "a new km/h redraws")
	eq(hud.speed_text(), "201")
	var c1 := hud.change_count()
	feed.speed_mps = _kmh(201.3)
	_run(0.2)
	eq(hud.change_count(), c1, "same shown number again: no change")


func test_idle_hud_hides_what_it_does_not_show() -> void:
	hud.bind(feed)
	hud.advance(DT)
	await _frames(1)
	check(not hud.min_speed_visible(), "above the threshold: no min-speed bar")
	eq(hud.event_line_count(), 0)
	eq(hud.glitter_alive(), 0)
	var root := hud.get_node("Root")
	check(not (root.get_node("Flyer") as Control).visible, "flyer hidden")
	check(not (root.get_node("Glitter") as Control).visible, "glitter hidden")
	check(not (root.get_node("Stack") as Control).visible, "empty stack hidden")
	check(not (root.get_node("Chain") as Control).visible, "no chain at 1.0×: row hidden")
	le(hud.visible_item_count(), 20, "canvas items drawn (budget)")


func test_only_the_buttons_take_touches() -> void:
	var root := hud.get_node("Root") as Control
	eq(root.mouse_filter, Control.MOUSE_FILTER_IGNORE, "root")
	for child in root.get_children():
		var c := child as Control
		if c is HudButton:
			eq(c.mouse_filter, Control.MOUSE_FILTER_STOP, c.name)
		else:
			eq(c.mouse_filter, Control.MOUSE_FILTER_IGNORE, c.name)


func test_buttons_emit_pause_and_camera() -> void:
	var got: Array[StringName] = []
	hud.pause_pressed.connect(func() -> void: got.append(&"pause"))
	hud.camera_pressed.connect(func() -> void: got.append(&"camera"))
	(hud.get_node("Root/Pause") as BaseButton).pressed.emit()
	(hud.get_node("Root/Camera") as BaseButton).pressed.emit()
	eq(got, [&"pause", &"camera"] as Array[StringName])


# ---------------------------------------------------------------- Event stack

func test_event_stack_keeps_four_lines_and_ages_out() -> void:
	hud.bind(feed)
	var pts: Array[int] = [100, 200, 300, 400, 500, 6800]
	var kinds: Array[StringName] = [Events.PASS, Events.CUT, Events.PASS, Events.CLOSE_PASS, Events.PASS, Events.THREAD]
	for i in pts.size():
		Events.scored.emit(kinds[i], pts[i], 2.0, 0.5)
		hud.advance(DT)
	eq(t.hud.event_stack_lines, 4, "spec: a stack of 4 lines")
	eq(hud.event_line_count(), t.hud.event_stack_lines, "never more than 4 lines")
	eq(hud.event_line(0), "THREAD! +6,800", "newest on top")
	eq(hud.event_line(1), "PASS +500")
	eq(hud.event_line(3), "PASS +300", "oldest kept is the 3rd event")
	_run(t.hud.event_hold_s)
	gt(hud.event_line_count(), 0, "still showing during the hold")
	_run(t.hud.event_fade_s + 0.1)
	eq(hud.event_line_count(), 0, "all lines faded out")


func test_every_event_has_its_own_word() -> void:
	hud.bind(feed)
	Events.scored.emit(Events.PASS, 480, 1.0, 0.8)
	Events.scored.emit(Events.CLOSE_PASS, 1450, 1.0, 0.2)
	Events.scored.emit(Events.CUT, 900, 1.0, 0.4)
	Events.scored.emit(Events.THREAD, 2000, 1.0, 0.3)
	var words := PackedStringArray()
	for i in hud.event_line_count():
		words.append(hud.event_line(i).get_slice(" ", 0))
	eq(words, PackedStringArray(["THREAD!", "CUT", "CLOSE!", "PASS"]))
	Events.hesitated.emit()
	eq(hud.event_line(0), "HESITATED")
	Events.chain_lost.emit(500, Events.REASON_HESITATED)
	eq(hud.event_line(0), "HESITATED", "hesitation shows once (its own word)")
	Events.chain_lost.emit(700, Events.REASON_HIT)
	eq(hud.event_line(0), "CHAIN LOST -700")
	Events.chain_banked.emit(1200, Events.REASON_CHECKPOINT, 2200)
	eq(hud.event_line(0), "BANKED +1,200")


# ---------------------------------------------------------------- Multiplier

func test_multiplier_text_caps_at_999() -> void:
	hud.bind(feed)
	var cases := {1.0: "1.0×", 1.04: "1.0×", 24.56: "24.6×", 99.94: "99.9×", 99.96: "100×",
		123.4: "123×", 999.0: "999×", 5000.0: "999×"}
	for m: float in cases:
		feed.multiplier = m
		hud.advance(DT)
		eq(hud.multiplier_text(), String(cases[m]), "multiplier %s" % m)


func test_multiplier_hue_cycles_faster_as_it_grows_and_wobbles_above_20() -> void:
	var h := t.hud
	eq(HudMultiplier.hue_hz(h, 1.0), 0.0, "no cycle at 1.0x (idle)")
	lt(HudMultiplier.hue_hz(h, 2.0), HudMultiplier.hue_hz(h, 10.0), "faster as it grows")
	le(HudMultiplier.hue_hz(h, 900.0), h.mult_hue_hz_max, "capped")
	eq(HudMultiplier.wobble_rad(h, h.multiplier_wobble_above), 0.0, "no wobble at 20x")
	gt(HudMultiplier.wobble_rad(h, h.multiplier_wobble_above + 5.0), 0.0, "wobbles above 20x")
	feed.multiplier = 30.0
	feed.chain = 100
	hud.bind(feed)
	var mult := hud.get_node("Root/Multiplier") as Control
	hud.advance(DT)
	var c0 := mult.self_modulate
	_run(0.25)
	ne(mult.self_modulate, c0, "hue moves")
	ne(mult.rotation, 0.0, "wobble")


# ---------------------------------------------------------------- Lives

func test_lives_icons_react_to_hit_and_life_restored() -> void:
	hud.bind(feed)
	hud.advance(DT)
	eq(hud.lives_shown(), 2)
	Events.hit.emit(Events.HIT_TRAFFIC, 1)
	eq(hud.lives_shown(), 1)
	check(hud.life_breaking(), "the lost icon breaks")
	feed.lives = 1
	_run(t.hud.life_break_s + 0.05)
	check(not hud.life_breaking(), "break animation ends")
	eq(hud.lives_shown(), 1)
	Events.ghost_started.emit(2.0)
	check(hud.ghost_shown(), "ghost indicated")
	Events.ghost_ended.emit()
	check(not hud.ghost_shown())
	Events.life_restored.emit(2)
	feed.lives = 2
	check(hud.life_restoring(), "restore pops the icon back")
	eq(hud.lives_shown(), 2)
	_run(t.hud.life_restore_s + 0.05)
	check(not hud.life_restoring())
	eq(hud.lives_shown(), 2)


# ---------------------------------------------------------------- Min speed

func test_min_speed_bar_visibility_thresholds() -> void:
	var show := t.hud.min_speed_bar_show_below_kmh
	var hyst := t.hud.min_speed_bar_hysteresis_kmh
	hud.bind(feed)
	feed.speed_mps = _kmh(show + hyst + 10.0)
	hud.advance(DT)
	check(not hud.min_speed_visible(), "hidden well above the threshold")
	feed.speed_mps = _kmh(show - 1.0)
	hud.advance(DT)
	check(hud.min_speed_visible(), "shown when speed nears the minimum")
	check(not hud.too_slow_shown(), "no TOO SLOW before the rule says so")
	feed.speed_mps = _kmh(show + hyst * 0.5)
	hud.advance(DT)
	check(hud.min_speed_visible(), "hysteresis: still shown just above")
	feed.speed_mps = _kmh(show + hyst + 1.0)
	hud.advance(DT)
	check(not hud.min_speed_visible(), "hidden above threshold + hysteresis")
	feed.speed_mps = _kmh(t.scoring.min_speed_kmh - 20.0)
	feed.too_slow = true
	hud.advance(DT)
	check(hud.min_speed_visible() and hud.too_slow_shown(), "TOO SLOW below the minimum")
	feed.speed_mps = _kmh(show + 50.0)
	hud.advance(DT)
	check(hud.min_speed_visible(), "always shown while TOO SLOW")
	feed.too_slow = false
	hud.advance(DT)
	check(not hud.min_speed_visible())


# ---------------------------------------------------------------- Banking

func test_banking_count_up_converges_to_the_banked_total() -> void:
	feed.chain = 500
	feed.multiplier = 3.0
	hud.bind(feed)
	hud.advance(DT)
	eq(hud.displayed_banked(), 1000)
	Events.chain_banked.emit(500, Events.REASON_CASH_OUT, 1500)
	feed.banked = 1500
	feed.chain = 0
	feed.multiplier = 1.0
	hud.advance(DT)
	check(hud.counting_up(), "count-up started")
	eq(hud.displayed_banked(), 1000, "waits for the fly-in")
	_run(t.hud.bank_fly_s + t.hud.bank_count_s * 0.5)
	var mid := hud.displayed_banked()
	check(mid > 1000 and mid < 1500, "counting (got %d)" % mid)
	var prev := mid
	var monotonic := true
	for i in ceili(t.hud.bank_count_s / DT) + 2:
		hud.advance(DT)
		monotonic = monotonic and hud.displayed_banked() >= prev
		prev = hud.displayed_banked()
	check(monotonic, "counts up, never down")
	eq(hud.displayed_banked(), 1500, "lands exactly on the banked total")
	check(not hud.counting_up())


func test_new_run_snaps_banked_down() -> void:
	feed.banked = 9000
	hud.bind(feed)
	hud.advance(DT)
	feed.reset()
	hud.advance(DT)
	eq(hud.displayed_banked(), 0, "a reset shows at once")


# ---------------------------------------------------------------- Glitter

func test_glitter_on_high_multiplier_close_passes_and_threads() -> void:
	hud.bind(feed)
	var high := t.hud.glitter_min_multiplier + 1.0
	Events.scored.emit(Events.PASS, 100, high, 1.0)
	eq(hud.glitter_alive(), 0, "plain passes do not glitter")
	Events.scored.emit(Events.CLOSE_PASS, 100, t.hud.glitter_min_multiplier - 1.0, 0.2)
	eq(hud.glitter_alive(), 0, "low multiplier: no glitter")
	Events.scored.emit(Events.THREAD, 100, high, 0.2)
	eq(hud.glitter_alive(), t.hud.glitter_count)
	for i in 10:
		Events.scored.emit(Events.CLOSE_PASS, 100, high, 0.2)
	le(hud.glitter_alive(), t.hud.glitter_max, "clamped")
	_run(t.hud.glitter_s + 0.05)
	eq(hud.glitter_alive(), 0, "burst ends")
	check(not (hud.get_node("Root/Glitter") as Control).visible, "hidden when done")


# ---------------------------------------------------------------- Boost, text size, accent

func test_boost_meter_fills_with_boost_fill() -> void:
	hud.bind(feed)
	feed.boost_fill = 0.0
	hud.advance(DT)
	eq(hud.boost_lit(), 0)
	feed.boost_fill = 1.0
	hud.advance(DT)
	eq(hud.boost_lit(), t.hud.boost_bar_segments)
	feed.boost_fill = 0.5
	hud.advance(DT)
	eq(hud.boost_lit(), ceili(t.hud.boost_bar_segments * 0.5))


func test_text_scale_setting_scales_the_layout() -> void:
	var base := hud.layout.score.size
	Settings.set_value(&"text_scale", 1.25)
	hud.advance(DT)
	near(hud.layout.score.size.x, base.x * 1.25, 1e-3, "125% text")
	Settings.set_value(&"text_scale", 3.0)
	hud.advance(DT)
	near(hud.layout.score.size.x, base.x * 1.25, 1e-3, "clamped to the offered sizes")


func test_accent_is_applied() -> void:
	hud.set_accent(Color.RED)
	eq(hud.style.accent, Color.RED)
