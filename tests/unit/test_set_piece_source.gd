extends WBTest
## The SetPiece SpawnSource, its runtime and the two pieces of WP6.2 (truck wall,
## rolling roadblock). Spec: Traffic → Traffic director (SetPiece source; "peak (often a
## set piece)"; "set piece variety grows"; the set-piece table: "Truck wall: trucks and
## buses roll side by side across all lanes but one; the open lane shifts slowly.
## Warning: visible from distance by silhouettes." "Rolling roadblock: cars at matched
## speed across all lanes; a gap opens every few seconds. Warning: brake lights ripple as
## it forms."); Fairness rules 1, 2 (telegraphing, no ambush), 4 ("no deceleration above
## 6 m/s² except in set pieces announced at least 300 m ahead") and 6. docs/SET_PIECES.md.

const SEED := 620301
const DT := 1.0 / 120.0
const EPS := 1e-6

var tuning: Tuning
var sc: TrafficScenario
var dir: TrafficDirector
var ev: ScoreEventBuffer
var time := 0.0
## Every set-piece event: [time, kind, tag, value, serial].
var piece_log: Array = []


func before_all() -> void:
	tuning = Tuning.load_default()


## The real registry and TrafficSim on a straight road, a bot player and the director
## (set pieces only when forced: chance 0).
func _rig(lanes: int, v_kmh: float, lane: int = 1, t: Tuning = null, seed_value: int = SEED) -> void:
	var tun := t if t != null else _no_chance()
	sc = TrafficScenario.new(seed_value, lanes, tun)
	sc.spawner_enabled = false
	sc.make_bot(TrafficBotPlayer.Mode.CRUISE, v_kmh, lane)
	dir = TrafficDirector.new(sc.ctx, sc.road, sc.sim, sc.registry.profiles, sc.registry.types,
		sc.bot.length_m, sc.bot.width_m)
	ev = ScoreEventBuffer.new(256)
	dir.events = ev
	sc.checker.set_piece_of = dir.set_pieces.instance_of
	dir.set_leg(3, sc.bot.state.s)
	dir.reset(sc.bot.state)
	time = 0.0
	piece_log.clear()


func _no_chance() -> Tuning:
	var t: Tuning = tuning.duplicate()
	t.director = tuning.director.duplicate() as DirectorTuning
	t.director.set_piece_chance_first_pct = 0.0
	t.director.set_piece_chance_last_pct = 0.0
	return t


func _tick() -> void:
	sc.bot.update(DT, sc.sim.state)
	sc.sim.step(DT, sc.bot.state, null, ev)
	time += DT
	sc.checker.observe(time, sc.sim.state, sc.bot.state)
	for slot in sc.checker.contacts_started:
		sc.sim.notify_hit(slot)
	dir.step(DT, sc.bot.state)
	for k in ev.size():
		var kind := ev.kind[k]
		if kind == SetPieceSource.KIND_WARNING or kind == SetPieceSource.KIND_STARTED or kind == SetPieceSource.KIND_ENDED:
			piece_log.append([time, kind, ev.tag[k], ev.value[k], ev.points[k]])
			if kind == SetPieceSource.KIND_WARNING:
				sc.checker.note_set_piece_warning(ev.points[k], sc.sim.state, sc.bot.state)
	ev.clear()


func _run(seconds: float) -> void:
	for k in roundi(seconds / DT):
		_tick()


## Forces `id` and runs until it spawned; returns its instance.
func _spawn(id: StringName) -> SetPieceSource.Instance:
	check(dir.force_set_piece(id), "forced %s" % id)
	for k in roundi(30.0 / DT):
		_tick()
		var inst := _running()
		if inst != null:
			return inst
	fail("%s never spawned" % id)
	return null


func _running() -> SetPieceSource.Instance:
	for inst in dir.set_pieces.instances:
		if inst.stage == SetPieceSource.Stage.RUNNING:
			return inst
	return null


func _lanes_of(inst: SetPieceSource.Instance) -> PackedInt32Array:
	var out := PackedInt32Array()
	for k in inst.n:
		if dir.set_pieces.alive(inst, k):
			out.append(sc.sim.state.lane[inst.slot[k]])
	return out


func _open_lanes(inst: SetPieceSource.Instance, lanes: int) -> PackedInt32Array:
	var used := _lanes_of(inst)
	var out := PackedInt32Array()
	for l in lanes:
		if not used.has(l):
			out.append(l)
	return out


## Everything but the piece off the road, and nothing new: the piece's own behaviour.
func _only_the_piece(inst: SetPieceSource.Instance) -> void:
	dir.set_density_scale(0.0)
	for i in sc.sim.state.capacity:
		if sc.sim.state.active[i] == 1 and dir.set_pieces.instance_of(i) != inst.serial:
			sc.sim.despawn(i)


func _events(kind: StringName) -> Array:
	var out: Array = []
	for e: Array in piece_log:
		if e[1] == kind:
			out.append(e)
	return out


# ---------------------------------------------------------------- Framework

func test_defs_load_with_their_controllers() -> void:
	var defs := SetPieceSource.load_defs(tuning.director)
	for id: StringName in [&"truck_wall", &"rolling_roadblock"]:
		if check(defs.has(id), "data/set_pieces/%s.tres" % id):
			var d: SetPieceDef = defs[id]
			eq(d.id, id)
			check(SetPieceSource.controller_for(d.kind) != null, "%s has a controller" % id)
			ge(d.speed_mps(0.0), tuning.scoring.min_speed_mps(), "%s never below the minimum speed" % id)
			check(not d.warning_sign_distances_m.is_empty(), "%s is announced" % id)
			check(not d.profile_ids.is_empty(), "%s has its vehicle mix" % id)
	for k: SetPieceDef.Kind in [SetPieceDef.Kind.MERGE_ZONE, SetPieceDef.Kind.ROAD_WORKS, SetPieceDef.Kind.SLALOM,
			SetPieceDef.Kind.CONVOY, SetPieceDef.Kind.TUNNEL_SQUEEZE, SetPieceDef.Kind.TOLL_GANTRY]:
		eq(SetPieceSource.controller_for(k), null, "kind %d comes in WP6.3" % k)


func test_kinds_unlock_by_leg_and_follow_the_biome_mix() -> void:
	_rig(3, 150.0)
	var sp := dir.set_pieces
	for u: float in [0.0, 0.3, 0.6, 0.99]:
		eq(sp.pick(1, null, u, 3).id, &"truck_wall", "leg 1: one kind (u %.2f)" % u)
	eq(sp.pick(2, null, 0.1, 3).id, &"truck_wall", "leg 2: two kinds")
	eq(sp.pick(2, null, 0.9, 3).id, &"rolling_roadblock")
	var only_wall := BiomeDef.new()
	only_wall.set_piece_ids = [&"slalom", &"truck_wall"]
	only_wall.set_piece_weights = PackedFloat64Array([1.0, 0.4])
	for u: float in [0.0, 0.5, 0.99]:
		eq(sp.pick(5, only_wall, u, 3).id, &"truck_wall", "a biome without roadblocks never gets one")
	var none := BiomeDef.new()
	none.set_piece_ids = [&"convoy"]
	none.set_piece_weights = PackedFloat64Array([1.0])
	eq(sp.pick(8, none, 0.5, 3), null, "nothing of the biome's mix is implemented or unlocked")
	var weights := BiomeDef.new()
	weights.set_piece_ids = [&"truck_wall", &"rolling_roadblock"]
	weights.set_piece_weights = PackedFloat64Array([1.0, 3.0])
	eq(sp.pick(8, weights, 0.2, 3).id, &"truck_wall", "biome weights 1:3")
	eq(sp.pick(8, weights, 0.3, 3).id, &"rolling_roadblock")
	eq(sp.pick(1, null, 0.5, 1), null, "one lane: no truck wall (it needs an open lane)")


func test_set_piece_batches_go_through_the_commit_path() -> void:
	# The piece's vehicles are ahead spawns like any: beyond the fog, and the cap applies.
	var t := _no_chance()
	_rig(3, 150.0, 1, t)
	var inst := _spawn(&"truck_wall")
	var min_ahead := dir.min_ahead_m()
	# The batch was committed when the player was up to a tick of distance behind now.
	ge(inst.s_rear - sc.bot.state.s + sc.bot.state.v * DT * 2.0, min_ahead - 20.0, "spawned past the fog")
	# At the cap, nothing of a piece gets through.
	var t2 := _no_chance()
	t2.traffic = tuning.traffic.duplicate() as TrafficTuning
	_rig(3, 150.0, 1, t2)
	t2.traffic.max_active_vehicles = 0
	var rej := dir.rejected_cap
	check(dir.force_set_piece(&"truck_wall"))
	_run(12.0)
	eq(dir.set_pieces.spawned, 0, "no room under the cap: no piece")
	gt(dir.rejected_cap, rej, "its records were refused at the commit")
	eq(dir.set_pieces.active_count(), 0, "and it was dropped")


# ---------------------------------------------------------------- Truck wall

func test_truck_wall_blocks_all_lanes_but_one() -> void:
	for lanes: int in [2, 3, 4]:
		_rig(lanes, 150.0)
		var inst := _spawn(&"truck_wall")
		var sp := dir.set_pieces
		eq(inst.n, lanes - 1, "%d lanes: one truck or bus per lane but one" % lanes)
		eq(_open_lanes(inst, lanes).size(), 1, "exactly one open lane")
		var s_lo := INF
		var s_hi := -INF
		for k in inst.n:
			var i := inst.slot[k]
			check(sc.sim.state.has_flag(i, TrafficState.FLAG_SCRIPTED), "scripted")
			var pid := sc.sim.state.profile_id[i]
			check(sc.registry.profiles[pid].id in [&"truck", &"bus"], "trucks and buses")
			near(sc.sim.state.v0[i], inst.speed, EPS, "matched speed")
			s_lo = minf(s_lo, sc.sim.state.s[i])
			s_hi = maxf(s_hi, sc.sim.state.s[i])
			eq(sp.instance_of(i), inst.serial)
		le(s_hi - s_lo, inst.def.row_stagger_m * 2.0 + EPS, "side by side")
		near(inst.speed, inst.def.speed_mps(sp.min_speed_mps), EPS)


func test_truck_wall_open_lane_shifts_slowly_with_telegraphing() -> void:
	# The player hangs back (a little slower than the wall): every shift_interval_s the
	# open lane moves by one, each move signaled like any lane change.
	_rig(4, 95.0)
	var inst := _spawn(&"truck_wall")
	var ctl := inst.controller as SetPieceSource.TruckWall
	_only_the_piece(inst)
	var open := ctl.open_lane
	var changes := 0
	var last_change := time
	var min_between := INF
	for k in roundi(60.0 / DT):
		_tick()
		if inst.stage != SetPieceSource.Stage.RUNNING:
			break
		if ctl.open_lane != open:
			eq(absi(ctl.open_lane - open), 1, "one lane at a time")
			min_between = minf(min_between, time - last_change)
			last_change = time
			open = ctl.open_lane
			changes += 1
			eq(_open_lanes(inst, 4).size(), 1, "still one open lane after the shift")
	ge(changes, 3, "the open lane shifts")
	ge(min_between, inst.def.shift_interval_s - 0.5, "slowly")
	eq(sc.checker.signal_violations + sc.checker.unsignaled_moves, 0, "telegraphed (rule 1)")
	eq(sc.checker.collision_pairs, 0)


func test_truck_wall_holds_its_open_lane_while_the_player_is_at_it() -> void:
	_rig(3, 150.0)
	var inst := _spawn(&"truck_wall")
	var ctl := inst.controller as SetPieceSource.TruckWall
	# Park the player 30 m behind the wall at its speed, in the open lane.
	var st := sc.bot.state
	st.s = inst.s_rear - 30.0
	sc.bot.lane = ctl.open_lane
	st.d = sc.road.lane_center_d(ctl.open_lane, st.s)
	st.v = inst.speed
	var open := ctl.open_lane
	for k in roundi(3.0 * inst.def.shift_interval_s / DT):
		_tick()
		eq(ctl.open_lane, open, "no shift with the player at the wall")
		if ctl.open_lane != open:
			break


# ---------------------------------------------------------------- Rolling roadblock

func test_rolling_roadblock_ripples_then_opens_gaps() -> void:
	_rig(3, 200.0)
	var inst := _spawn(&"rolling_roadblock")
	var sp := dir.set_pieces
	eq(inst.n, 3, "one car per lane")
	eq(_open_lanes(inst, 3).size(), 0, "across all lanes")
	# Approach until the warning, then keep the distance (the player at the row's speed).
	while _events(SetPieceSource.KIND_WARNING).is_empty() and time < 120.0:
		_tick()
	var warned: Array = _events(SetPieceSource.KIND_WARNING)
	check(not warned.is_empty(), "warned")
	sc.bot.state.v = inst.speed
	# Brake lights ripple across the row, lane by lane from the median.
	var first_brake := PackedFloat64Array([INF, INF, INF])
	var closing_seen := false
	var ctl := inst.controller as SetPieceSource.RollingRoadblock
	var gaps0 := ctl.gaps
	var t0 := time
	while time < t0 + 60.0 and inst.stage == SetPieceSource.Stage.RUNNING:
		_tick()
		for k in inst.n:
			var i := inst.slot[k]
			if sc.sim.state.has_flag(i, TrafficState.FLAG_BRAKE) and is_inf(first_brake[k]):
				first_brake[k] = time - t0
			ge(sc.sim.state.v0[i], sp.min_speed_mps - EPS, "never asked below the minimum speed + margin")
		if ctl.gap == SetPieceSource.RollingRoadblock.Gap.CLOSING:
			closing_seen = true
	for k in inst.n:
		check(not is_inf(first_brake[k]), "car %d brakes" % k)
	check(first_brake[0] < first_brake[1] and first_brake[1] < first_brake[2], "the ripple runs across the row")
	check(closing_seen, "a gap opened (a car dropped back gap_distance_m)")
	var d := inst.def
	ge(ctl.gaps - gaps0, floori(60.0 / (d.gap_interval_s + 2.0 * d.gap_phase_max_s)), "gaps open every few seconds")
	eq(sc.checker.collision_pairs + sc.checker.decel_violations, 0)


# ---------------------------------------------------------------- Events, release, rule 4

func test_warnings_start_and_end_then_release() -> void:
	_rig(3, 170.0)
	var inst := _spawn(&"truck_wall")
	var ctl := inst.controller as SetPieceSource.TruckWall
	# Drive through the open lane at a constant speed.
	var serial := inst.serial
	var slots := inst.slot.duplicate()
	var natural := inst.natural_v0.duplicate()
	var n := inst.n
	sc.bot.lane = ctl.open_lane
	var guard := 0
	while inst.stage == SetPieceSource.Stage.RUNNING and guard < roundi(120.0 / DT):
		sc.bot.lane = ctl.open_lane
		_tick()
		guard += 1
	var w: Array = _events(SetPieceSource.KIND_WARNING)
	var s: Array = _events(SetPieceSource.KIND_STARTED)
	var e: Array = _events(SetPieceSource.KIND_ENDED)
	eq(w.size(), inst.def.warning_sign_distances_m.size(), "one warning per distance")
	eq(s.size(), 1, "started once")
	eq(e.size(), 1, "ended once")
	if w.size() > 0 and s.size() > 0 and e.size() > 0:
		check(w[0][0] < s[0][0] and s[0][0] < e[0][0], "warning, start, end in order")
		eq(w[0][2], &"truck_wall", "tagged with the id")
		le(float(w[0][3]), inst.def.warning_sign_distances_m[0] + EPS, "at the warning distance")
		ge(float(w[0][3]), inst.def.warning_sign_distances_m[0] - 5.0)
		eq(int(w[0][4]), serial)
	for k in n:
		var i := slots[k]
		if sc.sim.state.is_active(i):
			check(not sc.sim.state.has_flag(i, TrafficState.FLAG_SCRIPTED), "released to ordinary traffic")
			near(sc.sim.state.v0[i], natural[k], EPS, "its own desired speed back")
			eq(dir.set_pieces.instance_of(i), -1)
	eq(dir.set_pieces.started, 1)
	eq(dir.set_pieces.ended, 1)
	eq(sc.checker.collision_pairs, 0)


func test_hard_decel_only_after_a_300m_warning() -> void:
	var min_w := tuning.director.set_piece_min_warning_m
	for dist: float in [min_w + 50.0, min_w - 50.0]:
		_rig(3, 170.0)
		var def: SetPieceDef = dir.set_pieces.defs[&"rolling_roadblock"].duplicate()
		def.allows_hard_decel = true
		def.warning_sign_distances_m = PackedFloat64Array([dist])
		dir.set_pieces.defs[&"rolling_roadblock"] = def
		var inst := _spawn(&"rolling_roadblock")
		while _events(SetPieceSource.KIND_WARNING).is_empty() and time < 120.0:
			_tick()
		_tick()
		var allowed := 0
		for k in inst.n:
			if sc.sim.hard_decel_allowed(inst.slot[k]):
				allowed += 1
		if dist >= min_w:
			eq(allowed, inst.n, "announced %.0f m ahead: may brake beyond the clamp" % dist)
			ge(sc.checker.set_piece_warned_m(inst.serial), min_w, "the checker measured the warning")
		else:
			eq(allowed, 0, "announced only %.0f m ahead: never beyond the clamp" % dist)


func test_scripted_vehicles_keep_the_clamp_without_permission() -> void:
	# A FLAG_SCRIPTED car closing fast on a stopped one: 6 m/s² at most unless allowed.
	for allow: bool in [false, true]:
		var s := TrafficScenario.new(SEED, 3)
		s.spawner_enabled = false
		s.make_bot(TrafficBotPlayer.Mode.CRUISE, 100.0, 2)
		s.bot.state.s = -2000.0
		s.add(400.0, 0, &"commuter", &"sedan", 0.0, 1.0)
		var car := s.add(300.0, 0, &"commuter", &"sedan", 120.0, 120.0, NAN, TrafficState.FLAG_SCRIPTED)
		s.sim.set_hard_decel_allowed(car, allow)
		var min_a := 0.0
		for k in roundi(6.0 / DT):
			s.tick()
			min_a = minf(min_a, s.sim.state.accel[car])
		if allow:
			lt(min_a, -tuning.traffic.max_decel_mps2 - 0.1, "allowed: beyond the clamp")
			ge(min_a, -tuning.traffic.scripted_max_decel_mps2 - EPS, "never beyond the scripted limit")
		else:
			ge(min_a, -tuning.traffic.max_decel_mps2 - EPS, "not allowed: the clamp holds")


func test_rule_checker_allows_hard_decel_only_to_warned_set_pieces() -> void:
	var reg := TrafficRegistry.load_default(tuning.traffic)
	var road := StraightRoadPath.new(3, tuning.road)
	var player := VehicleState.new()
	player.s = 0.0
	player.d = road.lane_center_d(2, 0.0)
	player.v = 40.0
	for case: int in 4:
		var ts := TrafficState.new(4)
		var i := ts.allocate()
		ts.s[i] = 400.0 if case != 1 else 250.0
		ts.d[i] = road.lane_center_d(0, ts.s[i])
		ts.v[i] = 30.0
		ts.length[i] = 4.8
		ts.width[i] = 1.85
		ts.profile_id[i] = reg.profile_index(&"commuter")
		ts.accel[i] = -8.0
		ts.flags[i] = TrafficState.FLAG_BRAKE | TrafficState.FLAG_BRAKE_STRONG \
			| (TrafficState.FLAG_SCRIPTED if case != 2 else 0)
		var c := TrafficRuleChecker.new(tuning, reg, road, 4.5, 1.9)
		if case != 3:
			c.set_piece_of = func(slot: int) -> int: return 7 if slot == i else -1
		c.note_set_piece_warning(7, ts, player)
		c.observe(0.0, ts, player)
		match case:
			0:
				eq(c.decel_violations, 0, "warned 400 m ahead: allowed")
				eq(c.set_piece_hard_decels, 1)
			1:
				eq(c.decel_violations, 1, "warned only 250 m ahead: a violation")
			2:
				eq(c.decel_violations, 1, "not scripted: a violation")
			3:
				eq(c.decel_violations, 1, "no set piece mapping: a violation")


# ---------------------------------------------------------------- Keeping clear, determinism

func test_flow_keeps_clear_of_a_live_piece() -> void:
	_rig(3, 150.0)
	var inst := _spawn(&"truck_wall")
	var sp := dir.set_pieces
	var max_vid := 0
	for i in sc.sim.state.capacity:
		if sc.sim.state.active[i] == 1:
			max_vid = maxi(max_vid, sc.sim.state.vehicle_id[i])
	var checked := 0
	for k in roundi(40.0 / DT):
		_tick()
		if inst.stage != SetPieceSource.Stage.RUNNING:
			break
		for i in sc.sim.state.capacity:
			if sc.sim.state.active[i] == 0 or sc.sim.state.vehicle_id[i] <= max_vid:
				continue
			max_vid = maxi(max_vid, sc.sim.state.vehicle_id[i])
			if sp.instance_of(i) >= 0 or sc.sim.state.s[i] < sc.bot.state.s:
				continue
			checked += 1
			var s := sc.sim.state.s[i]
			check(s < inst.s_rear - inst.def.clear_behind_m or s > inst.s_front + inst.def.clear_ahead_m,
				"a new ahead spawn at %.0f m keeps out of the wall's zone [%.0f, %.0f]" % [s, inst.s_rear, inst.s_front])
	gt(checked, 5, "new traffic was planned meanwhile")


func _piece_trace(seed_value: int) -> String:
	# Every peak gets a piece (chance 100%): the first one, where and how it is laid out.
	var t: Tuning = tuning.duplicate()
	t.director = tuning.director.duplicate() as DirectorTuning
	t.director.set_piece_chance_first_pct = 100.0
	t.director.set_piece_chance_last_pct = 100.0
	_rig(3, 200.0, 1, t, seed_value)
	var out := ""
	while sc.bot.state.s < 5000.0 and out == "":
		_tick()
		for inst in dir.set_pieces.instances:
			if inst.stage == SetPieceSource.Stage.RUNNING:
				out = "%d:%s@%.3f lanes %s" % [inst.serial, inst.def.id, inst.s_rear, str(_lanes_of(inst))]
	return out


func test_set_pieces_are_deterministic_by_seed() -> void:
	var a := _piece_trace(SEED)
	var b := _piece_trace(SEED)
	print("      pieces: %s" % a)
	ne(a, "", "pieces were scheduled at the peaks")
	eq(a, b, "same seed, same pieces")
	ne(_piece_trace(SEED + 5), a, "another seed differs")
