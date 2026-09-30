extends WBTest
## Text fit for the title and the online hub (WP8.5): the menu (with the widest name#tag
## in the profile chip), the settings view (both pages) and the account view, the hub with
## and without a session, at both text sizes, on a 1280x720 and a notched 1560x720 canvas.
## Same rules as tests/ui/test_text_fit.gd (docs/HUD.md → Text fit): each drawn string
## sits inside its ScreenText, inside the panel or button it is drawn in, inside the safe
## area; no two overlap, and no text runs under a button; every button stays in the safe
## area, is a touch target and overlaps no other. Spec: UI, HUD and design system
## (Accessibility: text size 100% / 125%; safe areas); UI → Screens (Title).

const CANVASES: Array[Vector2] = [Vector2(1280.0, 720.0), Vector2(1560.0, 720.0)]
const NOTCH := Vector4(44.0, 0.0, 44.0, 21.0)
const TOL := 0.5
const WIDE_NAME := "WWWWWWWWWWWWWWWW#8888"

var t: Tuning
var probe := HudTextProbe.new()
var fake: NetFakeSocial
var _nodes: Array[Node] = []


func before_all() -> void:
	t = Tuning.load_default()


func before_each() -> void:
	Settings.reset_to_defaults()
	probe.clear()
	HudDraw.probe = probe


func after_each() -> void:
	HudDraw.probe = null
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	Settings.reset_to_defaults()


func _session() -> NetSession:
	fake = NetFakeSocial.new()
	var s := NetSession.new()
	s.auto_start = false
	s.configure(fake, NetSessionStore.new(), NetTuning.load_default(), NetVirtualTime.new(1),
			"https://fit.test/api/v1", 5)
	s.unix_clock = func() -> float: return fake.now_s
	tree.root.add_child(s)
	_nodes.append(s)
	await s.start()
	s.profile.full_name = WIDE_NAME
	return s


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


func _title(c: Array) -> TitleScreens:
	Settings.set_value(&"text_scale", float(c[2]))
	var ts := TitleScreens.new()
	ts.persist_settings = false
	tree.root.add_child(ts)
	_nodes.push_front(ts)
	ts.set_screen(c[0], c[1])
	ts.show_state(Game.MENU)
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
		else:
			for b in buttons:
				check(not _overlap(g, b.get_global_rect()), "%s: %s runs under %s" % [what, _describe(i), b.name])
		check(_inside(g, safe), "%s: %s %s outside the safe area" % [what, _describe(i), g])
	for a in ids.size():
		for b in range(a + 1, ids.size()):
			if probe.items[ids[a]] == probe.items[ids[b]] and probe.rects[ids[a]] == probe.rects[ids[b]]:
				continue   # one item drawn twice in the frame, not two texts
			check(not _overlap(probe.global_rect(ids[a]), probe.global_rect(ids[b])),
					"%s: %s overlaps %s" % [what, _describe(ids[a]), _describe(ids[b])])
	for b in buttons:
		check(_inside(b.get_global_rect(), safe), "%s: %s %s outside the safe area" % [what, b.name, b.get_global_rect()])
		ge(b.size.y, t.hud.touch_target_px - TOL, "%s: %s touch target" % [what, b.name])
	for a in buttons.size():
		for b in range(a + 1, buttons.size()):
			if buttons[a].get_parent() is ProfilePanel or buttons[a].get_parent() is SettingsPanel:
				continue   # those panels' own tests cover their insides
			check(not _overlap(buttons[a].get_global_rect(), buttons[b].get_global_rect()),
					"%s: %s overlaps %s" % [what, buttons[a].name, buttons[b].name])
	return ids.size()


func test_title_menu_text_fits() -> void:
	await _session()
	for c in _configs():
		var ts := _title(c)
		var what: String = "menu %s" % c[3]
		check(ts.title.chip.shown_name().ends_with("...") or ts.title.chip.shown_name() == WIDE_NAME,
				"%s: the name shows whole or shortened" % what)
		await _capture(ts)
		gt(_check(ts.title, c[1], what), 8, "%s: the menu's texts were drawn" % what)
		_nodes.erase(ts)
		ts.free()


func test_title_settings_and_account_text_fits() -> void:
	await _session()
	for c in _configs():
		var ts := _title(c)
		var tt := ts.title
		tt.open_settings()
		ts.finish_animations()
		await _capture(ts)
		_check(tt, c[1], "settings GAME %s" % c[3])
		tt.settings.show_page(SettingsPanel.PAGE_AUDIO)
		await _capture(ts)
		_check(tt, c[1], "settings AUDIO %s" % c[3])
		tt.toggle_account()
		ts.finish_animations()
		await _capture(ts)
		_check(tt, c[1], "account %s" % c[3])
		_nodes.erase(ts)
		ts.free()


func test_online_hub_text_fits() -> void:
	for with_session: bool in [false, true]:
		if with_session:
			await _session()
		for c in _configs():
			var ts := _title(c)
			ts.open_hub()
			ts.finish_animations()
			await _capture(ts)
			var what: String = "hub %s %s" % ["online" if with_session else "no session", c[3]]
			gt(_check(ts.online_hub, c[1], what), 10, "%s: the hub's texts were drawn" % what)
			_nodes.erase(ts)
			ts.free()
