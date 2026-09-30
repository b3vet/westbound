extends WBTest
## WP8.3: text fit for the achievements screen: every tab, all locked (hidden ones
## hidden), all unlocked (every name shown) and the widest progress lines, at both text
## sizes (100% / 125%), on a 1280x720 and a notched 1560x720 canvas, in km/h and mph. Same
## rules as the garage's and the title's text-fit tests: each drawn string inside its
## ScreenText, inside its card or button, inside the safe area; no two overlap; no text
## under a button; buttons are touch targets in the safe area; and every card's title and
## line are shown whole (never cut with …). Cards stay inside the safe area and apart.
## Spec: Accessibility (text size, safe areas); UI → Screens. docs/ACHIEVEMENTS.md → Screen.

const CANVASES: Array[Vector2] = [Vector2(1280.0, 720.0), Vector2(1560.0, 720.0)]
const NOTCH := Vector4(44.0, 0.0, 44.0, 21.0)
const TOL := 0.5

var t: Tuning
var cat: AchievementCatalog
var probe := HudTextProbe.new()
var _nodes: Array[Node] = []
var _saved: Dictionary


func before_all() -> void:
	t = Tuning.load_default()
	cat = AchievementCatalog.load_path(AchievementTuning.load_default().catalog_path)


func before_each() -> void:
	Settings.reset_to_defaults()
	_saved = Save.data.duplicate(true)
	for k: String in [AchievementService.SECTION, Garage.SECTION_STATS, Garage.SECTION_UNLOCKS, Garage.SECTION_GARAGE]:
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


## The save for a state: "locked" (fresh), "progress" (the widest numbers short of each
## goal), "unlocked" (every one).
func _state(state: String) -> void:
	var sec := Save.section(AchievementService.SECTION)
	sec.clear()
	var stats := Save.section(Garage.SECTION_STATS)
	stats[MetaProfile.XP] = 0
	if state == "unlocked":
		var u := {}
		for a in cat.achievements:
			u[String(a.id)] = 20300.0
		sec[AchievementTracker.KEY_UNLOCKED] = u
	elif state == "progress":
		var p := {}
		for a in cat.achievements:
			var th := AchievementCatalog.internal_threshold(a)
			p[String(a.metric)] = maxf(float(p.get(String(a.metric), 0.0)), th * 0.999)
		sec[AchievementTracker.KEY_PROGRESS] = p
		stats[MetaProfile.XP] = Progression.xp_to_reach(9, t.progression)


func _screen(c: Array, units: StringName) -> TitleScreens:
	Settings.set_value(&"text_scale", float(c[2]))
	Settings.set_value(&"units", units)
	var ts := TitleScreens.new()
	ts.persist_settings = false
	tree.root.add_child(ts)
	_nodes.push_front(ts)
	ts.set_screen(c[0], c[1])
	ts.show_state(Game.MENU)
	ts.open_achievements()
	ts.finish_animations()
	return ts


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


func _check(screen: AchievementsScreen, safe: Rect2, what: String) -> int:
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
	var cards: Array[AchievementsCard] = []
	for c in screen.cards:
		if c.visible:
			cards.append(c)
	for c in cards:
		var r := c.get_global_rect()
		check(_inside(r, safe), "%s: card %s %s inside the safe area" % [what, c.def.id, r])
		check(c.texts_whole(), "%s: card %s shows '%s' / '%s' whole" % [what, c.def.id, c.title_text.text, c.desc_text.text])
		ge(c.size.y, c.desired_height() - TOL, "%s: card %s tall enough for its text" % [what, c.def.id])
		for b in buttons:
			check(not _overlap(r, b.get_global_rect()), "%s: card %s under %s" % [what, c.def.id, b.name])
	for a in cards.size():
		for b in range(a + 1, cards.size()):
			check(not _overlap(cards[a].get_global_rect(), cards[b].get_global_rect()),
					"%s: cards %s and %s overlap" % [what, cards[a].def.id, cards[b].def.id])
	return ids.size()


func test_achievements_text_fits() -> void:
	for c in _configs():
		for units: StringName in [&"kmh", &"mph"]:
			for state: String in ["locked", "progress", "unlocked"]:
				if units == &"mph" and state != "progress":
					continue
				_state(state)
				var ts := _screen(c, units)
				var a := ts.achievements
				for tab in cat.groups.size():
					a.show_tab(tab)
					var what: String = "%s %s %s tab %d" % [c[3], units, state, tab]
					await _capture(ts)
					gt(_check(a, c[1], what), 10, "%s: texts drawn" % what)
				_nodes.erase(ts)
				ts.free()


func test_the_title_row_fits_with_achievements() -> void:
	for c in _configs():
		Settings.set_value(&"text_scale", float(c[2]))
		var ts := TitleScreens.new()
		ts.persist_settings = false
		tree.root.add_child(ts)
		_nodes.push_front(ts)
		ts.set_screen(c[0], c[1])
		ts.show_state(Game.MENU)
		ts.finish_animations()
		var row: Array[ScreenButton] = [ts.title.boards_button, ts.title.settings_button, ts.title.garage_button,
				ts.title.achievements_button]
		for i in row.size():
			check(_inside(row[i].get_global_rect(), c[1]), "%s: %s in the safe area" % [c[3], row[i].name])
			ge(row[i].size.x, SocialUi.button_width(row[i], t.hud) - TOL, "%s: %s wide enough for its label" % [c[3], row[i].name])
			if i > 0:
				check(not _overlap(row[i - 1].get_global_rect(), row[i].get_global_rect()), "%s: the row's buttons apart" % c[3])
		_nodes.erase(ts)
		ts.free()
