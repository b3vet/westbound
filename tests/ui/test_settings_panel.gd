extends WBTest
## The settings (WP8.1): every setting the spec lists has a row on its page (GAME,
## CONTROLS, AUDIO); every option of every row writes Settings through an iOS-id tap and
## is announced on Events.settings_changed (the systems apply it live) and shows as
## selected; a change made elsewhere shows at once; the chooser revisited from CONTROLS
## (CHOOSE LAYOUT / BACK, reset when the panel closes); TILT is N/A without tilt; text fit
## on every page and the chooser (both text sizes, 1280x720 and a notched 1560x720, in
## the pause menu and on the title). Spec: UI → Screens → Settings; Controls → Settings
## and first run; Accessibility; Performance budget (quality tiers, battery saver).
## docs/SCREENS.md → Settings.

const SCREENS_SCENE := preload("res://src/ui/screens/run_screens.tscn")
const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const CANVASES: Array[Vector2] = [Vector2(1280.0, 720.0), Vector2(1560.0, 720.0)]
const NOTCH := Vector4(44.0, 0.0, 44.0, 21.0)
const IOS_ID := 1_893_457_201
const TOL := 0.5

## Every setting the spec names (UI → Screens → Settings; Controls → Settings; Cameras;
## Accessibility; Audio buses) plus the plan's D9 / D10, and the page it lives on.
const SPEC_ROWS := {
	&"steering_mode": SettingsPanel.PAGE_CONTROLS,
	&"throttle_mode": SettingsPanel.PAGE_CONTROLS,
	&"steer_sensitivity": SettingsPanel.PAGE_CONTROLS,
	&"steer_dead_zone": SettingsPanel.PAGE_CONTROLS,
	&"steer_curve": SettingsPanel.PAGE_CONTROLS,
	&"left_handed": SettingsPanel.PAGE_CONTROLS,
	&"drag_visual": SettingsPanel.PAGE_CONTROLS,
	&"controls_scale": SettingsPanel.PAGE_CONTROLS,
	&"quality_tier": SettingsPanel.PAGE_GAME,
	&"battery_saver": SettingsPanel.PAGE_GAME,
	&"haptics": SettingsPanel.PAGE_GAME,
	&"units": SettingsPanel.PAGE_GAME,
	&"camera_mode": SettingsPanel.PAGE_GAME,
	&"reduced_motion": SettingsPanel.PAGE_GAME,
	&"text_scale": SettingsPanel.PAGE_GAME,
	&"volume_master": SettingsPanel.PAGE_AUDIO,
	&"volume_music": SettingsPanel.PAGE_AUDIO,
	&"volume_sfx": SettingsPanel.PAGE_AUDIO,
	&"volume_engine": SettingsPanel.PAGE_AUDIO,
	&"volume_ui": SettingsPanel.PAGE_AUDIO,
	&"audio_muted": SettingsPanel.PAGE_AUDIO,
}

var t: Tuning
var probe := HudTextProbe.new()
var _nodes: Array[Node] = []
var _changed: Array[StringName] = []


class NoTilt:
	extends PlayerInput

	func is_gyro_supported() -> bool:
		return false


func before_all() -> void:
	t = Tuning.load_default()


func before_each() -> void:
	Settings.restore_defaults()
	_changed.clear()
	Events.settings_changed.connect(_on_changed)


func after_each() -> void:
	Events.settings_changed.disconnect(_on_changed)
	HudDraw.probe = null
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	Settings.restore_defaults()


func _on_changed(k: StringName) -> void:
	_changed.append(k)


func _screens(full: Rect2 = SCREEN, safe: Rect2 = SCREEN) -> RunScreens:
	var s := SCREENS_SCENE.instantiate() as RunScreens
	s.persist_settings = false
	tree.root.add_child(s)
	_nodes.push_front(s)
	s.bind(null, HudFeed.new())
	s.set_screen(full, safe)
	Events.game_state_changed.emit(Game.RUNNING, Game.PAUSED)
	s.pause_screen.open_settings()
	s.finish_animations()
	return s


func _tap(c: Control) -> void:
	var p := tree.root.get_final_transform() * c.get_global_rect().get_center()
	for down: bool in [true, false]:
		var ev := InputEventScreenTouch.new()
		ev.index = IOS_ID
		ev.position = p
		ev.pressed = down
		Input.parse_input_event(ev)
		Input.flush_buffered_events()


# ---------------------------------------------------------------- Rows

func test_every_spec_setting_has_a_row_on_its_page() -> void:
	var sp := _screens().pause_screen.settings
	for key: StringName in SPEC_ROWS:
		var r := sp.row(key)
		if not check(r != null, "a row for %s" % key):
			continue
		eq(r.page, int(SPEC_ROWS[key]), "%s on its page" % key)
		check(Settings.DEFAULTS.has(key))
		ge(r.buttons.size(), 2, "%s is a choice" % key)
	for r in sp.rows:
		check(SPEC_ROWS.has(r.key), "%s is a setting the spec or the plan names" % r.key)
	eq(sp.row(&"camera_mode").buttons.size(), t.camera.modes.size(), "every camera mode")
	check(sp.row(&"camera_mode").wide, "the camera row spans the page")
	eq(sp.row(&"quality_tier").buttons.size(), t.quality.tier_names.size(), "every quality tier")
	eq(sp.row(&"steer_dead_zone").values.size(), t.meta.settings_dead_zones.size())
	eq(sp.row(&"steer_curve").values.size(), t.meta.settings_curves.size())


func test_every_option_writes_its_setting_live() -> void:
	var sp := _screens().pause_screen.settings
	for page in SettingsPanel.PAGE_CAPTIONS.size():
		_tap(sp.tabs[page])
		eq(sp.page, page, "tab %d" % page)
		for r in sp.rows:
			var on := r.page == page
			check(r.buttons[0].visible == on, "%s shown only on its page" % r.key)
			if not on:
				continue
			for i in r.buttons.size():
				var b := r.buttons[i]
				if b.disabled:
					continue
				ge(b.size.y, t.hud.touch_target_px - TOL, "%s touch target" % b.name)
				_changed.clear()
				var before: Variant = Settings.get_value(r.key)
				_tap(b)
				var want: Variant = r.values[i]
				var got: Variant = Settings.get_value(r.key)
				if want is float:
					near(float(got), float(want), 1e-9, "%s = option %d" % [r.key, i])
				else:
					eq(str(got), str(want), "%s = option %d" % [r.key, i])
				eq(sp.selected_index(r.key), i, "%s shows option %d" % [r.key, i])
				if str(got) != str(before):
					check(_changed.has(r.key), "%s announced on Events.settings_changed" % r.key)
			# Back to the default for the next rows (text size changes the layout).
			Settings.set_value(r.key, Settings.DEFAULTS[r.key])


func test_a_change_elsewhere_shows_at_once() -> void:
	var sp := _screens().pause_screen.settings
	Settings.set_value(&"camera_mode", &"hood")   # the C key
	eq(sp.selected_index(&"camera_mode"), t.camera.modes.find("hood"))
	Settings.set_value(&"quality_tier", &"low")
	eq(sp.selected_index(&"quality_tier"), 0)
	check(_changed.has(&"quality_tier"), "the Quality autoload hears it (Events.settings_changed)")
	eq(Quality.tier, &"low", "and applies it live")
	Settings.set_value(&"quality_tier", &"medium")


# ---------------------------------------------------------------- Chooser

func test_choose_layout_from_the_controls_page() -> void:
	var p := _screens().pause_screen
	var sp := p.settings
	check(not sp.chooser_button.visible, "CHOOSE LAYOUT only on CONTROLS")
	_tap(sp.tabs[SettingsPanel.PAGE_CONTROLS])
	check(sp.chooser_button.visible)
	eq(sp.chooser_button.text, SettingsPanel.TEXT_CHOOSE)
	_tap(sp.chooser_button)
	check(sp.chooser_open and sp.chooser.visible, "the chooser opens")
	check(not sp.row(&"steering_mode").buttons[0].visible, "in place of the rows")
	eq(sp.chooser_button.text, SettingsPanel.TEXT_BACK)
	_tap(sp.chooser.option(1, 1))
	eq(Settings.get_value(&"throttle_mode"), &"manual", "the chooser writes Settings")
	check(p.settings_dirty, "saved with the other settings")
	_tap(sp.chooser.option(2, 1))
	eq(Settings.get_value(&"left_handed"), true)
	eq(sp.chooser.sketch.throttle, &"manual", "the sketch follows")
	check(sp.chooser.sketch.left_handed)
	_tap(sp.chooser_button)
	check(not sp.chooser.visible and sp.row(&"steering_mode").buttons[0].visible, "BACK: the rows again")
	eq(sp.selected_index(&"throttle_mode"), 1, "and they show the chooser's answer")
	# A tab closes the chooser; closing the settings resets it.
	sp.toggle_chooser()
	_tap(sp.tabs[SettingsPanel.PAGE_GAME])
	check(not sp.chooser_open and not sp.chooser.visible)
	sp.toggle_chooser()
	check(sp.chooser_open)
	p.close_settings()
	check(not sp.chooser_open, "closing the settings resets the chooser view")


func test_tilt_is_na_without_tilt() -> void:
	var s := _screens()
	var hub := NoTilt.new()
	s.pause_screen.settings.hub = hub
	var sp := s.pause_screen.settings
	sp.toggle_chooser()
	sp.chooser.refresh()
	sp.refresh()
	var tilt := sp.chooser.option(0, 1)
	check(tilt.disabled, "TILT disabled in the chooser")
	eq(tilt.note, FirstRunChooser.TEXT_NA)
	check(sp.option(&"steering_mode", 1).disabled, "and in the rows")
	eq(sp.chooser.sketch.steering, &"drag", "the sketch shows what steers: drag")
	hub.free()


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


## Every string inside its box (its button, or its ScreenText) and the safe area, none
## overlapping another or running under a button; every button in the safe area, a touch
## target and clear of the others.
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
	return ids.size()


func _fit_pages(host: Control, sp: SettingsPanel, safe: Rect2, what: String) -> void:
	for page in SettingsPanel.PAGE_CAPTIONS.size():
		sp.show_page(page)
		gt(await _fit(host, safe, "%s %s" % [what, SettingsPanel.PAGE_CAPTIONS[page]]), 6, "drawn")
	sp.show_page(SettingsPanel.PAGE_CONTROLS)
	sp.toggle_chooser()
	# The longest sketch lines: drag + manual, mirrored; gyro + auto.
	Settings.set_value(&"throttle_mode", &"manual")
	Settings.set_value(&"left_handed", true)
	gt(await _fit(host, safe, "%s chooser drag+manual left" % what), 6, "drawn")
	Settings.set_value(&"steering_mode", &"gyro")
	Settings.set_value(&"throttle_mode", &"auto")
	gt(await _fit(host, safe, "%s chooser gyro+auto" % what), 6, "drawn")
	Settings.set_value(&"throttle_mode", &"manual")
	Settings.set_value(&"left_handed", false)
	gt(await _fit(host, safe, "%s chooser gyro+manual" % what), 6, "drawn")
	sp.toggle_chooser()
	Settings.set_value(&"steering_mode", &"drag")
	Settings.set_value(&"throttle_mode", &"auto")


func test_pause_settings_text_fits() -> void:
	HudDraw.probe = probe
	for c in _configs():
		Settings.set_value(&"text_scale", float(c[2]))
		var s := _screens(c[0], c[1])
		await _fit_pages(s.pause_screen, s.pause_screen.settings, c[1], "pause %s" % c[3])
		_nodes.erase(s)
		s.free()


func test_title_settings_text_fits() -> void:
	HudDraw.probe = probe
	for c in _configs():
		Settings.set_value(&"text_scale", float(c[2]))
		var ts := TitleScreens.new()
		ts.persist_settings = false
		tree.root.add_child(ts)
		_nodes.push_front(ts)
		ts.set_screen(c[0], c[1])
		ts.show_state(Game.MENU)
		ts.title.open_settings()
		ts.finish_animations()
		await _fit_pages(ts.title, ts.title.settings, c[1], "title %s" % c[3])
		_nodes.erase(ts)
		ts.free()
