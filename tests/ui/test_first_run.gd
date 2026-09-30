extends WBTest
## The first-run chooser (WP8.1): shown once, on a fresh save, when the title's PLAY (or
## DAILY DRIVE) is pressed; DRIVE keeps the choice and starts the run, SKIP puts the
## default layout back (drag + auto, right hand) and starts, Esc goes back to the title;
## it never shows again, and never when the first run is off (tests and tools); its taps
## write Settings; the thumb-side DRIVE mirrors; text fit at both text sizes on a 1280x720
## and a notched 1560x720 canvas for every layout; nothing drawn after it closes. Spec:
## Controls → Settings and first run; Design system; Accessibility. docs/SCREENS.md →
## First run.

const CANVASES: Array[Vector2] = [Vector2(1280.0, 720.0), Vector2(1560.0, 720.0)]
const NOTCH := Vector4(44.0, 0.0, 44.0, 21.0)
const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const IOS_ID := 1_893_457_201
const TOL := 0.5

var t: Tuning
var probe := HudTextProbe.new()
var _nodes: Array[Node] = []
var _started: Array[StringName] = []
var _was_enabled: bool = false


func before_all() -> void:
	t = Tuning.load_default()


func before_each() -> void:
	Settings.restore_defaults()
	_started.clear()
	_was_enabled = Save.first_run_enabled
	Save.first_run_enabled = true
	Save.reset_fresh()


func after_each() -> void:
	HudDraw.probe = null
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	Save.first_run_enabled = _was_enabled
	Save.reset_fresh()
	Settings.restore_defaults()


func _title(full: Rect2 = SCREEN, safe: Rect2 = SCREEN) -> TitleScreens:
	var ts := TitleScreens.new()
	ts.persist_settings = false
	tree.root.add_child(ts)
	_nodes.push_front(ts)
	ts.set_screen(full, safe)
	ts.start.connect(func(m: StringName) -> void: _started.append(m))
	ts.show_state(Game.MENU)
	ts.finish_animations()
	return ts


func _tap(c: Control) -> void:
	var p := tree.root.get_final_transform() * c.get_global_rect().get_center()
	for down: bool in [true, false]:
		var ev := InputEventScreenTouch.new()
		ev.index = IOS_ID
		ev.position = p
		ev.pressed = down
		Input.parse_input_event(ev)
		Input.flush_buffered_events()


func _key(action: StringName) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func _open_chooser(ts: TitleScreens) -> FirstRunScreen:
	_tap(ts.title.play_button)
	ts.finish_animations()
	return ts.first_run


func test_play_on_a_fresh_save_shows_the_chooser_then_drives() -> void:
	var ts := _title()
	check(Save.chooser_pending(), "a fresh save")
	var fr := _open_chooser(ts)
	if not check(fr != null and fr.visible, "PLAY opens the chooser"):
		return
	eq(_started.size(), 0, "the run waits")
	check(not ts.title.visible, "the menu steps aside")
	check(ts.is_open())
	eq(fr.chooser.selected_index(0), 0, "DRAG preselected (the spec's default)")
	eq(fr.chooser.selected_index(1), 0, "AUTO preselected")
	_tap(fr.chooser.option(1, 1))
	eq(Settings.get_value(&"throttle_mode"), &"manual", "MANUAL written at once")
	_tap(fr.drive_button)
	eq(_started, [RunContext.MODE_JOURNEY] as Array[StringName], "DRIVE starts the Journey")
	check(not Save.chooser_pending(), "answered: never again")
	eq(Settings.get_value(&"throttle_mode"), &"manual", "the choice is kept")
	# The next PLAY goes straight to the run.
	ts.show_state(Game.COUNTDOWN)
	eq(ts.visible_item_count(), 0, "nothing drawn once the run starts")
	ts.show_state(Game.MENU)
	ts.finish_animations()
	_tap(ts.title.play_button)
	eq(_started.size(), 2, "no chooser the second time")


func test_skip_keeps_the_default_layout() -> void:
	var ts := _title()
	var fr := _open_chooser(ts)
	_tap(fr.chooser.option(0, 1))
	_tap(fr.chooser.option(2, 1))
	eq(Settings.get_value(&"left_handed"), true)
	_tap(fr.skip_button)
	eq(_started, [RunContext.MODE_JOURNEY] as Array[StringName], "SKIP starts too")
	eq(Settings.get_value(&"steering_mode"), &"drag", "drag")
	eq(Settings.get_value(&"throttle_mode"), &"auto", "auto")
	eq(Settings.get_value(&"left_handed"), false, "right hand")
	check(not Save.chooser_pending(), "skipping answers it")


func test_esc_goes_back_and_it_stays_pending() -> void:
	var ts := _title()
	var fr := _open_chooser(ts)
	_key(&"ui_cancel")
	check(not fr.visible and ts.title.visible, "back to the title")
	eq(_started.size(), 0)
	check(Save.chooser_pending(), "still pending")
	_tap(ts.title.daily_button)
	ts.finish_animations()
	check(fr.visible, "DAILY DRIVE asks too")
	_key(&"ui_accept")
	eq(_started, [RunContext.MODE_DAILY] as Array[StringName], "Enter drives the mode that asked")


func test_never_when_the_first_run_is_off() -> void:
	Save.first_run_enabled = false
	var ts := _title()
	_tap(ts.title.play_button)
	eq(_started, [RunContext.MODE_JOURNEY] as Array[StringName], "tests and tools play straight away")
	check(ts.first_run == null, "the chooser is never built")


func test_drive_on_the_thumb_side() -> void:
	var ts := _title()
	var fr := _open_chooser(ts)
	gt(fr.drive_button.position.x, fr.skip_button.position.x, "right hand: DRIVE right of SKIP")
	near(fr.drive_button.get_global_rect().end.x, SCREEN.end.x - t.hud.layout_grid_px, TOL, "in the corner")
	near(fr.drive_button.size.y, t.hud.primary_button_size_px.y, TOL, "the primary size")
	_tap(fr.chooser.option(2, 1))
	fr._layout()
	lt(fr.drive_button.position.x, fr.skip_button.position.x, "left hand: mirrored")
	near(fr.drive_button.position.x, t.hud.layout_grid_px, TOL)


func test_sketch_follows_the_layout() -> void:
	var ts := _title()
	var fr := _open_chooser(ts)
	var sk := fr.chooser.sketch
	var r0 := sk.redraws
	fr.chooser.refresh()
	await tree.process_frame
	var r1 := sk.redraws
	fr.chooser.refresh()
	await tree.process_frame
	eq(sk.redraws, r1, "an unchanged layout does not redraw")
	ge(r1, r0)
	_tap(fr.chooser.option(0, 1))
	eq(sk.steering, &"gyro")
	eq(fr.chooser.line1.text, "TILT THE PHONE TO STEER")
	_tap(fr.chooser.option(1, 1))
	_tap(fr.chooser.option(2, 1))
	eq(fr.chooser.line2.text, "BRAKE RIGHT · GAS + BOOST LEFT", "mirrored words")


# ---------------------------------------------------------------- Text fit

func _configs() -> Array[Array]:
	var out: Array[Array] = []
	for size in CANVASES:
		var full := Rect2(Vector2.ZERO, size)
		var safe := full
		if size.x > CANVASES[0].x:
			safe = Rect2(Vector2(NOTCH.x, NOTCH.y), size - Vector2(NOTCH.x + NOTCH.z, NOTCH.y + NOTCH.w))
		for ts in t.hud.text_scales:
			out.append([full, safe, ts, "%dx%d text %d%%" % [size.x, size.y, roundi(ts * 100.0)]])
	return out


func _redraw(n: Node) -> void:
	if n is CanvasItem:
		(n as CanvasItem).queue_redraw()
	for ch in n.get_children(true):
		_redraw(ch)


static func _buttons(n: Node, out: Array[ScreenButton]) -> void:
	if n is ScreenButton and (n as ScreenButton).is_visible_in_tree():
		out.append(n as ScreenButton)
	for ch in n.get_children():
		_buttons(ch, out)


func _fit(root: Control, safe: Rect2, what: String) -> int:
	_redraw(root)
	probe.clear()
	await tree.process_frame
	var ids: Array[int] = []
	for i in probe.size():
		var ci := probe.items[i]
		if is_instance_valid(ci) and ci.is_visible_in_tree() and root.is_ancestor_of(ci):
			ids.append(i)
	var buttons: Array[ScreenButton] = []
	_buttons(root, buttons)
	for i in ids:
		var ci := probe.items[i] as Control
		var g := probe.global_rect(i)
		var label := "'%s'" % probe.texts[i]
		if ci is ScreenButton:
			check(ci.get_global_rect().grow(TOL).encloses(g), "%s: %s fits its button" % [what, label])
		else:
			if ci is ScreenText:
				check(Rect2(Vector2.ZERO, ci.size).grow(TOL).encloses(probe.rects[i]), "%s: %s fits its box" % [what, label])
			for b in buttons:
				check(not g.grow(-TOL).intersects(b.get_global_rect().grow(-TOL)), "%s: %s under %s" % [what, label, b.name])
		check(safe.grow(TOL).encloses(g), "%s: %s inside the safe area" % [what, label])
	for a in ids.size():
		for b in range(a + 1, ids.size()):
			if probe.items[ids[a]] == probe.items[ids[b]]:
				continue
			check(not probe.global_rect(ids[a]).grow(-TOL).intersects(probe.global_rect(ids[b]).grow(-TOL)),
					"%s: '%s' overlaps '%s'" % [what, probe.texts[ids[a]], probe.texts[ids[b]]])
	for b in buttons:
		check(safe.grow(TOL).encloses(b.get_global_rect()), "%s: %s inside the safe area" % [what, b.name])
		ge(b.size.y, t.hud.touch_target_px - TOL, "%s: %s touch target" % [what, b.name])
	for a in buttons.size():
		for b in range(a + 1, buttons.size()):
			check(not buttons[a].get_global_rect().grow(-TOL).intersects(buttons[b].get_global_rect().grow(-TOL)),
					"%s: %s overlaps %s" % [what, buttons[a].name, buttons[b].name])
	# The sketch stays clear of the rows and the buttons.
	var sk := (root as FirstRunScreen).chooser.sketch.get_global_rect()
	for b in buttons:
		check(not sk.intersects(b.get_global_rect()), "%s: the sketch clear of %s" % [what, b.name])
	return ids.size()


func test_chooser_text_fits() -> void:
	HudDraw.probe = probe
	var layouts: Array[Array] = [[&"drag", &"auto", false], [&"drag", &"manual", true], [&"gyro", &"auto", false],
		[&"gyro", &"manual", true]]
	for c in _configs():
		Settings.set_value(&"text_scale", float(c[2]))
		Save.reset_fresh()
		Settings.set_value(&"text_scale", float(c[2]))
		var ts := _title(c[0], c[1])
		var fr := _open_chooser(ts)
		for l in layouts:
			Settings.set_value(&"steering_mode", l[0])
			Settings.set_value(&"throttle_mode", l[1])
			Settings.set_value(&"left_handed", l[2])
			fr._layout()
			fr.finish_animations()
			var what := "%s %s+%s%s" % [c[3], l[0], l[1], " left" if l[2] else ""]
			gt(await _fit(fr, c[1], what), 10, "%s: drawn" % what)
		_nodes.erase(ts)
		ts.free()
