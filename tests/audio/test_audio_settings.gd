extends WBTest
## The audio page of the in-run settings (WP7A): GAME / AUDIO tabs in the header row, a
## volume row per bus (Master, Music, SFX, Engine, UI) and the SOUND (mute) row; taps
## write Settings and the buses follow. Spec: UI → Screens ("Settings: ... audio
## buses"); Audio ("Buses ... each with a volume setting"). docs/AUDIO.md → Settings.

const SCREENS_SCENE := preload("res://src/ui/screens/run_screens.tscn")
const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const IOS_ID := 1_893_457_201

var _nodes: Array[Node] = []


func before_each() -> void:
	Settings.reset_to_defaults()


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	await tree.process_frame
	Settings.reset_to_defaults()


func _screens() -> RunScreens:
	var s := SCREENS_SCENE.instantiate() as RunScreens
	s.persist_settings = false
	tree.root.add_child(s)
	_nodes.append(s)
	s.bind(null, HudFeed.new())
	s.set_screen(SCREEN, SCREEN)
	return s


func _tap(c: Control) -> void:
	var to_window := tree.root.get_final_transform()
	var ev := InputEventScreenTouch.new()
	ev.index = IOS_ID
	ev.position = to_window * c.get_global_rect().get_center()
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()
	var up := ev.duplicate() as InputEventScreenTouch
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()


func test_audio_page_writes_volumes_and_mute() -> void:
	var s := _screens()
	Events.game_state_changed.emit(Game.RUNNING, Game.PAUSED)
	var p := s.pause_screen
	p.open_settings()
	s.finish_animations()
	var sp := p.settings
	eq(sp.page, SettingsPanel.PAGE_GAME, "opens on the game page")
	eq(sp.tabs.size(), 2)
	check(sp.tabs[0].selected and not sp.tabs[1].selected)
	for k in AudioBuses.VOLUME_KEYS:
		check(sp.row(k) != null, "row %s" % k)
		check(not sp.row(k).buttons[0].visible, "%s hidden on the game page" % k)
	check(sp.row(AudioBuses.MUTE_KEY) != null, "the SOUND row")
	check(sp.row(&"haptics").buttons[0].visible, "game rows shown")
	# The tabs sit in the header row, clear of the title and DONE.
	for tab in sp.tabs:
		var r := tab.get_global_rect()
		check(not r.intersects(p.title.get_global_rect()), "tab clear of the title")
		check(not r.intersects(p.done_button.get_global_rect()), "tab clear of DONE")
		check(SCREEN.encloses(r), "tab on screen")
	_tap(sp.tabs[1])
	eq(sp.page, SettingsPanel.PAGE_AUDIO, "AUDIO tab")
	check(not sp.row(&"haptics").buttons[0].visible, "game rows hidden")
	var steps := AudioTuning.resolve().volume_steps
	eq(sp.row(&"volume_music").buttons.size(), steps.size())
	eq(sp.row(&"volume_music").buttons[0].text, "OFF")
	eq(sp.selected_index(&"volume_music"), steps.size() - 1, "100% selected")
	_tap(sp.option(&"volume_music", 1))
	near(float(Settings.get_value(&"volume_music")), steps[1], 1e-9, "music volume written")
	eq(sp.selected_index(&"volume_music"), 1)
	_tap(sp.option(&"volume_engine", 0))
	eq(float(Settings.get_value(&"volume_engine")), 0.0, "engine off")
	_tap(sp.option(AudioBuses.MUTE_KEY, 1))
	eq(Settings.get_value(AudioBuses.MUTE_KEY), true, "muted")
	check(p.settings_dirty, "saved with the other settings")
	for k in AudioBuses.VOLUME_KEYS:
		var b := sp.row(k).buttons[0]
		check(b.visible and SCREEN.encloses(b.get_global_rect()), "%s row on screen" % k)
	_tap(sp.tabs[0])
	eq(sp.page, SettingsPanel.PAGE_GAME)
	check(sp.row(&"haptics").buttons[0].visible, "back to the game rows")


## Text fit on the AUDIO page (as tests/ui/test_text_fit.gd does for the GAME page):
## both text sizes, a plain and a notched canvas; every caption inside its button or
## label, inside the safe area, and no two texts overlapping.
func test_audio_page_text_fits() -> void:
	var probe := HudTextProbe.new()
	HudDraw.probe = probe
	var canvases: Array[Rect2] = [SCREEN, Rect2(0.0, 0.0, 1560.0, 720.0)]
	var notch := Vector4(44.0, 0.0, 44.0, 21.0)
	for full in canvases:
		var safe := full
		if full.size.x > SCREEN.size.x:
			safe = Rect2(Vector2(notch.x, notch.y), full.size - Vector2(notch.x + notch.z, notch.y + notch.w))
		for ts in Tuning.load_default().hud.text_scales:
			Settings.set_value(&"text_scale", ts)
			var s := _screens()
			s.set_screen(full, safe)
			Events.game_state_changed.emit(Game.RUNNING, Game.PAUSED)
			var p := s.pause_screen
			p.open_settings()
			p.settings.show_page(SettingsPanel.PAGE_AUDIO)
			s.finish_animations()
			_redraw(s)
			probe.clear()
			await tree.process_frame
			var what := "%dx%d text %d%%" % [full.size.x, full.size.y, roundi(ts * 100.0)]
			var ids: Array[int] = []
			for i in probe.size():
				var ci := probe.items[i]
				if is_instance_valid(ci) and ci.is_visible_in_tree() and p.is_ancestor_of(ci):
					ids.append(i)
			gt(ids.size(), 0, "%s: drawn" % what)
			for i in ids:
				var ci := probe.items[i] as Control
				var g := probe.global_rect(i)
				if ci is ScreenButton:
					check(ci.get_global_rect().grow(0.5).encloses(g), "%s: '%s' fits its button" % [what, probe.texts[i]])
				elif ci is ScreenText:
					check(Rect2(Vector2.ZERO, ci.size).grow(0.5).encloses(probe.rects[i]), "%s: '%s' fits" % [what, probe.texts[i]])
				check(safe.grow(0.5).encloses(g), "%s: '%s' inside the safe area" % [what, probe.texts[i]])
			for a in ids.size():
				for b in range(a + 1, ids.size()):
					check(not probe.global_rect(ids[a]).grow(-0.5).intersects(probe.global_rect(ids[b]).grow(-0.5)),
						"%s: '%s' overlaps '%s'" % [what, probe.texts[ids[a]], probe.texts[ids[b]]])
			_nodes.erase(s)
			s.free()
	HudDraw.probe = null


func _redraw(n: Node) -> void:
	if n is CanvasItem:
		(n as CanvasItem).queue_redraw()
	for ch in n.get_children(true):
		_redraw(ch)
