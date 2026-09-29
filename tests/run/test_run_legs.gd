extends WBTest
## Gate M5 (plan Phase 5: "a headless scripted run cycles day -> night -> dawn correctly
## across legs") and the WP5.2 run wiring. Spec: Core loop -> Sky timeline and sun
## clock, Night (x2 on everything scored at night, including leg bonuses for a leg
## finished at night; the next checkpoint plays the dawn), Legs and checkpoints (warning
## signs at 1 km and 500 m; the 5-step crossing; leg bonuses; the leg objective); Lives
## (a clean-leg restore never exceeds 2 lives).
##
## The real Run (run.tscn) ticks manually with a weaving bot; checkpoints come from the
## procedural road. Each leg is shortened by teleporting the car to just before its
## checkpoint (dev_teleport: the leg keeps counting from its start), and the sunset is
## brought forward by setting sky_t just before it, so four legs fit in a few seconds.

const RUN_SCENE := preload("res://src/run/run.tscn")
const SEED := 20260929
const BOT_SEED := 11
const FRAME_S := 1.0 / 60.0
const TICKS_PER_FRAME := 2
const BOT_SPEED_MPS := 52.0
const APPROACH_M := 15.0
const APPROACH_KMH := 200.0
const LEGS := 5

var t: Tuning
var _runs: Array[Run] = []
var _log: Array = []
var _conns: Array = []


func before_all() -> void:
	t = Tuning.load_default()


func before_each() -> void:
	_log.clear()
	_listen(Events.checkpoint_warning, func(m: float) -> void: _log.append(["checkpoint_warning", m]))
	_listen(Events.checkpoint_crossed, func(leg: int, summary: Dictionary) -> void:
		_log.append(["checkpoint_crossed", leg, summary]))
	_listen(Events.leg_started, func(leg: int, b: StringName, o: StringName) -> void:
		_log.append(["leg_started", leg, b, o]))
	_listen(Events.bonus_awarded, func(k: StringName, p: int, _tot: int) -> void: _log.append(["bonus_awarded", k, p]))
	_listen(Events.objective_completed, func(o: StringName, p: int) -> void: _log.append(["objective_completed", o, p]))
	_listen(Events.night_started, func() -> void: _log.append(["night_started"]))
	_listen(Events.dawn_started, func(d: float) -> void: _log.append(["dawn_started", d]))
	_listen(Events.morning_reached, func() -> void: _log.append(["morning_reached"]))
	_listen(Events.life_restored, func(n: int) -> void: _log.append(["life_restored", n]))
	_listen(Events.hit, func(src: StringName, left: int) -> void: _log.append(["hit", src, left]))


func after_each() -> void:
	for c: Array in _conns:
		(c[0] as Signal).disconnect(c[1])
	_conns.clear()
	for r in _runs:
		r.queue_free()
	_runs.clear()
	await tree.process_frame


func _listen(sig: Signal, fn: Callable) -> void:
	sig.connect(fn)
	_conns.append([sig, fn])


func _make(run_seed: int = SEED) -> Run:
	var r := RUN_SCENE.instantiate() as Run
	r.run_seed = run_seed
	r.manual_ticks = true
	r.crash_cinematic = false
	r.record_best = false
	tree.root.add_child(r)
	_runs.append(r)
	var bot := SandboxBot.new(r.road, r.sim.state, r.car.params, BOT_SEED)
	bot.mode = SandboxBot.Mode.WEAVE
	bot.v_target = BOT_SPEED_MPS
	bot.length_m = r.car.car.length_m
	bot.width_m = r.car.car.width_m
	r.drive_controller = bot
	return r


func _run_ticks(r: Run, n: int) -> void:
	for i in n:
		r.tick()
		if i % TICKS_PER_FRAME == TICKS_PER_FRAME - 1:
			r.frame(FRAME_S)


func _ticks_for(seconds: float) -> int:
	return roundi(seconds * float(t.vehicle.physics_tick_hz))


## Teleports to just before the next checkpoint and drives across it (then one more
## frame so every event of the crossing is on the bus).
func _cross(r: Run) -> void:
	var done := r.legs.legs_completed
	var cp := r.legs.distance_to_checkpoint(r.car.state.s)
	check(is_finite(cp), "a checkpoint is queued")
	r.dev_teleport(r.car.state.s + cp - APPROACH_M, Units.kmh_to_mps(APPROACH_KMH))
	var ticks := 0
	while r.legs.legs_completed == done and ticks < _ticks_for(3.0):
		_run_ticks(r, TICKS_PER_FRAME)
		ticks += TICKS_PER_FRAME
	eq(r.legs.legs_completed, done + 1, "crossed the checkpoint of leg %d" % (done + 1))
	_run_ticks(r, TICKS_PER_FRAME)


## Replaces the current leg's objective (after its leg_started was published).
func _force_objective(r: Run, id: StringName) -> void:
	r.objectives.force(id)
	r.legs.set_objective(id)


func _index(entry: Array, from: int = 0) -> int:
	for i in range(from, _log.size()):
		var e: Array = _log[i]
		if e.size() >= entry.size() and e.slice(0, entry.size()) == entry:
			return i
	return -1


func _entries(name: String) -> Array:
	var out: Array = []
	for e: Array in _log:
		if e[0] == name:
			out.append(e)
	return out


func _base_points(kind: StringName) -> int:
	match kind:
		LegTracker.BONUS_CLEAN:
			return t.legs.bonus_clean_points
		LegTracker.BONUS_PACE:
			return t.legs.bonus_pace_points
		LegTracker.BONUS_THREADS:
			return t.legs.bonus_threads_points
		LegTracker.BONUS_HEAT:
			return t.legs.bonus_heat_points
		LegTracker.BONUS_OBJECTIVE:
			return t.legs.objective_bonus_points
	return -1


## The seeded objective sequence a run with `run_seed` draws (the pure system).
func _expected_objectives(run_seed: int, n: int) -> Array[StringName]:
	var o := LegObjectives.new(t.legs)
	o.reset(RunContext.new(run_seed, RunContext.MODE_JOURNEY, t))
	var out: Array[StringName] = []
	for leg in range(1, n + 1):
		out.append(o.start_leg(leg))
	return out


# ---------------------------------------------------------------- Gate M5

func test_m5_day_night_dawn_across_legs() -> void:
	var r := _make()
	var night_factor := t.scoring.night_factor
	eq(night_factor, 2.0, "spec: x2 at night")
	r.go()
	_run_ticks(r, _ticks_for(0.5))
	eq(_entries("leg_started").size(), 1, "leg 1 announced on entry")

	# ---- Leg 1, day: warnings at 1 km and 500 m, then the crossing.
	_cross(r)
	var w1 := _index(["checkpoint_warning", 1000.0])
	var w2 := _index(["checkpoint_warning", 500.0])
	var c1 := _index(["checkpoint_crossed", 1])
	check(w1 >= 0 and w2 > w1 and c1 > w2, "1 km, then 500 m, then the line: %s" % [[w1, w2, c1]])
	var s1: Dictionary = _log[c1][2]
	check(not bool(s1[&"at_night"]), "leg 1 finished by day")
	for e: Array in _entries("bonus_awarded"):
		eq(e[2], _base_points(e[1]), "day bonus %s x1" % e[1])
	eq(r.lives.lives, t.lives.lives, "clean leg with full lives: still 2")
	eq(_entries("life_restored").size(), 0, "nothing to restore")

	# ---- Leg 2: an objective reached mid-leg, the sun sets, the leg ends at night.
	_force_objective(r, LegObjectives.TOP_SPEED)
	r.dev_teleport(r.car.state.s + 50.0, Units.kmh_to_mps(t.legs.objective_top_speed_kmh + 5.0))
	_run_ticks(r, TICKS_PER_FRAME * 2)
	var oc := _index(["objective_completed", LegObjectives.TOP_SPEED], c1)
	check(oc >= 0, "top speed objective completed at once")
	eq(_log[oc][2], t.legs.objective_bonus_points, "paid by day")
	check(r.legs.is_objective_done())
	r.sun.sky_t = t.sun.sky_t_sunset - 1e-5
	_run_ticks(r, _ticks_for(0.2))
	check(r.sun.is_night(), "the sun set")
	check(r.scoring.is_night(), "scoring x2 at night")
	var bonus_before := _entries("bonus_awarded").size()
	_cross(r)
	var n1 := _index(["night_started"])
	var c2 := _index(["checkpoint_crossed", 2])
	var d2 := _index(["dawn_started"])
	check(n1 >= 0 and c2 > n1 and d2 > c2, "night, then the line, then the dawn: %s" % [[n1, c2, d2]])
	near(float(_log[d2][1]), t.sun.dawn_transition_s, 1e-9, "6 s dawn")
	var s2: Dictionary = _log[c2][2]
	check(bool(s2[&"at_night"]), "leg 2 finished at night")
	check(bool(s2[&"objective_done"]), "summary: objective done")
	eq(s2[&"objective"], LegObjectives.TOP_SPEED)
	eq(s2[&"objective_points"], t.legs.objective_bonus_points, "summary carries what was paid")
	var night_bonuses := _entries("bonus_awarded").slice(bonus_before)
	gt(night_bonuses.size(), 0, "leg bonuses paid at the night checkpoint")
	for e: Array in night_bonuses:
		ne(e[1], LegTracker.BONUS_OBJECTIVE, "the objective is not paid again at the line")
		eq(e[2], roundi(_base_points(e[1]) * night_factor), "night bonus %s x2" % e[1])
	check(not r.sun.is_night() and r.sun.is_dawning(), "dawning, gameplay continues")
	check(not r.scoring.is_night(), "the dawn clears x2 after the bonuses")
	_run_ticks(r, _ticks_for(t.sun.dawn_transition_s + 0.1))
	var m2 := _index(["morning_reached"])
	check(m2 > d2, "morning after the dawn")
	check(not r.sun.is_dawning() and not r.sun.is_night(), "day again")
	near(r.sun.sky_t, t.sun.sky_t_morning, 1e-3, "sky_t lands at morning")

	# ---- Leg 3: a hit, so no life back at its checkpoint.
	r.force_hit(HitDetection.HIT_BARRIER)
	_run_ticks(r, TICKS_PER_FRAME)
	eq(r.lives.lives, t.lives.lives - 1, "first hit")
	_cross(r)
	var s3: Dictionary = _log[_index(["checkpoint_crossed", 3])][2]
	check(not bool(s3[&"clean"]), "leg 3 not clean")
	eq(r.lives.lives, t.lives.lives - 1, "hit leg: no life back")
	eq(_entries("life_restored").size(), 0)

	# ---- Leg 4: clean, a "no X" objective judged at the line, the life comes back.
	_force_objective(r, LegObjectives.NO_SHOULDER)
	var paid_before := _entries("objective_completed").size()
	_cross(r)
	var c4 := _index(["checkpoint_crossed", 4])
	var s4: Dictionary = _log[c4][2]
	check(bool(s4[&"clean"]), "leg 4 clean")
	eq(r.lives.lives, t.lives.lives, "clean leg restores the life")
	eq(_entries("life_restored"), [["life_restored", t.lives.lives]])
	var oc4 := _index(["objective_completed", LegObjectives.NO_SHOULDER], c4)
	check(oc4 > c4, "no-shoulder completes at the line")
	eq(_entries("objective_completed").size(), paid_before + 1)
	check(bool(s4[&"objective_done"]), "summary: done at the line")
	eq(s4[&"objective_points"], t.legs.objective_bonus_points)

	# ---- Leg 5: clean again with full lives: capped at 2.
	_cross(r)
	eq(r.lives.lives, t.lives.lives, "never above 2")
	le(r.lives.lives, 2, "spec: up to the maximum of 2")
	eq(_entries("life_restored").size(), 1, "no restore past the cap")

	# ---- Bonuses paid once; objectives drawn from the seed.
	var objective_bonuses := 0
	for e: Array in _entries("bonus_awarded"):
		if e[1] == LegTracker.BONUS_OBJECTIVE:
			objective_bonuses += 1
	var completions := _entries("objective_completed")
	eq(objective_bonuses, completions.size(), "one objective bonus per completion")
	var crossed := _entries("checkpoint_crossed")
	eq(crossed.size(), LEGS)
	for e: Array in crossed:
		var summary: Dictionary = e[2]
		if bool(summary[&"objective_done"]):
			gt(int(summary[&"objective_points"]), 0, "leg %d: paid" % e[1])
	var started := _entries("leg_started")
	eq(started.size(), LEGS + 1, "legs 1..6 announced")
	var drawn: Array[StringName] = []
	for e: Array in started:
		drawn.append(e[3])
	eq(drawn, _expected_objectives(r.current_seed, LEGS + 1), "objectives come from the seed")
	for i in range(1, drawn.size()):
		ne(drawn[i], drawn[i - 1], "never the same objective twice in a row")
	eq(r.stats.legs_completed, LEGS)


# ---------------------------------------------------------------- Wiring

func test_same_seed_same_objectives_and_retry_redraws() -> void:
	var a := _make()
	a.go()
	_run_ticks(a, TICKS_PER_FRAME)
	var first: StringName = _entries("leg_started")[0][3]
	eq(first, _expected_objectives(a.current_seed, 1)[0])
	eq(a.legs.objective, first, "the tracker holds the leg's objective")
	eq(a.feed.objective, first, "and the HUD feed")
	a.retry()
	_run_ticks(a, TICKS_PER_FRAME)
	var second: StringName = _entries("leg_started")[1][3]
	eq(second, _expected_objectives(a.current_seed, 1)[0], "a retry draws from its own seed")


func test_objective_progress_reaches_the_feed() -> void:
	var r := _make()
	r.go()
	_force_objective(r, LegObjectives.CLOSE_PASSES)
	r.objectives.notify_scored(ScoreEvents.CLOSE_PASS)
	r.objectives.notify_scored(ScoreEvents.CLOSE_PASS)
	_run_ticks(r, TICKS_PER_FRAME)
	eq(r.feed.objective, LegObjectives.CLOSE_PASSES)
	eq(r.feed.objective_progress, 2)
	eq(r.feed.objective_target, t.legs.objective_close_passes_count)
	check(not r.feed.objective_done and not r.feed.objective_failed)
	_force_objective(r, LegObjectives.NO_BRAKING)
	r.objectives.step(t.legs.objective_avoid_grace_s + 0.1, 1.0, 50.0, false, false)
	_run_ticks(r, TICKS_PER_FRAME)
	check(r.feed.objective_failed, "a broken 'no X' shows as failed")


func test_objective_completion_pays_at_night_x2() -> void:
	var r := _make()
	r.go()
	_run_ticks(r, TICKS_PER_FRAME)
	r.sun.sky_t = t.sun.sky_t_night
	r.sun.phase = SunClock.Phase.NIGHT
	_run_ticks(r, TICKS_PER_FRAME)
	_force_objective(r, LegObjectives.TOP_SPEED)
	var banked := r.scoring.banked()
	r.dev_teleport(r.car.state.s + 50.0, Units.kmh_to_mps(t.legs.objective_top_speed_kmh + 5.0))
	_run_ticks(r, TICKS_PER_FRAME * 2)
	var paid := roundi(t.legs.objective_bonus_points * t.scoring.night_factor)
	eq(_entries("objective_completed"), [["objective_completed", LegObjectives.TOP_SPEED, paid]])
	ge(r.scoring.banked() - banked, paid, "straight into the banked total")


func test_adapter_publishes_objective_completed() -> void:
	var adapter := RunEvents.new()
	tree.root.add_child(adapter)
	var buf := ScoreEventBuffer.new(8)
	adapter.add_buffer(buf)
	buf.push(LegObjectives.KIND_OBJECTIVE_COMPLETED, 5000, 0.0, -1.0, -1, 0.0, LegObjectives.THREADS)
	adapter.drain()
	eq(_log, [["objective_completed", LegObjectives.THREADS, 5000]])
	eq(adapter.emitted_last, 1)
	adapter.free()


# ---------------------------------------------------------------- Leg toast (WP5.6)

## Every leg's toast names its biome, in a real run across more legs than the journey
## (the coast is leg 8; legs go on after it), at both text sizes and both units. The
## toast used to drop the place name whenever the footer's objective was long, so most
## legs read just "LEG 4".
func test_every_leg_toast_names_its_biome() -> void:
	var r := _make()
	var hud := r.hud as Hud
	check(hud != null, "the run has its HUD")
	hud.set_screen(Rect2(0.0, 0.0, 1280.0, 720.0), Rect2(0.0, 0.0, 1280.0, 720.0))
	r.infinite_lives = true
	r.go()
	_run_ticks(r, TICKS_PER_FRAME)
	var legs := t.legs.legs_to_coast + 1
	for leg in range(1, legs + 1):
		var started_before := _entries("leg_started").size()
		_cross(r)
		var started := _entries("leg_started")
		eq(started.size(), started_before + 1, "leg %d started once" % (leg + 1))
		var e: Array = started[started.size() - 1]
		eq(e[1], leg + 1)
		var biome: StringName = e[2]
		ne(biome, &"", "leg %d announces a biome" % (leg + 1))
		eq(biome, r.biome_director.biome_at(r.legs.leg_start_s()).id, "the biome where leg %d starts" % (leg + 1))
		var place := Hud.biome_name(biome)
		ne(place, "", "the biome has a display name")
		check(hud.toast_visible(), "leg %d: the toast shows" % leg)
		var want := "LEG %d — %s" % [leg + 1, place]
		check(hud.toast_lines().has(want), "leg %d: %s in %s" % [leg, want, hud.toast_lines()])
		for ts in t.hud.text_scales:
			for units: StringName in [&"kmh", &"mph"]:
				Settings.set_value(&"text_scale", ts)
				Settings.set_value(&"units", units)
				eq(hud.toast_footer()[0], want, "leg %d at text %.2f %s: the drawn footer names the biome (objective %s)"
						% [leg, ts, units, e[3]])
		Settings.reset_to_defaults()
	eq(r.legs.legs_completed, legs, "past the coast")
