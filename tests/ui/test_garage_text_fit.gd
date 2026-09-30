extends WBTest
## WP8.2: text fit for the garage (every tab, locked and unlocked items, the previews, a
## placeholder's line, max level) and the results' XP panel (a level-up with a long list of
## unlocks, the XP to the next level, max level), at both text sizes (100% / 125%), on a
## 1280x720 and a notched 1560x720 canvas, both hands for the results. Same rules as
## tests/ui/test_title_text_fit.gd: each drawn string sits inside its ScreenText, inside
## its panel or button, inside the safe area; no two overlap and no text runs under a
## button; buttons stay in the safe area, are touch targets and overlap no other. A paint
## chip never covers its name. Spec: Accessibility (text size, safe areas); UI → Screens.

const CANVASES: Array[Vector2] = [Vector2(1280.0, 720.0), Vector2(1560.0, 720.0)]
const NOTCH := Vector4(44.0, 0.0, 44.0, 21.0)
const TOL := 0.5

var t: Tuning
var cat: GarageCatalog
var probe := HudTextProbe.new()
var _nodes: Array[Node] = []
var _saved: Dictionary


func before_all() -> void:
	t = Tuning.load_default()
	cat = Garage.catalog()


func before_each() -> void:
	Settings.reset_to_defaults()
	_saved = Save.data.duplicate(true)
	for k: String in [Garage.SECTION_STATS, Garage.SECTION_UNLOCKS, Garage.SECTION_GARAGE]:
		Save.data.erase(k)
	Save.section(Garage.SECTION_STATS)[MetaProfile.BACKFILLED] = true
	probe.clear()
	HudDraw.probe = probe


func after_each() -> void:
	HudDraw.probe = null
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	Save.data = _saved
	Save.dirty = false
	Settings.reset_to_defaults()


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


func _garage(c: Array) -> TitleScreens:
	Settings.set_value(&"text_scale", float(c[2]))
	var ts := TitleScreens.new()
	ts.persist_settings = false
	tree.root.add_child(ts)
	_nodes.push_front(ts)
	ts.set_screen(c[0], c[1])
	ts.show_state(Game.MENU)
	ts.open_garage()
	ts.finish_animations()
	return ts


func _set_xp(xp: int) -> void:
	var p := Garage.profile()
	p.stats[MetaProfile.XP] = xp
	p.refresh_unlocks()


func _redraw(n: Node) -> void:
	if n is CanvasItem:
		(n as CanvasItem).queue_redraw()
	for ch in n.get_children(true):
		_redraw(ch)


func _capture(root: Node) -> void:
	_redraw(root)
	probe.clear()
	await tree.process_frame


func _visible(root: Node) -> Array[int]:
	var out: Array[int] = []
	for i in probe.size():
		var ci := probe.items[i]
		if is_instance_valid(ci) and ci.is_visible_in_tree() and root.is_ancestor_of(ci):
			out.append(i)
	return out


func _describe(i: int) -> String:
	return "'%s' (%s)" % [probe.texts[i], probe.items[i].name]


static func _inside(inner: Rect2, outer: Rect2) -> bool:
	return outer.grow(TOL).encloses(inner)


static func _overlap(a: Rect2, b: Rect2) -> bool:
	return a.grow(-TOL).intersects(b.grow(-TOL))


static func _container(ci: CanvasItem) -> Control:
	if ci is ScreenButton:
		return ci as Control
	var n := ci.get_parent()
	while n != null and not (n is RunScreen):
		if n is ScreenPanel or n is ScreenButton:
			return n as Control
		n = n.get_parent()
	return null


static func _buttons(n: Node, out: Array[ScreenButton]) -> void:
	if n is ScreenButton and (n as ScreenButton).is_visible_in_tree():
		out.append(n as ScreenButton)
	for ch in n.get_children():
		_buttons(ch, out)


## Checks one screen's drawn text and buttons. Returns how many strings it checked.
func _check(screen: RunScreen, safe: Rect2, what: String) -> int:
	var ids := _visible(screen)
	var buttons: Array[ScreenButton] = []
	_buttons(screen, buttons)
	for i in ids:
		var ci := probe.items[i] as Control
		var g := probe.global_rect(i)
		if ci is ScreenText:
			check(_inside(probe.rects[i], Rect2(Vector2.ZERO, ci.size)),
					"%s: %s %s runs out of its box %s" % [what, _describe(i), probe.rects[i], ci.size])
		var box := _container(ci)
		if box != null:
			check(_inside(g, box.get_global_rect()),
					"%s: %s %s runs out of %s %s" % [what, _describe(i), g, box.name, box.get_global_rect()])
			if box is GarageItemButton and (box as GarageItemButton).has_swatch:
				var gb := box as GarageItemButton
				var chip := gb.swatch_rect()
				chip.position += gb.get_global_rect().position
				check(not _overlap(g, chip), "%s: the chip covers %s" % [what, _describe(i)])
		else:
			for b in buttons:
				check(not _overlap(g, b.get_global_rect()), "%s: %s runs under %s" % [what, _describe(i), b.name])
		check(_inside(g, safe), "%s: %s %s outside the safe area" % [what, _describe(i), g])
	for a in ids.size():
		for b in range(a + 1, ids.size()):
			if probe.items[ids[a]] == probe.items[ids[b]] and probe.rects[ids[a]] == probe.rects[ids[b]]:
				continue
			check(not _overlap(probe.global_rect(ids[a]), probe.global_rect(ids[b])),
					"%s: %s overlaps %s" % [what, _describe(ids[a]), _describe(ids[b])])
	for b in buttons:
		check(_inside(b.get_global_rect(), safe), "%s: %s %s outside the safe area" % [what, b.name, b.get_global_rect()])
		ge(b.size.y, t.hud.touch_target_px - TOL, "%s: %s touch target" % [what, b.name])
	for a in buttons.size():
		for b in range(a + 1, buttons.size()):
			check(not _overlap(buttons[a].get_global_rect(), buttons[b].get_global_rect()),
					"%s: %s overlaps %s" % [what, buttons[a].name, buttons[b].name])
	return ids.size()


func _slot_of(kind: StringName) -> GarageSlot:
	for s in cat.slots:
		if s.unlock == kind:
			return s
	return null


func test_garage_text_fits() -> void:
	for c in _configs():
		for xp: int in [0, Progression.xp_to_reach(t.progression.max_level, t.progression) + 123_456_789]:
			_set_xp(xp)
			var ts := _garage(c)
			var g := ts.garage
			var what: String = "%s xp %d" % [c[3], xp]
			await _capture(ts)
			gt(_check(g, c[1], "CAR %s" % what), 8, "%s: the garage's texts were drawn" % what)
			for kind: StringName in [GarageSlot.UNLOCK_DAILY_STREAK, GarageSlot.UNLOCK_THREADS, GarageSlot.UNLOCK_LEG]:
				g.pick(_slot_of(kind).id)
				await _capture(ts)
				_check(g, c[1], "CAR preview %s %s" % [kind, what])
			g.show_tab(GarageScreen.Tab.PAINT)
			g.pick(cat.paints[cat.paints.size() - 1].id)
			await _capture(ts)
			_check(g, c[1], "PAINT %s" % what)
			g.show_tab(GarageScreen.Tab.RIMS)
			g.pick(cat.rims[cat.rims.size() - 1].id)
			await _capture(ts)
			_check(g, c[1], "RIMS %s" % what)
			_nodes.erase(ts)
			ts.free()


func _screens(c: Array, hand_left: bool) -> RunScreens:
	Settings.set_value(&"text_scale", float(c[2]))
	Settings.set_value(&"left_handed", hand_left)
	var s := (load("res://src/ui/screens/run_screens.tscn") as PackedScene).instantiate() as RunScreens
	s.persist_settings = false
	tree.root.add_child(s)
	_nodes.push_front(s)
	s.bind(null, HudFeed.new())
	s.set_screen(c[0], c[1])
	return s


func _payload(level_before: int, level: int, unlocked: Array[String]) -> Dictionary:
	return {
		RunStats.SCORE: 88_888_888, RunStats.DISTANCE_M: 888_800.0, RunStats.LEGS_COMPLETED: 88,
		RunStats.COAST_REACHED: false, RunStats.BEST_CHAIN: 8_888_888, RunStats.BEST_MULTIPLIER: 888.8,
		RunStats.THREADS: 888, RunStats.CLOSE_PASSES: 8888, RunStats.TOP_SPEED_KMH: 388.0,
		RunStats.NIGHT_TIME_S: 5999.0, RunStats.HITS: 88, RunStats.MODE: &"journey",
		&"personal_best": 99_999_999, &"new_best": false, &"previous_best": 99_999_999,
		MetaProfile.R_XP_GAINED: 88_888_888, MetaProfile.R_XP_TOTAL: Progression.xp_to_reach(level, t.progression) + 1,
		MetaProfile.R_LEVEL_BEFORE: level_before, MetaProfile.R_LEVEL: level, MetaProfile.R_UNLOCKED: unlocked,
	}


func test_results_xp_panel_text_fits() -> void:
	var all: Array[String] = []
	for id in cat.unlock_ids():
		all.append(id)
	var few: Array[String] = [all[1]]
	var cases := [
		["level up + every unlock", _payload(1, t.progression.max_level, all)],
		["level up + one unlock", _payload(1, 2, few)],
		["no level up", _payload(3, 3, [] as Array[String])],
		["max level", _payload(t.progression.max_level, t.progression.max_level, [] as Array[String])],
	]
	for c in _configs():
		for left: bool in [false, true]:
			var s := _screens(c, left)
			for k: Array in cases:
				s.show_state(Game.RESULTS, Game.CRASH)
				s.show_results(k[1])
				s.finish_animations()
				var rs := s.results_screen
				check(rs.xp_panel.visible, "the XP panel shows")
				await _capture(s)
				var what: String = "%s %s %s" % [c[3], "left" if left else "right", k[0]]
				_check(rs, c[1], "results %s" % what)
				check(not _overlap(rs.xp_panel.get_global_rect(), rs.retry_button.get_global_rect()), "%s: clear of RETRY" % what)
				check(not _overlap(rs.xp_panel.get_global_rect(), rs.garage_button.get_global_rect()), "%s: clear of GARAGE" % what)
			_nodes.erase(s)
			s.free()
