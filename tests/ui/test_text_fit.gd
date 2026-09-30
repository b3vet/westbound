extends WBTest
## Text fit (WP5.6): no text the HUD or the in-run screens draw runs out of its widget or
## into another text. Spec: UI, HUD and design system (Accessibility: text size 100% /
## 125%; units km/h or mph; left-handed mirroring; safe areas). docs/HUD.md → Text fit.
##
## Every string drawn through HudDraw is recorded (HudDraw.probe) with its box: the
## advance width, from the baseline up one cap height. The sweep covers both text sizes,
## both units, both hands, and a 1280x720 and a notched 1560x720 canvas. For each
## visible text:
##   - HUD: the box sits inside its widget; no two boxes overlap.
##   - Screens: the box sits inside its own ScreenText, inside the panel or button it is
##     drawn in, and inside the safe area; no two boxes overlap, and a text outside a
##     button never runs under one.

const HUD_SCENE := preload("res://src/ui/hud/hud.tscn")
const SCREENS_SCENE := preload("res://src/ui/screens/run_screens.tscn")
const DT := 1.0 / 60.0
const CANVASES: Array[Vector2] = [Vector2(1280.0, 720.0), Vector2(1560.0, 720.0)]
## The 1560 canvas is a notched phone: left, top, right, bottom insets (canvas px).
const NOTCH := Vector4(44.0, 0.0, 44.0, 21.0)
## Sub-pixel slack: glyph advances are fractional.
const TOL := 0.5
## Long enough for the stack's lines to settle into their rows (event_slide_s), short
## of their hold.
const SETTLE_S := 0.4

var t: Tuning
var probe := HudTextProbe.new()
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


## Every sweep configuration: [canvas, safe, text scale, miles, left-handed, label].
func _configs() -> Array[Array]:
	var out: Array[Array] = []
	for size in CANVASES:
		var full := Rect2(Vector2.ZERO, size)
		var safe := full
		if size.x > CANVASES[0].x:
			safe = Rect2(Vector2(NOTCH.x, NOTCH.y), size - Vector2(NOTCH.x + NOTCH.z, NOTCH.y + NOTCH.w))
		for ts in t.hud.text_scales:
			for miles: bool in [false, true]:
				for left: bool in [false, true]:
					out.append([full, safe, ts, miles, left, "%dx%d text %d%% %s %s" % [size.x, size.y,
							roundi(ts * 100.0), "mph" if miles else "km/h", "left" if left else "right"]])
	return out


func _apply_settings(c: Array) -> void:
	Settings.set_value(&"text_scale", float(c[2]))
	Settings.set_value(&"units", &"mph" if bool(c[3]) else &"kmh")
	Settings.set_value(&"left_handed", bool(c[4]))
	Settings.set_value(&"throttle_mode", PlayerInput.MANUAL)


func _redraw(n: Node) -> void:
	if n is CanvasItem:
		(n as CanvasItem).queue_redraw()
	for ch in n.get_children(true):
		_redraw(ch)


## Redraws everything under `root` and records what it draws.
func _capture(root: Node) -> void:
	_redraw(root)
	probe.clear()
	await tree.process_frame


## The records drawn by visible canvas items under `root`.
func _visible(root: Node) -> Array[int]:
	var out: Array[int] = []
	for i in probe.size():
		var ci := probe.items[i]
		if is_instance_valid(ci) and ci.is_visible_in_tree() and root.is_ancestor_of(ci):
			out.append(i)
	return out


## `text` was drawn by a visible canvas item under `root`.
func _drawn(root: Node, text: String) -> bool:
	for i in _visible(root):
		if probe.texts[i] == text:
			return true
	return false


func _describe(i: int) -> String:
	return "'%s' (%s)" % [probe.texts[i], probe.items[i].name]


static func _inside(inner: Rect2, outer: Rect2) -> bool:
	return outer.grow(TOL).encloses(inner)


static func _overlap(a: Rect2, b: Rect2) -> bool:
	return a.grow(-TOL).intersects(b.grow(-TOL))


# ---------------------------------------------------------------- HUD

func _hud(c: Array) -> Hud:
	_apply_settings(c)
	var hud := HUD_SCENE.instantiate() as Hud
	hud.auto_process = false
	hud.set_screen(c[0], c[1])
	tree.root.add_child(hud)
	_nodes.append(hud)
	return hud


func _free_nodes() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()


func _advance(hud: Hud, seconds: float) -> void:
	for i in ceili(seconds / DT):
		hud.advance(DT)


## A long-number, everything-showing state.
func _busy_feed() -> HudFeed:
	var f := HudFeed.new()
	f.top_speed_mps = Units.kmh_to_mps(270.0)
	f.min_speed_mps = t.scoring.min_speed_mps()
	f.speed_mps = Units.kmh_to_mps(60.0)
	f.too_slow = true
	f.boost_fill = 0.35
	f.sun_height = 0.4
	f.checkpoint_distance_m = 3480.0
	f.leg_index = 8
	f.lives = 1
	f.ghost = true
	f.banked = 88_888_888
	f.best = 99_999_999
	f.chain = 8_888_888
	f.multiplier = 888.8
	return f


## The bank fly-in and the glitter are transients that fly across the others.
static func _transient(ci: CanvasItem) -> bool:
	return ci is HudFlyer or ci is HudGlitter


func _check_hud(hud: Hud, what: String) -> int:
	var ids: Array[int] = []
	for i in _visible(hud):
		if not _transient(probe.items[i]):
			ids.append(i)
	for i in ids:
		var ci := probe.items[i] as Control
		if ci == null:
			continue
		check(_inside(probe.rects[i], Rect2(Vector2.ZERO, ci.size)),
				"%s: %s %s runs out of its widget %s" % [what, _describe(i), probe.rects[i], ci.size])
	for a in ids.size():
		for b in range(a + 1, ids.size()):
			var i := ids[a]
			var j := ids[b]
			check(not _overlap(probe.global_rect(i), probe.global_rect(j)),
					"%s: %s overlaps %s" % [what, _describe(i), _describe(j)])
	return ids.size()


func test_hud_text_fits_every_setting() -> void:
	var n := 0
	for c in _configs():
		var hud := _hud(c)
		var f := _busy_feed()
		f.objective = LegObjectives.SLIPSTREAM
		f.objective_target = LegObjectives.target_of(f.objective, t.legs)
		hud.bind(f)
		Events.gear_shifted.emit(6)
		Events.chain_lost.emit(888_888, Events.REASON_HIT)
		Events.bonus_awarded.emit(LegTracker.BONUS_THREADS, 88_888, 0)
		Events.checkpoint_warning.emit(1000.0)
		Events.scored.emit(Events.THREAD, 88_888, 888.8, 0.2)
		_advance(hud, SETTLE_S)
		gt(hud.event_line_count(), 3, "the stack is full")
		await _capture(hud)
		n += _check_hud(hud, c[5])
		# A six-digit chain keeps its CHAIN label (the row spans the sun bar here).
		f.chain = 999_999
		hud.advance(DT)
		await _capture(hud)
		_check_hud(hud, "%s chain 999,999" % c[5])
		check(_drawn(hud, HudChain.LABEL_CHAIN), "%s: CHAIN shows beside 999,999" % c[5])
		_free_nodes()
	gt(n, 0, "texts were recorded")


## Plan D14: the compact bottom-centre cluster in each of its states (three-digit
## speed with the gear, READY, BOOSTING, a percentage, TOO SLOW), in every setting.
func test_cluster_text_fits_every_state() -> void:
	var fills: Array[float] = [1.0, 1.0, 0.88, 0.35]
	var words: Array[String] = [HudBoost.LABEL_READY, HudBoost.LABEL_BOOSTING, "88%", "35%"]
	var n := 0
	for c in _configs():
		var hud := _hud(c)
		var f := _busy_feed()
		hud.bind(f)
		Events.gear_shifted.emit(6)
		for st in fills.size():
			f.too_slow = st == 3
			f.speed_mps = Units.kmh_to_mps(60.0 if f.too_slow else 888.0)
			f.boost_fill = fills[st]
			f.boosting = st == 1
			hud.advance(DT)
			await _capture(hud)
			var what := "%s cluster state %d" % [c[5], st]
			n += _check_hud(hud, what)
			check(_drawn(hud, words[st]), "%s: %s shows" % [what, words[st]])
			check(_drawn(hud, hud.speed_text()), "%s: the speed shows" % what)
		_free_nodes()
	gt(n, 0, "texts were recorded")


## Every objective label (both units) in every state, in every setting: the chip grows
## to fit its text and progress, and the text stays at full size.
func test_objective_chip_fits_every_label() -> void:
	var n := 0
	var ids := LegObjectives.catalog()
	for c in _configs():
		var huds: Array[Hud] = []
		var feeds: Array[HudFeed] = []
		for id in ids:
			var hud := _hud(c)
			var f := _busy_feed()
			f.objective = id
			f.objective_target = LegObjectives.target_of(id, t.legs)
			hud.bind(f)
			huds.append(hud)
			feeds.append(f)
		for st in 3:   # pending, done, failed ("no X" only)
			for k in ids.size():
				var f := feeds[k]
				f.objective_progress = f.objective_target if st == 1 else 0
				f.objective_done = st == 1
				f.objective_failed = st == 2 and LegObjectives.completes_at_checkpoint(ids[k])
				huds[k].advance(DT)
				_advance(huds[k], t.hud.objective_pop_s)
			await _capture(tree.root)
			for k in ids.size():
				var what := "%s %s %s" % [c[5], ids[k], ["pending", "done", "failed"][st]]
				check(huds[k].objective_visible(), what)
				check(huds[k].objective_text_fits(), "%s: the text is at full size" % what)
				var r := huds[k].objective_rect()
				le(r.size.x, t.hud.objective_chip_max_width_px * float(c[2]) + TOL, "%s: at most the max width" % what)
				check(huds[k].layout.objective.encloses(r), "%s: inside its slot" % what)
				n += _check_hud(huds[k], what)
		_free_nodes()
	gt(n, 0)


## The toast at the worst case (night, every leg bonus, the objective, the life) with
## every objective as the next one: it fits, and its footer names the biome.
func test_leg_toast_fits_every_setting() -> void:
	var n := 0
	for c in _configs():
		var hud := _hud(c)
		hud.bind(_busy_feed())
		hud.advance(DT)
		for id in LegObjectives.catalog():
			var summary := {
				RunEvents.SUMMARY_LEG_INDEX: 7, RunEvents.SUMMARY_CLEAN: true, RunEvents.SUMMARY_AT_NIGHT: true,
				RunEvents.SUMMARY_OBJECTIVE_DONE: true, RunEvents.SUMMARY_OBJECTIVE_POINTS: 88_888,
			}
			Events.checkpoint_crossed.emit(7, summary)
			Events.leg_started.emit(8, &"farmland", id)
			Events.chain_banked.emit(8_888_888, Events.REASON_CHECKPOINT, 0)
			for kind: StringName in [LegTracker.BONUS_CLEAN, LegTracker.BONUS_PACE, LegTracker.BONUS_THREADS,
					LegTracker.BONUS_HEAT]:
				Events.bonus_awarded.emit(kind, 88_888, 0)
			Events.life_restored.emit(2)
			_advance(hud, SETTLE_S)
			await _capture(hud)
			var what := "%s toast %s" % [c[5], id]
			check(hud.toast_visible(), what)
			eq(hud.toast_footer()[0], "LEG 8 — FARMLAND PLAINS", "%s names the biome" % what)
			check(_drawn(hud, "LEG 8 — FARMLAND PLAINS"), "%s: the biome is drawn" % what)
			eq(hud.toast_items_shown(), 7, "%s: every item fits" % what)
			n += _check_hud(hud, what)
			_advance(hud, t.hud.leg_toast_s)
		_free_nodes()
	gt(n, 0)


# ---------------------------------------------------------------- Screens

func _screens(c: Array, feed: HudFeed) -> RunScreens:
	_apply_settings(c)
	var s := SCREENS_SCENE.instantiate() as RunScreens
	s.persist_settings = false
	tree.root.add_child(s)
	_nodes.append(s)
	s.bind(null, feed)
	s.set_screen(c[0], c[1])
	return s


## The panel or button a screen text sits in (null = on the screen itself).
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


func _check_screen(screen: RunScreen, safe: Rect2, what: String) -> int:
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
			var i := ids[a]
			var j := ids[b]
			check(not _overlap(probe.global_rect(i), probe.global_rect(j)),
					"%s: %s overlaps %s" % [what, _describe(i), _describe(j)])
	return ids.size()


func _results_payload() -> Dictionary:
	return {
		RunStats.SCORE: 88_888_888,
		RunStats.DISTANCE_M: 888_800.0,
		RunStats.LEGS_COMPLETED: 88,
		RunStats.COAST_REACHED: false,
		RunStats.BEST_CHAIN: 8_888_888,
		RunStats.BEST_MULTIPLIER: 888.8,
		RunStats.THREADS: 888,
		RunStats.CLOSE_PASSES: 8888,
		RunStats.TOP_SPEED_KMH: 388.0,
		RunStats.NIGHT_TIME_S: 5999.0,
		RunStats.HITS: 88,
		&"personal_best": 99_999_999,
		&"new_best": false,
		&"previous_best": 99_999_999,
	}


func test_screens_text_fits_every_setting() -> void:
	var n := 0
	for c in _configs():
		var f := HudFeed.new()
		f.leg_index = 8
		f.objective = LegObjectives.SLIPSTREAM
		f.distance_m = 888_800.0
		f.banked = 88_888_888
		var s := _screens(c, f)
		var safe: Rect2 = c[1]
		# Countdown: the leg line, its biome and objective, and the gyro card.
		Events.run_started.emit(&"journey", 1)
		Events.leg_started.emit(8, &"farmland", LegObjectives.SLIPSTREAM)
		s.countdown.set_gyro(true)
		s.countdown.show_step(3)
		s.finish_animations()
		s.countdown.freeze()
		await _capture(s)
		n += _check_screen(s.countdown, safe, "%s countdown" % c[5])
		gt(s.countdown.hud_rects.size(), 0, "the countdown knows the HUD's panels")
		for info in s.countdown.info_rects():
			for r in s.countdown.hud_rects:
				check(not info.intersects(r), "%s countdown: its info %s runs into a HUD panel %s" % [c[5], info, r])
		eq(s.countdown.leg_lines(), PackedStringArray(["LEG 8 OF 8", "FARMLAND PLAINS",
				LegObjectives.label(LegObjectives.SLIPSTREAM, t.legs, bool(c[3]))]), "%s countdown leg chip" % c[5])
		# The web motion-permission tap card.
		s.countdown.set_hold(true)
		s.finish_animations()
		await _capture(s)
		n += _check_screen(s.countdown, safe, "%s tap to enable" % c[5])
		s.countdown.set_hold(false)
		s.countdown.set_gyro(false)
		# Pause, with RECALIBRATE, then its settings.
		s.show_state(Game.PAUSED, Game.RUNNING)
		s.pause_screen.set_gyro(true)
		s.pause_screen.open()   # as if the hub steered by tilt (show_state reads it first)
		s.finish_animations()
		await _capture(s)
		n += _check_screen(s.pause_screen, safe, "%s pause" % c[5])
		s.pause_screen.open_settings()
		s.finish_animations()
		await _capture(s)
		n += _check_screen(s.pause_screen, safe, "%s settings" % c[5])
		s.pause_screen.close_settings()
		# Crash hint.
		s.show_state(Game.CRASH, Game.RUNNING)
		s.crash_screen.show_hint_now()
		await _capture(s)
		n += _check_screen(s.crash_screen, safe, "%s crash" % c[5])
		# Results: no record, then a new best.
		s.show_state(Game.RESULTS, Game.CRASH)
		var res := _results_payload()
		s.show_results(res)
		s.finish_animations()
		await _capture(s)
		n += _check_screen(s.results_screen, safe, "%s results" % c[5])
		res[&"new_best"] = true
		res[&"previous_best"] = 1_000
		res[RunStats.COAST_REACHED] = true
		s.show_results(res)
		s.finish_animations()
		await _capture(s)
		n += _check_screen(s.results_screen, safe, "%s results best" % c[5])
		_free_nodes()
	gt(n, 0)
