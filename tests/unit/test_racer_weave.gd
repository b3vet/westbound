extends WBTest
## Racers weave harder (plan D17, WP6.9; owner: racers take tighter gaps and change lanes
## more willingly, so they come past a fast player). Spec: Traffic → Longitudinal model:
## IDM, Lane changes: MOBIL ("the player gets extra safety: b_safe tightens to 2 m/s^2"),
## Fairness rules 1-4 (telegraphing, no ambush, readable braking, no sudden stops), Driver
## types; Lives → rear-end prevention. The racer profile's "Weaving" fields
## (DriverProfile) toward traffic, and nothing relaxed toward the player. Design and
## measured numbers: docs/TRAFFIC.md "Racers weave harder", docs/SPAWNING.md.

const DT := 1.0 / 120.0
## Runs per cell in the density gate (soak tier).
const DENSITY_SEEDS := 8

var t: Tuning
var reg: TrafficRegistry


func before_all() -> void:
	t = Tuning.load_default()
	reg = TrafficRegistry.load_default(t.traffic)


func _kmh(x: float) -> float:
	return Units.kmh_to_mps(x)


func _racer() -> DriverProfile:
	return reg.profiles[reg.profile_index(&"racer")]


## The racer with every weaving field off (the WP6.6 racer), for comparisons.
func _plain_racer() -> DriverProfile:
	var p := _racer().duplicate() as DriverProfile
	p.idm_headway_vs_traffic_s = -1.0
	p.idm_s0_vs_traffic_m = -1.0
	p.idm_b_comfort_vs_traffic_mps2 = -1.0
	p.mobil_b_safe_vs_traffic_mps2 = -1.0
	p.lookahead_lane_choice_m = 0.0
	p.lane_change_cooldown_s = -1.0
	p.lane_change_cap_count = 0
	return p


## A bare 3-lane world with a registry whose racer is `racer` (null: the data's), the
## player parked far behind (no interaction) unless placed.
class World:
	extends RefCounted
	var road: StraightRoadPath
	var reg: TrafficRegistry
	var sim: TrafficSim
	var player := VehicleState.new()
	var events: ScoreEventBuffer
	var rec := SpawnSource.Record.new()

	func _init(tun: Tuning, racer: DriverProfile, lanes: int = 3) -> void:
		road = StraightRoadPath.new(lanes, tun.road)
		var base := TrafficRegistry.load_default(tun.traffic)
		if racer != null:
			var ps: Array[DriverProfile] = []
			for p in base.profiles:
				ps.append(racer if p.id == &"racer" else p)
			reg = TrafficRegistry.new(ps, base.types, tun.traffic)
		else:
			reg = base
		sim = TrafficSim.new(RunContext.new(9901, RunContext.MODE_JOURNEY, tun), road, reg)
		sim.set_player_body(tun.traffic.player_length_m, tun.traffic.player_width_m)
		events = ScoreEventBuffer.new(tun.scoring.event_buffer_capacity)
		player.s = -5000.0
		player.d = road.lane_center_d(0, 0.0)

	func add(s: float, lane: int, profile: StringName, type: StringName, v: float, v0: float, flags: int = 0) -> int:
		rec.s = s
		rec.lane = lane
		rec.d = NAN
		rec.v = v
		rec.v0 = v0
		rec.profile_id = reg.profile_index(profile)
		rec.type_id = reg.type_index(type)
		rec.flags = flags
		return sim.spawn(rec)

	func refresh() -> void:
		sim.step(0.0, player, null, events)
		events.clear()

	func run(seconds: float) -> void:
		for k in roundi(seconds / DT):
			player.s += player.v * DT
			sim.step(DT, player, null, events)
			events.clear()


# ---------------------------------------------------------------- Data

## Only the racer weaves; every other profile leaves the weaving fields at their
## defaults, so the sim takes exactly its WP6.6 path for them (bit-identical).
func test_only_the_racer_weaves() -> void:
	var w := World.new(t, null)
	for p in reg.profile_count():
		var d := reg.profiles[p]
		if d.id == &"racer":
			check(w.sim.weaves(p), "the racer weaves")
			continue
		check(not w.sim.weaves(p), "%s does not weave" % d.id)
		lt(d.idm_headway_vs_traffic_s, 0.0, d.id)
		lt(d.idm_s0_vs_traffic_m, 0.0, d.id)
		lt(d.idm_b_comfort_vs_traffic_mps2, 0.0, d.id)
		lt(d.mobil_b_safe_vs_traffic_mps2, 0.0, d.id)
		eq(d.lookahead_lane_choice_m, 0.0, d.id)
		lt(d.lane_change_cooldown_s, 0.0, d.id)
		eq(d.lane_change_cap_count, 0, d.id)
	check(not World.new(t, _plain_racer()).sim.weaves(reg.profile_index(&"racer")), "all fields off: no weaving")


func test_racer_weaving_data() -> void:
	var r := _racer()
	var clamp_mps2 := t.traffic.max_decel_mps2
	lt(r.idm_headway_vs_traffic_s, r.idm_headway_s, "closer behind traffic")
	ge(r.idm_headway_vs_traffic_s, 0.0)
	le(r.idm_s0_vs_traffic_m, r.idm_s0_m)
	# Its comfortable b toward traffic stays the ordinary one (a higher b cost leg-8
	# density without any speed gain: docs/TRAFFIC.md "Racers weave harder").
	lt(r.idm_b_comfort_vs_traffic_mps2, 0.0, "b unchanged")
	lt(r.lane_change_cooldown_s, 0.0, "the global cooldown (a shorter one cost density)")
	gt(r.mobil_b_safe_vs_traffic_mps2, r.mobil_b_safe_mps2, "accepts tighter gaps toward traffic")
	le(r.mobil_b_safe_vs_traffic_mps2, clamp_mps2 - 1.0, "well below the 6 m/s^2 clamp")
	gt(r.lookahead_lane_choice_m, 0.0, "looks ahead")
	gt(r.lookahead_gain_per_s, 0.0)
	gt(r.lookahead_incentive_max_mps2, 0.0)
	gt(r.lane_change_cap_count, 0, "a readability cap")
	le(r.lane_change_cap_count, TrafficSim.WEAVE_CAP_MAX)
	gt(r.lane_change_cap_window_s, 0.0)
	# Telegraphing is unchanged (fairness rule 1): the 0.6 s blinker, never under 0.5 s.
	near(r.signal_time_s, t.traffic.signal_time_aggressive_s, 1e-9)
	ge(reg.signal_s[reg.profile_index(&"racer")], t.traffic.signal_time_floor_s)
	# The player as new follower keeps its 2 m/s^2 whatever the racer accepts from traffic.
	var w := World.new(t, null)
	var pr := reg.profile_index(&"racer")
	near(w.sim.weave_b_safe(pr), r.mobil_b_safe_vs_traffic_mps2, 1e-12)
	near(Mobil.b_safe_for(w.sim.weave_b_safe(pr), true, t.traffic.player_b_safe_mps2),
		t.traffic.player_b_safe_mps2, 0.0, "player b_safe unchanged")


func test_weave_b_safe_never_exceeds_the_clamp() -> void:
	var r := _racer().duplicate() as DriverProfile
	r.mobil_b_safe_vs_traffic_mps2 = 9.0
	var w := World.new(t, r)
	near(w.sim.weave_b_safe(w.reg.profile_index(&"racer")), t.traffic.max_decel_mps2, 0.0, "capped at the clamp")


# ---------------------------------------------------------------- IDM: closer behind traffic, not behind the player

## One lane: a racer settles behind a traffic car at IDM's equilibrium gap with its
## traffic T and s0, and behind the player at the ordinary T and s0 (rear-end prevention
## unchanged).
func test_racer_follows_traffic_closer_but_not_the_player() -> void:
	var r := _racer()
	var v := _kmh(120.0)
	var v0 := _kmh(200.0)
	var gaps: Array[float] = []
	for behind_player: bool in [false, true]:
		var w := World.new(t, null, 1)
		if behind_player:
			w.player.s = 1000.0
			w.player.d = w.road.lane_center_d(0, 0.0)
			w.player.v = v
		else:
			w.add(1000.0, 0, &"commuter", &"sedan", v, v)
		var car := w.add(800.0, 0, &"racer", &"sports", v, v0)
		w.run(90.0)
		var hw := r.idm_headway_s
		var s0 := r.idm_s0_m
		if not behind_player:
			hw = r.idm_headway_vs_traffic_s
			s0 = r.idm_s0_vs_traffic_m
		var expected := Idm.equilibrium_gap(v, v0, hw, s0, roundi(r.idm_delta))
		near(w.sim.leader_gap(car), expected, 0.3, "behind the %s: IDM equilibrium with its %s T and s0" % [
			"player" if behind_player else "traffic car", "ordinary" if behind_player else "traffic"])
		gaps.append(w.sim.leader_gap(car))
	lt(gaps[0], gaps[1] - 5.0, "closer behind traffic than behind the player")


# ---------------------------------------------------------------- MOBIL: tighter gaps toward traffic only

## A racer in lane 1 asks for lane 0, where a follower at the same speed sits behind: at
## this gap the follower would brake between the racer's ordinary b_safe and its b_safe
## toward traffic. A traffic follower: the weaving racer takes the gap, the WP6.6 racer
## does not. The player at the same place: refused (b_safe 2 m/s^2, unchanged).
func test_tighter_gap_toward_traffic_but_not_the_player() -> void:
	var r := _racer()
	var v := _kmh(130.0)
	var com := reg.profiles[reg.profile_index(&"commuter")]
	# Commuter at its desired speed: a~n = -a (s* / gap)^2 with s* = s0 + v T.
	var target := (r.mobil_b_safe_mps2 + r.mobil_b_safe_vs_traffic_mps2) * 0.5
	var s_star := com.idm_s0_m + v * com.idm_headway_s
	var gap := s_star / sqrt(target / com.idm_a_max_mps2)
	var a_n := Idm.accel(v, v, gap, 0.0, com.idm_a_max_mps2, com.idm_b_comfort_mps2, com.idm_headway_s,
		com.idm_s0_m, 4, t.traffic.idm_gap_floor_m)
	check(a_n < -r.mobil_b_safe_mps2 and a_n > -r.mobil_b_safe_vs_traffic_mps2, "geometry: a~n %.2f" % a_n)
	var car_s := 1000.0
	var len_sports := reg.types[reg.type_index(&"sports")].length_m
	var len_sedan := reg.types[reg.type_index(&"sedan")].length_m
	var results: Array[bool] = []
	for racer: DriverProfile in [null, _plain_racer()]:
		var w := World.new(t, racer)
		w.add(car_s - gap - (len_sports + len_sedan) * 0.5, 0, &"commuter", &"sedan", v, v)
		var car := w.add(car_s, 1, &"racer", &"sports", v, _kmh(220.0))
		w.refresh()
		results.append(w.sim.request_lane_change(car, 0))
	check(results[0], "weaving racer: takes the gap in front of a traffic car")
	check(not results[1], "the WP6.6 racer did not")
	# The player there instead: its a~n is far below -2 m/s^2 -> refused.
	var wp := World.new(t, null)
	wp.player.s = car_s - gap - (len_sports + t.traffic.player_length_m) * 0.5
	wp.player.d = wp.road.lane_center_d(0, 0.0)
	wp.player.v = v
	var a_p := Idm.interaction_accel(v, gap, 0.0, t.traffic.player_idm_a_max_mps2, t.traffic.player_idm_b_comfort_mps2,
		t.traffic.player_idm_headway_s, t.traffic.player_idm_s0_m, t.traffic.idm_gap_floor_m)
	lt(a_p, -t.traffic.player_b_safe_mps2, "geometry: the player would brake beyond 2 m/s^2")
	var car_p := wp.add(car_s, 1, &"racer", &"sports", v, _kmh(220.0))
	wp.refresh()
	check(not wp.sim.request_lane_change(car_p, 0), "player follower: b_safe 2 m/s^2, refused")


## The racer's own braking behind a new leader: toward a traffic car it accepts up to its
## traffic b_safe; behind the player only its ordinary b_safe.
func test_own_braking_behind_the_player_is_not_relaxed() -> void:
	var r := _racer()
	var v := _kmh(160.0)
	var vl := _kmh(130.0)
	var v0 := _kmh(220.0)
	# Find a gap where its IDM behind the new leader lies between the two b_safes, with
	# the ordinary parameters (behind the player) and with the traffic ones.
	var gap_p := _gap_for(v, v0, v - vl, r.idm_a_max_mps2, r.idm_b_comfort_mps2, r.idm_headway_s, r.idm_s0_m,
		(r.mobil_b_safe_mps2 + r.mobil_b_safe_vs_traffic_mps2) * 0.5)
	var wp := World.new(t, null)
	var len_sports := reg.types[reg.type_index(&"sports")].length_m
	wp.player.s = 1000.0 + gap_p + (len_sports + t.traffic.player_length_m) * 0.5
	wp.player.d = wp.road.lane_center_d(0, 0.0)
	wp.player.v = vl
	var car := wp.add(1000.0, 1, &"racer", &"sports", v, v0)
	wp.refresh()
	check(not wp.sim.request_lane_change(car, 0), "behind the player: its ordinary b_safe refuses")
	# The same own braking behind a traffic car is within its traffic b_safe.
	var b_t := r.idm_b_comfort_vs_traffic_mps2 if r.idm_b_comfort_vs_traffic_mps2 > 0.0 else r.idm_b_comfort_mps2
	var gap_t := _gap_for(v, v0, v - vl, r.idm_a_max_mps2, b_t, r.idm_headway_vs_traffic_s,
		r.idm_s0_vs_traffic_m, (r.mobil_b_safe_mps2 + r.mobil_b_safe_vs_traffic_mps2) * 0.5)
	var wt := World.new(t, null)
	var len_sedan := reg.types[reg.type_index(&"sedan")].length_m
	wt.add(1000.0 + gap_t + (len_sports + len_sedan) * 0.5, 0, &"commuter", &"sedan", vl, vl)
	var car_t := wt.add(1000.0, 1, &"racer", &"sports", v, v0)
	wt.refresh()
	check(wt.sim.request_lane_change(car_t, 0), "behind a traffic car: its traffic b_safe accepts")


## The gap at which IDM gives acceleration -decel (bisection; test helper).
func _gap_for(v: float, v0: float, dv: float, a: float, b: float, hw: float, s0: float, decel: float) -> float:
	var lo := 0.5
	var hi := 1000.0
	for k in 60:
		var mid := (lo + hi) * 0.5
		if Idm.accel(v, v0, mid, dv, a, b, hw, s0, 4, t.traffic.idm_gap_floor_m) < -decel:
			lo = mid
		else:
			hi = mid
	return (lo + hi) * 0.5


# ---------------------------------------------------------------- Lookahead lane choice

## A lane's pace: the mean speed the racer can make there over its lookahead,
## H = lookahead / v0: its desired speed when clear; behind a car, at most as far as its
## following gap behind it within H; a car it would not reach within H does not bind.
func test_lookahead_lane_pace() -> void:
	var r := _racer()
	var v0 := _kmh(220.0)
	var h := r.lookahead_lane_choice_m / v0
	var w := World.new(t, null)
	var car := w.add(1000.0, 1, &"racer", &"sports", _kmh(130.0), v0)
	var vl := _kmh(110.0)
	w.add(1050.0, 1, &"commuter", &"sedan", vl, vl)
	w.add(1000.0 + r.lookahead_lane_choice_m - 10.0, 0, &"commuter", &"sedan", _kmh(140.0), _kmh(140.0))
	w.refresh()
	var len_sports := reg.types[reg.type_index(&"sports")].length_m
	var len_sedan := reg.types[reg.type_index(&"sedan")].length_m
	var gap := 50.0 - (len_sports + len_sedan) * 0.5
	var expected := (gap + vl * h - r.idm_s0_vs_traffic_m - vl * r.idm_headway_vs_traffic_s) / h
	near(w.sim.weave_lane_pace(car, 1), expected, 1e-9, "behind a car 50 m ahead")
	lt(w.sim.weave_lane_pace(car, 1), v0)
	near(w.sim.weave_lane_pace(car, 2), v0, 0.0, "a clear lane: its desired speed")
	near(w.sim.weave_lane_pace(car, 0), v0, 0.0, "a car it cannot reach within H does not bind")
	# The plain racer has no lookahead.
	var wp := World.new(t, _plain_racer())
	var cp := wp.add(1000.0, 1, &"racer", &"sports", _kmh(130.0), v0)
	wp.add(1050.0, 1, &"commuter", &"sedan", vl, vl)
	wp.refresh()
	near(wp.sim.weave_lane_pace(cp, 1), v0, 0.0, "no lookahead: off")


## Closing on a 100 km/h car in lane 1 with lane 0 clear: MOBIL's incentive already
## sees the first car, and the lookahead adds the pace difference, so the weaving racer
## signals out at least as early as the WP6.6 racer.
func test_lookahead_leaves_a_blocked_lane_no_later() -> void:
	var when: Array[float] = []
	var v := _kmh(100.0)
	for racer: DriverProfile in [_plain_racer(), null]:
		var w := World.new(t, racer)
		w.add(1150.0, 1, &"commuter", &"sedan", v, v)
		w.add(1000.0, 2, &"truck", &"semi", _kmh(85.0), _kmh(85.0))
		var car := w.add(1000.0, 1, &"racer", &"sports", _kmh(140.0), _kmh(220.0))
		var time := INF
		for k in roundi(10.0 / DT):
			w.sim.step(DT, w.player, null, w.events)
			w.events.clear()
			if w.sim.state.lc_state[car] != TrafficState.LaneChange.NONE:
				time = float(k) * DT
				eq(w.sim.state.target_lane[car], 0, "into the clear lane")
				break
		when.append(time)
	check(is_finite(when[1]), "the weaving racer leaves the blocked lane")
	le(when[1], when[0], "no later than MOBIL alone (%.2f s vs %.2f s)" % [when[1], when[0]])


# ---------------------------------------------------------------- Weaving in traffic: legal, readable

## Dense mixed traffic with many racers and a weaving player: no collisions, no rule
## violations; every car a racer cuts in front of brakes (raw IDM, before the clamp) at
## less than the 6 m/s^2 clamp while the racer leads it; no racer starts more lane
## changes in any cap window than its cap. Racers do weave (several moves each).
func test_racers_weave_legally_in_dense_traffic_seed_69() -> void:
	_weave_legally(69)


func test_racers_weave_legally_in_dense_traffic_seed_70() -> void:
	_weave_legally(70)


func _weave_legally(seed_value: int) -> void:
	var r := _racer()
	var clamp_mps2 := t.traffic.max_decel_mps2
	var sc := _dense(seed_value)
	var st := sc.sim.state
	var racer := sc.registry.profile_index(&"racer")
	var prev := PackedInt32Array()
	prev.resize(st.capacity)
	var vid := PackedInt32Array()
	vid.resize(st.capacity)
	vid.fill(-1)
	var times: Array[PackedFloat64Array] = []
	for i in st.capacity:
		times.append(PackedFloat64Array())
	var watch_f := PackedInt32Array()
	var watch_r := PackedInt32Array()
	var watch_until := PackedFloat64Array()
	var worst := 0.0
	var cut_ins := 0
	var moves := 0
	var max_in_window := 0
	for k in roundi(40.0 / DT):
		sc.tick()
		for i in st.capacity:
			if st.active[i] == 0 or st.profile_id[i] != racer:
				continue
			if vid[i] != st.vehicle_id[i]:
				vid[i] = st.vehicle_id[i]
				prev[i] = st.lc_state[i]
				times[i] = PackedFloat64Array()
				continue
			if st.lc_state[i] == TrafficState.LaneChange.SIGNALING and prev[i] == TrafficState.LaneChange.NONE:
				times[i].append(sc.time)
				var n := 0
				for x in times[i]:
					if sc.time - x < r.lane_change_cap_window_s:
						n += 1
				max_in_window = maxi(max_in_window, n)
			if st.lc_state[i] == TrafficState.LaneChange.MOVING and prev[i] != TrafficState.LaneChange.MOVING:
				moves += 1
				var f := _follower_in(sc, i, st.target_lane[i])
				if f >= 0:
					cut_ins += 1
					watch_f.append(f)
					watch_r.append(i)
					watch_until.append(sc.time + st.lc_duration[i] + 5.0)
			prev[i] = st.lc_state[i]
		for q in watch_f.size():
			if sc.time <= watch_until[q] and st.active[watch_f[q]] == 1 \
					and sc.sim.leader_of(watch_f[q]) == watch_r[q]:
				worst = minf(worst, sc.sim.idm_accel(watch_f[q]))
	print("      seed %d: %d racer moves, %d cut-ins, hardest raw braking of a car cut in front of %.2f m/s^2, at most %d lane changes in %.0f s" % [
		seed_value, moves, cut_ins, worst, max_in_window, r.lane_change_cap_window_s])
	eq(sc.checker.collision_pairs, 0, "seed %d: no traffic collisions" % seed_value)
	eq(sc.checker.total_violations(), 0, sc.checker.summary())
	gt(cut_ins, 5, "seed %d: racers cut in" % seed_value)
	gt(worst, -clamp_mps2, "seed %d: a cut-in never needs the clamp" % seed_value)
	le(max_in_window, r.lane_change_cap_count, "seed %d: no zig-zag beyond the cap" % seed_value)


func _dense(seed_value: int) -> TrafficScenario:
	var sc := TrafficScenario.new(seed_value)
	var w := PackedFloat64Array()
	w.resize(reg.profile_count())
	w.fill(0.0)
	w[reg.profile_index(&"racer")] = 0.3
	w[reg.profile_index(&"aggressive")] = 0.1
	w[reg.profile_index(&"commuter")] = 0.35
	w[reg.profile_index(&"cruiser")] = 0.1
	w[reg.profile_index(&"truck")] = 0.1
	w[reg.profile_index(&"van")] = 0.05
	sc.weights = w
	sc.density_per_km_lane = 18.0
	sc.make_bot(TrafficBotPlayer.Mode.WEAVE, 170.0, 1)
	sc.populate()
	return sc


## The nearest vehicle behind vehicle i whose body overlaps lane `lane`, -1 when none.
func _follower_in(sc: TrafficScenario, i: int, lane: int) -> int:
	var st := sc.sim.state
	var c := sc.road.lane_center_d(lane, st.s[i])
	var half := sc.road.lane_width(st.s[i]) * 0.5
	var best := -1
	for j in st.capacity:
		if j == i or st.active[j] == 0 or st.s[j] >= st.s[i] or st.s[i] - st.s[j] > t.traffic.idm_lookahead_m:
			continue
		if absf(st.d[j] - c) < half + st.width[j] * 0.5 and (best < 0 or st.s[j] > st.s[best]):
			best = j
	return best


## The cap in isolation (two lanes): with no cooldown, a racer that finds a slower car in
## each lane it moves into wants to move again soon; with a cap of one change per 20 s the second
## change waits for the window.
func test_lane_change_cap_holds() -> void:
	var gaps: Array[float] = []
	for cap: int in [0, 1]:
		var r := _racer().duplicate() as DriverProfile
		r.lane_change_cap_count = cap
		r.lane_change_cap_window_s = 20.0
		r.lane_change_cooldown_s = 0.0
		var w := World.new(t, r, 2)
		var car := w.add(1000.0, 1, &"racer", &"sports", _kmh(150.0), _kmh(230.0))
		w.add(1150.0, 1, &"commuter", &"sedan", _kmh(100.0), _kmh(100.0))
		var starts := PackedFloat64Array()
		var last: int = TrafficState.LaneChange.NONE
		var time := 0.0
		for k in roundi(30.0 / DT):
			w.sim.step(DT, w.player, null, w.events)
			w.events.clear()
			time += DT
			var lc := w.sim.state.lc_state[car]
			if lc == TrafficState.LaneChange.SIGNALING and last == TrafficState.LaneChange.NONE:
				starts.append(time)
			if lc == TrafficState.LaneChange.NONE and last == TrafficState.LaneChange.MOVING:
				# Arrived: a slow car ahead in the new lane (scripted: it keeps that lane), so
				# it wants to move again.
				w.add(w.sim.state.s[car] + 150.0, w.sim.state.lane[car], &"commuter", &"sedan", _kmh(70.0),
					_kmh(70.0), TrafficState.FLAG_SCRIPTED)
			last = lc
		ge(starts.size(), 2, "cap %d: it weaves" % cap)
		gaps.append(starts[1] - starts[0] if starts.size() >= 2 else INF)
	lt(gaps[0], 20.0, "without a cap it moves again within the window (%.1f s)" % gaps[0])
	ge(gaps[1], 20.0 - 1e-6, "with the cap the second change waits for the window (%.1f s)" % gaps[1])


func test_weaving_trace_is_deterministic() -> void:
	var a := _trace(71)
	eq(a, _trace(71), "same seed, same trace")
	ne(a, _trace(72), "another seed differs")


func _trace(seed_value: int) -> PackedInt64Array:
	var sc := _dense(seed_value)
	sc.hash_every_s = 1.0
	sc.run(12.0)
	return sc.hashes


## Weaving adds no allocation to the tick (the lookahead, the cap ring, the traffic IDM).
func test_weaving_ticks_allocate_nothing() -> void:
	var sc := _dense(73)
	sc.observe = false
	sc.spawner_enabled = false
	for k in 240:
		sc.tick()
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var mem := OS.get_static_memory_usage()
	for k in 600:
		sc.tick()
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), objects)
	eq(OS.get_static_memory_usage(), mem)


# ---------------------------------------------------------------- Through full traffic (soak tier)

## WP6.9's measurement (the WP6.7 harness: the density survey's observer at 170, 200,
## 230 km/h through full traffic at legs 4 and 8, 3 lanes): passes per km printed
## (docs/SPAWNING.md, "Racers weave harder"); every rule holds, cut-ins never need the
## clamp, and no racer weaves faster than its cap.
func soak_racers_pass_through_traffic() -> void:
	var r := _racer()
	for leg: int in [4, 8]:
		for kmh: float in [170.0, 200.0, 230.0]:
			var d := RacerPassSurvey.cell(3, leg, kmh)
			print("      " + RacerPassSurvey.format_row(d))
			eq(int(d["violations"]), 0, "leg %d at %.0f: rules" % [leg, kmh])
			eq(int(d["collisions"]), 0, "leg %d at %.0f: collisions" % [leg, kmh])
			gt(float(d["cut_in_min_raw_mps2"]), -t.traffic.max_decel_mps2, "leg %d at %.0f: cut-ins" % [leg, kmh])
			le(int(d["racer_max_moves_10s"]), r.lane_change_cap_count, "leg %d at %.0f: readable" % [leg, kmh])


## Plan D11 / D17: the leg-8 density survey (8 runs x 14 km per cell: with 4 runs the
## chaos between otherwise identical runs, about +-1.5 %, is half the gate) with
## weaving racers costs at most 3 % of the density of the same survey with the racer's
## weaving off. WP9.6 (orchestrator, PL-3): the guard's intent is "weaving must not cost
## density", so the bound is one-sided (WEAVE_DENSITY_MIN_CHANGE), with an upper sanity
## bound (WEAVE_DENSITY_MAX_CHANGE) that catches a weave piling traffic up; weaving
## racers pass through slow traffic, so they may add a few percent (WP9.5: +3.63 % on 4
## lanes, +2.4 % on 3).
const WEAVE_DENSITY_MIN_CHANGE := -0.03
const WEAVE_DENSITY_MAX_CHANGE := 0.08


func soak_density_with_weaving_racers() -> void:
	var r := _racer()
	var saved := r.duplicate() as DriverProfile
	var plain := _plain_racer()
	for lanes: int in [3, 4]:
		_copy_weaving(plain, r)
		var before := DensitySurvey.cell(lanes, 8, DensitySurvey.SCRIPTED, DENSITY_SEEDS, 4)
		_copy_weaving(saved, r)
		var after := DensitySurvey.cell(lanes, 8, DensitySurvey.SCRIPTED, DENSITY_SEEDS, 4)
		print("      weaving off %s" % DensitySurvey.format_row(before))
		print("      weaving on  %s" % DensitySurvey.format_row(after))
		var change := float(after["density"]) / float(before["density"]) - 1.0
		print("      %d lanes leg 8: weaving changes density by %+.2f %%" % [lanes, change * 100.0])
		ge(change, WEAVE_DENSITY_MIN_CHANGE, "%d lanes leg 8: weaving costs at most 3 %% density" % lanes)
		le(change, WEAVE_DENSITY_MAX_CHANGE, "%d lanes leg 8: weaving adds at most 8 %% (sanity)" % lanes)
		eq(int(after["violations"]), 0)
	_copy_weaving(saved, r)


func _copy_weaving(from: DriverProfile, to: DriverProfile) -> void:
	for f: String in ["idm_headway_vs_traffic_s", "idm_s0_vs_traffic_m", "idm_b_comfort_vs_traffic_mps2",
			"mobil_b_safe_vs_traffic_mps2", "lookahead_lane_choice_m", "lookahead_gain_per_s",
			"lookahead_incentive_max_mps2", "lane_change_cooldown_s", "lane_change_cap_count",
			"lane_change_cap_window_s", "lane_change_frequency_scale"]:
		to.set(f, from.get(f))
