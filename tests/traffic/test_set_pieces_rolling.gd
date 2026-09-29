extends WBTest
## The rolling set pieces of WP6.3 (slalom, convoy), rule 4 for every WP6.3 piece and
## the pieces' determinism. Spec: Traffic → Traffic director, set-piece table ("Slalom |
## Staggered cars across lanes forming an S-line of gaps | None needed (all visible)";
## "Convoy | A slow line of same-color vehicles with hazards on, honking | Visible");
## Fairness rules 1, 2, 4 ("no deceleration above 6 m/s² except in set pieces announced
## at least 300 m ahead"); Traffic → Tests (determinism). docs/SET_PIECES.md.

const SEED := 630401
const EPS := 1e-6
## The determinism runs: seconds after each forced piece, and the seed (a road on which
## all three fit: none on a blind stretch, the rolling ones clear of the works).
const MIX_STEP_S := 8.0
const MIX_SEED := SEED + 2

var tuning: Tuning


func before_all() -> void:
	tuning = Tuning.load_default()


## Legs long enough that a forced formation is never near a checkpoint.
func _long_legs() -> Tuning:
	var t: Tuning = tuning.duplicate()
	t.legs = tuning.legs.duplicate() as LegsTuning
	t.legs.leg_length_km = 12.0
	return t


# ---------------------------------------------------------------- Slalom

func test_slalom_rows_leave_one_lane_open_in_an_s_line() -> void:
	for lanes: int in [2, 3, 4]:
		var r := SetPieceRig.new(SEED + lanes, lanes, null, _long_legs(), 200.0, 0)
		var inst := r.force(&"slalom")
		if not check(inst != null, "%d lanes: live" % lanes):
			continue
		var sl := inst.controller as SlalomPiece
		var rows := sl.open_lanes.size()
		ge(rows, inst.def.vehicles_min, "rows")
		le(rows, inst.def.vehicles_max)
		le(inst.n, rows * (lanes - 1), "a car in every lane but one, per row")
		ge(inst.n, rows * (lanes - 1) - 1, "(one may not have fitted the live traffic)")
		for k in range(1, rows):
			eq(absi(sl.open_lanes[k] - sl.open_lanes[k - 1]), 1, "the open lane moves one lane per row")
		# Every row: its open lane is free, the others taken; rows at least row_gap_m apart.
		var row_lo := PackedFloat64Array()
		var row_hi := PackedFloat64Array()
		row_lo.resize(rows)
		row_hi.resize(rows)
		row_lo.fill(INF)
		row_hi.fill(-INF)
		for j in inst.n:
			var i := inst.slot[j]
			var rw := inst.row[j]
			ne(r.sim.state.lane[i], sl.open_lanes[rw], "row %d keeps its open lane free" % rw)
			var hl := r.sim.state.length[i] * 0.5
			row_lo[rw] = minf(row_lo[rw], r.sim.state.s[i] - hl)
			row_hi[rw] = maxf(row_hi[rw], r.sim.state.s[i] + hl)
		for k in range(1, rows):
			ge(row_lo[k] - row_hi[k - 1], inst.def.row_gap_m - 0.5, "rows a lane change apart")


func test_slalom_holds_its_shape_and_a_bot_threads_it() -> void:
	var r := SetPieceRig.new(SEED, 3, null, _long_legs(), 200.0, 0)
	var inst := r.force(&"slalom")
	if not check(inst != null, "live"):
		return
	var sl := inst.controller as SlalomPiece
	r.only_the_piece(inst)
	# The bot threads it at the piece's speed + 60 km/h: in each row's open lane when it
	# gets there, one lane change (its own, 1 s) between rows.
	var st := r.bot.state
	var rows := sl.open_lanes.size()
	st.s = inst.s_rear - 120.0
	r.bot.set_weave(1e9, 1e9)
	r.bot.follow = false   # it holds its speed: only its lane changes get it through
	r.bot.lane = sl.open_lanes[0]
	st.d = r.road.lane_center_d(r.bot.lane, st.s)
	r.bot.v_target = inst.speed + Units.kmh_to_mps(60.0)
	st.v = r.bot.v_target
	r.hits.reset(st, null)
	var lanes0 := PackedInt32Array()
	for j in inst.n:
		lanes0.append(r.sim.state.lane[inst.slot[j]])
	var row := 0
	var windows := ImpossibleWindowChecker.new(r.tuning, r.registry, load("res://data/cars/falcon_gt.tres") as CarDef)
	var blocked := 0
	for k in roundi(30.0 / SetPieceRig.DT):
		var hl := r.bot.length_m * 0.5
		while row < rows and st.s - hl > _row_front(r, inst, row) + 1.0:
			row += 1
		if row >= rows:
			break
		var target := sl.open_lanes[row]
		if r.bot.lane != target and not r.bot.is_changing_lanes() and (row == 0 or st.s - hl > _row_front(r, inst, row - 1)):
			r.bot.change_lane(r.bot.lane + signi(target - r.bot.lane))
		if k % 60 == 0 and not windows.is_passable(r.sim.state, st, r.road):
			blocked += 1
		r.tick()
	eq(row, rows, "the bot got past every row")
	eq(r.checker.contact_episodes, 0, "without touching a car")
	eq(blocked, 0, "a path through it all along (the impossible-window oracle)")
	for j in inst.n:
		if r.dir.set_pieces.alive(inst, j):
			eq(r.sim.state.lane[inst.slot[j]], lanes0[j], "the slalom cars never change lanes")
	eq(r.checker.collision_pairs + r.checker.decel_violations, 0)
	ge(inst.speed, tuning.scoring.min_speed_mps(), "following it is a valid path")


## The front bumper of the slalom's row `row` (the furthest one of its live cars).
func _row_front(r: SetPieceRig, inst: SetPieceSource.Instance, row: int) -> float:
	var f := -INF
	for j in inst.n:
		if inst.row[j] == row and r.dir.set_pieces.alive(inst, j):
			var i := inst.slot[j]
			f = maxf(f, r.sim.state.s[i] + r.sim.state.length[i] * 0.5)
	return f


# ---------------------------------------------------------------- Convoy

func test_convoy_is_one_same_colour_line_with_hazards_that_honks() -> void:
	var r := SetPieceRig.new(SEED + 1, 3, null, _long_legs(), 200.0, 0)
	var inst := r.force(&"convoy")
	if not check(inst != null, "live"):
		return
	var cv := inst.controller as ConvoyPiece
	var ts := r.sim.state
	ge(inst.n, inst.def.vehicles_min, "a line")
	var i0 := inst.slot[0]
	for j in inst.n:
		var i := inst.slot[j]
		eq(ts.lane[i], cv.line_lane, "one lane")
		eq(ts.color_index[i], ts.color_index[i0], "the same color")
		eq(ts.type_id[i], ts.type_id[i0], "the same vehicle")
		eq(ts.model_variant[i], ts.model_variant[i0])
		check(ts.has_flag(i, TrafficState.FLAG_HAZARD), "hazards on")
	check(cv.line_lane >= inst.lanes - 2, "a slow line keeps right")
	near(inst.speed, r.dir.set_pieces.min_speed_mps, EPS, "slow: the slowest a piece may be")
	ge(inst.speed, tuning.scoring.min_speed_mps(), "above the minimum speed")
	# The player comes alongside in the next lane: the line holds, keeps its hazards, honks.
	r.only_the_piece(inst)
	var st := r.bot.state
	var side := cv.line_lane - 1
	r.bot.keep_lane()
	r.bot.lane = side
	st.s = inst.s_rear - 150.0
	st.d = r.road.lane_center_d(side, st.s)
	r.bot.v_target = inst.speed + Units.kmh_to_mps(40.0)
	st.v = r.bot.v_target
	var serial := inst.serial
	var slots := inst.slot.duplicate()
	var n := inst.n
	var ended := false
	for k in roundi(50.0 / SetPieceRig.DT):
		r.tick()
		if r.dir.set_pieces.instance_by_serial(serial) == null:
			ended = true
			break
		for j in inst.n:
			var i := inst.slot[j]
			eq(ts.lane[i], cv.line_lane, "stays in lane")
			check(ts.has_flag(i, TrafficState.FLAG_HAZARD), "hazards stay on")
			if ts.lane[i] != cv.line_lane or not ts.has_flag(i, TrafficState.FLAG_HAZARD):
				return
	gt(cv.honks, 0, "it honks while the player is alongside")
	var from_convoy := 0
	for h: Array in r.horns:
		if slots.slice(0, n).has(int(h[1])):
			from_convoy += 1
	ge(from_convoy, cv.honks, "horn events from the convoy (audio)")
	check(ended, "it ended when the player passed")
	for j in n:
		var i := slots[j]
		if ts.active[i] == 1:
			check(not ts.has_flag(i, TrafficState.FLAG_HAZARD), "released: hazards off")
			check(not ts.has_flag(i, TrafficState.FLAG_SCRIPTED), "released: ordinary traffic")
	eq(r.checker.collision_pairs + r.checker.total_violations(), 0)


# ---------------------------------------------------------------- Rule 4 and determinism

func _no_hard_braking(id: StringName) -> void:
	# The piece runs within 6 m/s^2: it does not ask for the rule-4 exception, the sim
	# never grants it, the independent checker sees no violation.
	var r := SetPieceRig.new(SEED + 3, 3, null, _long_legs(), 200.0, 1)
	var inst := r.force(id)
	if not check(inst != null, "%s live" % id):
		return
	var serial := inst.serial
	var min_a := 0.0
	var granted := 0
	for k in roundi(20.0 / SetPieceRig.DT):
		r.tick()
		if r.dir.set_pieces.instance_by_serial(serial) == null:
			break
		for j in inst.n:
			if r.dir.set_pieces.alive(inst, j):
				var i := inst.slot[j]
				min_a = minf(min_a, r.sim.state.accel[i])
				if r.sim.hard_decel_allowed(i):
					granted += 1
	eq(granted, 0, "%s: no hard-decel permission" % id)
	ge(min_a, -tuning.traffic.max_decel_mps2 - EPS, "%s: within the clamp" % id)
	eq(r.checker.decel_violations, 0, "%s: the checker agrees" % id)
	eq(r.checker.set_piece_hard_decels, 0)


func test_no_hard_braking_slalom() -> void:
	_no_hard_braking(&"slalom")


func test_no_hard_braking_convoy() -> void:
	_no_hard_braking(&"convoy")


func test_no_hard_braking_merge_zone() -> void:
	_no_hard_braking(&"merge_zone")


func _mix_trace(seed_value: int) -> String:
	# Three pieces at once (a slalom, a convoy, then a road works forced on top) and
	# every peak a piece: what gets laid out where, and the traffic's state hash along
	# the way (every second).
	var t := _long_legs()
	t.director = tuning.director.duplicate() as DirectorTuning
	t.director.set_pieces_unlocked_by_leg = PackedInt32Array([7])
	t.director.set_piece_max_active = 3
	var r := SetPieceRig.new(seed_value, 3, null, t, 230.0, 1, 0.0, 6)
	r.tuning.director.set_piece_chance_first_pct = 100.0
	r.tuning.director.set_piece_chance_last_pct = 100.0
	r.dir.set_density_scale(0.4)
	var out := ""
	var h := TraceHash.SEED
	var seen := {}
	for id: StringName in [&"slalom", &"convoy", &"road_works"]:
		r.dir.force_set_piece(id)
		for k in roundi(MIX_STEP_S / SetPieceRig.DT):
			r.tick()
			if k % 120 == 0:
				h = r.sim.state.hash_into(h)
			for inst in r.dir.set_pieces.instances:
				if inst.stage == SetPieceSource.Stage.RUNNING and not seen.has(inst.serial):
					seen[inst.serial] = true
					out += "%d:%s@%.3f/%.3f " % [inst.serial, inst.def.id, inst.zone_s0 if inst.is_anchored() else inst.s_rear,
						inst.zone_s1 if inst.is_anchored() else inst.s_front]
	return out + str(h)


func test_set_pieces_are_deterministic_by_seed() -> void:
	var a := _mix_trace(MIX_SEED)
	var b := _mix_trace(MIX_SEED)
	print("      %s" % a)
	eq(a.count(":"), 3, "all three pieces were laid out")
	eq(a, b, "same seed, same pieces, same traffic")


func test_another_seed_gives_other_traffic() -> void:
	ne(_mix_trace(MIX_SEED + 1), _mix_trace(MIX_SEED), "another seed differs")
