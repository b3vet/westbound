extends WBTest
## The run in a room (RunRoom) against the scripted room server: the first placement starts
## the run there with protection, states go up once per room tick, remote players are drawn
## ghosted with nametags and strip dots, hits and the crash-out are reported, the respawn
## placement starts a fresh run, REJOIN CREW teleports and keeps the run, the room clock
## follows the server, leaving and a kick go back to the hub. Spec: multiplayer handoff →
## Players, Time of day in multiplayer, Rooms. docs/ROOMS_CLIENT.md. WP N5.2.

const RUN_SCENE := preload("res://src/run/run.tscn")
const FakeRoomServer := preload("res://tests/net/fake_room_server.gd")
const MAP_HASH := "0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186"
const FRAME_S := 1.0 / 60.0
const TICKS_PER_FRAME := 2

var net: NetTuning
var time: NetVirtualTime
var link: NetLoopbackLink
var server: RefCounted
var rs: NetRoomSession
var run: Run
var _reduced: bool


func before_all() -> void:
	net = NetTuning.load_default()


func before_each() -> void:
	_reduced = bool(Settings.get_value(&"reduced_motion"))
	Settings.set_value(&"reduced_motion", true)
	time = NetVirtualTime.new(1_000_000)
	link = NetLoopbackLink.new(time, Rng.new(5))
	link.latency_s = 0.03
	link.ordered = true
	server = FakeRoomServer.new(link)
	var l := RunLoop.loop_road(Tuning.load_default()).length()
	rs = NetRoomSession.new(link.client, net, l, time)
	rs.configure("loop://rooms", 1, NetCodec.hex_to_bytes(MAP_HASH), func() -> String: return "token")
	run = RUN_SCENE.instantiate() as Run
	run.run_seed = 20260930
	run.manual_ticks = true
	run.crash_cinematic = false
	run.record_best = false
	tree.root.add_child(run)


func after_each() -> void:
	tree.paused = false
	if run != null and is_instance_valid(run):
		run.free()
	run = null
	rs = null
	server = null
	link = null
	await tree.process_frame
	Settings.set_value(&"reduced_motion", _reduced)


## Network and run together: one 60 Hz frame (two 120 Hz ticks) per step.
func _frames(n: int) -> void:
	for i in n:
		time.advance_s(FRAME_S)
		server.call("poll")
		rs.poll()
		if run.room == null:
			continue
		for k in TICKS_PER_FRAME:
			run.tick()
		run.frame(FRAME_S)


func _seconds(s: float) -> void:
	_frames(roundi(s / FRAME_S))


func _net(s: float) -> void:
	for i in roundi(s / 0.01):
		time.advance_s(0.01)
		server.call("poll")
		rs.poll()


func _join() -> void:
	rs.quick_join()
	_net(0.3)
	check(rs.is_in_room(), "joined")
	run.start_room(rs)


func _loop_len() -> float:
	return run.loop.road.length()


func test_first_placement_starts_the_run_there_protected() -> void:
	_join()
	eq(run.state, Game.RUNNING, "no countdown in a room")
	check(run.is_loop())
	var s := run.car.state
	near(run.loop.road.wrap_s(s.s), 1000.0, 0.01, "at the placement's s")
	check(s.s >= _loop_len(), "unwrapped from lap 1")
	near(s.d, 3.5, 0.01, "at the placement's d")
	near(s.v, 30.0, 0.01, "at the placement's speed")
	check(run.room.is_protected())
	near(run.room.protected_left_s, net.room_protection_s, 1e-9, "3 s of protection")
	run.force_hit(HitDetection.HIT_BARRIER)
	_frames(2)
	eq(run.lives.lives, run.lives.max_lives, "no hits while protected")
	_seconds(net.room_protection_s + 0.2)
	check(not run.room.is_protected())
	run.force_hit(HitDetection.HIT_BARRIER)
	_frames(2)
	eq(run.lives.lives, run.lives.max_lives - 1, "hits count after the protection")
	_net(0.1)
	var hits: Array[Dictionary] = server.get("hits")
	if eq(hits.size(), 1, "the hit is reported"):
		eq(hits[0]["target"], "barrier")
		eq(hits[0]["lives_left"], 1)


func test_states_go_up_once_per_room_tick() -> void:
	_join()
	_seconds(2.0)
	var states: Array[Dictionary] = server.get("states")
	check(states.size() >= 35 and states.size() <= 41, "about 20 a second (%d in 2 s)" % states.size())
	var steps := 0
	for i in range(1, states.size()):
		var dt := int(states[i]["tick"]) - int(states[i - 1]["tick"])
		check(dt >= 1, "ticks increase")
		if dt == 1:
			steps += 1
	check(steps >= states.size() - 3, "one state per tick")
	eq(states[0]["run_state"], "protected", "protected at first")
	eq(states.back()["run_state"], "protected", "still within 3 s")
	# Consecutive states are consistent with their ticks (the server's distance check).
	for i in range(1, states.size()):
		var ds := float(int(states[i]["s_mm"]) - int(states[i - 1]["s_mm"])) / 1000.0
		var dt := float(int(states[i]["tick"]) - int(states[i - 1]["tick"])) / 20.0
		var v := float(int(states[i]["speed_cms"])) / 100.0
		check(absf(ds - v * dt) < 0.6, "state %d moves %.2f m in %.2f s at %.1f m/s" % [i, ds, dt, v])
	_seconds(1.5)
	eq((server.get("states") as Array[Dictionary]).back()["run_state"], "driving", "driving after 3 s")


func test_remote_players_are_drawn_ghosted_with_nametags() -> void:
	_join()
	_seconds(0.5)
	var me := run.car.state
	var tick := floori(float(server.call("server_ticks")))
	var s_mm := roundi(run.loop.road.wrap_s(me.s + 60.0) * 1000.0)
	for k in 6:
		server.call("send", [server.call("other_state", 0, tick - 5 + k, s_mm + k * 1500, -350, 3000)])
	_frames(3)
	var slot := rs.remotes.slot_of(0)
	check(slot >= 0, "Dusty has a slot")
	var view := run.room.view
	check(view.is_shown(slot), "Dusty's car is drawn")
	near(view.opacity_of(slot), 1.0, 0.01, "solid when far")
	var hud := run.room.hud
	eq(hud.nametags.text_of(slot), "Dusty#1234 [WB]")
	eq(hud.strip.dots_shown(), 1, "one dot on the strip")
	check(hud.strip.me_x() >= 0, "and you")
	# Right beside us: translucent.
	me = run.car.state
	var tick2 := floori(float(server.call("server_ticks")))
	var near_mm := roundi(run.loop.road.wrap_s(me.s + 8.0) * 1000.0)
	for k in 4:
		server.call("send", [server.call("other_state", 0, tick2 - 3 + k, near_mm + k * 1500, roundi(me.d * 100.0) - 350, 3000)])
	_frames(3)
	check(view.opacity_of(slot) < 1.0, "translucent within 15 m")
	# No data: faded away after 250 ms + the fade.
	_seconds(net.room_extrap_max_ms / 1000.0 + net.room_interp_delay_ms / 1000.0 + net.room_fade_out_s + 0.2)
	check(not view.is_shown(slot), "gone until data arrives")
	check(not hud.nametags.is_shown(slot))


func test_crash_out_reports_and_respawns_a_fresh_run() -> void:
	_join()
	_seconds(net.room_protection_s + 0.2)
	run.force_hit(HitDetection.HIT_BARRIER)
	_frames(2)
	_seconds(Tuning.load_default().lives.ghost_period_s + 0.1)
	run.force_hit(HitDetection.HIT_TRAFFIC)
	_frames(2)
	eq(run.state, Game.CRASH)
	_net(0.1)
	var hits: Array[Dictionary] = server.get("hits")
	eq(hits.back()["lives_left"], 0, "crash-out: lives_left 0")
	check(run.room.crashed)
	_seconds(Tuning.load_default().feel.slowmo_crash_s + 0.5)
	eq(run.state, Game.RESULTS, "waiting for the respawn (no results screen)")
	check(not run.screens.results_screen.visible, "no results screen in a room")
	server.call("send", [{"type": "run_result", "player_id": 1, "run_seq": 1, "end_reason": "crashed",
		"flags": {"verified": true, "leaderboard_eligible": true}, "score": 0, "duration_ms": 65000,
		"distance_m": 2100, "passes": 0, "close_passes": 0, "cuts": 0, "threads": 0, "trains": 0,
		"max_multiplier_milli": 1000}])
	_frames(4)
	check(run.room.hud.is_toast_shown(), "the results toast")
	check(run.room.hud.toast_sub.text.contains("2.1 KM"), run.room.hud.toast_sub.text)
	var tick := floori(float(server.call("server_ticks")))
	server.call("send", [server.call("placement", tick, 5_000_000)])
	_frames(4)
	eq(run.state, Game.RUNNING, "respawned")
	near(run.loop.road.wrap_s(run.car.state.s), 5000.0, 2.0, "at the respawn placement")
	eq(run.lives.lives, run.lives.max_lives, "a fresh run")
	check(not run.room.crashed)
	check(run.room.is_protected(), "protected again")
	eq(run.room.respawns, 1, "one respawn")
	eq(run.room.placements, 2, "the first spawn and the respawn")
	_seconds(net.room_result_toast_s)
	check(not run.room.hud.is_toast_shown(), "the toast lasts 3 s")


func test_rejoin_crew_teleports_and_keeps_the_run() -> void:
	_join()
	_seconds(net.room_protection_s + 0.2)
	run.force_hit(HitDetection.HIT_BARRIER)
	_frames(2)
	var seed_before := run.current_seed
	run.room.hud.rejoin_button.pressed.emit()
	_net(0.1)
	var ev: Array[Dictionary] = server.get("run_events")
	if not eq(ev.size(), 1):
		return
	eq(ev[0]["kind"], "rejoin")
	var tick := floori(float(server.call("server_ticks")))
	server.call("send", [server.call("placement", tick, 9_000_000)])
	_frames(4)
	near(run.loop.road.wrap_s(run.car.state.s), 9000.0, 2.0, "teleported to the crew")
	eq(run.current_seed, seed_before, "the same run")
	eq(run.lives.lives, run.lives.max_lives - 1, "lives kept")
	eq(run.scoring.chain(), 0, "the unbanked chain is forfeit")
	check(run.room.is_protected(), "3 s of protection")
	eq(run.room.teleports, 1)


func test_the_room_clock_drives_the_sky() -> void:
	server.set("cycle_ms", 1_319_000)
	_join()
	_seconds(0.5)
	var now := rs.server_tick()
	near(run.loop.clock.phase_s(), rs.room.cycle_ms_at(now) / 1000.0, 0.05, "the loop clock follows cycle_ms")
	check(not run.loop.night)
	_seconds(1.5)
	check(run.loop.night, "night after 22 min of the cycle")
	check(run.feed.night, "the HUD's clock says night")


func test_leaving_and_a_kick_go_back_to_the_hub() -> void:
	_join()
	_seconds(0.2)
	run.room.hud.menu.open(RoomMenu.Tab.PLAYERS)
	run.room.hud.menu.leave_button.pressed.emit()
	eq(run.state, Game.MENU, "back on the title")
	check(run.room == null)
	check(run.title.online_hub.visible, "on the online hub")
	_net(0.2)
	eq(server.get("leaves"), 1, "room_leave sent")
	# Join again and get kicked.
	_join()
	_seconds(0.2)
	server.call("send", [{"type": "lobby_event", "kind": "room_left", "reason": "kicked"}])
	_frames(3)
	eq(run.state, Game.MENU)
	check(run.room == null)
	eq(run.title.online_hub.room_message, "The host removed you from the room.")
	eq(run.title.online_hub.rooms_note.text, "The host removed you from the room.")


func test_a_dropped_socket_keeps_driving_and_rejoins_the_seat() -> void:
	_join()
	_seconds(net.room_protection_s + 0.2)
	run.force_hit(HitDetection.HIT_BARRIER)
	_frames(2)
	var seed_before := run.current_seed
	server.call("drop")
	_seconds(0.2)
	eq(rs.state, NetRoomSession.State.RECONNECTING)
	eq(run.state, Game.RUNNING, "your car never waits for the network")
	check(run.room.hud.banner.visible, "the reconnecting banner")
	check(run.room.hud.banner.text.begins_with("RECONNECTING"), run.room.hud.banner.text)
	_seconds(1.5)
	eq(rs.state, NetRoomSession.State.IN_ROOM, "back in the seat")
	check(not run.room.hud.banner.visible)
	eq(run.room.teleports, 1, "placed where the car was: a teleport, not a new run")
	eq(run.current_seed, seed_before, "the same run")
	eq(run.lives.lives, run.lives.max_lives - 1, "lives kept")


func test_a_lost_seat_goes_back_to_the_hub() -> void:
	_join()
	link.refuse = true
	server.call("drop")
	_seconds(net.room_reconnect_window_s + 0.5)
	eq(run.state, Game.MENU)
	check(run.room == null)
	eq(run.title.online_hub.room_message, "Lost the connection to the room.")
