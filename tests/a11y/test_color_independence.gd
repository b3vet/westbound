extends WBTest
## Color independence (WP9.3). Spec: UI, HUD and design system → Accessibility ("event
## messages never rely on color alone; every event has its own word and sound").
## docs/ACCESSIBILITY.md → Color independence (the audit table).
##
## - Every HUD state whose color changes also says it in words or shape: TOO SLOW,
##   BOOSTING / READY, GHOST, FAILED / a tick, the event words (one per event).
## - Traffic: a blinker flashes (a temporal channel) and brake lights hold steady, so
##   amber vs red is never the only difference.
## - Rooms: crew colors a color-blind player confuses never share a loop-strip dot shape.
## - Drag braking: the thumb gets a hot ring as well as a hot dot.
## - The dev color-blindness filter (CvdFilter) behaves: greys stay grey, the image
##   pass matches the per-color one.

const HUD_SCENE := preload("res://src/ui/hud/hud.tscn")
const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const DT := 1.0 / 60.0
## CIE76 ΔE below which two colors read as the same (a generous "confusable").
const CONFUSABLE_DE := 25.0
const DICHROMACIES: Array[StringName] = [CvdFilter.PROTAN, CvdFilter.DEUTAN, CvdFilter.TRITAN]
const PX_PER_CM := 40.0
const IOS_ID := 1_893_457_201

var t: Tuning
var probe := HudTextProbe.new()
var _nodes: Array[Node] = []


func before_all() -> void:
	t = Tuning.load_default()


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


func _add(n: Node) -> Node:
	tree.root.add_child(n)
	_nodes.append(n)
	return n


# ---------------------------------------------------------------- HUD words

func _hud(f: HudFeed) -> Hud:
	var hud := HUD_SCENE.instantiate() as Hud
	hud.auto_process = false
	hud.set_screen(SCREEN, SCREEN)
	_add(hud)
	hud.bind(f)
	hud.advance(DT)
	return hud


func _feed() -> HudFeed:
	var f := HudFeed.new()
	f.top_speed_mps = Units.kmh_to_mps(270.0)
	f.min_speed_mps = t.scoring.min_speed_mps()
	f.speed_mps = Units.kmh_to_mps(180.0)
	f.sun_height = 0.6
	return f


func _redraw(n: Node) -> void:
	if n is CanvasItem:
		(n as CanvasItem).queue_redraw()
	for ch in n.get_children(true):
		_redraw(ch)


## The strings the HUD draws now.
func _drawn(hud: Hud) -> PackedStringArray:
	_redraw(hud)
	probe.clear()
	await tree.process_frame
	var out := PackedStringArray()
	for i in probe.size():
		var ci := probe.items[i]
		if is_instance_valid(ci) and ci.is_visible_in_tree():
			out.append(probe.texts[i])
	return out


func test_hud_states_say_it_in_words() -> void:
	var f := _feed()
	f.speed_mps = Units.kmh_to_mps(60.0)
	f.too_slow = true
	f.lives = 1
	f.ghost = true
	f.boost_fill = 1.0
	f.leg_index = 2
	f.objective = LegObjectives.NO_BRAKING
	f.objective_failed = true
	var hud := _hud(f)
	var words := await _drawn(hud)
	for w: String in [HudMinSpeed.LABEL_TOO_SLOW, HudLives.LABEL_GHOST, HudBoost.LABEL_READY, HudObjective.WORD_FAILED]:
		check(words.has(w), "'%s' is drawn (color is not the only cue)" % w)
	f.boost_fill = 0.6
	f.boosting = true
	hud.advance(DT)
	words = await _drawn(hud)
	check(words.has(HudBoost.LABEL_BOOSTING), "BOOSTING is drawn")
	eq(hud.objective_state(), HudObjective.State.FAILED)


func test_every_event_has_its_own_word() -> void:
	var hud := _hud(_feed())
	var seen := {}
	var emits: Array[Callable] = [
		func() -> void: Events.scored.emit(Events.PASS, 100, 2.0, 1.5),
		func() -> void: Events.scored.emit(Events.CLOSE_PASS, 200, 2.0, 0.3),
		func() -> void: Events.scored.emit(Events.CUT, 150, 2.0, 1.0),
		func() -> void: Events.scored.emit(Events.THREAD, 400, 2.0, 0.2),
		func() -> void: Events.hesitated.emit(),
		func() -> void: Events.chain_banked.emit(900, Events.REASON_CASH_OUT, 900),
		func() -> void: Events.chain_lost.emit(500, Events.REASON_HIT),
		func() -> void: Events.shoulder_penalty_changed.emit(true),
		func() -> void: Events.night_started.emit(),
		func() -> void: Events.life_restored.emit(2),
	]
	for e in emits:
		e.call()
		hud.advance(DT)
		var line := hud.event_line(0)
		var word := line.get_slice(" +", 0).get_slice(" -", 0).get_slice(" ×", 0)
		check(not word.is_empty(), "a word for event %d" % seen.size())
		check(not seen.has(word), "'%s' is used by one event only" % word)
		seen[word] = true
	eq(seen.size(), emits.size())


# ---------------------------------------------------------------- Traffic lamps

## Over one blinker cycle the blinker bit flashes and the brake bit holds: a flash vs a
## steady lamp, whatever the lamps' hues look like.
func test_blinkers_flash_and_brake_lights_hold() -> void:
	var hz := t.traffic_view.blinker_hz
	var duty := t.traffic_view.blinker_duty_frac()
	var flags := TrafficState.FLAG_BLINKER_LEFT | TrafficState.FLAG_BRAKE
	var mask := TrafficLights.blink_mask(flags)
	var blink_states := {}
	var brake_states := {}
	var steps := 40
	for i in steps:
		var b := TrafficLights.bits(flags, mask, float(i) / (hz * float(steps)), hz, duty)
		blink_states[(b & TrafficLights.BIT_BLINK_L) != 0] = true
		brake_states[(b & TrafficLights.BIT_BRAKE) != 0] = true
	eq(blink_states.size(), 2, "the blinker flashes on and off")
	eq(brake_states.size(), 1, "the brake light holds")
	check(brake_states.has(true), "and is on")
	check(TrafficLights.PART_BRAKE != TrafficLights.PART_BLINK_L and TrafficLights.PART_BRAKE != TrafficLights.PART_BLINK_R,
			"the brake-only lamp (third brake light) is its own part")


# ---------------------------------------------------------------- Rooms

func test_confusable_crew_colors_have_different_dot_shapes() -> void:
	var net := NetTuning.load_default()
	var cols := net.room_crew_colors
	for kind in DICHROMACIES:
		for a in cols.size():
			for b in range(a + 1, cols.size()):
				var de := CvdFilter.delta_e(CvdFilter.simulate(cols[a], kind), CvdFilter.simulate(cols[b], kind))
				if de < CONFUSABLE_DE:
					ne(HudLoopStrip.facets_for(net, cols[a]), HudLoopStrip.facets_for(net, cols[b]),
							"%s: crew colors %d and %d (ΔE %.1f) need different shapes" % [kind, a, b, de])


func test_loop_strip_draws_the_crew_shape() -> void:
	var net := NetTuning.load_default()
	var style := HudStyle.new()
	style.setup(UiTheme.load_theme(), t.hud, 1.0)
	var strip := HudLoopStrip.new()
	strip.size = Vector2(520.0, 12.0)
	_add(strip)
	strip.setup(style, net, net.room_crew_colors.size())
	for i in net.room_crew_colors.size():
		strip.set_dot(i, float(i) / float(net.room_crew_colors.size()), net.room_crew_colors[i])
		eq(strip.dot_facets(i), net.room_crew_dot_facets[i % net.room_crew_dot_facets.size()], "dot %d" % i)
	strip.set_dot(0, 0.5, Color.MAGENTA)
	eq(strip.dot_facets(0), HudLoopStrip.DOT_FACETS, "not a crew color: the plain hexagon")


# ---------------------------------------------------------------- Touch controls

func test_drag_braking_shows_a_ring_not_only_a_color() -> void:
	var hub := PlayerInput.new()
	hub.auto_advance = false
	hub.controls = t.controls
	hub.configure_screen(SCREEN, SCREEN, PX_PER_CM)
	hub.set_layout(PlayerInput.DRAG, PlayerInput.AUTO, false)
	_add(hub)
	var overlay := (load("res://src/ui/controls_overlay.tscn") as PackedScene).instantiate() as ControlsOverlay
	_add(overlay)
	await tree.process_frame
	var down := InputEventScreenTouch.new()
	down.index = IOS_ID
	down.position = Vector2(640.0, 300.0)
	down.pressed = true
	hub.handle_pointer(down, 0.0)
	check(not overlay.brake_ring_visible(), "no ring while steering")
	var drag := InputEventScreenDrag.new()
	drag.index = IOS_ID
	drag.position = Vector2(640.0, 300.0 + PX_PER_CM * t.controls.drag_max_cm)
	hub.handle_pointer(drag, 0.1)
	hub.advance(0.1)
	check(hub.drag.brake > 0.0, "a drag down brakes")
	check(overlay.brake_ring_visible(), "braking shows the ring")


# ---------------------------------------------------------------- The dev filter

func test_cvd_filter_keeps_greys_and_changes_hues() -> void:
	for kind in CvdFilter.KINDS:
		for g: float in [0.0, 0.25, 0.5, 1.0]:
			var c := CvdFilter.simulate(Color(g, g, g), kind)
			near(c.r, g, 0.01, "%s grey %.2f r" % [kind, g])
			near(c.g, g, 0.01, "%s grey %.2f g" % [kind, g])
			near(c.b, g, 0.01, "%s grey %.2f b" % [kind, g])
	var red := Color(1.0, 0.0, 0.0)
	var green := Color(0.0, 1.0, 0.0)
	gt(CvdFilter.delta_e(red, green), 80.0, "red and green far apart to normal vision")
	for kind: StringName in [CvdFilter.PROTAN, CvdFilter.DEUTAN]:
		lt(CvdFilter.delta_e(CvdFilter.simulate(red, kind), CvdFilter.simulate(green, kind)),
				CvdFilter.delta_e(red, green) * 0.6, "%s pulls red and green together" % kind)
	var mono := CvdFilter.simulate(Color(0.9, 0.3, 0.1), CvdFilter.MONO)
	near(mono.r, mono.g, 1e-4, "mono is grey")
	near(mono.g, mono.b, 1e-4, "mono is grey")


func test_cvd_image_pass_matches_the_color_one() -> void:
	var img := Image.create(8, 4, false, Image.FORMAT_RGBA8)
	var cols: Array[Color] = [Color(1.0, 0.35, 0.3), Color(0.2, 0.85, 1.0), Color(0.55, 1.0, 0.35), Color(1.0, 0.8, 0.2),
			Color(0.1, 0.1, 0.2), Color(0.95, 0.95, 0.95), Color(0.85, 0.45, 1.0), Color(0.0, 0.0, 0.0)]
	for x in 8:
		for y in 4:
			img.set_pixel(x, y, cols[x])
	for kind in CvdFilter.KINDS:
		var out := CvdFilter.apply(img, kind)
		eq(out.get_size(), img.get_size())
		for x in 8:
			var want := CvdFilter.simulate(Color(img.get_pixel(x, 0)), kind)
			var got := out.get_pixel(x, 2)
			near(got.r, want.r, 2.0 / 255.0, "%s pixel %d r" % [kind, x])
			near(got.g, want.g, 2.0 / 255.0, "%s pixel %d g" % [kind, x])
			near(got.b, want.b, 2.0 / 255.0, "%s pixel %d b" % [kind, x])
