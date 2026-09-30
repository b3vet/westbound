extends WBTest
## Reduced motion everywhere (WP9.3). Spec: UI, HUD and design system → Accessibility
## ("Reduced motion: turns off camera shake, camera roll, the field-of-view punch and slow
## motion"); Cameras ("The setting turns off shake, roll and the field-of-view punch").
## docs/ACCESSIBILITY.md → Reduced motion (the same table, row for row).
##
## ROWS is the audit: every motion source, what reduced motion does to it and where. Each
## row is driven twice, with the setting off and on, measuring the largest motion it
## draws (px, radians, pulse depth, flashes per second: see each driver):
##   - `moves` rows must move with the setting off (the driver really exercises it)
##     and stay within `bound` with it on;
##   - `kept` rows are motion the spec keeps (speed lines): the same both ways;
##   - `still` rows never move (fade-only toasts, static icons);
##   - `covered` rows are proved by the named test (heavy fixtures: the crash's Jolt
##     orbit, the garage turntable); the file must exist and test reduced motion.

const RIG_SCENE := preload("res://src/camera/camera_rig.tscn")
const HUD_SCENE := preload("res://src/ui/hud/hud.tscn")
const SCREENS_SCENE := preload("res://src/ui/screens/run_screens.tscn")
const CAR_SCENE := "res://src/vehicle/player_car.tscn"
const CAR_PATH := "res://data/cars/falcon_gt.tres"
const DOC := "res://docs/ACCESSIBILITY.md"
const SHELL := "res://platform/web/shell.html"
const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const DT := 1.0 / 60.0
const TICK := 1.0 / 120.0
## Motion below this is rest (float noise).
const EPS := 1e-4
## WCAG 2.3.1: no more than three flashes in any one second.
const MAX_FLASHES_PER_S := 3.0
const ATTRACT_SETTLE_TICKS := 480

enum Kind { MOVES, KEPT, STILL, COVERED }

## [id, kind, bound (on), driver method or covering test, what reduced motion does].
const ROWS: Array[Array] = [
	["camera_shake", Kind.MOVES, EPS, "_drive_camera_shake", "off"],
	["camera_roll", Kind.MOVES, EPS, "_drive_camera_roll", "off"],
	["fov_punch", Kind.MOVES, EPS, "_drive_fov_punch", "off"],
	["cockpit_head_sway", Kind.MOVES, EPS, "_drive_head_sway", "off"],
	["slow_motion", Kind.MOVES, EPS, "_drive_slow_motion", "off (requests ignored)"],
	["finale_swing", Kind.MOVES, EPS, "_drive_finale", "refused (the toast still shows)"],
	["attract_camera", Kind.MOVES, EPS, "_drive_attract", "holds the chase pose, no shots or cuts"],
	["hud_chain_pulse", Kind.MOVES, EPS, "_drive_chain_pulse", "no pop"],
	["hud_multiplier_wobble", Kind.MOVES, EPS, "_drive_wobble", "no wobble (hue cycle kept)"],
	["hud_event_stack", Kind.MOVES, EPS, "_drive_stack", "lines fade in place"],
	["hud_bank_flyer", Kind.MOVES, EPS, "_drive_flyer", "fades where the chain was"],
	["hud_glitter", Kind.MOVES, EPS, "_drive_glitter", "none"],
	["hud_life_break", Kind.MOVES, EPS, "_drive_life_break", "the lost gem fades in place"],
	["hud_life_restore", Kind.MOVES, EPS, "_drive_life_restore", "fades in, no overshoot"],
	["hud_ghost_blink", Kind.MOVES, EPS, "_drive_ghost_blink", "steady (GHOST says it)"],
	["hud_too_slow_pulse", Kind.MOVES, EPS, "_drive_too_slow", "steady (TOO SLOW says it)"],
	["hud_boost_pulse", Kind.MOVES, EPS, "_drive_boost", "steady (BOOSTING says it)"],
	["hud_objective_pop", Kind.MOVES, EPS, "_drive_objective", "no pop, fades"],
	["hud_journey_grow", Kind.MOVES, EPS, "_drive_journey", "no grow, fades"],
	["hud_leg_toast", Kind.STILL, EPS, "_drive_leg_toast", "fades only (both)"],
	["hud_achievement_toast", Kind.STILL, EPS, "_drive_achievement_toast", "fades only (both)"],
	["hud_cooling_icon", Kind.STILL, EPS, "_drive_cooling", "static (both)"],
	["screen_title", Kind.MOVES, EPS, "_drive_title", "fades only, no slides"],
	["screen_online_hub", Kind.MOVES, EPS, "_drive_hub", "fades only, no slides"],
	["screen_pause", Kind.MOVES, EPS, "_drive_pause", "fades only, no slides"],
	["screen_countdown", Kind.MOVES, EPS, "_drive_countdown", "no punch"],
	["screen_results", Kind.MOVES, EPS, "_drive_results", "fades only, no slides or pops"],
	["screen_crash_hint", Kind.MOVES, EPS, "_drive_crash_hint", "steady, no pulse"],
	["ghost_flicker", Kind.MOVES, MAX_FLASHES_PER_S, "_drive_ghost_flicker", "slows to 2 Hz"],
	["damage_lamp_flicker", Kind.MOVES, MAX_FLASHES_PER_S, "_drive_lamp_flicker", "slows to 2 Hz"],
	["speed_lines", Kind.KEPT, 0.0, "_drive_speed_lines", "kept (spec: not camera motion)"],
	["garage_turntable", Kind.COVERED, 0.0, "res://tests/ui/test_garage.gd", "holds still"],
	["crash_orbit", Kind.COVERED, 0.0, "res://tests/run/test_crash_sequence.gd", "orbit at 35 %"],
	["loading_shell", Kind.COVERED, 0.0, "res://tests/a11y/test_reduced_motion.gd", "system setting: no sweep"],
]

var t: Tuning
var _nodes: Array[Node] = []
var _base_ticks: int = 0


func before_all() -> void:
	t = Tuning.load_default()


func before_each() -> void:
	Settings.restore_defaults()
	_base_ticks = Engine.physics_ticks_per_second


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	Settings.restore_defaults()
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = _base_ticks


func _add(n: Node) -> Node:
	tree.root.add_child(n)
	_nodes.append(n)
	return n


func _free_all() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()


# ---------------------------------------------------------------- The table

func test_every_motion_source_honours_reduced_motion() -> void:
	for row in ROWS:
		var id: String = row[0]
		var kind: Kind = row[1]
		var bound: float = row[2]
		var how: String = row[3]
		if kind == Kind.COVERED:
			continue
		Settings.set_value(&"reduced_motion", false)
		var off: float = await call(how, false)
		_free_all()
		Settings.set_value(&"reduced_motion", true)
		var on: float = await call(how, true)
		_free_all()
		Settings.set_value(&"reduced_motion", false)
		match kind:
			Kind.MOVES:
				gt(off, bound, "%s moves with reduced motion off (the driver works)" % id)
				le(on, bound, "%s with reduced motion on" % id)
			Kind.KEPT:
				gt(off, 0.0, "%s shows" % id)
				near(on, off, EPS, "%s is kept with reduced motion" % id)
			Kind.STILL:
				le(off, bound, "%s never moves" % id)
				le(on, bound, "%s never moves (reduced motion)" % id)


func test_covered_rows_name_a_test_of_reduced_motion() -> void:
	for row in ROWS:
		if row[1] != Kind.COVERED:
			continue
		var src := FileAccess.get_file_as_string(row[3])
		check(src.contains("reduced_motion") or src.contains("reduced motion"),
				"%s: %s tests reduced motion" % [row[0], row[3]])


## docs/ACCESSIBILITY.md lists every row (the audit table stays the tested one).
func test_the_doc_table_lists_every_row() -> void:
	var doc := FileAccess.get_file_as_string(DOC)
	check(not doc.is_empty(), "docs/ACCESSIBILITY.md exists")
	for row in ROWS:
		check(doc.contains("`%s`" % row[0]), "the doc's motion table has `%s`" % row[0])


## The web loading shell (before the engine, so the game's setting is unknown) follows
## the system's reduced-motion preference: no sweep, a stepped opacity only.
func test_web_shell_follows_the_system_setting() -> void:
	var html := FileAccess.get_file_as_string(SHELL)
	var at := html.find("@media (prefers-reduced-motion: reduce)")
	if not check(at >= 0, "the shell has a prefers-reduced-motion rule"):
		return
	var block := html.substr(at, html.find("}\n}", at) - at)
	check(block.contains("#wb-sweep") and block.contains("transform: none"), "the sweep does not move")
	check(block.contains("animation: wb-breathe"), "it breathes in opacity instead")
	var breathe := html.substr(html.find("@keyframes wb-breathe"))
	check(not breathe.substr(0, breathe.find("}\n}")).contains("transform"), "opacity only")


## Turning the setting on mid-animation settles the HUD at once (no pop left half-way).
func test_turning_it_on_settles_running_motion() -> void:
	var hud := _hud()
	var f := _feed()
	f.multiplier = 80.0
	hud.bind(f)
	Events.scored.emit(Events.CLOSE_PASS, 500, 80.0, 0.3)
	_advance(hud, DT * 3.0)
	gt(_widget(hud, "Chain").motion_amount() + _widget(hud, "Glitter").motion_amount(), EPS, "moving")
	Settings.set_value(&"reduced_motion", true)
	for w: String in ["Chain", "Multiplier", "Stack", "Glitter", "Flyer", "Lives"]:
		le(_widget(hud, w).motion_amount(), EPS, "%s settled" % w)


# ---------------------------------------------------------------- Camera

func _rig(mode: StringName = &"chase") -> Array:
	var target := Node3D.new()
	_add(target)
	var st := VehicleState.new()
	st.v = Units.kmh_to_mps(200.0)
	var rig := RIG_SCENE.instantiate() as CameraRig
	_add(rig)
	rig.set_physics_process(false)
	rig.set_mode(mode)
	rig.set_target(target, st, Units.kmh_to_mps(280.0))
	return [rig, target, st]


func _drive_camera_shake(_reduced: bool) -> float:
	var r := _rig()
	var rig: CameraRig = r[0]
	rig.shake(1.0, 1.0)
	var m := 0.0
	for i in 60:
		rig.advance(TICK)
		m = maxf(m, rig.camera().position.length() + rig.camera().rotation.length())
	return m


func _drive_camera_roll(_reduced: bool) -> float:
	var r := _rig()
	var rig: CameraRig = r[0]
	(r[2] as VehicleState).accel_lat = 6.0
	var m := 0.0
	for i in 120:
		rig.advance(TICK)
		m = maxf(m, absf(rig.roll_rad()))
	return m


func _drive_fov_punch(_reduced: bool) -> float:
	var r := _rig()
	var rig: CameraRig = r[0]
	Events.boost_started.emit()
	var m := 0.0
	for i in 60:
		rig.advance(TICK)
		m = maxf(m, rig.punch_deg())
	return m


func _drive_head_sway(_reduced: bool) -> float:
	var r := _rig(t.camera.cockpit_mode)
	var rig: CameraRig = r[0]
	var st: VehicleState = r[2]
	st.accel_lat = 6.0
	st.accel_long = -8.0
	var m := 0.0
	for i in 120:
		rig.advance(TICK)
		m = maxf(m, rig.head_transform().origin.length())
	return m


func _drive_slow_motion(_reduced: bool) -> float:
	var ts := TimeScale.new()
	_add(ts)
	var f := t.feel
	Events.slowmo_requested.emit(f.slowmo_first_hit_scale, f.slowmo_first_hit_s, TimeScale.REASON_FIRST_HIT)
	var m := 1.0 - Engine.time_scale
	Events.scored.emit(Events.THREAD, 100, 2.0, 0.2)
	m = maxf(m, 1.0 - Engine.time_scale)
	ts.advance_real(f.slowmo_crash_s)
	return m


func _drive_finale(_reduced: bool) -> float:
	var r := _rig()
	var rig: CameraRig = r[0]
	rig.start_finale(1.0)
	var m := 0.0
	for i in 120:
		rig.advance(TICK)
		m = maxf(m, rig.finale_weight())
	return m


## The attract director hands the rig a new orbit view every tick while the car drives
## straight: how far the camera moves relative to the car between ticks, once the chase
## springs have settled from standing (ATTRACT_SETTLE_TICKS; in the game they follow the
## car all along).
func _drive_attract(_reduced: bool) -> float:
	var r := _rig()
	var rig: CameraRig = r[0]
	var target: Node3D = r[1]
	var st: VehicleState = r[2]
	rig.start_attract()
	var m := 0.0
	var last := Vector3.INF
	for i in ATTRACT_SETTLE_TICKS + 60:
		target.position += Vector3.FORWARD * (st.v * TICK)
		var a := float(i) * 0.02
		var eye := target.position + Vector3(sin(a), 0.1, -cos(a)) * t.camera.attract_orbit_distance_m
		rig.set_attract_view(eye, target.position, t.camera.attract_fov_deg, 0.0, i == 0)
		rig.advance(TICK)
		var rel := rig.global_position - target.position
		if i > ATTRACT_SETTLE_TICKS and last != Vector3.INF:
			m = maxf(m, rel.distance_to(last))
		last = rel
	rig.stop_attract()
	return m


# ---------------------------------------------------------------- HUD

func _hud() -> Hud:
	var hud := HUD_SCENE.instantiate() as Hud
	hud.auto_process = false
	hud.set_screen(SCREEN, SCREEN)
	_add(hud)
	return hud


func _feed() -> HudFeed:
	var f := HudFeed.new()
	f.top_speed_mps = Units.kmh_to_mps(270.0)
	f.min_speed_mps = t.scoring.min_speed_mps()
	f.speed_mps = Units.kmh_to_mps(180.0)
	f.boost_fill = 0.5
	f.sun_height = 0.6
	f.lives = 2
	f.chain = 1200
	f.multiplier = 3.0
	return f


static func _widget(hud: Hud, node_name: String) -> HudWidget:
	return hud.get_node("Root/%s" % node_name) as HudWidget


func _advance(hud: Hud, seconds: float) -> void:
	for i in ceili(seconds / DT):
		hud.advance(DT)


## The largest motion_amount() of `w` over `seconds` of frames.
func _sample(hud: Hud, w: HudWidget, seconds: float) -> float:
	var m := w.motion_amount()
	for i in ceili(seconds / DT):
		hud.advance(DT)
		m = maxf(m, w.motion_amount())
	return m


func _drive_chain_pulse(_reduced: bool) -> float:
	var hud := _hud()
	hud.bind(_feed())
	hud.advance(DT)
	Events.scored.emit(Events.PASS, 100, 3.0, 1.5)
	return _sample(hud, _widget(hud, "Chain"), t.hud.chain_pulse_s)


func _drive_wobble(_reduced: bool) -> float:
	var hud := _hud()
	var f := _feed()
	f.multiplier = t.hud.mult_wobble_full_at
	hud.bind(f)
	return _sample(hud, _widget(hud, "Multiplier"), 1.0)


func _drive_stack(_reduced: bool) -> float:
	var hud := _hud()
	hud.bind(_feed())
	hud.advance(DT)
	Events.scored.emit(Events.PASS, 100, 3.0, 1.5)
	hud.advance(DT)
	Events.scored.emit(Events.CLOSE_PASS, 300, 3.0, 0.3)
	return _sample(hud, _widget(hud, "Stack"), t.hud.event_slide_s * 2.0)


func _drive_flyer(_reduced: bool) -> float:
	var hud := _hud()
	var f := _feed()
	hud.bind(f)
	hud.advance(DT)
	f.banked = 1200
	Events.chain_banked.emit(1200, Events.REASON_CASH_OUT, 1200)
	return _sample(hud, _widget(hud, "Flyer"), t.hud.bank_fly_s)


func _drive_glitter(_reduced: bool) -> float:
	var hud := _hud()
	var f := _feed()
	f.multiplier = t.hud.glitter_min_multiplier + 1.0
	hud.bind(f)
	hud.advance(DT)
	Events.scored.emit(Events.THREAD, 500, f.multiplier, 0.2)
	return _sample(hud, _widget(hud, "Glitter"), t.hud.glitter_s * 0.5)


func _drive_life_break(_reduced: bool) -> float:
	var hud := _hud()
	var f := _feed()
	hud.bind(f)
	hud.advance(DT)
	f.lives = 1
	Events.hit.emit(Events.HIT_TRAFFIC, 1)
	return _sample(hud, _widget(hud, "Lives"), t.hud.life_break_s)


func _drive_life_restore(_reduced: bool) -> float:
	var hud := _hud()
	var f := _feed()
	f.lives = 1
	hud.bind(f)
	hud.advance(DT)
	f.lives = 2
	Events.life_restored.emit(2)
	return _sample(hud, _widget(hud, "Lives"), t.hud.life_restore_s)


func _drive_ghost_blink(_reduced: bool) -> float:
	var hud := _hud()
	var f := _feed()
	f.lives = 1
	f.ghost = true
	hud.bind(f)
	return _sample(hud, _widget(hud, "Lives"), 1.0)


func _drive_too_slow(_reduced: bool) -> float:
	var hud := _hud()
	var f := _feed()
	f.speed_mps = Units.kmh_to_mps(60.0)
	f.too_slow = true
	hud.bind(f)
	return _sample(hud, _widget(hud, "MinSpeed"), 1.0)


func _drive_boost(_reduced: bool) -> float:
	var hud := _hud()
	var f := _feed()
	hud.bind(f)
	hud.advance(DT)
	f.boosting = true
	Events.boost_started.emit()
	return _sample(hud, _widget(hud, "Boost"), 1.0)


func _drive_objective(_reduced: bool) -> float:
	var hud := _hud()
	var f := _feed()
	f.leg_index = 2
	f.objective = LegObjectives.CLOSE_PASSES
	hud.bind(f)
	return _sample(hud, _widget(hud, "Objective"), t.hud.objective_pop_s)


func _drive_journey(_reduced: bool) -> float:
	var hud := _hud()
	hud.bind(_feed())
	hud.advance(DT)
	Events.journey_complete.emit()
	return _sample(hud, hud.get_node("Root/JourneyToast") as HudWidget, t.hud.journey_toast_in_s)


func _drive_leg_toast(_reduced: bool) -> float:
	var hud := _hud()
	hud.bind(_feed())
	hud.advance(DT)
	Events.checkpoint_crossed.emit(1, {})
	Events.leg_started.emit(2, &"desert", &"")
	return _sample(hud, _widget(hud, "LegToast"), t.hud.leg_toast_s)


func _drive_achievement_toast(_reduced: bool) -> float:
	var hud := _hud()   # for the style and a canvas to live on
	var w := HudAchievementToast.new()
	w.tuning = AchievementTuning.load_default()
	hud.get_node("Root").add_child(w)
	w.setup(hud.style)
	w.show_unlock("300 CLUB")
	var m := 0.0
	for i in ceili(w.tuning.toast_s / DT):
		w.animate(DT)
		m = maxf(m, w.motion_amount())
	return m


func _drive_cooling(_reduced: bool) -> float:
	var hud := _hud()
	hud.bind(_feed())
	hud.set_cooling(true)
	return _sample(hud, hud.get_node("Root/Cooling") as HudWidget, 1.0)


# ---------------------------------------------------------------- Screens

## How far any control of `root` sits from where its entry transition ends (position px +
## scale), measured before the first tween step.
static func _entry_motion(root: Node, finish: Callable) -> float:
	var ctrls: Array[Control] = []
	_controls(root, ctrls)
	var pos: Array[Vector2] = []
	var sc: Array[Vector2] = []
	for c in ctrls:
		pos.append(c.position)
		sc.append(c.scale)
	finish.call()
	var m := 0.0
	for i in ctrls.size():
		if is_instance_valid(ctrls[i]) and ctrls[i].is_visible_in_tree():
			m = maxf(m, ctrls[i].position.distance_to(pos[i]) + (ctrls[i].scale - sc[i]).abs().length())
	return m


static func _controls(n: Node, out: Array[Control]) -> void:
	for c in n.get_children():
		if c is Control:
			out.append(c as Control)
		_controls(c, out)


func _title_screens() -> TitleScreens:
	var ts := TitleScreens.new()
	ts.persist_settings = false
	_add(ts)
	ts.set_screen(SCREEN, SCREEN)
	return ts


func _drive_title(_reduced: bool) -> float:
	var ts := _title_screens()
	ts.show_state(Game.MENU)
	return _entry_motion(ts.title, ts.finish_animations)


func _drive_hub(_reduced: bool) -> float:
	var ts := _title_screens()
	ts.show_state(Game.MENU)
	ts.finish_animations()
	ts.open_hub()
	return _entry_motion(ts.online_hub, ts.finish_animations)


func _run_screens() -> RunScreens:
	var s := SCREENS_SCENE.instantiate() as RunScreens
	s.persist_settings = false
	_add(s)
	s.bind(null, _feed())
	s.set_screen(SCREEN, SCREEN)
	return s


func _drive_pause(_reduced: bool) -> float:
	var s := _run_screens()
	s.show_state(Game.PAUSED, Game.RUNNING)
	return _entry_motion(s.pause_screen, s.pause_screen.finish_animations)


func _drive_countdown(_reduced: bool) -> float:
	var s := _run_screens()
	s.prepare_countdown()
	s.countdown.show_step(t.hud.countdown_from)
	return _entry_motion(s.countdown, s.countdown.finish_animations)


func _drive_results(_reduced: bool) -> float:
	var s := _run_screens()
	s.show_results({
		RunStats.SCORE: 120_000,
		RunStats.DISTANCE_M: 12_000.0,
		RunStats.LEGS_COMPLETED: 2,
		&"personal_best": 100_000,
		&"new_best": true,
		&"previous_best": 100_000,
	})
	return _entry_motion(s.results_screen, s.results_screen.finish_animations)


func _drive_crash_hint(_reduced: bool) -> float:
	var s := _run_screens()
	s.show_state(Game.CRASH, Game.RUNNING)
	s.crash_screen.finish_animations()
	var hint := s.crash_screen.hint
	var lo := INF
	var hi := -INF
	var steps := ceili((t.hud.crash_hint_delay_s + 2.0) / DT)
	for i in steps:
		s.crash_screen._process(DT)
		if float(i) * DT > t.hud.crash_hint_delay_s + t.hud.screen_fade_in_s * 2.0:
			lo = minf(lo, hint.modulate.a)
			hi = maxf(hi, hint.modulate.a)
	return hi - lo


# ---------------------------------------------------------------- The car's damage look

func _player_fx() -> PlayerFx:
	var road := StraightRoadPath.new(3, t.road)
	var car_def := load(CAR_PATH) as CarDef
	var car := (load(CAR_SCENE) as PackedScene).instantiate() as PlayerCar
	car.self_tick = false
	_add(car)
	car.setup(RunContext.new(1), road, null, car_def, VehicleParams.build(t, car_def))
	car.place_at(100.0, road.lane_center_d(1, 100.0), Units.kmh_to_mps(150.0))
	var fx := PlayerFx.new()
	_add(fx)
	fx.set_process(false)
	fx.bind(car)
	return fx


## Visible -> hidden flips of the body per second during a 2 s ghost.
func _drive_ghost_flicker(_reduced: bool) -> float:
	var fx := _player_fx()
	var seconds := 2.0
	fx.start_ghost(seconds + 1.0)
	var flashes := 0
	var was := fx.car.visual.visible
	for i in roundi(seconds / DT):
		fx.advance(DT)
		var v := fx.car.visual.visible
		if was and not v:
			flashes += 1
		was = v
	fx.stop_ghost()
	return float(flashes) / seconds


## Lit -> dark flips of the dead headlight per second.
func _drive_lamp_flicker(_reduced: bool) -> float:
	var fx := _player_fx()
	fx.set_damaged(true)
	var seconds := 4.0
	var flashes := 0
	var was := 0.0
	var mat := fx.get_lamp().material_override as ShaderMaterial
	for i in roundi(seconds / DT):
		fx.advance(DT)
		var level := float(mat.get_shader_parameter(&"level"))
		if was > 0.0 and level <= 0.0:
			flashes += 1
		was = level
	return float(flashes) / seconds


func _drive_speed_lines(_reduced: bool) -> float:
	var lines := SpeedLines.new()
	_add(lines)
	lines.setup(t.feel, 1.0)
	lines.update(DT, Units.kmh_to_mps(240.0), false)
	return lines.intensity

