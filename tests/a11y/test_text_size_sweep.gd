extends WBTest
## Text size sweep (WP9.3). Spec: UI, HUD and design system → Accessibility ("Text size:
## an option (100% / 125%) for HUD and menus"); Safe areas. docs/ACCESSIBILITY.md → Text size.
##
## Every screen and HUD widget at both text sizes on the three canvas shapes the game
## meets in landscape (project stretch: canvas_items / expand on a 1280x720 base):
##   - 1280x720: a 16:9 phone;
##   - 1560x720: a notched 19.5:9 phone (44 px side insets, 21 px home indicator);
##   - 1280x960: a 4:3 tablet (1024x768 and 2048x1536 windows both give this canvas).
##
## The per-screen text-fit tests (tests/ui/test_*text_fit.gd, the first-run chooser, the
## settings pages, leaderboards, the achievement toast, the HUD layout and the cooling
## icon) already sweep 1280x720 and 1560x720 with their own fixtures and rules
## (docs/HUD.md → Text fit). This sweep re-runs those same methods on the tablet canvas:
## it loads each script's source, swaps its CANVASES constant for [TABLET] and runs the
## listed methods through the same lifecycle as tests/run_all.gd, forwarding every
## failure. So one table covers every screen at every size, with each screen's own
## fixture, and nothing is copied. The two screens with no text-fit test of their own
## (the first-run warm-up hint and the room HUD) are checked here at all three canvases.
##
## WP9.7 (landscape only, room for the camera cutout): every one of those methods also
## re-runs on a left-inset canvas: 1560x720 with the phone minimum on the left
## (ControlsTuning.min_left_inset_cm at the web's px per cm, about 74 px; what a phone
## gets when Safari reports no inset), nothing on the right (the right side only gets
## a reported inset) and the 21 px home indicator. Same mechanism: CANVASES becomes
## [1560x720], the NOTCH constant that inset, and its "wider than the first canvas"
## test always true. The warm-up hint and the room HUD get the same canvas.

const TABLET := Vector2(1280.0, 960.0)
const CANVASES_RE := "const CANVASES: Array\\[Vector2\\] = \\[[^\\n]*\\]"
const CANVASES_TABLET := "const CANVASES: Array[Vector2] = [Vector2(%.1f, %.1f)]"
## WP9.7: the left-inset canvas and how its re-run rewrites the per-screen tests.
const LEFT_CANVAS := Vector2(1560.0, 720.0)
const HOME_INDICATOR_PX := 21.0
const NOTCH_RE := "const NOTCH := Vector4\\([^\\n]*\\)"
const NOTCH_LEFT := "const NOTCH := Vector4(%.2f, 0.0, 0.0, %.1f)"
const WIDER_THAN_FIRST := "if size.x > CANVASES[0].x:"

## [script, methods] re-run on the tablet canvas. Only methods that loop over CANVASES.
const TEXT_FIT: Array[Array] = [
	["res://tests/ui/test_text_fit.gd", ["test_hud_text_fits_every_setting", "test_cluster_text_fits_every_state"]],
	["res://tests/ui/test_text_fit.gd", ["test_objective_chip_fits_every_label", "test_leg_toast_fits_every_setting"]],
	["res://tests/ui/test_text_fit.gd", ["test_screens_text_fits_every_setting"]],
	["res://tests/ui/test_title_text_fit.gd", ["test_title_menu_text_fits", "test_title_settings_and_account_text_fits",
			"test_online_hub_text_fits"]],
	["res://tests/ui/test_garage_text_fit.gd", ["test_garage_text_fits", "test_results_xp_panel_text_fits"]],
	["res://tests/ui/test_achievements_text_fit.gd", ["test_achievements_text_fits",
			"test_the_title_row_fits_with_achievements"]],
	["res://tests/ui/test_social_text_fit.gd", ["test_friends_text_fits_every_setting", "test_crew_text_fits_every_setting"]],
	["res://tests/ui/test_first_run.gd", ["test_chooser_text_fits"]],
	["res://tests/ui/test_settings_panel.gd", ["test_pause_settings_text_fits", "test_title_settings_text_fits"]],
	["res://tests/ui/test_leaderboards_screen.gd", ["test_text_fits_every_setting"]],
	["res://tests/ui/test_achievements_toast.gd", ["test_clear_of_thumbs_middle_and_readouts", "test_every_title_fits"]],
	["res://tests/ui/test_room_score_hud.gd", ["test_room_scoring_text_fits_beside_the_hud"]],
]


## The left inset (canvas px) on LEFT_CANVAS: the phone minimum at the web's px per cm.
static func left_inset_px() -> float:
	var c := Tuning.load_default().controls
	return ScreenInsets.min_left_px(c, PlayerInput.canvas_px_per_cm(c, LEFT_CANVAS, Vector2i.ZERO))


## The left-inset canvas's insets: left, top, right, bottom.
static func left_notch() -> Vector4:
	return Vector4(left_inset_px(), 0.0, 0.0, HOME_INDICATOR_PX)


## Loads `path` with its CANVASES constant swapped for [TABLET], or (`left`) for
## [LEFT_CANVAS] with the left-only inset.
func _variant_script(path: String, left: bool) -> GDScript:
	var src := FileAccess.get_file_as_string(path)
	var re := RegEx.create_from_string(CANVASES_RE)
	if not check(re.search(src) != null, "%s declares CANVASES" % path):
		return null
	var size := LEFT_CANVAS if left else TABLET
	src = re.sub(src, CANVASES_TABLET % [size.x, size.y])
	if left:
		var nre := RegEx.create_from_string(NOTCH_RE)
		if not check(nre.search(src) != null and src.contains(WIDER_THAN_FIRST),
				"%s declares NOTCH and insets canvases wider than the first" % path):
			return null
		src = nre.sub(src, NOTCH_LEFT % [left_inset_px(), HOME_INDICATOR_PX])
		src = src.replace(WIDER_THAN_FIRST, "if size.x > 0.0:")
	var s := GDScript.new()
	s.source_code = src
	if not eq(s.reload(), OK, "%s compiles with the %s canvas" % [path, "left-inset" if left else "tablet"]):
		return null
	return s


## Runs `methods` of `path` on the tablet canvas, or (`left`) the left-inset canvas
## (tests/run_all.gd's lifecycle).
func _rerun(path: String, methods: Array, left: bool = false) -> void:
	var s := _variant_script(path, left)
	if s == null:
		return
	# Object, as in tests/run_all.gd: the hooks may be coroutines in the subclass.
	var suite: Object = s.new()
	suite.set(&"tree", tree)
	await suite.before_all()
	for m: String in methods:
		if not check(suite.has_method(m), "%s has %s" % [path, m]):
			continue
		await suite.before_each()
		await suite.call(m)
		await suite.after_each()
		var fails: PackedStringArray = suite.call(&"_take_failures")
		for f in fails:
			fail("%s::%s @ %s: %s" % [path.get_file(), m, "%dx%d left inset" % [LEFT_CANVAS.x, LEFT_CANVAS.y]
					if left else "%dx%d" % [TABLET.x, TABLET.y], f])
		expect_errors(int(suite.call(&"_take_expected_errors")))
	await suite.after_all()


func _rerun_row(i: int, left: bool = false) -> void:
	await _rerun(TEXT_FIT[i][0], TEXT_FIT[i][1], left)


func test_tablet_hud() -> void:
	await _rerun_row(0)


func test_tablet_hud_objective_and_toast() -> void:
	await _rerun_row(1)


func test_tablet_run_screens() -> void:
	await _rerun_row(2)


func test_tablet_title_and_hub() -> void:
	await _rerun_row(3)


func test_tablet_garage_and_results_xp() -> void:
	await _rerun_row(4)


func test_tablet_achievements() -> void:
	await _rerun_row(5)


func test_tablet_friends_and_crew() -> void:
	await _rerun_row(6)


func test_tablet_first_run_chooser() -> void:
	await _rerun_row(7)


func test_tablet_settings_pages() -> void:
	await _rerun_row(8)


func test_tablet_leaderboards() -> void:
	await _rerun_row(9)


func test_tablet_achievement_toast() -> void:
	await _rerun_row(10)


func test_tablet_room_scoring_lines() -> void:
	await _rerun_row(11)


# ---------------------------------------------------------------- Left inset (WP9.7)

func test_left_inset_hud() -> void:
	await _rerun_row(0, true)


func test_left_inset_hud_objective_and_toast() -> void:
	await _rerun_row(1, true)


func test_left_inset_run_screens() -> void:
	await _rerun_row(2, true)


func test_left_inset_title_and_hub() -> void:
	await _rerun_row(3, true)


func test_left_inset_garage_and_results_xp() -> void:
	await _rerun_row(4, true)


func test_left_inset_achievements() -> void:
	await _rerun_row(5, true)


func test_left_inset_friends_and_crew() -> void:
	await _rerun_row(6, true)


func test_left_inset_first_run_chooser() -> void:
	await _rerun_row(7, true)


func test_left_inset_settings_pages() -> void:
	await _rerun_row(8, true)


func test_left_inset_leaderboards() -> void:
	await _rerun_row(9, true)


func test_left_inset_achievement_toast() -> void:
	await _rerun_row(10, true)


func test_left_inset_room_scoring_lines() -> void:
	await _rerun_row(11, true)


## Every row has a left-inset re-run (and a tablet one).
func test_every_row_is_swept_on_the_left_inset_canvas() -> void:
	var src := FileAccess.get_file_as_string(get_script().resource_path)
	for i in TEXT_FIT.size():
		check(src.contains("await _rerun_row(%d, true)" % i), "row %d (%s) has a left-inset re-run" % [i, TEXT_FIT[i][0]])
		check(src.contains("await _rerun_row(%d)\n" % i), "row %d has a tablet re-run" % i)


# ---------------------------------------------------------------- No text-fit test of their own

const CANVASES: Array[Vector2] = [Vector2(1280.0, 720.0), Vector2(1560.0, 720.0), TABLET]
## The notched canvas again with the left-only inset (WP9.7): in _configs() as a fourth.
const LEFT_INSET_CANVAS := Vector2(1560.0, 720.0)
## The notched phone's insets: left, top, right, bottom (canvas px).
const NOTCH := Vector4(44.0, 0.0, 44.0, 21.0)
const TOL := 0.5
const ROOM_FIXTURE := "res://tests/ui/test_room_hud.gd"
const WIDE_NAME := "WWWWWWWWWWWWWWWW#8888"
## Gameplay HUD panels the room HUD must stay off (the leg objective, hidden in loop mode,
## and the event stack's column, which the room toast and banner share by design, excepted).
const ROOM_CLEAR_OF: PackedStringArray = ["score", "sun", "chain", "lives", "pause", "camera", "high_beam",
		"cooling", "min_speed", "speedo", "boost"]

var probe := HudTextProbe.new()
var _nodes: Array[Node] = []


func before_each() -> void:
	Settings.restore_defaults()
	probe.clear()
	HudDraw.probe = probe


func after_each() -> void:
	HudDraw.probe = null
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	Settings.restore_defaults()


## [full, safe, text scale, label] for every canvas and text size.
func _configs() -> Array[Array]:
	var out: Array[Array] = []
	var ht := Tuning.load_default().hud
	for size in CANVASES:
		var full := Rect2(Vector2.ZERO, size)
		var safe := full
		if size.x > CANVASES[0].x:
			safe = Rect2(Vector2(NOTCH.x, NOTCH.y), size - Vector2(NOTCH.x + NOTCH.z, NOTCH.y + NOTCH.w))
		for ts in ht.text_scales:
			out.append([full, safe, ts, "%dx%d text %d%%" % [size.x, size.y, roundi(ts * 100.0)]])
	var lfull := Rect2(Vector2.ZERO, LEFT_INSET_CANVAS)
	var lsafe := ScreenInsets.safe_rect(lfull, left_notch())
	for ts in ht.text_scales:
		out.append([lfull, lsafe, ts, "%dx%d left inset text %d%%" % [LEFT_INSET_CANVAS.x, LEFT_INSET_CANVAS.y,
				roundi(ts * 100.0)]])
	return out


func _redraw(n: Node) -> void:
	if n is CanvasItem:
		(n as CanvasItem).queue_redraw()
	for ch in n.get_children(true):
		_redraw(ch)


func _capture(root: Node) -> void:
	_redraw(root)
	probe.clear()
	await tree.process_frame


static func _container(ci: CanvasItem, root: Node) -> Control:
	if ci is ScreenButton:
		return ci as Control
	var n := ci.get_parent()
	while n != null and n != root:
		if n is ScreenPanel or n is ScreenButton:
			return n as Control
		n = n.get_parent()
	return null


static func _buttons(n: Node, out: Array[ScreenButton]) -> void:
	if n is ScreenButton and (n as ScreenButton).is_visible_in_tree():
		out.append(n as ScreenButton)
	for ch in n.get_children():
		_buttons(ch, out)


## The rules of tests/ui/test_*text_fit.gd for everything drawn under `root`: each string
## inside its ScreenText, inside the panel or button it is drawn in and inside the safe
## area; no two overlap; buttons inside the safe area and touch-sized. Returns the count.
func _check(root: Node, safe: Rect2, what: String) -> int:
	var ids: Array[int] = []
	for i in probe.size():
		var ci := probe.items[i]
		if is_instance_valid(ci) and ci.is_visible_in_tree() and root.is_ancestor_of(ci):
			ids.append(i)
	for i in ids:
		var ci := probe.items[i] as Control
		var g := probe.global_rect(i)
		var desc := "'%s' (%s)" % [probe.texts[i], ci.name]
		if ci is ScreenText:
			check(Rect2(Vector2.ZERO, ci.size).grow(TOL).encloses(probe.rects[i]),
					"%s: %s %s runs out of its box %s" % [what, desc, probe.rects[i], ci.size])
		var box := _container(ci, root)
		if box != null:
			check(box.get_global_rect().grow(TOL).encloses(g), "%s: %s runs out of %s" % [what, desc, box.name])
		check(safe.grow(TOL).encloses(g), "%s: %s %s outside the safe area %s" % [what, desc, g, safe])
	for a in ids.size():
		for b in range(a + 1, ids.size()):
			if probe.items[ids[a]] == probe.items[ids[b]] and probe.rects[ids[a]] == probe.rects[ids[b]]:
				continue
			check(not probe.global_rect(ids[a]).grow(-TOL).intersects(probe.global_rect(ids[b]).grow(-TOL)),
					"%s: '%s' overlaps '%s'" % [what, probe.texts[ids[a]], probe.texts[ids[b]]])
	var buttons: Array[ScreenButton] = []
	_buttons(root, buttons)
	var ht := Tuning.load_default().hud
	for b in buttons:
		check(safe.grow(TOL).encloses(b.get_global_rect()), "%s: %s outside the safe area" % [what, b.name])
		ge(b.size.y, ht.touch_target_px - TOL, "%s: %s touch target" % [what, b.name])
	return ids.size()


func test_warmup_hint_fits_everywhere() -> void:
	var ht := Tuning.load_default().hud
	for c in _configs():
		Settings.set_value(&"text_scale", float(c[2]))
		var hint := FirstRunWarmupHint.new()
		tree.root.add_child(hint)
		_nodes.append(hint)
		hint.set_screen(c[0], c[1])
		var hl := HudLayout.new()
		hl.build(ht, c[0], c[1], null, float(c[2]))
		for ending: bool in [false, true]:
			if ending:
				hint.set_ending()
			else:
				hint.set_seconds(88)
			await _capture(hint)
			var what: String = "warm-up %s %s" % ["ending" if ending else "count", c[3]]
			ge(_check(hint, c[1], what), 2, "%s: its lines were drawn" % what)
			for r in hl.rects():
				if r.size.x > 0.0:
					check(not hint.panel_rect().grow(-TOL).intersects(r), "%s: the panel sits on a HUD panel %s" % [what, r])
		_nodes.erase(hint)
		hint.free()


func test_room_hud_fits_everywhere() -> void:
	var fx: Object = (load(ROOM_FIXTURE) as GDScript).new()
	fx.set(&"tree", tree)
	await fx.before_all()
	await fx.before_each()
	var hud: RoomHud = fx.get(&"hud")
	var ht := Tuning.load_default().hud
	var names := HudLayout.names()
	for c in _configs():
		Settings.set_value(&"text_scale", float(c[2]))   # the room HUD restyles live (WP9.3)
		hud.set_screen(c[0], c[1])
		hud.show_result({"score": 88_888_888, "distance_m": 888_888, "duration_ms": 5_999_000,
				"flags": {"verified": false}})
		hud.set_crew(7, 8.88)
		hud.show_train(99)
		for i in 3:
			hud.add_feed(WIDE_NAME, "NICE PASS!", Color.WHITE)
		hud.show_notice("RECONNECTING  ·  88 S")
		hud.advance(0.0)
		await _capture(hud)
		var what: String = "room HUD %s" % c[3]
		ge(_check(hud, c[1], what), 8, "%s: its texts were drawn" % what)
		check(hud.crew_line.is_visible_in_tree() and hud.train_badge.is_visible_in_tree(),
				"%s: the crew line and TRAIN badge show" % what)
		var hl := HudLayout.new()
		hl.build(ht, c[0], c[1], null, float(c[2]))
		var rects := hl.rects()
		for k in rects.size():
			if not ROOM_CLEAR_OF.has(names[k]) or rects[k].size.x <= 0.0:
				continue
			for ctl: Control in [hud.room_button, hud.rejoin_button, hud.line, hud.crew_line, hud.train_badge,
					hud.feed[0], hud.strip]:
				check(not ctl.get_global_rect().grow(-TOL).intersects(rects[k]),
						"%s: %s sits on the HUD's %s" % [what, ctl.name, names[k]])
		hud.menu.open()
		await _capture(hud.menu)
		_check(hud.menu, c[1], "room menu %s" % c[3])
		hud.menu.close()
	var fails: PackedStringArray = fx.call(&"_take_failures")
	for f in fails:
		fail("room fixture: %s" % f)
	await fx.after_each()
