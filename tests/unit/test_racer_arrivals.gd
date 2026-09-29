extends WBTest
## Racers from behind (plan D17, WP6.7; owner: "Yes, pass me at speed"). Spec: Traffic →
## Spawning ("Behind: faster vehicles spawn about 150 m behind in the left lanes, only
## when the player is slower than them and the spawn point is outside the camera
## frustum"), Driver types (Aggressive "passes the player from behind"), Fairness rules
## (telegraphing, no ambush, rule 4's clamp, rule 5), Lives → rear-end prevention;
## Traffic director (intensity waves: no arrivals in breathers). TrafficDirector's
## arrival process with the real TrafficSim and TrafficRuleChecker. Design and measured
## numbers: docs/SPAWNING.md, "Racers from behind (WP6.7)".

const SEED := 670701
const DT := 1.0 / 120.0
const SPEEDS_KMH: Array[float] = [170.0, 200.0, 230.0]
## On a road without other traffic an arrival passes within this: the longest leg-1
## interval (40 s) plus the slowest pass (a 245 km/h racer closing 150 m on a 230 km/h
## player, ~36 s), at 230 km/h ~4.9 km, and a wave breather in between.
const PASS_WITHIN_KM := 7.0
## The player's braking in the rear-end tests: "a player driving normally" brakes at no
## more than the traffic's own clamp (TrafficRuleChecker's rear_end_normal rule).
const PLAYER_BRAKE_MPS2 := 6.0
const BRAKE_TO_KMH := 120.0
const WORST_KMH := 250.0
const WORST_PLAYER_KMH := 170.0
## The rate test's drive at 170 km/h (~200 s).
const RATE_KM := 9.5
## Determinism runs: the soak's run at leg 6, this far.
const DETERMINISM_M := 800.0

var tuning: Tuning
var registry: TrafficRegistry
var _scene: Node3D


class World:
	extends RefCounted
	var road: StraightRoadPath
	var run: RunContext
	var sim: TrafficSim
	var dir: TrafficDirector
	var player := VehicleState.new()
	var checker: TrafficRuleChecker
	var events: ScoreEventBuffer
	var time := 0.0
	var seen := 0
	## Per arrival, at its spawn tick: s relative to the player, v0 - player v, spawn
	## speed, lane, the wave phase at the player, whether it was in view.
	var rel := PackedFloat64Array()
	var v0_margin := PackedFloat64Array()
	var v_spawn := PackedFloat64Array()
	var lane := PackedInt32Array()
	var phase := PackedInt32Array()
	var visible := 0
	var in_player_lane := 0
	var min_racer_accel := 0.0


func before_all() -> void:
	tuning = Tuning.load_default()
	registry = TrafficRegistry.load_default(tuning.traffic)


func after_each() -> void:
	if _scene != null:
		_scene.queue_free()
		await tree.process_frame
		_scene = null


## A straight road with `lanes`, the real sim and director at `leg`, the player in
## `lane` at `kmh`. `empty`: the director's density scale is 0 and wave peaks get no
## set pieces, so the arrivals are the only traffic.
func _world(lanes: int, leg: int, kmh: float, lane: int, empty: bool = true, seed_value: int = SEED,
		t: Tuning = null) -> World:
	var tun := t if t != null else tuning
	var w := World.new()
	w.road = StraightRoadPath.new(lanes, tun.road)
	w.run = RunContext.new(seed_value, RunContext.MODE_JOURNEY, tun)
	var reg := registry if t == null else TrafficRegistry.load_default(tun.traffic)
	w.sim = TrafficSim.new(w.run, w.road, reg)
	w.sim.set_player_body(tun.traffic.player_length_m, tun.traffic.player_width_m)
	w.dir = TrafficDirector.new(w.run, w.road, w.sim, reg.profiles, reg.types, tun.traffic.player_length_m,
		tun.traffic.player_width_m)
	w.checker = TrafficRuleChecker.new(tun, reg, w.road, tun.traffic.player_length_m, tun.traffic.player_width_m)
	w.events = ScoreEventBuffer.new(tun.scoring.event_buffer_capacity)
	w.player.s = 0.0
	w.player.d = w.road.lane_center_d(lane, 0.0)
	w.player.v = Units.kmh_to_mps(kmh)
	w.dir.set_leg(leg, 0.0)
	if empty:
		w.dir.set_density_scale(0.0)
		w.dir.set_pieces_enabled = false
	w.dir.reset(w.player)
	return w


## One tick: the player holds its speed (or brakes at `brake` m/s^2 down to `floor_v`),
## then the sim, the rule checker and the director; new arrivals are logged.
func _tick(w: World, brake: float = 0.0, floor_v: float = 0.0) -> void:
	var p := w.player
	p.accel_long = 0.0
	if brake > 0.0 and p.v > floor_v:
		p.accel_long = -brake
		p.v = maxf(p.v - brake * DT, floor_v)
	p.s += p.v * DT
	w.sim.step(DT, p, null, w.events)
	w.events.clear()
	w.checker.observe(w.time, w.sim.state, p)
	w.dir.step(DT, p)
	w.time += DT
	var st := w.sim.state
	var racer := w.dir.flow.racer_profile()
	for i in st.capacity:
		if st.active[i] == 1 and st.profile_id[i] == racer:
			w.min_racer_accel = minf(w.min_racer_accel, st.accel[i])
	if w.dir.racer_arrivals == w.seen:
		return
	w.seen = w.dir.racer_arrivals
	var i := w.dir.last_arrival_slot
	w.rel.append(st.s[i] - p.s)
	w.v0_margin.append(st.v0[i] - p.v)
	w.v_spawn.append(st.v[i])
	w.lane.append(st.lane[i])
	w.phase.append(int(w.dir.waves.phase_at(p.s)))
	if w.dir.is_visible(st.s[i], st.d[i]):
		w.visible += 1
	if absf(st.d[i] - p.d) < w.road.lane_width(p.s) * 0.5:
		w.in_player_lane += 1


func _drive_until(w: World, max_m: float, stop: Callable) -> void:
	var end := w.player.s + max_m
	while w.player.s < end:
		_tick(w)
		if stop.call():
			return


## Every rule the soak gates, zero.
func _legal(w: World, what: String) -> void:
	var c := w.checker
	eq(c.collision_pairs, 0, "%s: collisions" % what)
	eq(c.signal_violations, 0, "%s: signal time" % what)
	eq(c.unsignaled_moves, 0, "%s: unsignaled moves" % what)
	eq(c.ambush_violations, 0, "%s: no-ambush" % what)
	eq(c.decel_violations, 0, "%s: decel clamp" % what)
	eq(c.brake_flag_violations, 0, "%s: brake lights" % what)
	eq(c.rear_end_normal, 0, "%s: rear-end of a normally driving player" % what)
	eq(c.offroad_violations, 0, "%s: off-road" % what)


## Each arrival: out of view, behind by racer_arrival_behind_min_m..spawn_behind_m, its
## desired speed at least the margin above the player's, spawned at least that fast, and
## never in a wave breather.
func _arrivals_ok(w: World, what: String) -> void:
	var margin := Units.kmh_to_mps(tuning.director.racer_arrival_speed_margin_kmh)
	eq(w.visible, 0, "%s: never spawned in view" % what)
	for k in w.rel.size():
		le(w.rel[k], -tuning.director.racer_arrival_behind_min_m + 1.0, "%s: behind the player" % what)
		ge(w.rel[k], -tuning.traffic.spawn_behind_m - 1.0, "%s: about 150 m back" % what)
		lt(w.rel[k], -tuning.director.behind_spawn_view_margin_m, "%s: beyond the view volume" % what)
		ge(w.v0_margin[k], margin - 1e-6, "%s: its own speed beats the player's by the margin" % what)
		ne(w.phase[k], int(IntensityWaves.Phase.BREATHER), "%s: not in a breather" % what)


# ---------------------------------------------------------------- Arrive and pass

## At 170, 200 and 230 km/h on every leg, a racer arrives from behind and gets past the
## player within PASS_WITHIN_KM (the road has no other traffic: the process alone).
func _arrive_and_pass(kmh: float) -> void:
	for leg in range(1, tuning.director.ramp_last_leg + 1):
		var w := _world(3, leg, kmh, 1)
		_drive_until(w, PASS_WITHIN_KM * Units.M_PER_KM, func() -> bool: return w.dir.arrivals_passed_player > 0)
		var what := "leg %d at %.0f km/h" % [leg, kmh]
		ge(w.dir.racer_arrivals, 1, "%s: an arrival" % what)
		ge(w.dir.arrivals_passed_player, 1, "%s: it passed the player within %.0f km" % [what, PASS_WITHIN_KM])
		ge(w.dir.racers_passed_player + (w.dir.arrivals_passed_player - w.dir.racers_passed_player), 1)
		eq(w.in_player_lane, 0, "%s: in a lane beside the player" % what)
		_arrivals_ok(w, what)
		_legal(w, what)
		print("      %s: passed after %.2f km (%d arrivals)" % [what, w.player.s / Units.M_PER_KM, w.dir.racer_arrivals])


func test_racers_arrive_and_pass_a_170_kmh_player_on_every_leg() -> void:
	_arrive_and_pass(SPEEDS_KMH[0])


func test_racers_arrive_and_pass_a_200_kmh_player_on_every_leg() -> void:
	_arrive_and_pass(SPEEDS_KMH[1])


func test_racers_arrive_and_pass_a_230_kmh_player_on_every_leg() -> void:
	_arrive_and_pass(SPEEDS_KMH[2])


## The rate: the arrival clock runs at the wave's multiplier outside breathers and
## draws racer_arrival_interval_s(leg); late legs get more arrivals.
func test_arrival_rate_follows_the_leg() -> void:
	var counts := PackedInt32Array()
	for leg: int in [1, tuning.director.ramp_last_leg]:
		var w := _world(3, leg, 170.0, 2)
		var clock := 0.0
		var dist := RATE_KM * Units.M_PER_KM
		while w.player.s < dist:
			_tick(w)
			if w.dir.waves.phase_at(w.player.s) != IntensityWaves.Phase.BREATHER:
				clock += DT * w.dir.waves.mult_at(w.player.s)
		var lo := tuning.director.racer_arrival_interval_s(leg, 0.0)
		var hi := tuning.director.racer_arrival_interval_s(leg, 1.0)
		var expected := clock / ((lo + hi) * 0.5)
		print("      leg %d: %d arrivals in %.0f km at 170 km/h (clock %.0f s, %.1f expected at the mean interval)" % [
			leg, w.dir.racer_arrivals, RATE_KM, clock, expected])
		ge(float(w.dir.racer_arrivals), floorf(clock / hi), "leg %d: at least one per longest interval" % leg)
		le(float(w.dir.racer_arrivals), ceilf(clock / lo), "leg %d: at most one per shortest interval" % leg)
		_arrivals_ok(w, "leg %d" % leg)
		_legal(w, "leg %d" % leg)
		counts.append(w.dir.racer_arrivals)
	gt(counts[1], counts[0], "late legs: more arrivals")


func test_interval_ramps_by_leg() -> void:
	var d := tuning.director
	near(d.racer_arrival_interval_s(1, 0.0), d.racer_arrival_interval_first_min_s, 1e-9)
	near(d.racer_arrival_interval_s(1, 1.0), d.racer_arrival_interval_first_max_s, 1e-9)
	near(d.racer_arrival_interval_s(d.ramp_last_leg, 0.0), d.racer_arrival_interval_last_min_s, 1e-9)
	near(d.racer_arrival_interval_s(d.ramp_last_leg + 3, 1.0), d.racer_arrival_interval_last_max_s, 1e-9)
	lt(d.racer_arrival_interval_s(d.ramp_last_leg, 0.5), d.racer_arrival_interval_s(1, 0.5), "more often later")


## Flow.max_speed_behind inverts s*: at the speed it returns the IDM gap (closing term
## included) is exactly the spacing; Flow.braking_spacing is the comfortable stop.
func test_spawn_speed_keeps_the_idm_gap() -> void:
	var w := _world(3, 8, 200.0, 1)
	var f := w.dir.flow
	var p := f.racer_profile()
	var ln := 4.5
	for spacing: float in [60.0, 150.0, 300.0]:
		for vl_kmh: float in [95.0, 145.0, 230.0]:
			var vl := Units.kmh_to_mps(vl_kmh)
			var v := f.max_speed_behind(p, ln, spacing, vl, ln)
			gt(v, 0.0)
			near(f.min_spacing(p, v, ln, vl, ln), spacing, 1e-6, "s* at %.0f m behind %.0f km/h" % [spacing, vl_kmh])
	lt(f.max_speed_behind(p, ln, ln * 0.5, 0.0, ln), 0.0, "no room at all")
	var racer := registry.profiles[p]
	var b := f.braking_spacing(p, ln, 50.0, 40.0, ln)
	near(b, ln + racer.idm_s0_m + 40.0 * racer.idm_headway_s * f.headway_scale
		+ (50.0 * 50.0 - 40.0 * 40.0) / (2.0 * racer.idm_b_comfort_mps2), 1e-9)


## Arrivals need their own speed above the player's: a player faster than every racer
## (and every aggressive driver) plus the margin gets none.
func test_no_arrival_for_a_player_faster_than_any_racer() -> void:
	var top := 0.0
	for p in registry.profiles:
		top = maxf(top, p.desired_speed_max_mps())
	var w := _world(3, 8, Units.mps_to_kmh(top) - tuning.director.racer_arrival_speed_margin_kmh + 1.0, 1)
	for k in 30:
		w.dir.force_racer_arrival()
		for n in 120:
			_tick(w)
	eq(w.dir.racer_arrivals, 0, "nothing is fast enough to pass it")


# ---------------------------------------------------------------- Breathers, forks, set pieces

## Requested breathers (WP6.5: a fork's approach, the journey finale) within
## racer_arrival_clear_ahead_m block arrivals; once cleared, a due arrival comes.
func test_no_arrival_near_a_requested_breather() -> void:
	var w := _world(3, 4, 200.0, 2)
	var clear := tuning.director.racer_arrival_clear_ahead_m
	var s0 := clear * 0.5
	w.dir.request_breather(s0, s0 + clear)
	# Until the spawn point is past the breather's end, the window overlaps it.
	while w.player.s - tuning.traffic.spawn_behind_m < s0 + clear - w.player.v:
		w.dir.force_racer_arrival()
		_tick(w)
	eq(w.dir.racer_arrivals, 0, "no arrival while a fork or finale breather is within reach")
	w.dir.clear_breathers()
	for k in 60 * 120:
		w.dir.force_racer_arrival()
		_tick(w)
		if w.dir.racer_arrivals > 0:
			break
	eq(w.dir.racer_arrivals, 1, "arrivals resume after the breather")


## A live (scheduled or running) set piece within reach blocks arrivals: a racer would
## drive into it.
func test_no_arrival_near_a_set_piece() -> void:
	var w := _world(3, 4, 200.0, 2)
	var def: SetPieceDef = w.dir.set_pieces.defs.get(tuning.director.set_piece_unlock_order[0])
	check(def != null, "a set-piece definition")
	var inst := w.dir.set_pieces.schedule(def, w.player.s + tuning.director.racer_arrival_clear_ahead_m * 0.5, 3,
		def.speed_mps(w.dir.set_pieces.min_speed_mps))
	check(inst != null, "scheduled")
	for k in 600:
		w.dir.force_racer_arrival()
		_tick(w)
	eq(w.dir.racer_arrivals, 0, "no arrival toward a live set piece")


## Wave breathers (and the checkpoint breather) get no arrivals; every arrival over a
## journey's legs came outside them, and the player spent time in breathers.
func test_no_arrival_in_wave_breathers() -> void:
	var w := _world(3, 8, 180.0, 2)
	var breather_s := 0.0
	var dist := 3.0 * tuning.legs.leg_length_m()
	while w.player.s < dist:
		_tick(w)
		if w.dir.waves.phase_at(w.player.s) == IntensityWaves.Phase.BREATHER:
			breather_s += DT
			w.dir.force_racer_arrival()   # due all the time: still none
	gt(breather_s, 10.0, "the player drove through breathers")
	gt(w.dir.racer_arrivals, 3)
	_arrivals_ok(w, "three legs")


# ---------------------------------------------------------------- Lanes and the view

## Racers use their left lanes, never the rightmost; on a two-lane road with the player
## in the left lane the arrival comes up in the player's lane, keeping IDM's s* to it
## (no hard braking), then pulls out with its blinker and passes.
func test_arrival_lanes_and_pulling_out() -> void:
	var w := _world(3, 1, 200.0, 1)
	for k in 4:
		w.dir.force_racer_arrival()
		_drive_until(w, 3000.0, func() -> bool: return w.dir.racer_arrivals > k)
	var racer_left := registry.profiles[registry.profile_index(tuning.traffic.spawn_racer_profile_id)].spawn_left_lane_count
	eq(w.lane.size(), 4)
	eq(w.lane[0], 0, "the leftmost lane first (beside the player)")
	for k in w.lane.size():
		lt(w.lane[k], mini(racer_left, 2), "left lanes, never the rightmost")

	var w2 := _world(2, 1, 170.0, 0)
	w2.dir.racer_arrivals_enabled = true
	var signals0 := w2.sim.stat_signals
	w2.dir.force_racer_arrival()
	_drive_until(w2, 6000.0, func() -> bool: return w2.dir.arrivals_passed_player > 0)
	ge(w2.dir.racer_arrivals, 1)
	eq(w2.in_player_lane, w2.dir.racer_arrivals, "two lanes: only the player's lane is a racer lane")
	ge(w2.dir.arrivals_passed_player, 1, "it pulled out and passed")
	gt(w2.sim.stat_signals, signals0, "with its blinker")
	var racer := registry.profiles[registry.profile_index(tuning.traffic.spawn_racer_profile_id)]
	print("      two lanes: the arrival came up behind the player; its hardest braking %.2f m/s^2" % w2.min_racer_accel)
	ge(w2.min_racer_accel, -racer.idm_b_comfort_mps2, "coming up behind the player: comfortable braking only")
	_arrivals_ok(w2, "two lanes")
	_legal(w2, "two lanes")


# ---------------------------------------------------------------- Rear-end prevention

## Lives → rear-end prevention with the player as the leader, at the worst closing speed
## (a 250 km/h racer on a 170 km/h player; the sim's IDM looks idm_lookahead_m ahead):
## the racer starts in the player's lane at spawn_behind_m (what the arrival process
## never does, but a player's lane change can) or further back, and the player brakes
## to BRAKE_TO_KMH at PLAYER_BRAKE_MPS2 at different moments. No contact, and the
## racer never brakes beyond the 6 m/s^2 clamp.
func test_rear_end_prevention_racer_closing_at_250_on_a_braking_player() -> void:
	var worst_gap := INF
	var worst_accel := 0.0
	for back: float in [tuning.traffic.spawn_behind_m, 300.0, tuning.traffic.idm_lookahead_m]:
		for brake_at: float in [0.0, 2.0, 4.0, 6.0, 9.0, 14.0]:
			var w := _world(2, 8, WORST_PLAYER_KMH, 0)
			w.dir.racer_arrivals_enabled = false
			var slot := _place_racer(w, 0, -back, Units.kmh_to_mps(WORST_KMH))
			check(slot >= 0, "racer placed")
			var floor_v := Units.kmh_to_mps(BRAKE_TO_KMH)
			while w.time < brake_at + 20.0:
				_tick(w, PLAYER_BRAKE_MPS2 if w.time >= brake_at else 0.0, floor_v)
				var st := w.sim.state
				if st.active[slot] == 1 and absf(st.d[slot] - w.player.d) < w.road.lane_width(w.player.s) * 0.5:
					var gap := w.player.s - st.s[slot] - (st.length[slot] + tuning.traffic.player_length_m) * 0.5
					if gap > -tuning.traffic.player_length_m:
						worst_gap = minf(worst_gap, gap)
			worst_accel = minf(worst_accel, w.min_racer_accel)
			var what := "racer %.0f m back, player brakes at %.0f s" % [back, brake_at]
			eq(w.checker.player_contacts, 0, "%s: no contact" % what)
			eq(w.checker.rear_end_normal, 0, what)
			eq(w.checker.decel_violations, 0, "%s: never beyond the clamp" % what)
			_legal(w, what)
	print("      250 on 170, braking to 120: closest bumper gap %.1f m, hardest braking %.2f m/s^2" % [worst_gap, worst_accel])
	gt(worst_gap, 0.0, "no contact")
	ge(worst_accel, -tuning.traffic.max_decel_mps2 - 1e-9, "never beyond 6 m/s^2")


## The same through the arrival process: two lanes, the player in the racer lane, the
## arrival comes up behind it; the player brakes to BRAKE_TO_KMH when the racer is
## close. No contact, no hard braking beyond the clamp.
func test_rear_end_prevention_arrival_behind_a_braking_player() -> void:
	for kmh: float in SPEEDS_KMH:
		var w := _world(2, 8, kmh, 0)
		w.dir.force_racer_arrival()
		_drive_until(w, 3000.0, func() -> bool: return w.dir.racer_arrivals > 0)
		eq(w.dir.racer_arrivals, 1, "%.0f km/h: an arrival in the player's lane" % kmh)
		var slot := w.dir.last_arrival_slot
		var braking := false
		var t_end := w.time + 60.0
		while w.time < t_end and w.sim.state.active[slot] == 1:
			var st := w.sim.state
			if not braking and w.player.s - st.s[slot] < 60.0:
				braking = true
			_tick(w, PLAYER_BRAKE_MPS2 if braking else 0.0, Units.kmh_to_mps(BRAKE_TO_KMH))
		check(braking, "%.0f km/h: the racer came up behind the player" % kmh)
		eq(w.checker.player_contacts, 0, "%.0f km/h: no contact" % kmh)
		ge(w.min_racer_accel, -tuning.traffic.max_decel_mps2 - 1e-9, "%.0f km/h: within the clamp" % kmh)
		_legal(w, "%.0f km/h, player braking" % kmh)


## A racer record from the arrival draw, placed `rel` from the player in `lane` at `v`.
func _place_racer(w: World, lane: int, rel: float, v: float) -> int:
	var rec := SpawnSource.Record.new()
	var flow := w.dir.flow
	w.dir.ctx.player = w.player
	if not flow.draw_arrival_into(w.dir.ctx, Rng.new(SEED), flow.racer_profile(), lane, v - 1.0, rec):
		return -1
	rec.s = w.player.s + rel
	rec.v0 = v
	rec.v = v
	return w.sim.spawn(rec)


# ---------------------------------------------------------------- In traffic, determinism, counters

## Real traffic (the soak's run: procedural road, full density, the weaving soak bot):
## arrivals come, every rule holds, and they are never in view (the soak tier's
## soak_arrivals_in_traffic counts the passes over every leg).
func test_arrivals_in_traffic_are_legal_leg_1() -> void:
	gt(_in_traffic(1, 2.5).director.racer_arrivals, 0, "arrivals in traffic")


func test_arrivals_in_traffic_are_legal_leg_8() -> void:
	gt(_in_traffic(8, 2.5).director.racer_arrivals, 0, "arrivals in traffic")


## Every leg, 2 x 3.5 km each on 3 lanes with the soak bot: legal, and arrivals get past
## the player (passes per km printed; docs/SPAWNING.md "Racers from behind"). A run
## whose bot is slower than the left lanes gets ordinary behind spawns there instead.
func soak_arrivals_in_traffic() -> void:
	var arrivals := 0
	var passed := 0
	for leg in range(1, tuning.director.ramp_last_leg + 1):
		for index in 2:
			var r := _in_traffic(leg, tuning.legs.leg_length_m() / Units.M_PER_KM, index)
			arrivals += r.director.racer_arrivals
			passed += r.director.arrivals_passed_player
	gt(arrivals, 8, "arrivals in traffic")
	gt(passed, 4, "and they pass the player")


func _in_traffic(leg: int, km: float, index: int = 0) -> TrafficSoakRun:
	var r := _soak_run(leg, km, index)
	var seen := 0
	var visible := 0
	var margin := Units.kmh_to_mps(tuning.director.racer_arrival_speed_margin_kmh)
	var slow := 0
	while not r.finished:
		r.tick()
		if r.director.racer_arrivals != seen:
			seen = r.director.racer_arrivals
			var i := r.director.last_arrival_slot
			var st := r.sim.state
			if r.director.is_visible(st.s[i], st.d[i]) or st.s[i] > r.bot.state.s - tuning.director.racer_arrival_behind_min_m + 1.0:
				visible += 1
			if st.v0[i] < r.bot.state.v + margin - 1e-6 or st.v[i] < r.bot.state.v + margin - 1e-6:
				slow += 1
	var d := r.result()
	for k: String in ["collision_pairs", "signal_violations", "unsignaled_moves", "ambush_violations",
			"decel_violations", "brake_flag_violations", "rear_end_normal", "offroad_violations"]:
		eq(int(d[k]), 0, "leg %d: %s" % [leg, k])
	eq(visible, 0, "leg %d: never spawned in view" % leg)
	eq(slow, 0, "leg %d: faster than the player by the margin" % leg)
	print("      leg %d run %d, soak bot (%.0f km/h on average): %.1f km, %d arrivals, %d passed it; racers passed it %d, overtaken %d" % [
		leg, index, float(d["km"]) * Units.M_PER_KM / maxf(float(d["sim_s"]), 1.0) / Units.kmh_to_mps(1.0), float(d["km"]),
		r.director.racer_arrivals, r.director.arrivals_passed_player, r.director.racers_passed_player,
		r.director.racers_overtaken])
	return r


func _soak_run(leg: int, km: float, index: int = 0) -> TrafficSoakRun:
	var t: Tuning = tuning.duplicate()
	t.traffic = tuning.traffic.duplicate() as TrafficTuning
	t.traffic.soak_lane_counts = PackedInt32Array([3])
	var r := TrafficSoakRun.new(index, SEED, 1, km * Units.M_PER_KM, t, leg)
	r.check_windows = false
	return r


## The soak's run (real traffic, the soak bot): the same seed gives the same arrivals
## and the same traffic trace; another seed differs.
func test_arrivals_are_deterministic() -> void:
	var a := _trace(0)
	var b := _trace(0)
	var c := _trace(1)
	eq(a, b, "same seed, same trace")
	ne(a, c, "another seed differs")
	gt(int(a[1]), 0, "arrivals in the trace")
	print("      %d arrivals, %d passed the player" % [a[1], a[2]])


func _trace(index: int) -> Array:
	var r := _soak_run(6, DETERMINISM_M / Units.M_PER_KM, index)
	r.run_to_end()
	return [r.trace, r.director.racer_arrivals, r.director.arrivals_passed_player, r.director.racers_passed_player]


## Passes are counted once per side change, for every racer (DevStats / COPY).
func test_passes_are_counted() -> void:
	var w := _world(3, 1, 150.0, 1)
	w.dir.racer_arrivals_enabled = false
	var slot := _place_racer(w, 0, -60.0, Units.kmh_to_mps(200.0))
	_drive_until(w, 2000.0, func() -> bool: return w.sim.state.s[slot] - w.player.s > 60.0)
	eq(w.dir.racers_passed_player, 1, "the racer passed the player once")
	eq(w.dir.racers_overtaken, 0)
	# The player speeds past it.
	w.player.v = Units.kmh_to_mps(260.0)
	_drive_until(w, 2000.0, func() -> bool: return w.player.s - w.sim.state.s[slot] > 60.0)
	eq(w.dir.racers_overtaken, 1, "the player overtook it once")
	eq(w.dir.racers_passed_player, 1)
	eq(w.dir.arrivals_passed_player, 0, "not an arrival")
	var line := DevReport.racers_line(w.dir)
	check(line.contains("passed you 1") and line.contains("you overtook 1"), line)
	eq(DevReport.racers_line(null), "-")
	w.dir.reset(w.player)
	eq(w.dir.racers_passed_player, 0, "per run")


## Tick-rate work (the arrival clock, tries and the pass tracking) allocates nothing.
func test_arrival_ticks_allocate_nothing() -> void:
	var w := _world(3, 4, 200.0, 1)
	for k in 240:
		_tick(w)
	var before := Performance.get_monitor(Performance.OBJECT_COUNT)
	for k in 600:
		w.dir.force_racer_arrival()
		w.player.s += w.player.v * DT
		w.sim.step(DT, w.player, null, w.events)
		w.events.clear()
		w.dir.step(DT, w.player)
		if w.player.s + w.dir.ahead_distance() + w.player.v >= w.dir.spawned_to():
			break
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), before)


# ---------------------------------------------------------------- Density (soak tier)

## Plan D11 / D17: the leg-8 density survey (the scripted observer at 150-250 km/h, 4
## runs x 14 km per cell) stays within 3 % of the same survey without arrivals (83 % /
## 89 % of the target on 3 / 4 lanes in WP6.6).
func soak_density_survey_with_arrivals() -> void:
	var off: Tuning = tuning.duplicate()
	off.director = tuning.director.duplicate() as DirectorTuning
	off.director.racer_arrival_interval_first_min_s = 1e9
	off.director.racer_arrival_interval_first_max_s = 1e9
	off.director.racer_arrival_interval_last_min_s = 1e9
	off.director.racer_arrival_interval_last_max_s = 1e9
	for lanes: int in [3, 4]:
		var before := DensitySurvey.cell(lanes, 8, DensitySurvey.SCRIPTED, 4, 4, off)
		var after := DensitySurvey.cell(lanes, 8, DensitySurvey.SCRIPTED, 4, 4)
		print("      before %s" % DensitySurvey.format_row(before))
		print("      after  %s" % DensitySurvey.format_row(after))
		within_pct(float(after["density"]), float(before["density"]), 0.03, "%d lanes leg 8" % lanes)
		eq(int(after["violations"]), 0)


# ---------------------------------------------------------------- The sandbox (review tool)

## The sandbox's ARR toggle survives a re-seed, ARRIVE makes one due, and the counters
## reach the stats panel and DevStats (the dev HUD's COPY).
func test_sandbox_arrival_controls() -> void:
	_scene = (load("res://src/traffic/dev/traffic_sandbox.tscn") as PackedScene).instantiate()
	tree.root.add_child(_scene)
	_scene.set_physics_process(false)
	await tree.process_frame
	var ctl := _scene.get(&"fast_controls") as FastTrafficControls
	ctl.set_arrivals(false)
	check(not (_scene.get(&"director") as TrafficDirector).racer_arrivals_enabled, "ARR OFF")
	_scene.call(&"reseed", 7)
	check(not (_scene.get(&"director") as TrafficDirector).racer_arrivals_enabled, "kept across a re-seed")
	ctl.force_arrival()
	var dir := _scene.get(&"director") as TrafficDirector
	check(dir.racer_arrivals_enabled, "ARRIVE turns arrivals on")
	eq(dir.racer_arrival_due_in(), 0.0, "and makes one due")
	_scene.call(&"advance_ticks", 120)
	_scene.call(&"refresh_stats")
	check(DevStats.has_value(&"racers_passed_you") and DevStats.has_value(&"racer_arrivals"), "DevStats")
	eq(DevStats.get_value(&"racer_arrivals"), dir.racer_arrivals)
