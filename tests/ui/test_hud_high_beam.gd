extends WBTest
## The HUD's high-beam button (WP5.5, plan D8: the player's manual high beams). Spec:
## UI, HUD and design system (top-right cluster: lives, pause and camera buttons;
## faceted small controls; the update rule), World → Night lighting. A tap (iOS-style
## touch id, through the engine's input path) emits high_beam_pressed, which the run
## connects to PlayerInput.toggle_high_beam(); the lit state follows
## Events.high_beam_changed; the button shows only while the headlights are on (dusk,
## night, dawn) and keeps its slot by day.

const HUD_SCENE := "res://src/ui/hud/hud.tscn"
const RUN_SCENE := "res://src/run/run.tscn"
const SKY_SCENE := "res://src/sun/sky.tscn"
const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const IOS_ID := 1_893_457_201
const DT := 1.0 / 60.0

var t: Tuning
var _nodes: Array[Node] = []


func before_all() -> void:
	t = Tuning.load_default()


func before_each() -> void:
	Settings.reset_to_defaults()


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	Settings.reset_to_defaults()


func _hub() -> PlayerInput:
	var hub := PlayerInput.new()
	hub.auto_advance = false
	hub.controls = t.controls
	hub.configure_screen(SCREEN, SCREEN, PlayerInput.canvas_px_per_cm(t.controls, SCREEN.size, Vector2i.ZERO))
	tree.root.add_child(hub)
	_nodes.append(hub)
	return hub


func _hud() -> Hud:
	var hud := (load(HUD_SCENE) as PackedScene).instantiate() as Hud
	hud.auto_process = false
	hud.set_screen(SCREEN, SCREEN)
	tree.root.add_child(hud)
	_nodes.append(hud)
	return hud


func _button(hud: Hud) -> HudButton:
	return hud.get_node("Root/HighBeam") as HudButton


## The headlight ramp of the color script at `sky_t`.
func _ramp(sky_t: float) -> float:
	var cs := ColorScript.load_default()
	cs.bind(t.sun)
	var key := ColorKey.new()
	cs.sample_into(sky_t, key)
	return key.emissive_headlight


func _settle(hud: Hud) -> void:
	for i in ceili(t.hud.high_beam_fade_s / DT) + 2:
		hud.advance(DT)


## A tap with an iOS-style touch id at the centre of `c`, through the engine's input
## path (the button gets the mouse press and release Godot emulates from the touch).
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


# ---------------------------------------------------------------- Press

func test_tap_toggles_the_high_beams() -> void:
	var hub := _hub()
	var hud := _hud()
	hud.high_beam_pressed.connect(hub.toggle_high_beam)   # as Run._install_hud does
	hud.set_headlight_ramp(_ramp(t.sun.sky_t_night))
	_settle(hud)
	check(hud.high_beam_visible(), "shown at night")
	check(not hub.high_beam, "low beams to start")
	_tap(_button(hud))
	check(hub.high_beam, "a tap turns the high beams on")
	hud.advance(DT)
	check(hud.high_beam_lit(), "and lights the button")
	_tap(_button(hud))
	check(not hub.high_beam, "a second tap turns them off")
	check(not hud.high_beam_lit())
	hub.advance(DT)
	eq(hub.steer, 0.0, "the button's touches never reach the steering")


## The run wires the button to its hub (Run._install_hud).
func test_run_connects_the_button_to_its_hub() -> void:
	var r := (load(RUN_SCENE) as PackedScene).instantiate() as Run
	r.run_seed = 5508
	r.manual_ticks = true
	r.crash_cinematic = false
	r.record_best = false
	tree.root.add_child(r)
	_nodes.append(r)
	r.screens.persist_settings = false
	var hud := r.hud as Hud
	if not check(hud != null, "the run has a HUD"):
		return
	check(hud.high_beam_pressed.is_connected(r.hub.toggle_high_beam), "high_beam_pressed -> hub.toggle_high_beam")
	r.sky.sky_t = t.sun.sky_t_night
	r.sky.push_now()
	hud.auto_process = false
	hud.set_screen(SCREEN, SCREEN)
	_settle(hud)
	check(hud.high_beam_visible(), "shown at night (the run's sky)")
	var before := r.hub.high_beam
	_tap(_button(hud))
	eq(r.hub.high_beam, not before, "a tap toggles the run's high beams")


# ---------------------------------------------------------------- Lit state

func test_lit_state_follows_the_event() -> void:
	var hud := _hud()
	hud.set_headlight_ramp(1.0)
	_settle(hud)
	check(not hud.high_beam_lit())
	Events.high_beam_changed.emit(true)
	check(hud.high_beam_lit(), "lit on high_beam_changed(true)")
	Events.high_beam_changed.emit(false)
	check(not hud.high_beam_lit(), "unlit on high_beam_changed(false)")
	# The hub's own toggle (H key, gamepad X) relays on the bus too.
	var hub := _hub()
	hub.set_high_beam(true)
	check(hud.high_beam_lit(), "follows the hub's toggle")
	hub.set_high_beam(false)
	check(not hud.high_beam_lit())


func test_lit_from_the_start_when_the_hub_already_has_high_beams() -> void:
	var hub := _hub()
	hub.set_high_beam(true)
	var hud := _hud()
	hud.advance(DT)
	check(hud.high_beam_lit(), "synced from the hub when found")


# ---------------------------------------------------------------- Visibility

func test_hidden_by_day_shown_at_dusk_and_night() -> void:
	var hud := _hud()
	var base := hud.visible_item_count()
	hud.set_headlight_ramp(_ramp(t.sun.sky_t_afternoon))
	_settle(hud)
	check(not hud.high_beam_visible(), "hidden by day")
	eq(hud.visible_item_count(), base, "no canvas item by day (0 draw calls)")
	var slot := hud.layout.high_beam
	hud.set_headlight_ramp(_ramp(t.sun.sky_t_night))
	hud.advance(DT)
	check(hud.high_beam_visible(), "fading in")
	check(hud.high_beam_alpha() > 0.0 and hud.high_beam_alpha() < 1.0, "part way")
	_settle(hud)
	near(hud.high_beam_alpha(), 1.0, 1e-9, "fully shown at night")
	eq(hud.visible_item_count(), base + 1, "one more canvas item (one draw call: plate only)")
	eq(hud.layout.high_beam, slot, "the slot does not move")
	eq(_button(hud).get_rect(), slot, "the button sits in its slot")
	check(_ramp(t.sun.sky_t_dusk) >= t.hud.high_beam_min_ramp, "the headlights are on at dusk")
	check(_ramp(t.sun.sky_t_dawn) >= t.hud.high_beam_min_ramp, "and at dawn")
	check(_ramp(t.sun.sky_t_golden_hour) < t.hud.high_beam_min_ramp, "not yet at golden hour")
	hud.set_headlight_ramp(_ramp(t.sun.sky_t_dusk))
	_settle(hud)
	check(hud.high_beam_visible(), "shown at dusk")
	hud.set_headlight_ramp(0.0)
	_settle(hud)
	check(not hud.high_beam_visible(), "hidden again by day")
	eq(hud.visible_item_count(), base)


## Without a pinned ramp the button follows the SkyRig in the tree.
func test_follows_the_sky_rig() -> void:
	var sky := (load(SKY_SCENE) as PackedScene).instantiate() as SkyRig
	sky.push_sink = func(_n: StringName, _v: Variant) -> void: pass
	sky.set_process(false)
	tree.root.add_child(sky)
	_nodes.append(sky)
	sky.sky_t = t.sun.sky_t_afternoon
	sky.push_now()
	var hud := _hud()
	_settle(hud)
	check(not hud.high_beam_visible(), "day sky: hidden")
	sky.sky_t = t.sun.sky_t_night
	sky.push_now()
	_settle(hud)
	check(hud.high_beam_visible(), "night sky: shown")


func test_takes_touches_and_stays_clear_of_the_cluster() -> void:
	var hud := _hud()
	var b := _button(hud)
	eq(b.mouse_filter, Control.MOUSE_FILTER_STOP, "a button takes touches")
	var l := hud.layout
	for r: Rect2 in [l.lives, l.pause, l.camera, l.score, l.sun, l.chain, l.stack, l.objective]:
		check(not l.high_beam.intersects(r), "clear of %s" % r)
	near(l.high_beam.end.x, l.camera.end.x, 1e-6, "right-aligned under [CAM]")
	gt(l.high_beam.position.y, l.camera.end.y, "below it")
