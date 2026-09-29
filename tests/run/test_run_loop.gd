extends WBTest
## The loop test mode (N3.2): the run on the multiplayer loop, lap after lap. Spec:
## WESTBOUND_MULTIPLAYER_HANDOFF.md → The loop map ("s wraps modulo L. Every distance
## comparison uses the wrapped signed difference. Floating origin still applies"), Time
## of day in multiplayer, Scoring in multiplayer (sectors); milestone N3 ("the loop drives
## cleanly end-to-end in single-player test mode"). docs/LOOP_MAP.md → Loop test mode.
##
## Headless: the run ticks manually (tick() = one 120 Hz tick, frame() = one frame). A
## weaving bot drives across the seam (s = k L) with traffic, watched tick by tick for
## pops (the car's and every car's position, heading), traffic-to-traffic collisions
## (TrafficRuleChecker), scoring anomalies and the sector crossing at the start / finish
## line. The soak drives three whole laps.

const RUN_SCENE := preload("res://src/run/run.tscn")
const SEED := 20260929
const BOT_SEED := 11
const FRAME_S := 1.0 / 60.0
const TICKS_PER_FRAME := 2
const BOT_SPEED_MPS := 45.0
## The room clock's start in the tests: a fixed UTC second (replayable), at the start of
## a cycle (day).
const CLOCK_START := 1_789_998_720.0   # 932,291 cycles of 32 min after the epoch
## A tick's travel is at most this factor of v dt (world distance vs road distance).
const POP_FACTOR := 1.2
## Heading change per tick at most (rad): the tightest loop bend at bot speed turns
## about 0.0003 rad a tick.
const HEADING_STEP_MAX := 0.01
## PASS / CLOSE / CUT / THREAD events in any one second at most (a seam glitch that
## re-reads the traffic scores dozens at once).
const SCORED_PER_S_MAX := 12

var _runs: Array[Run] = []
var _conns: Array = []
var _log: Array = []
var _reduced: bool


func before_each() -> void:
	_log.clear()
	_reduced = bool(Settings.get_value(&"reduced_motion"))
	Settings.set_value(&"reduced_motion", true)
	_listen(Events.scored, func(k: StringName, p: int, _m: float, _c: float) -> void: _log.append(["scored", k, p]))
	_listen(Events.checkpoint_crossed, func(leg: int, sm: Dictionary) -> void: _log.append(["checkpoint_crossed", leg, sm]))
	_listen(Events.chain_banked, func(p: int, _r: StringName, _m: int) -> void: _log.append(["banked", p]))
	_listen(Events.bonus_awarded, func(k: StringName, p: int, _t: int) -> void: _log.append(["bonus", k, p]))
	_listen(Events.night_started, func() -> void: _log.append(["night"]))
	_listen(Events.morning_reached, func() -> void: _log.append(["morning"]))
	_listen(Events.sun_lifted, func(_v: float) -> void: _log.append(["sun_lifted"]))
	_listen(Events.coast_reached, func() -> void: _log.append(["coast"]))
	_listen(Events.fork_announced, func(_a: StringName, _b: StringName) -> void: _log.append(["fork"]))


func after_each() -> void:
	for c: Array in _conns:
		(c[0] as Signal).disconnect(c[1])
	_conns.clear()
	tree.paused = false
	for r in _runs:
		r.queue_free()
	_runs.clear()
	await tree.process_frame
	Settings.set_value(&"reduced_motion", _reduced)


func _listen(sig: Signal, fn: Callable) -> void:
	sig.connect(fn)
	_conns.append([sig, fn])


func _make(clock_start: float = CLOCK_START, run_seed: int = SEED) -> Run:
	var r := RUN_SCENE.instantiate() as Run
	r.run_seed = run_seed
	r.manual_ticks = true
	r.crash_cinematic = false
	r.record_best = false
	r.mode = Run.MODE_LOOP
	r.loop = RunLoop.new()
	r.loop.clock_start_unix_s = clock_start
	tree.root.add_child(r)
	_runs.append(r)
	return r


func _bot(r: Run) -> SandboxBot:
	var bot := SandboxBot.new(r.road, r.sim.state, r.car.params, BOT_SEED)
	bot.mode = SandboxBot.Mode.WEAVE
	bot.v_target = BOT_SPEED_MPS
	bot.length_m = r.car.car.length_m
	bot.width_m = r.car.car.width_m
	r.drive_controller = bot
	return bot


## The car `before_m` before the end of lap `lap` (the seam into lap + 1), driving.
func _to_seam(r: Run, lap: int, before_m: float) -> void:
	var s := float(lap + 1) * _len(r) - before_m
	r.dev_teleport(s, BOT_SPEED_MPS)
	r.legs.skip_to(s)
	_bot(r)
	if r.state == Game.COUNTDOWN:
		r.go()


func _len(r: Run) -> float:
	return (r.road as LoopRoadPath).length()


func _run_ticks(r: Run, n: int) -> void:
	for i in n:
		r.tick()
		if i % TICKS_PER_FRAME == TICKS_PER_FRAME - 1:
			r.frame(FRAME_S)


func _ticks_for(seconds: float) -> int:
	return roundi(seconds * float(Tuning.load_default().vehicle.physics_tick_hz))


func _count(name: String) -> int:
	var n := 0
	for e: Array in _log:
		if e[0] == name:
			n += 1
	return n


## Watches the car and traffic tick by tick for `ticks` ticks: no pop (road-space and
## world continuity, heading), no traffic collision, bounded scoring. Returns the
## checker.
func _drive_watched(r: Run, ticks: int) -> TrafficRuleChecker:
	var t := Tuning.load_default()
	var checker := TrafficRuleChecker.new(t, r.registry, r.road, r.car.car.length_m, r.car.car.width_m)
	var dt := t.vehicle.physics_dt()
	var smp := RoadSample.new()
	var prev_s := r.car.state.s
	r.road.sample_into(prev_s, smp)
	var prev_x := smp.pos_x
	var prev_y := smp.pos_y
	var prev_z := smp.pos_z
	var prev_h := smp.heading
	var ts := r.sim.state
	var prev_id := ts.vehicle_id.duplicate()
	var prev_ts := ts.s.duplicate()
	var pops := 0
	var traffic_pops := 0
	var worst_step := 0.0
	var scored_at := PackedInt32Array()
	var logged := _log.size()
	for i in ticks:
		r.tick()
		if i % TICKS_PER_FRAME == TICKS_PER_FRAME - 1:
			r.frame(FRAME_S)
		var st := r.car.state
		checker.observe(float(i) * dt, ts, st)
		var ds := st.s - prev_s
		r.road.sample_into(st.s, smp)
		var step := sqrt(pow(smp.pos_x - prev_x, 2.0) + pow(smp.pos_y - prev_y, 2.0) + pow(smp.pos_z - prev_z, 2.0))
		worst_step = maxf(worst_step, step)
		if ds < 0.0 or step > maxf(ds, 0.0) * POP_FACTOR + 1e-6 or absf(smp.heading - prev_h) > HEADING_STEP_MAX:
			pops += 1
		prev_s = st.s
		prev_x = smp.pos_x
		prev_y = smp.pos_y
		prev_z = smp.pos_z
		prev_h = smp.heading
		for k in ts.capacity:
			if ts.active[k] != 0 and ts.vehicle_id[k] == prev_id[k]:
				if absf(ts.s[k] - prev_ts[k]) > maxf(ts.v[k], 1.0) * dt * POP_FACTOR + 0.05:
					traffic_pops += 1
			prev_id[k] = ts.vehicle_id[k] if ts.active[k] != 0 else -1
			prev_ts[k] = ts.s[k]
		if i % TICKS_PER_FRAME == TICKS_PER_FRAME - 1:
			var n := 0
			for j in range(logged, _log.size()):
				if _log[j][0] == "scored":
					n += 1
			logged = _log.size()
			scored_at.append(n)
	eq(pops, 0, "the car never pops (road-space step %.3f m worst)" % worst_step)
	eq(traffic_pops, 0, "no traffic car jumps")
	eq(checker.collision_pairs, 0, "no traffic-to-traffic collisions: %s" % checker.summary())
	var frames_per_s := roundi(1.0 / FRAME_S)
	var worst := 0
	for a in range(0, scored_at.size()):
		var sum := 0
		for b in range(a, mini(a + frames_per_s, scored_at.size())):
			sum += scored_at[b]
		worst = maxi(worst, sum)
	le(worst, SCORED_PER_S_MAX, "scoring events in any second")
	return checker


# ---------------------------------------------------------------- Setup

func test_loop_mode_runs_on_the_loop() -> void:
	var r := _make()
	check(r.road is LoopRoadPath, "the loop's road")
	check(r.is_loop())
	var L := _len(r)
	near(L, 25000.0, 1e-6, "loop_v1 is 25 km")
	var lr := r.road as LoopRoadPath
	near(r.car.state.s, L + lr.layout.spawn_s[0], 1e-9, "lap 1, the first spawn point past the start line")
	eq(lr.lap_of(r.car.state.s), 1)
	check(r.biome_director.plan.period_legs == lr.section_count(), "a periodic look plan")
	eq(r.biome_director.biome_at(L * 7.0 + 17000.0).id, &"city", "any lap: the city")
	check(r.adapter.forks == null, "no forks in loop mode")
	eq(r.legs.objective, &"", "sectors have no objective")
	eq(r.director.leg, r.loop.tuning.director_leg, "the director drives the loop's leg")
	check(r.features.elevated.plan.zone_s0.size() == 1, "the loop's elevated zone")
	gt(r.features.elevated.ground_drop_at(L + (lr.layout.elevated_s0[0] + lr.layout.elevated_s1[0]) * 0.5), 1.0,
		"the city is elevated in lap 1")
	gt(r.features.elevated.ground_drop_at(L * 4.0 + (lr.layout.elevated_s0[0] + lr.layout.elevated_s1[0]) * 0.5), 1.0,
		"and in lap 4")
	eq(r.features.elevated.ground_drop_at(L + 2000.0), 0.0, "not in the desert")
	_run_ticks(r, _ticks_for(1.0))
	check(r.loop.feed.active, "the HUD's loop feed is filled")
	gt(r.loop.feed.sector_distance_m, 0.0, "the next sector gantry is planned")
	eq(r.loop.feed.lap, 1)
	eq(r.loop.feed.sector, 1)
	# The run's tuning is a copy: the shared tuning is untouched.
	check(r.ctx.tuning != Tuning.load_default(), "loop mode runs on its own tuning copy")
	eq(Tuning.load_default().legs.legs_to_coast, 8, "the shared legs tuning is untouched")


func test_single_player_is_unchanged_after_a_loop_run() -> void:
	var r := _make()
	var journey_flow := Tuning.load_default().traffic.lane_flow_speeds_from_right_kmh.duplicate()
	_to_seam(r, 1, 5500.0)   # the city
	_run_ticks(r, _ticks_for(1.0))
	eq(Tuning.load_default().traffic.lane_flow_speeds_from_right_kmh, journey_flow, "the shared traffic tuning is untouched")
	r.dev_toggle_loop()
	check(not r.is_loop())
	check(r.road is ProceduralRoadPath, "the journey's road again")
	check(r.loop == null)
	check(r.forks.plan != null and r.adapter.forks == r.forks, "forks are back")
	near(r.car.state.s, Tuning.load_default().road.roadside_behind_m, 1e-9)
	_run_ticks(r, _ticks_for(4.0))
	check(r.state == Game.RUNNING)


# ---------------------------------------------------------------- The seam

func test_crossing_the_seam_is_clean() -> void:
	var r := _make()
	_to_seam(r, 1, 250.0)
	var L := _len(r)
	var lr := r.road as LoopRoadPath
	var chunk := Tuning.load_default().road.chunk_length_m
	var sectors_before := r.legs.legs_completed
	_drive_watched(r, _ticks_for(12.0))
	gt(r.car.state.s, 2.0 * L + 150.0, "across the seam (unwrapped s)")
	eq(lr.lap_of(r.car.state.s), 2, "lap 2")
	eq(r.legs.legs_completed, sectors_before + 1, "the start / finish gantry was crossed once")
	eq(_count("checkpoint_crossed"), 1)
	eq(_count("sun_lifted"), 0, "no sun meter")
	eq(_count("coast"), 0, "never the coast")
	eq(_count("fork"), 0, "no forks")
	var last: Array = _log.filter(func(e: Array) -> bool: return e[0] == "checkpoint_crossed")[0]
	eq(int(last[1]), 2 * lr.layout.sector_s.size() + 1, "lap 2's gantry 0 (lap x sectors + 1)")
	check(r.builder.has_chunk(floori(r.car.state.s / chunk)), "the road is built under the car past the seam")
	check(r.builder.has_chunk(floori((r.car.state.s + 400.0) / chunk)), "and ahead of it")
	gt(r.sim.state.count, 10, "traffic stays alive across the seam")
	eq(r.loop.feed.lap, 2)


func test_lap_after_lap() -> void:
	var r := _make()
	var lr := r.road as LoopRoadPath
	var scored := 0
	for lap: int in [1, 2, 3]:
		_to_seam(r, lap, 120.0)
		var before := r.legs.legs_completed
		_drive_watched(r, _ticks_for(4.0))
		eq(lr.lap_of(r.car.state.s), lap + 1, "into lap %d" % (lap + 1))
		eq(r.legs.legs_completed, before + 1, "gantry 0 of lap %d crossed" % (lap + 1))
		var smp := r.road.sample(r.car.state.s)
		var first := r.road.sample(r.car.state.s - float(lap) * _len(r))
		near(smp.pos_x, first.pos_x, 1e-6, "the same ground every lap")
		near(smp.pos_z, first.pos_z, 1e-6)
		eq(r.road.lane_count(r.car.state.s), r.road.lane_count(r.car.state.s + _len(r)))
	scored = _count("scored")
	gt(scored, 0, "the bot scored along the way")
	eq(_count("checkpoint_crossed"), 3)


func test_floating_origin_follows_across_laps() -> void:
	var r := _make()
	_to_seam(r, 3, 200.0)
	_run_ticks(r, _ticks_for(6.0))
	var smp := r.road.sample(r.car.state.s)
	var shift := Tuning.load_default().road.floating_origin_shift_km * Units.M_PER_KM
	le(absf(smp.pos_x - r.origin.origin_x), shift, "the origin stays near the car (x)")
	le(absf(smp.pos_z - r.origin.origin_z), shift, "(z)")
	var local := r.car.visual.global_position
	le(Vector2(local.x, local.z).length(), shift + 50.0, "the car renders near the origin")


func test_loop_runs_are_deterministic() -> void:
	var hashes: Array = []
	for pass_i in 2:
		var r := _make()
		_to_seam(r, 1, 200.0)
		var trace := PackedInt64Array()
		for k in 8:
			_run_ticks(r, _ticks_for(1.0))
			trace.append(r.trace_hash())
		hashes.append(trace)
		r.queue_free()
		_runs.erase(r)
		await tree.process_frame
	eq(hashes[0], hashes[1], "identical traces across the seam")


# ---------------------------------------------------------------- Sectors, clock, traffic

func test_sector_gantry_banks_and_pays() -> void:
	var r := _make()
	var lr := r.road as LoopRoadPath
	var gantry := _len(r) + lr.layout.sector_s[1]
	r.dev_teleport(gantry - 300.0, BOT_SPEED_MPS)
	r.legs.skip_to(gantry - 300.0)
	_bot(r)
	r.go()
	_run_ticks(r, _ticks_for(10.0))
	eq(_count("checkpoint_crossed"), 1, "sector 1's gantry")
	var e: Array = _log.filter(func(x: Array) -> bool: return x[0] == "checkpoint_crossed")[0]
	eq(int(e[1]), lr.layout.sector_s.size() + 2, "lap 1, gantry 1")
	var sm: Dictionary = e[2]
	eq(sm.get(RunEvents.SUMMARY_COAST), false)
	eq(sm.get(RunEvents.SUMMARY_OBJECTIVE_POINTS), 0, "no objective")
	eq(_count("sun_lifted"), 0, "no sun lift")
	gt(_count("bonus"), 0, "a sector bonus (clean at least)")
	eq(r.legs.coast_reached, false)


func test_room_clock_drives_the_sky_and_night_x2() -> void:
	var loop_t := LoopTuning.load_default()
	var r := _make(CLOCK_START + loop_t.room_day_s() - 2.0)
	check(not r.sun.is_night(), "day")
	_to_seam(r, 1, 4000.0)
	var sky0 := r.sun.sky_t
	near(sky0, Tuning.load_default().sun.sky_t_sunset, 0.01, "just before sunset")
	_run_ticks(r, _ticks_for(4.0))
	check(r.sun.is_night(), "night from the room clock")
	check(r.scoring.is_night(), "night ×2 in scoring")
	eq(_count("night"), 1, "night_started once")
	check(r.loop.feed.night)
	near(r.loop.feed.flip_in_s, loop_t.room_cycle_s() - loop_t.room_day_s() - 2.0, 0.1, "time until the day")


func test_traffic_follows_the_sections() -> void:
	var r := _make()
	var lr := r.road as LoopRoadPath
	var loop_t := r.loop.tuning
	_to_seam(r, 1, _len(r) - (lr.section_start(3) + 800.0))   # the city, lap 1
	_run_ticks(r, _ticks_for(1.0))
	eq(r.loop.section, 3, "the city")
	eq(r.ctx.tuning.traffic.lane_flow_speeds_from_right_kmh, lr.def.sections[3].lane_flow_speeds_from_right_kmh,
		"the city's flow speeds")
	near(r.director.target_density_per_km_lane(), loop_t.density_per_km_lane * loop_t.section_density_frac(3), 1e-9,
		"normal density x the city's share")
	check(not r.ctx.tuning.director.set_piece_unlock_order.has(&"merge_zone"), "no lane-reshaping set pieces")
	_to_seam(r, 1, _len(r) - (lr.section_start(1) + 500.0))
	_run_ticks(r, _ticks_for(1.0))
	eq(r.loop.section, 1, "the canyon")
	eq(r.ctx.tuning.traffic.lane_flow_speeds_from_right_kmh, lr.def.sections[1].lane_flow_speeds_from_right_kmh)
	near(r.director.target_density_per_km_lane(), loop_t.density_per_km_lane * loop_t.section_density_frac(1), 1e-9)


func test_loop_ticks_create_no_objects() -> void:
	var r := _make()
	_to_seam(r, 1, 1500.0)
	_run_ticks(r, _ticks_for(2.0))
	var before := Performance.get_monitor(Performance.OBJECT_COUNT)
	for i in 120:
		r.tick()
	var after := Performance.get_monitor(Performance.OBJECT_COUNT)
	le(after - before, 0.0, "a second of loop-mode ticks (clock, sections) allocates no objects")


## Frame cost at the loop's busiest spot (the city, normal density x 1.3, 4 lanes): the
## run's 120 Hz tick and its per-frame update (world nodes, views, HUD feed). Budgets
## are ~3x a local median (WBBench) and far inside the 8.3 ms tick / 16.7 ms frame.
func test_city_frame_cost() -> void:
	var r := _make()
	_to_seam(r, 1, _len(r) - (r.road as LoopRoadPath).layout.elevated_s0[0] - 600.0)
	r.infinite_lives = true
	_run_ticks(r, _ticks_for(4.0))
	eq(r.loop.section, 3, "in the city")
	var tick_us := WBBench.usec_per_call(r.tick, 24, 24, 5)
	var frame_us := WBBench.usec_per_call(r.frame.bind(FRAME_S), 12, 12, 5)
	WBBench.report("loop city: run tick (%d vehicles)" % r.sim.state.count, tick_us, 3000.0)
	WBBench.report("loop city: run frame", frame_us, 12000.0)
	le(tick_us, WBBench.budget(3000.0), "run tick usec")
	le(frame_us, WBBench.budget(12000.0), "run frame usec")


# ---------------------------------------------------------------- Soak

## Three whole laps (75 km) with a weaving bot and traffic, twice: no pop, no traffic
## collision, bounded scoring, a crossing at every gantry, identical traces.
func soak_three_laps_with_traffic() -> void:
	var traces: Array = []
	for pass_i in 2:
		_log.clear()
		var r := _make()
		_bot(r)
		r.infinite_lives = true
		r.go()
		var lr := r.road as LoopRoadPath
		var laps := 3
		var target := r.car.state.s + float(laps) * _len(r)
		var trace := PackedInt64Array()
		var checker := TrafficRuleChecker.new(Tuning.load_default(), r.registry, r.road, r.car.car.length_m, r.car.car.width_m)
		while r.car.state.s < target:
			var c := _drive_watched(r, _ticks_for(60.0))
			checker.collision_pairs += c.collision_pairs
			trace.append(r.trace_hash())
		eq(checker.collision_pairs, 0, "no traffic-to-traffic collisions in 3 laps")
		eq(_count("checkpoint_crossed"), laps * lr.layout.sector_s.size(), "every gantry, every lap")
		eq(lr.lap_of(r.car.state.s), 1 + laps)
		print("  soak: 3 laps, %d hits, banked %d, %d vehicles at the end" % [r.lives.hits, r.scoring.banked(), r.sim.state.count])
		traces.append(trace)
		r.queue_free()
		_runs.erase(r)
		await tree.process_frame
	eq(traces[0], traces[1], "three laps replay exactly")
