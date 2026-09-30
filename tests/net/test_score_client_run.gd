extends WBTest
## Multiplayer scoring in the real run (N6.2): a Run in a room against the scripted server
## with streamed network cars. The run's own passes become claims on the wire (the server's
## car ids; each claim's tick is where the uploaded states show the car fully behind, and not
## 150 ms before); score_sync eases the HUD's banked total to the official one at banking
## moments; TRAIN ×n and the crew line; the crash-out toast with the official score; night ×2
## from the room clock; garage XP from the official score (run_result, or the last official
## banked total when leaving mid-run). Spec: multiplayer handoff → Scoring in multiplayer;
## docs/SERVER.md → Scoring (N6.1). docs/ROOMS_CLIENT.md → Scoring in a room. WP N6.2.

const RUN_SCENE := preload("res://src/run/run.tscn")
const FakeScoreServer := preload("res://tests/net/fake_score_server.gd")
const MAP_HASH := "0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186"
const FRAME_S := 1.0 / 60.0
const TICKS_PER_FRAME := 2
const RATE := 20.0
## Scripted network cars: slower than the car, so it passes them.
const CAR_SPEED := 18.0
const MY_SPEED := 30.0

var net: NetTuning
var time: NetVirtualTime
var link: NetLoopbackLink
var server: FakeScoreServer
var rs: NetRoomSession
var run: Run
var _reduced: bool
var _save: Dictionary
## Scripted cars: car id -> [s at tick0 (unwrapped), d, tick0, speed].
var _cars: Dictionary = {}


func before_all() -> void:
	net = NetTuning.load_default()


func before_each() -> void:
	_reduced = bool(Settings.get_value(&"reduced_motion"))
	Settings.set_value(&"reduced_motion", true)
	_save = Save.data.duplicate(true)
	Save.data = SaveMigrations.fresh()
	time = NetVirtualTime.new(1_000_000)
	link = NetLoopbackLink.new(time, Rng.new(5))
	link.latency_s = 0.03
	link.ordered = true
	server = FakeScoreServer.new(link)
	var l := RunLoop.loop_road(Tuning.load_default()).length()
	rs = NetRoomSession.new(link.client, net, l, time)
	rs.configure("loop://rooms", 1, NetCodec.hex_to_bytes(MAP_HASH), func() -> String: return "token")
	run = RUN_SCENE.instantiate() as Run
	run.run_seed = 20260930
	run.manual_ticks = true
	run.crash_cinematic = false
	run.record_best = false
	tree.root.add_child(run)
	_cars = {}


func after_each() -> void:
	tree.paused = false
	if run != null and is_instance_valid(run):
		run.free()
	run = null
	rs = null
	server = null
	link = null
	await tree.process_frame
	Save.data = _save
	Save.dirty = false
	Settings.set_value(&"reduced_motion", _reduced)


## One 60 Hz frame (two 120 Hz ticks) per step; the scripted cars get a correction every
## 6 frames (the server's truth: constant speed).
func _frames(n: int) -> void:
	for i in n:
		time.advance_s(FRAME_S)
		server.poll()
		if not _cars.is_empty() and i % 6 == 0 and rs.is_in_room():
			var tick := floori(server.server_ticks())
			var corr := []
			for id: int in _cars:
				corr.append({"car_id": id, "s_mm": roundi(run.loop.road.wrap_s(_car_s(id, tick)) * 1000.0),
					"d_cm": roundi(float(_cars[id][1]) * 100.0), "speed_cms": roundi(float(_cars[id][3]) * 100.0)})
			server.send([{"type": "traffic_correction", "tick": tick, "cars": corr}])
		rs.poll()
		if run.room == null:
			continue
		for k in TICKS_PER_FRAME:
			run.tick()
		run.frame(FRAME_S)
		if run.hud != null:
			(run.hud as Hud).advance(FRAME_S)   # no tree frames here: the HUD reads its feed


func _seconds(s: float) -> void:
	_frames(roundi(s / FRAME_S))


func _net(s: float) -> void:
	for i in roundi(s / 0.01):
		time.advance_s(0.01)
		server.poll()
		rs.poll()


func _join() -> void:
	rs.quick_join()
	_net(0.3)
	check(rs.is_in_room(), "joined")
	run.start_room(rs)
	var bot := SandboxBot.new(run.road, run.sim.state, run.car.params, 5)
	bot.v_target = MY_SPEED
	bot.target_lane = run.road.lane_index_at(run.car.state.d, run.car.state.s)
	bot.length_m = run.car.car.length_m
	bot.width_m = run.car.car.width_m
	run.drive_controller = bot


## The scripted car's true s (unwrapped, near the car) at room tick `tick`.
func _car_s(id: int, tick: float) -> float:
	var c: Array = _cars[id]
	return float(c[0]) + float(c[3]) * (tick - float(c[2])) / RATE


## Network cars `ahead` metres ahead of the car in the lane `side` lanes away (+ = away from
## the median), at CAR_SPEED: spawned and dated by a correction batch, as N4.2 streams them.
func _spawn(cars: Array) -> void:
	var me := run.car.state
	var road := run.loop.road
	var tick := floori(server.server_ticks())
	var lane := road.lane_index_at(me.d, me.s)
	var spawns := []
	var corr := []
	for c: Array in cars:
		var at := me.s + float(c[1])
		var ln := clampi(lane + int(c[2]), 0, road.lane_count(at) - 1)
		var d := road.lane_center_d(ln, at)
		_cars[int(c[0])] = [at, d, tick, CAR_SPEED]
		var wire_lane := road.lane_count(at) - 1 - ln
		spawns.append({"car_id": c[0], "vehicle": 0, "color": 1, "profile": 0, "lane": wire_lane,
			"s_mm": roundi(road.wrap_s(at) * 1000.0), "d_cm": roundi(d * 100.0), "speed_cms": roundi(CAR_SPEED * 100.0),
			"lc_phase": "none", "lc_target_lane": 0, "lc_move_start_tick": 0, "lc_duration_ms": 0,
			"flags": {"hazard": false, "braking": false}})
		corr.append({"car_id": c[0], "s_mm": roundi(road.wrap_s(at) * 1000.0), "d_cm": roundi(d * 100.0),
			"speed_cms": roundi(CAR_SPEED * 100.0)})
	server.send([{"type": "traffic_spawn", "cars": spawns}, {"type": "traffic_correction", "tick": tick, "cars": corr}])


## The car's uploaded state at room tick `tick` (s unwrapped near `near_s`), or NAN.
func _state_s(tick: int, near_s: float) -> float:
	for st: Dictionary in server.states:
		if int(st["tick"]) == tick:
			return run.loop.road.unwrap_near(near_s, float(int(st["s_mm"])) / 1000.0)
	return NAN


func _neighbour() -> int:
	var road := run.loop.road
	var me := run.car.state
	var lane := road.lane_index_at(me.d, me.s)
	return 1 if lane + 1 < road.lane_count(me.s) else -1


func test_passes_go_up_as_claims_the_server_can_check() -> void:
	_join()
	_seconds(0.3)
	var side := _neighbour()
	_spawn([[41, 35.0, side], [42, 80.0, side]])
	_seconds(9.0)
	var claims: Array[Dictionary] = server.claims
	if not ge(claims.size(), 2, "both passes claimed (%s)" % [claims]):
		return
	var src := run.room.net_traffic
	for cl in claims:
		check(cl["kind"] == "pass" or cl["kind"] == "close_pass", "a pass: %s" % cl)
		var id := int(cl["cars"][0]["car_id"])
		check(id == 41 or id == 42, "the server's car id (%d)" % id)
		eq(cl["side"], "right" if run.car.state.d < float(_cars[id][1]) else "left")
		var tick := int(cl["tick"])
		var me_now := run.car.state.s
		var slot := src.slot_of(id)
		var hl := run.car.car.length_m * 0.5 + (run.sim.state.length[slot] if slot >= 0 else 4.5) * 0.5 \
			- 2.0 * Tuning.load_default().lives.collision_inset_m
		var at := _state_s(tick, me_now) - _car_s(id, tick)
		var before := _state_s(tick - 3, me_now) - _car_s(id, tick - 3)
		check(at >= hl - 0.3, "claim %d: fully behind at its tick (%.2f m past, needs %.2f)" % [id, at, hl])
		check(before < hl, "claim %d: not yet 150 ms before (%.2f m)" % [id, before])
	var ids: Array[int] = []
	for cl in claims:
		ids.append(int(cl["claim_id"]))
	eq(ids[0], 1)
	eq(ids[1], 2, "ids count up")
	eq(run.room.score.claims_skipped, 0)


func test_local_director_cars_are_not_claimed() -> void:
	_join()
	_seconds(6.0)
	check(run.room.net_traffic == null, "no network traffic")
	eq(server.claims.size(), 0, "the local director's cars are never claimed")


func test_score_sync_eases_the_hud_at_banking() -> void:
	_join()
	_seconds(2.5)
	var hud := run.hud as Hud
	var sc := run.room.score
	var t_sync := floori(rs.server_tick()) - roundi(RATE * 1.5)
	var local := sc.local_total_at(t_sync)
	check(local >= 0, "the client's own history at the sync's tick")
	# Mid-chain: nothing moves.
	server.send([server.sync_msg(t_sync, 1, local + 100, 0, false)])
	_seconds(0.2)
	eq(sc.pending_offset, 100)
	eq(hud.displayed_banked(), run.scoring.banked(), "no correction mid-chain")
	# The banking moment: eased in.
	server.send([server.sync_msg(t_sync + 1, 1, sc.local_total_at(t_sync + 1) + 100, 0, true)])
	_frames(3)
	var mid := hud.displayed_banked() - run.scoring.banked()
	check(mid < 100, "not at once (%d)" % mid)
	_seconds(net.score_ease_up_s + Tuning.load_default().hud.bank_count_s + 0.3)
	eq(hud.displayed_banked(), run.scoring.banked() + 100, "the official total")
	# Behind (a claim rejected: 50 fewer than before): the display comes down slowly.
	server.send([server.sync_msg(floori(rs.server_tick()) - 30, 1,
		sc.local_total_at(floori(rs.server_tick()) - 30) + 50, 0, true)])
	var prev := hud.displayed_banked() - run.scoring.banked()
	for k in roundi(net.score_ease_down_s / FRAME_S) + 30:
		_frames(1)
		var now := hud.displayed_banked() - run.scoring.banked()
		check(prev - now <= 3, "a small step down (%d -> %d)" % [prev, now])
		prev = now
	eq(prev, 50, "eased down to the official total")


func test_trains_crew_and_the_official_toast() -> void:
	_join()
	_seconds(net.room_protection_s + 0.3)
	var me := run.car.state
	var tick := floori(server.server_ticks())
	# A crewmate (Dusty, crew slot 0) 12 m behind.
	var s_mm := roundi(run.loop.road.wrap_s(me.s - 12.0) * 1000.0)
	for k in 6:
		server.send([server.other_state(0, tick - 5 + k, s_mm + k * 1500, roundi(me.d * 100.0), 3000)])
	_frames(3)
	var hud := run.room.hud
	eq(run.room.score.crew_in_range, 1)
	eq(hud.crew_line.text, "CREW ×1.25  ·  1 NEAR")
	# A train link.
	server.send([server.event_msg(tick, 1, "train", 75, 3, 0, 41)])
	_frames(2)
	check(hud.is_train_shown())
	eq(hud.train_badge.text, "TRAIN ×3")
	eq((run.hud as Hud).event_line(0), "TRAIN ×3 +75", "on the event stack")
	eq(run.room.score.run_trains, 1)
	server.send([{"type": "room_event", "kind": "crew", "crew_slot": 0, "color": 3, "session_total": 48250}])
	_frames(2)
	hud.menu.open(RoomMenu.Tab.PLAYERS)
	eq(hud.menu.crew_total.text, "CREW TOTAL 48,250", "the session crew total in the room menu")
	hud.menu.close()
	_seconds(net.train_show_s + 0.1)
	check(not hud.is_train_shown())
	# The crash-out toast shows the official score.
	server.send([server.result_msg(1, 1, 4321, "crashed", 1)])
	_frames(2)
	check(hud.is_toast_shown())
	check(hud.toast_sub.text.begins_with("SCORE 4,321  ·  "), hud.toast_sub.text)


func test_night_doubles_from_the_room_clock() -> void:
	server.cycle_ms = 1_320_000 + 60_000   # a minute into the night
	_join()
	_seconds(0.3)
	check(run.loop.night)
	check(run.scoring.is_night(), "scoring pays ×2 in the room's night")


func test_xp_from_the_official_score() -> void:
	run.record_best = true
	_join()
	_seconds(0.5)
	var p0 := Garage.profile().xp()
	server.send([server.result_msg(1, 1, 5000, "crashed", 0, 2)])
	_frames(2)
	var xp_per := Tuning.load_default().progression.xp_per_point
	eq(Garage.profile().xp() - p0, roundi(5000.0 * xp_per), "XP from run_result's score")
	server.send([server.result_msg(1, 1, 5000, "crashed", 0, 2)])
	_frames(2)
	eq(Garage.profile().xp() - p0, roundi(5000.0 * xp_per), "once per run")
	# The next run: leaving mid-run awards the last official banked total.
	server.send([server.sync_msg(floori(rs.server_tick()), 2, 1200, 300, false)])
	_frames(2)
	run.room.leave()
	eq(Garage.profile().xp() - p0, roundi(6200.0 * xp_per), "the last official banked total")


func test_stamps_never_stall_across_a_clock_step_back() -> void:
	_join()
	_seconds(0.2)
	var room := run.room
	var t0 := floorf(rs.server_tick()) + 100.0
	rs.demo_tick = t0
	near(room._room_now(), t0, 1e-9)
	time.advance_s(0.1)
	rs.demo_tick = t0 - 1.0   # the estimate stepped back by a tick after 0.1 s
	var least := t0 + 0.1 * RATE * (1.0 - net.clock_slew_max_rate)
	near(room._room_now(), least, 1e-6, "keeps running at 95 % of the wall clock")
	time.advance_s(0.05)
	rs.demo_tick = t0 + 3.0   # caught up: the estimate again
	near(room._room_now(), t0 + 3.0, 1e-9)
	time.advance_s(0.01)
	rs.demo_tick = t0 - 20.0   # a whole second back: taken as it is
	near(room._room_now(), t0 - 20.0, 1e-9, "a step beyond room_stamp_max_hold_ms is not held")
	rs.demo_tick = -1.0


## A frame hitch, then the physics catching up in bursts (Godot runs up to 8 ticks a frame)
## and slow motion: consecutive states stay consistent with their ticks (the server's
## distance check) because they are stamped by the car's own clock.
func test_states_follow_the_car_through_hitches() -> void:
	_join()
	_seconds(0.5)
	var from := server.states.size()
	# A 150 ms hitch: 8 ticks (67 ms), then catch-up frames of 4 ticks each 16.7 ms.
	var plan: Array[Array] = [[0.15, 8]]
	for k in 6:
		plan.append([FRAME_S, 4])
	for k in 30:
		plan.append([FRAME_S, 2])
	# Slow motion: a quarter of the ticks for 0.5 s.
	for k in 30:
		plan.append([FRAME_S, 1 if k % 2 == 0 else 0])
	for k in 60:
		plan.append([FRAME_S, 2])
	for p in plan:
		time.advance_s(float(p[0]))
		server.poll()
		rs.poll()
		for k in int(p[1]):
			run.tick()
		run.frame(float(p[0]))
	_net(0.05)
	var states: Array[Dictionary] = server.states
	gt(states.size() - from, 40, "states went up")
	var worst := 0.0
	for i in range(from + 1, states.size()):
		var a: Dictionary = states[i - 1]
		var b: Dictionary = states[i]
		var dt := float(int(b["tick"]) - int(a["tick"])) / RATE
		var ds := float(int(b["s_mm"]) - int(a["s_mm"])) / 1000.0
		var v := maxf(float(int(a["speed_cms"])), float(int(b["speed_cms"]))) / 100.0
		worst = maxf(worst, ds - v * dt)
		check(ds <= (v + 14.4 * dt * 0.5) * dt + 2.0, "states %d: %.2f m in %.2f s at %.1f m/s (the server's distance check)" % [i, ds, dt, v])
	lt(worst, 0.5, "never more than half a metre beyond the speed (%.2f m)" % worst)
