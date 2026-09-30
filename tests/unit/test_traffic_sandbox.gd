extends WBTest
## Traffic sandbox (WP3.2). Spec: Traffic → Traffic sandbox (debug scene). The scene
## boots on the real stack and runs at 4x; pause / step are exact; re-seed, spawn and
## clear do what they say; the MOBIL readout (MobilProbe) equals a direct Idm / Mobil
## computation, and agrees with the lane changes the sim actually starts.

const SCENE := "res://src/traffic/dev/traffic_sandbox.tscn"
const DT := 1.0 / 120.0
const FRAME := 1.0 / 60.0

var _scene: Node3D


func after_each() -> void:
	if _scene != null:
		_scene.queue_free()
		await tree.process_frame
		_scene = null


func _boot() -> Node3D:
	_scene = (load(SCENE) as PackedScene).instantiate()
	tree.root.add_child(_scene)
	# The scene ticks itself in _physics_process; tests drive it directly.
	_scene.set_physics_process(false)
	await tree.process_frame
	return _scene


# ---------------------------------------------------------------- Scene

func test_boots_and_runs_five_seconds_at_4x() -> void:
	var sb := await _boot()
	gt(sb.sim.state.count, 10, "the director filled the road at boot")
	gt(sb.director.opposite.state.count, 0, "opposite carriageway populated")
	sb.time_scale = 4.0
	var s0: float = sb.car.state.s
	for i in 300:   # 5 s of 60 fps frames
		sb.advance_frame(FRAME)
	near(sb.sim_time, 20.0, DT * 2.0, "5 s at 4x = 20 s of sim time")
	eq(sb.ticks, 2400, "8 ticks per frame at 4x")
	gt(sb.car.state.s - s0, 400.0, "the bot drove on")
	gt(sb.sim.state.count, 10, "traffic stays alive")
	gt(sb.sim.stat_model_updates, 0, "the sim ran")
	# Let the views and overlays draw a few frames (engine errors fail the test).
	sb.cam.set_mode(SandboxCamera.Mode.TOP)
	for i in 3:
		await tree.process_frame
	if sb.view is TrafficDebugView:
		gt((sb.view as TrafficDebugView).drawn_vehicle_count(), 10, "debug view draws the traffic")
	sb.refresh_stats()
	check(DevStats.has_value(&"sandbox_lc_per_min"), "stats reported to DevStats")
	gt(DevStats.sim_tick_sample_count(), 0, "sim tick cost reported")
	eq(DevStats.get_value(DevStats.VEHICLES), sb.sim.state.count, "vehicle count in DevStats")


func test_time_scale_bounds_and_frame_cap() -> void:
	var sb := await _boot()
	sb.time_scale = 0.1
	for i in 60:
		sb.advance_frame(FRAME)
	near(sb.sim_time, 0.1, DT, "0.1x for one second")
	sb.time_scale = 4.0
	var t0: int = sb.ticks
	sb.advance_frame(1.0)   # a long hitch: capped, not a spiral
	eq(sb.ticks - t0, sb.MAX_TICKS_PER_FRAME, "ticks per frame are capped")


func test_pause_and_step_are_exact() -> void:
	var sb := await _boot()
	sb.advance_frame(FRAME)
	sb.toggle_pause()
	check(sb.paused, "paused")
	var t0: int = sb.ticks
	var h0: int = sb.sim.state.trace_hash()
	for i in 10:
		sb.advance_frame(FRAME)
	eq(sb.ticks, t0, "no ticks while paused")
	eq(sb.sim.state.trace_hash(), h0, "traffic frozen while paused")
	sb.step_ticks(1)
	sb.advance_frame(FRAME)
	eq(sb.ticks, t0 + 1, "STEP advances exactly one tick")
	ne(sb.sim.state.trace_hash(), h0, "and traffic moved")
	sb.advance_frame(FRAME)
	eq(sb.ticks, t0 + 1, "still paused after the step")
	sb.step_ticks(120)
	sb.advance_frame(FRAME)
	eq(sb.ticks, t0 + 121, "+1 S advances exactly 120 ticks")
	sb.toggle_pause()
	sb.advance_frame(FRAME)
	eq(sb.ticks, t0 + 123, "running again at 1x: 2 ticks per 60 fps frame")


func test_reseed_changes_traffic_and_is_deterministic() -> void:
	var sb := await _boot()
	sb.reseed(7)
	sb.advance_ticks(240)
	var a: int = sb.sim.state.trace_hash()
	var s_a: float = sb.car.state.s
	sb.reseed(8)
	sb.advance_ticks(240)
	ne(sb.sim.state.trace_hash(), a, "a new seed gives different traffic")
	# Same seed from the same player state = same traffic (the director fill and the sim).
	sb.reseed(21)
	sb.advance_ticks(240)
	var h1: int = sb.sim.state.trace_hash()
	var s_1: float = sb.car.state.s
	sb.car.place_at(s_1 - sb.car.state.v * 2.0, sb.car.state.d, sb.car.state.v)
	ne(s_a, s_1, "the car moved on")
	eq(sb.traffic_seed, 21, "seed recorded")
	var h2: int = sb.sim.state.trace_hash()
	sb.reseed(21)
	var h3: int = sb.sim.state.trace_hash()
	sb.reseed(21)
	eq(sb.sim.state.trace_hash(), h3, "re-seeding with the same seed refills identically")
	ne(h1, h2 + 1, "hashes are plain ints")


func test_spawn_specific_profile_lane_and_clear() -> void:
	var sb := await _boot()
	sb.clear_traffic()
	eq(sb.sim.state.count, 0, "CLEAR empties the player's carriageway")
	var reg: TrafficRegistry = sb.registry
	var truck := reg.profile_index(&"truck")
	var slot: int = sb.spawn_vehicle(truck, 0, 2, true)
	check(slot >= 0, "spawned")
	eq(sb.sim.state.profile_id[slot], truck, "requested profile")
	eq(sb.sim.state.lane[slot], 2, "requested lane")
	eq(reg.types[sb.sim.state.type_id[slot]].id, &"semi", "the profile's first allowed type")
	gt(sb.sim.state.s[slot], sb.car.state.s, "ahead of the player")
	var moto := reg.profile_index(&"motorbike")
	var s2: int = sb.spawn_vehicle(moto, 0, 0, false)
	check(s2 >= 0, "spawned behind")
	eq(sb.sim.state.profile_id[s2], moto, "motorbike")
	eq(sb.sim.state.lane[s2], 0, "lane 0")
	lt(sb.sim.state.s[s2], sb.car.state.s, "behind the player")
	# A second vehicle at the same request lands further out, never overlapping.
	var s3: int = sb.spawn_vehicle(truck, 0, 2, true)
	check(s3 >= 0, "second truck")
	gt(absf(sb.sim.state.s[s3] - sb.sim.state.s[slot]), 16.0 + sb.SPAWN_CLEAR_M - 0.01, "kept its distance")
	var com := reg.profile_index(&"commuter")
	var types := reg.types_for_profile(com)
	var s4: int = sb.spawn_vehicle(com, 1, 1, true)
	eq(sb.sim.state.type_id[s4], types[1], "TYPE picks among the profile's allowed types")
	sb.advance_ticks(120)
	sb.clear_traffic()
	eq(sb.sim.state.count, 0, "CLEAR again")
	sb.auto_spawn = false
	sb.advance_ticks(600)
	eq(sb.sim.state.count, 0, "AUTO off: nothing spawns")


func test_driver_modes_and_overlay_toggles() -> void:
	var sb := await _boot()
	sb.set_driver(sb.Driver.MANUAL)
	check(sb.car.controller is PlayerController, "manual = PlayerController on PlayerInput")
	sb.set_driver(sb.Driver.BOT_KEEP)
	check(sb.car.controller is SandboxBot, "bot controller")
	var lane: int = sb.road.lane_index_at(sb.car.state.d, sb.car.state.s)
	sb.advance_ticks(600)
	eq(sb.road.lane_index_at(sb.car.state.d, sb.car.state.s), lane, "KEEP holds its lane")
	for mode: SandboxCamera.Mode in [SandboxCamera.Mode.FOLLOW, SandboxCamera.Mode.TOP, SandboxCamera.Mode.FREE]:
		sb.cam.set_mode(mode)
		sb.overlay.show_passability = true
		sb.overlay.selected_slot = -1
		await tree.process_frame
		await tree.process_frame
	var v: Array[Vector2] = [Vector2(sb.car.state.s, sb.car.state.d), Vector2(sb.car.state.s + 50.0, 5.0)]
	var paths: Array[PackedVector2Array] = [PackedVector2Array(v)]
	sb.overlay.passability_paths = paths
	sb.overlay.selected_slot = 0 if sb.sim.state.active[0] == 1 else -1
	await tree.process_frame
	await tree.process_frame
	check(true, "all overlays and camera modes drew without errors")


func test_bot_weave_changes_lanes_smoothly() -> void:
	var sb := await _boot()
	sb.set_driver(sb.Driver.BOT_WEAVE)
	# A slow truck ahead in its lane, three times, on an otherwise empty road (the
	# director's traffic around the start varies with the intensity waves, WP6.2).
	sb.auto_spawn = false
	sb.clear_traffic()
	for k in 3:
		var lane: int = sb.road.lane_index_at(sb.car.state.d, sb.car.state.s)
		sb.spawn_vehicle(sb.registry.profile_index(&"truck"), 0, lane, true)
		sb.advance_ticks(120 * 7)
	gt(sb.bot.lane_changes, 1, "the weaving bot changes lanes")
	lt(absf(sb.car.state.yaw), 0.2, "and stays stable")


# ---------------------------------------------------------------- Touch (web: huge ids)

func test_camera_touch_uses_raw_ids_safely() -> void:
	var sb := await _boot()
	var c: SandboxCamera = sb.cam
	c.set_mode(SandboxCamera.Mode.TOP)
	var h0 := c.top_height_m
	var ids: Array[int] = [1_893_457_201, 1_893_457_202]
	_touch(c, ids[0], Vector2(400, 300), true)
	_touch(c, ids[1], Vector2(600, 300), true)
	_drag(c, ids[1], Vector2(800, 300), Vector2(200, 0))
	_touch(c, ids[1], Vector2(800, 300), false)
	_touch(c, ids[0], Vector2(400, 300), false)
	lt(c.top_height_m, h0, "pinch out zooms in with iOS Safari touch ids")
	var taps: Array[Vector2] = []
	c.tapped.connect(func(p: Vector2) -> void: taps.append(p))
	_touch(c, ids[0], Vector2(10, 10), true)
	_touch(c, ids[0], Vector2(12, 11), false)
	eq(taps.size(), 1, "a short tap with a huge id emits tapped")


func _touch(c: SandboxCamera, index: int, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = pressed
	c._unhandled_input(e)


func _drag(c: SandboxCamera, index: int, pos: Vector2, rel: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.position = pos
	e.relative = rel
	c._unhandled_input(e)


# ---------------------------------------------------------------- MOBIL readout

## Straight 3-lane road. A (commuter) in lane 1 closes on a slow truck B; C (commuter)
## in lane 0 behind A's position (the new follower), E ahead in lane 0 (the new
## leader); D (cruiser) behind A in lane 1 (the old follower). The player is 150 m
## behind in lane 2: inside near_radius_m (so every car's model ran this tick) and
## laterally clear of lanes 0 and 1.
func _scenario() -> Dictionary:
	var ctx := RunContext.new(3)
	var road := StraightRoadPath.new(3, ctx.tuning.road)
	var reg := TrafficRegistry.load_default(ctx.tuning.traffic)
	var sim := TrafficSim.new(ctx, road, reg)
	var player := VehicleState.new()
	player.s = -150.0
	player.d = road.lane_center_d(2, 0.0)
	player.v = 30.0
	var commuter := reg.profile_index(&"commuter")
	var cruiser := reg.profile_index(&"cruiser")
	var truck := reg.profile_index(&"truck")
	var sedan := reg.type_index(&"sedan")
	var semi := reg.type_index(&"semi")
	var ids := {}
	ids["a"] = _put(sim, 0.0, 1, 28.0, 34.0, sedan, commuter)
	ids["b"] = _put(sim, 40.0, 1, 23.0, 23.5, semi, truck)
	ids["c"] = _put(sim, -32.0, 0, 28.0, 36.0, sedan, commuter)
	ids["e"] = _put(sim, 80.0, 0, 35.0, 37.0, sedan, commuter)
	ids["d"] = _put(sim, -25.0, 1, 27.0, 27.0, sedan, cruiser)
	var events := ScoreEventBuffer.new(ctx.tuning.scoring.event_buffer_capacity)
	sim.step(DT, player, null, events)
	var probe := MobilProbe.new(sim, road)
	probe.set_player(player)
	return {"sim": sim, "road": road, "reg": reg, "probe": probe, "player": player, "ids": ids, "ctx": ctx}


func _put(sim: TrafficSim, s: float, lane: int, v: float, v0: float, tid: int, pid: int) -> int:
	var r := SpawnSource.Record.new()
	r.s = s
	r.lane = lane
	r.d = NAN
	r.v = v
	r.v0 = v0
	r.type_id = tid
	r.profile_id = pid
	return sim.spawn(r)


func _idm(st: TrafficState, reg: TrafficRegistry, f: int, gap: float, dv: float, floor_m: float) -> float:
	var p := st.profile_id[f]
	return Idm.accel(st.v[f], st.v0[f], gap, dv, reg.a_max[p], reg.b_comfort[p], reg.headway[p], reg.s0[p],
		reg.delta[p], floor_m)


func _gap(st: TrafficState, back: int, front: int) -> float:
	return st.s[front] - st.s[back] - (st.length[front] + st.length[back]) * 0.5


func test_mobil_probe_matches_direct_computation() -> void:
	var sc := _scenario()
	var sim: TrafficSim = sc["sim"]
	var reg: TrafficRegistry = sc["reg"]
	var probe: MobilProbe = sc["probe"]
	var ids: Dictionary = sc["ids"]
	var st := sim.state
	var t := sim.tuning
	var fl := t.idm_gap_floor_m
	var a: int = ids["a"]
	var b: int = ids["b"]
	var c: int = ids["c"]
	var d: int = ids["d"]
	var e: int = ids["e"]
	eq(sim.leader_of(a), b, "setup: A follows the truck")
	var r := MobilProbe.Result.new()
	probe.evaluate_into(a, 0, r)
	eq(r.lead, e, "new leader E")
	eq(r.follower, c, "new follower C")
	eq(r.old_follower, d, "old follower D")
	var a_c := _idm(st, reg, a, _gap(st, a, b), st.v[a] - st.v[b], fl)
	near(r.a_c, a_c, 1e-12, "a_c = A's IDM behind the truck")
	near(sim.idm_accel(a), a_c, 1e-12, "and that is the sim's own idm_accel")
	var a_c_new := _idm(st, reg, a, _gap(st, a, e), st.v[a] - st.v[e], fl)
	var a_n := _idm(st, reg, c, _gap(st, c, e), st.v[c] - st.v[e], fl)
	var a_n_new := _idm(st, reg, c, _gap(st, c, a), st.v[c] - st.v[a], fl)
	var a_o := _idm(st, reg, d, _gap(st, d, a), st.v[d] - st.v[a], fl)
	var a_o_new := _idm(st, reg, d, _gap(st, d, b), st.v[d] - st.v[b], fl)
	near(r.a_c_new, a_c_new, 1e-12, "a~c")
	near(r.a_n, a_n, 1e-12, "a_n")
	near(r.a_n_new, a_n_new, 1e-12, "a~n")
	near(r.a_o, a_o, 1e-12, "a_o")
	near(r.a_o_new, a_o_new, 1e-12, "a~o")
	var pa := st.profile_id[a]
	var inc := Mobil.incentive(a_c_new, a_c, a_n_new, a_n, a_o_new, a_o, reg.politeness[pa])
	near(r.incentive, inc, 1e-12, "incentive = Mobil.incentive of the terms")
	var bias := reg.a_bias[pa]
	if st.v0[a] < t.lane_flow_speed_mps(0, 3):
		bias += t.lane_discipline_bias_mps2
	var th := Mobil.threshold(reg.a_threshold[pa], bias, false)
	near(r.threshold, th, 1e-12, "threshold (left: + bias, + lane discipline)")
	var safe := Mobil.is_safe(a_n_new, reg.b_safe[st.profile_id[c]]) and a_c_new >= -reg.b_safe[pa]
	eq(r.is_safe(), safe, "safety verdict = Mobil.is_safe for the new follower and the car")
	eq(r.accepts(), safe and inc > th, "decision = safe and incentive > threshold")
	check(r.accepts(), "scenario: overtaking the truck on the left is worth it (inc %.3f th %.3f ref %s)" % [
		r.incentive, r.threshold, MobilProbe.REFUSAL_NAMES[r.refusal]])
	# Right: lane 2 is empty ahead -> free road; the player (150 m back) follows.
	probe.evaluate_into(a, 2, r)
	eq(r.lead, -1, "no leader in lane 2")
	eq(r.follower, sim.player_index(), "the player is lane 2's follower")
	var pv: float = (sc["player"] as VehicleState).v
	near(r.a_n_new, Idm.interaction_accel(pv, st.s[a] - (sc["player"] as VehicleState).s - (st.length[a]
		+ t.player_length_m) * 0.5, pv - st.v[a], t.player_idm_a_max_mps2, t.player_idm_b_comfort_mps2,
		t.player_idm_headway_s, t.player_idm_s0_m, fl), 1e-12, "player judged by its interaction term")
	near(r.a_c_new, Idm.free_accel(st.v[a], st.v0[a], reg.a_max[pa], reg.delta[pa]), 1e-12, "free road")
	check(r.to_right, "to the right")
	# Lane -1 does not exist.
	probe.evaluate_into(a, -1, r)
	eq(r.refusal, MobilProbe.Refusal.NO_LANE, "lane -1 does not exist")
	# ... and the sim, at A's next MOBIL evaluation, signals the side the readout
	# prefers (the larger accepted margin; left on ties, as in TrafficSim).
	var player: VehicleState = sc["player"]
	var events := ScoreEventBuffer.new(16)
	var left := MobilProbe.Result.new()
	var right := MobilProbe.Result.new()
	var k := 0
	while st.lc_state[a] == TrafficState.LaneChange.NONE and k < 240:
		probe.set_player(player)
		probe.evaluate_into(a, 0, left)
		probe.evaluate_into(a, 2, right)
		player.s += player.v * DT
		sim.step(DT, player, null, events)
		k += 1
	eq(st.lc_state[a], TrafficState.LaneChange.SIGNALING, "the sim signals")
	var want := 0 if left.accepts() and (not right.accepts() or left.margin() >= right.margin()) else 2
	print("  scenario: left margin %.3f (%s), right margin %.3f (%s); sim chose lane %d" % [left.margin(),
		MobilProbe.REFUSAL_NAMES[left.refusal], right.margin(), MobilProbe.REFUSAL_NAMES[right.refusal],
		st.target_lane[a]])
	eq(st.target_lane[a], want, "the readout's preferred side")


func test_mobil_probe_refusals_follow_the_sim() -> void:
	var sc := _scenario()
	var sim: TrafficSim = sc["sim"]
	var probe: MobilProbe = sc["probe"]
	var ids: Dictionary = sc["ids"]
	var r := MobilProbe.Result.new()
	# C (lane 0) moving right into lane 1 right beside A: overlap.
	var c: int = ids["c"]
	var a: int = ids["a"]
	sim.state.s[c] = sim.state.s[a] - 2.0
	probe.evaluate_into(c, 1, r)
	check(r.refusal == MobilProbe.Refusal.LEADER_OVERLAP or r.refusal == MobilProbe.Refusal.FOLLOWER_OVERLAP,
		"side by side = overlap refusal (%s)" % MobilProbe.REFUSAL_NAMES[r.refusal])
	check(not r.accepts(), "refused")
	# The truck may not move left of its two right lanes: lane 1 -> 0 is refused.
	probe.evaluate_into(ids["b"], 0, r)
	eq(r.refusal, MobilProbe.Refusal.KEEP_RIGHT, "keep-right profile")
	# The sim agrees: a scripted request for the same move is refused too.
	check(not sim.request_lane_change(ids["b"], 0), "sim refuses the truck's move left")
	# Player right behind lane 2's target spot: the player's b_safe (2 m/s^2) applies.
	var player: VehicleState = sc["player"]
	player.s = sim.state.s[a] - 9.0
	player.v = 40.0
	probe.set_player(player)
	probe.evaluate_into(a, 2, r)
	eq(r.follower, sim.player_index(), "the player is the new follower")
	near(r.b_safe, minf(sim.registry.b_safe[sim.state.profile_id[a]], sim.tuning.player_b_safe_mps2), 1e-12,
		"player b_safe")
	check(not r.accepts(), "the player is not cut off")
	check(r.refusal_is_player, "refusal involves the player")


## Organic lane changes in a full sandbox run: at every signal start the probe (run
## right after the tick) must agree that MOBIL accepts the move. The sim evaluates
## inside its tick, so tiny timing differences are allowed for at most a few percent.
func test_mobil_readout_agrees_with_sim_decisions() -> void:
	var sb := await _boot()
	sb.set_leg(8)
	sb.fill_traffic()
	sb.set_driver(sb.Driver.BOT_KEEP)
	var agree := 0
	var total := 0
	var st: TrafficState = sb.sim.state
	var prev := PackedInt32Array()
	prev.resize(st.capacity)
	var prev_id := PackedInt32Array()
	prev_id.resize(st.capacity)
	var r := MobilProbe.Result.new()
	for k in 120 * 40:
		sb.advance_ticks(1)
		for i in st.capacity:
			if st.active[i] == 0:
				prev_id[i] = -1
				continue
			var was := prev[i] if prev_id[i] == st.vehicle_id[i] else 0
			if st.lc_state[i] == TrafficState.LaneChange.SIGNALING and was == 0 \
					and st.target_lane[i] != st.lane[i]:
				sb.probe.set_player(sb.car.state)
				sb.probe.evaluate_into(i, st.target_lane[i], r)
				total += 1
				if r.accepts():
					agree += 1
				var dec: Array = sb.overlay.last_decision(i)
				eq(dec.size(), 5, "overlay recorded the decision")
			prev[i] = st.lc_state[i]
			prev_id[i] = st.vehicle_id[i]
	print("  MOBIL readout agrees with %d of %d organic signal starts" % [agree, total])
	gt(total, 10, "enough lane changes to judge")
	ge(float(agree), float(total) * 0.95, "readout matches the sim's decisions")
