extends WBTest
## The HUD's leg pieces (WP5.2). Spec: Core loop -> Legs and checkpoints (warning signs
## at 1 km and 500 m; crossing step 5 "a 2.5-second leg summary toast that does not
## pause play"; leg bonuses, night doubles them; the leg objective shown on entry),
## Night; UI -> HUD elements (the middle third stays clear; update rule: nothing
## animates when idle), Screens ("Leg summary: a non-blocking toast"); Accessibility
## (every message has its own word).

const HUD_SCENE := "res://src/ui/hud/hud.tscn"
const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const DT := 1.0 / 60.0
const CANVASES: Array[Vector2] = [Vector2(1280.0, 720.0), Vector2(1361.0, 720.0), Vector2(1560.0, 720.0)]
const INSET := Vector4(44.0, 0.0, 44.0, 21.0)
## The top-centre readouts end above this share of the height (test_hud_layout.gd).
const MIDDLE_TOP_FRAC := 0.45

var t: Tuning
var hud: Hud
var feed: HudFeed


func before_all() -> void:
	t = Tuning.load_default()


func before_each() -> void:
	Settings.reset_to_defaults()
	hud = (load(HUD_SCENE) as PackedScene).instantiate() as Hud
	hud.auto_process = false
	hud.set_screen(SCREEN, SCREEN)
	tree.root.add_child(hud)
	feed = HudFeed.new()
	feed.top_speed_mps = Units.kmh_to_mps(270.0)
	feed.min_speed_mps = t.scoring.min_speed_mps()
	feed.speed_mps = Units.kmh_to_mps(200.0)
	feed.checkpoint_distance_m = 2000.0
	feed.leg_index = 2
	feed.objective = LegObjectives.CLOSE_PASSES
	feed.objective_target = t.legs.objective_close_passes_count
	feed.objective_progress = 0
	hud.bind(feed)
	hud.advance(DT)


func after_each() -> void:
	if hud != null:
		hud.free()
		hud = null
	Settings.reset_to_defaults()


func _run(seconds: float) -> void:
	for i in ceili(seconds / DT):
		hud.advance(DT)


func _frames(n: int) -> void:
	for i in n:
		await tree.process_frame


func _summary(leg: int, night: bool, objective_points: int = 0) -> Dictionary:
	return {
		RunEvents.SUMMARY_LEG_INDEX: leg, RunEvents.SUMMARY_CLEAN: true, RunEvents.SUMMARY_PACE: true,
		RunEvents.SUMMARY_THREADS: 3, RunEvents.SUMMARY_HEAT: false, RunEvents.SUMMARY_AT_NIGHT: night,
		RunEvents.SUMMARY_OBJECTIVE: LegObjectives.CLOSE_PASSES,
		RunEvents.SUMMARY_OBJECTIVE_DONE: objective_points > 0,
		RunEvents.SUMMARY_OBJECTIVE_POINTS: objective_points,
	}


## A crossing in the run's event order (RunEvents drains them in one frame).
func _cross(leg: int, night: bool, objective_points: int = 0, bonuses: Array = [[LegTracker.BONUS_CLEAN, 5000]],
		life: bool = true, objective_at_line: int = 0) -> void:
	var k := 2 if night else 1
	Events.checkpoint_crossed.emit(leg, _summary(leg, night, maxi(objective_points, objective_at_line)))
	Events.leg_started.emit(leg + 1, &"farmland", LegObjectives.THREADS)
	Events.chain_banked.emit(12_300, Events.REASON_CHECKPOINT, 50_000)
	if night:
		Events.dawn_started.emit(t.sun.dawn_transition_s)
	for b: Array in bonuses:
		Events.bonus_awarded.emit(b[0], int(b[1]) * k, 60_000)
	if objective_at_line > 0:
		Events.bonus_awarded.emit(LegTracker.BONUS_OBJECTIVE, objective_at_line, 62_000)
		Events.objective_completed.emit(LegObjectives.NO_BRAKING, objective_at_line)
	if life:
		Events.life_restored.emit(2)


# ---------------------------------------------------------------- Leg toast

func test_toast_summarises_the_crossing() -> void:
	_cross(2, true, 5000, [[LegTracker.BONUS_CLEAN, 5000], [LegTracker.BONUS_PACE, 3000]])
	hud.advance(DT)
	check(hud.toast_visible(), "the toast shows on checkpoint_crossed")
	var lines := hud.toast_lines()
	eq(lines[0], "LEG 2 COMPLETE")
	check(lines.has("BANKED +12,300"), "the banked chain: %s" % lines)
	check(lines.has("NIGHT ×2"), "night tag")
	check(lines.has("CLEAN +10,000"), "night doubles the leg bonus")
	check(lines.has("PACE +6,000"))
	check(lines.has("OBJECTIVE +5,000"), "an objective paid mid-leg is listed")
	check(lines.has("LIFE RESTORED"))
	check(lines.has("LEG 3 — FARMLAND PLAINS"), "the next leg and its biome: %s" % lines)
	check(lines.has(LegObjectives.label(LegObjectives.THREADS, t.legs)), "the next objective")
	eq(hud.toast_items_shown(), 5, "all items fit")
	# The crossing's lines went to the toast, not the stack.
	for i in hud.event_line_count():
		var line := hud.event_line(i)
		check(not line.begins_with("BANKED") and not line.begins_with("CLEAN") and line != "LIFE RESTORED",
				"'%s' is in the toast, not the stack" % line)


func test_objective_paid_at_the_line_is_listed_once() -> void:
	_cross(4, false, 0, [[LegTracker.BONUS_CLEAN, 5000]], false, 2500)
	hud.advance(DT)
	var n := 0
	for line in hud.toast_lines():
		if line.begins_with("OBJECTIVE"):
			n += 1
			eq(line, "OBJECTIVE +2,500")
	eq(n, 1, "listed once")
	check(not hud.toast_lines().has("NIGHT ×2"), "day crossing: no night tag")
	check(not hud.toast_lines().has("LIFE RESTORED"), "no life came back")


func test_toast_lasts_leg_toast_s_and_does_not_block() -> void:
	near(t.hud.leg_toast_s, 2.5, 1e-9, "spec: 2.5 s")
	var root := hud.get_node("Root") as Control
	var toast := root.get_node("LegToast") as Control
	eq(toast.mouse_filter, Control.MOUSE_FILTER_IGNORE, "takes no touches")
	eq((root.get_node("Objective") as Control).mouse_filter, Control.MOUSE_FILTER_IGNORE)
	_cross(1, false)
	Events.scored.emit(Events.CLOSE_PASS, 900, 3.0, 0.4)
	hud.advance(DT)
	check(hud.toast_visible())
	check(not (root.get_node("Stack") as Control).visible, "the stack steps aside for the toast")
	gt(hud.event_line_count(), 0, "lines still arrive while the toast shows")
	_run(t.hud.leg_toast_s * 0.5)
	check(hud.toast_visible(), "still showing mid-way")
	near(toast.modulate.a, 1.0, 1e-6, "fully shown in the hold")
	_run(t.hud.leg_toast_s * 0.5)
	check(not hud.toast_visible(), "gone after leg_toast_s")
	eq(hud.event_line_count(), 0, "lines aged out while hidden (no stale lines)")
	Events.scored.emit(Events.PASS, 300, 3.0, 0.9)
	check((root.get_node("Stack") as Control).visible, "the stack is back")


func test_toast_worst_case_fits() -> void:
	# Night, all four leg bonuses, the objective and the life (the journey bonus comes
	# with the coast finale, WP6.5).
	for ts in t.hud.text_scales:
		Settings.set_value(&"text_scale", ts)
		hud.advance(DT)
		_cross(3, true, 5000, [[LegTracker.BONUS_CLEAN, 5000], [LegTracker.BONUS_PACE, 3000],
				[LegTracker.BONUS_THREADS, 3000], [LegTracker.BONUS_HEAT, 5000]])
		hud.advance(DT)
		eq(hud.toast_items_shown(), 7, "every item fits at text %.2f" % ts)
		_run(t.hud.leg_toast_s + 0.1)


func test_toast_and_chip_stay_out_of_the_middle_third() -> void:
	var n := 0
	for size in CANVASES:
		for inset: bool in [false, true]:
			var full := Rect2(Vector2.ZERO, size)
			var safe := full
			if inset:
				safe = Rect2(Vector2(INSET.x, INSET.y), size - Vector2(INSET.x + INSET.z, INSET.y + INSET.w))
			for left: bool in [false, true]:
				for throttle: StringName in [PlayerInput.AUTO, PlayerInput.MANUAL]:
					for scale: float in [0.8, 1.0, 1.2]:
						for ts in t.hud.text_scales:
							var c := ControlsLayout.new()
							c.build(t.controls, full, safe, PlayerInput.canvas_px_per_cm(t.controls, full.size,
									Vector2i.ZERO), PlayerInput.DRAG, throttle, left, scale)
							var l := HudLayout.new()
							l.build(t.hud, full, safe, c, ts)
							var what := "%s%s %s %s x%.1f text %.2f" % [size, " inset" if inset else "",
									"left" if left else "right", throttle, scale, ts]
							var col := l.middle_column()
							var mid_top := l.safe.position.y + l.safe.size.y * MIDDLE_TOP_FRAC
							var middle := Rect2(col.position.x, mid_top, col.size.x, l.safe.end.y - mid_top)
							for r: Rect2 in [l.toast, l.objective]:
								check(l.safe.encloses(r), "%s inside the safe area" % what)
								check(not r.intersects(middle), "%s %s in the middle third" % [what, r])
							near(l.toast.position.x, l.stack.position.x, 1e-3, "%s toast in the stack's slot" % what)
							near(l.toast.size.x, l.stack.size.x, 1e-3)
							var others: Array[Rect2] = [l.score, l.sun, l.chain, l.lives, l.pause, l.camera,
									l.min_speed, l.speedo, l.boost, l.objective]
							for o in others:
								check(not l.toast.intersects(o), "%s toast overlaps %s" % [what, o])
							n += 1
	gt(n, 100)


# ---------------------------------------------------------------- Objective chip

func test_chip_shows_the_objective_and_its_progress() -> void:
	check(hud.objective_visible(), "shown on entry")
	eq(hud.objective_text(), "5 CLOSE PASSES")
	eq(hud.objective_caption(), "LEG 2 OBJECTIVE")
	eq(hud.objective_progress_text(), "0/5")
	eq(hud.objective_state(), HudObjective.State.PENDING)
	feed.objective_progress = 3
	hud.advance(DT)
	eq(hud.objective_progress_text(), "3/5")
	var c0 := hud.change_count()
	var r0 := hud.redraw_count()
	_run(0.5)
	await _frames(2)
	eq(hud.change_count(), c0, "idle: no changes")
	r0 = hud.redraw_count()
	_run(0.5)
	await _frames(2)
	eq(hud.redraw_count(), r0, "idle: nothing redraws")
	feed.objective = &""
	hud.advance(DT)
	check(not hud.objective_visible(), "no objective: hidden")


func test_chip_completes_gold_then_fades_out() -> void:
	feed.objective_progress = 5
	feed.objective_done = true
	hud.advance(DT)
	eq(hud.objective_state(), HudObjective.State.DONE)
	eq(hud.objective_progress_text(), "5/5")
	_run(t.hud.objective_end_hold_s)
	check(hud.objective_visible(), "holds after completion")
	_run(t.hud.objective_fade_s + 0.1)
	check(not hud.objective_visible(), "then fades out")
	_run(1.0)
	check(not hud.objective_visible(), "stays hidden for the rest of the leg")
	# The next leg's objective shows again.
	feed.leg_index = 3
	feed.objective = LegObjectives.NO_BRAKING
	feed.objective_done = false
	feed.objective_target = 0
	feed.objective_progress = 0
	hud.advance(DT)
	check(hud.objective_visible())
	eq(hud.objective_text(), "NO BRAKING")
	eq(hud.objective_progress_text(), "", "nothing to count")
	eq(hud.objective_state(), HudObjective.State.PENDING)
	feed.objective_failed = true
	hud.advance(DT)
	eq(hud.objective_state(), HudObjective.State.FAILED)


func test_chip_units_follow_the_setting() -> void:
	feed.objective = LegObjectives.TOP_SPEED
	feed.objective_target = 0
	hud.advance(DT)
	eq(hud.objective_text(), "HIT 250 KM/H")
	Settings.set_value(&"units", &"mph")
	hud.advance(DT)
	eq(hud.objective_text(), "HIT 155 MPH")


# ---------------------------------------------------------------- Messages

func test_checkpoint_warnings_in_the_stack() -> void:
	Events.checkpoint_warning.emit(1000.0)
	eq(hud.event_line(0), "CHECKPOINT 1 KM")
	Events.checkpoint_warning.emit(500.0)
	eq(hud.event_line(0), "CHECKPOINT 500 M")
	Settings.set_value(&"units", &"mph")
	hud.advance(DT)
	Events.checkpoint_warning.emit(1000.0)
	eq(hud.event_line(0), "CHECKPOINT 0.6 MI")


func test_night_dawn_and_morning_messages() -> void:
	Events.night_started.emit()
	eq(hud.event_line(0), "NIGHT ×2")
	Events.dawn_started.emit(t.sun.dawn_transition_s)
	eq(hud.event_line(0), "DAWN")
	Events.morning_reached.emit()
	eq(hud.event_line(0), "MORNING")


func test_new_run_clears_the_toast() -> void:
	_cross(1, false)
	hud.advance(DT)
	check(hud.toast_visible())
	Events.run_started.emit(&"journey", 1)
	hud.advance(DT)
	check(not hud.toast_visible())
	Events.scored.emit(Events.PASS, 300, 1.0, 0.9)
	check((hud.get_node("Root/Stack") as Control).visible, "stack unmuted")
