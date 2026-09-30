class_name RunRoom
extends RefCounted
## The in-room run mode (N5.2): loop mode driven by the room. Spec:
## WESTBOUND_MULTIPLAYER_HANDOFF.md → Players (your car is yours, a PlayerState 20 times a
## second; other players 100 ms behind, interpolated, extrapolated up to 250 ms, ghosted,
## nametags; the loop strip; spawning with 3 s protection; crash-out: "two hits end your
## run and a 3-second results toast shows the score. You then respawn next to your crew
## with a fresh run"; rejoin crew; reconnect), Time of day in multiplayer (the room clock
## replaces the sun bar), Rooms (quick chat, mute). docs/ROOMS_CLIENT.md, docs/RUN.md.
##
## The Run owns one while it drives in a room (`run.room`); run.gd keeps only thin hooks
## and everything else is here:
## - **Placements** (PROTOCOL.md §12): the first one starts the run there (Run.start_s_m /
##   start_speed / start_d read `start_*`), a respawn after a crash-out starts a fresh run
##   there, any other (rejoin, reconnect) teleports the car and keeps the run (a rejoin
##   forfeits the unbanked chain). Every placement gives room_protection_s of protection:
##   no traffic hits (the run skips contacts) and the ghost flicker.
## - **Upload:** once per room tick (server_now()), the car's state stamped with that tick,
##   extrapolated back to the tick's instant (the frame reads it a little later).
## - **Crash-out:** `hit_report` with lives_left 0 at the crash, then the run waits in
##   RESULTS (no results screen) for the respawn placement; the room HUD shows the
##   server's run_result for room_result_toast_s.
## - **Room clock:** the loop's RoomClock is set every frame from the room's
##   cycle_ms_at(server_now()) (held in fixed and night modes).
## - **Remote players:** sampled at server_now() − 100 ms, placed near the player's
##   unwrapped s (LoopRoadPath.unwrap_near) in a pooled RemoteCarView, ghosted by
##   distance, with nametags and strip dots in their crew color.
## - **Traffic (N4.3):** the local traffic director runs as in loop practice until the
##   server streams traffic in this room (its first traffic message, `traffic_frame`);
##   then N4.3's NetworkTrafficSource takes the run's TrafficState over (the local cars
##   go) and the run calls step_traffic() in place of sim.step + director.step (the
##   opposite carriageway's director keeps running) and the source's notify_hit in place
##   of sim.notify_hit; hit reports carry the network car id. The source (and the
##   TrafficState, at least NetTuning.room_traffic_capacity cars in a room) is kept across
##   respawns and teleports: the server sends each car once for the area around the
##   player. Every room_snapshot clears it (the server sends the whole area in the same
##   frame). NetTuning.room_network_traffic = false keeps the local director (dev).
## - **Scoring (N6.2, NetScoreClient):** the run's own Scoring scores the network cars;
##   every 120 Hz tick the new events are read (tick(): the tick before's, stamped with its
##   room tick; frame(): the last tick's, before the run drains them) and turned into
##   claims, sent from the frame. score_sync eases the HUD's banked total to the official
##   one at banking moments (Hud.set_score_offset); the crew line (crewmates within 30 m,
##   the factor), TRAIN ×n and official sector bonuses the run did not pay (event stack);
##   the crash-out toast shows the official score; XP from the official score (Garage).

const MS_PER_S := 1000.0   # lint: allow-number unit conversion
## Brake input above this reads as braking for the brake-light flag.
const BRAKE_FLAG_MIN := 0.05   # lint: allow-number input threshold, not tuning

var run: Run
var session: NetRoomSession
var net: NetTuning
var view: RemoteCarView
var hud: RoomHud
## N4.3's source once the server streams traffic (null: the local director).
var net_traffic: NetworkTrafficSource
## N6.2: claims, the official score, crew and trains.
var score: NetScoreClient

## The pending start (the first placement, or a respawn's): road-space s (unwrapped), d, v.
var start_valid: bool = false
var start_s: float = 0.0
var start_d: float = 0.0
var start_v: float = 0.0
## Protection left (s), ticked by the run.
var protected_left_s: float = 0.0
## Crashed out: waiting for the respawn placement.
var crashed: bool = false
## Placements applied, respawns, teleports, states sent (tests, dev HUD).
var placements: int = 0
var respawns: int = 0
var teleports: int = 0
var rejoin_requested: bool = false
## Ticks per second of the room (states' tick → seconds).
var tick_rate: float = 20.0

var _headlights: bool = false
var _stats_frames: int = 0
## The network traffic rows of the dev HUD update every this many frames.
const STATS_EVERY_FRAMES := 10
## Dev (snaps): demo players keep their places around the car (snap_room).
var demo_remotes: int = 0

var _car_len: float = 4.5
var _car_w: float = 1.9
## N6.2: the run's events read so far this frame, and the room tick of the last 120 Hz
## tick (its events are stamped with it).
var _scan_from: int = 0
var _tick_at: int = 0
## N6.2: the official run (run_seq) XP was last awarded for (-1: none yet).
var _xp_run_seq: int = -1
## N6.2: the stamping clock (_room_now): its last value and when it was read (usec).
var _now_tick: float = -1.0
## N6.2: the room time of the car's latest simulated state (-1: not started); see
## _advance_car_clock().
var _car_clock: float = -1.0
var _now_us: int = 0


func _init(owner_run: Run, room_session: NetRoomSession, net_tuning: NetTuning = null) -> void:
	run = owner_run
	session = room_session
	net = net_tuning if net_tuning != null else room_session.tuning
	tick_rate = session.room.tick_rate
	session.run_result.connect(_on_run_result)
	session.chat.connect(_on_chat)
	session.reconnecting.connect(_on_reconnecting)
	session.left.connect(_on_left)
	session.notice.connect(_on_notice)
	session.traffic_frame.connect(_on_traffic_frame)
	session.rejoined.connect(_on_rejoined)
	session.joined.connect(_on_rejoined)
	var thread_m := owner_run.tuning.scoring.thread_clearance_m if owner_run.tuning != null else 1.5
	score = NetScoreClient.new(session, net, thread_m)
	score.train.connect(_on_train)
	score.crew_train.connect(_on_crew_train)
	score.sector_bonus.connect(_on_sector_bonus)
	if _read_placement():
		start_valid = true


## Nodes under the run (the remote cars and the room HUD); once.
func install() -> void:
	if view == null:
		view = RemoteCarView.new()
		run.add_child(view)
	if hud == null:
		hud = RoomHud.new()
		hud.name = "RoomHud"
		run.add_child(hud)
		hud.setup(net, session)
		hud.rejoin_pressed.connect(request_rejoin)
		hud.leave_pressed.connect(leave)
		hud.chat_pressed.connect(send_chat)
		hud.mute_pressed.connect(toggle_mute)


## Removes the nodes and lets go of the session's signals (the run is leaving the room).
func uninstall() -> void:
	for s: Signal in [session.run_result, session.chat, session.reconnecting, session.left, session.notice,
			session.traffic_frame, session.rejoined, session.joined]:
		for c: Dictionary in s.get_connections():
			if (c["callable"] as Callable).get_object() == self:
				s.disconnect(c["callable"])
	score.detach()
	if view != null:
		view.queue_free()
		view = null
	if hud != null:
		hud.queue_free()
		hud = null


## The run was (re)built (Run._start_run in room mode): the remote cars on the new road,
## then the start placement, or hold until it comes.
func on_run_started() -> void:
	install()
	var car_def: CarDef = load(Run.CAR_PATHS[clampi(net.room_remote_car, 0, Run.CAR_PATHS.size() - 1)])
	view.setup(run.road, run.origin, car_def, net.room_max_remotes)
	_car_len = run.car.car.length_m
	_car_w = run.car.car.width_m
	hud.bind_run(run)
	if net_traffic != null:
		net_traffic.set_player_body(_car_len, _car_w)
	_follow_clock()
	if start_valid:
		# The run was built at the placement: drive from there, protected.
		start_valid = false
		crashed = false
		rejoin_requested = false
		_car_clock = _room_now()
		_tick_at = _stamp()
		_scan_from = run.events.size()
		score.reset_run(_tick_at)
		_set_score_offset(0)
		protected_left_s = net.room_protection_s
		run.fx.start_ghost(net.room_protection_s)
		run.go()
	else:
		run.hold_countdown(true)   # no placement yet: wait (frame() starts it)


## Per 120 Hz tick with network traffic, in place of sim.step + director.step: the
## source at the room clock (the player a participant), the opposite carriageway locally.
func step_traffic(dt: float, st: VehicleState, events: ScoreEventBuffer) -> void:
	var now := session.server_tick()
	if now >= 0.0:
		net_traffic.step(now, st, events)
	run.director.opposite.step(dt, st.s)


## The run's headlights (the room clock's night) on the network cars too.
func set_traffic_headlights(on: bool) -> void:
	_headlights = on
	if net_traffic != null:
		net_traffic.set_headlights(on)


## The first traffic message of the room: the source takes the run's TrafficState over.
func _begin_network_traffic() -> void:
	var t := run.ctx.tuning
	net_traffic = NetworkTrafficSource.new(net, t.traffic, run.road, run.registry, run.sim.state)
	net_traffic.set_headway_scale(t.director.headway_scale(run.loop.tuning.director_leg))
	net_traffic.set_player_body(run.car.car.length_m, run.car.car.width_m)
	net_traffic.set_headlights(_headlights)
	score.wire_id = net_traffic.car_id   # N6.2: claims name the server's cars


func _on_traffic_frame(f: NetServerFrame) -> void:
	if not net.room_network_traffic or run.sim == null or run.loop == null:
		return
	if net_traffic == null:
		_begin_network_traffic()
	net_traffic.note_frame_bytes(session.last_frame_bytes)
	net_traffic.apply_frame(f, run.car.state.s, session.server_tick(), session.one_way_ticks())


## Every room_snapshot (a join, a reconnect): the server sends the whole area of interest
## in the same frame (after this signal), so the network traffic starts over.
func _on_rejoined(_room: NetRoomState) -> void:
	_now_tick = -1.0   # N6.2: the clock restarts with the room's snapshot
	_car_clock = -1.0
	if net_traffic != null:
		net_traffic.clear()


## Per 120 Hz tick (RUNNING, before the tick's scoring): the tick before's events become
## claims (stamped with its room tick), then protection counts down.
func tick(dt: float) -> void:
	_scan()
	_advance_car_clock(dt)
	_tick_at = _stamp()
	if protected_left_s > 0.0:
		protected_left_s = maxf(protected_left_s - dt, 0.0)


## No traffic hits while protected (spawn, respawn, rejoin).
func is_protected() -> bool:
	return protected_left_s > 0.0


## A counted hit that did not end the run (the client reports its own hits).
func on_hit(contact: HitDetection.Contact, lives_left: int) -> void:
	_send_hit(contact, lives_left)


## The crash-out (the last life): reported with lives_left 0; the respawn placement comes
## crash_respawn (3 s) later.
func on_crash(contact: HitDetection.Contact) -> void:
	crashed = true
	_send_hit(contact, 0)


func _send_hit(contact: HitDetection.Contact, lives_left: int) -> void:
	var target := "traffic"
	if contact.source == HitDetection.HIT_BARRIER:
		target = "barrier"
	elif contact.source != HitDetection.HIT_TRAFFIC:
		target = "roadside"
	var car_id := 0
	if net_traffic != null and target == "traffic" and contact.slot >= 0:
		car_id = maxi(net_traffic.car_id(contact.slot), 0)   # the wire id (0: not traffic)
	session.send_hit(_room_tick(), target, car_id, lives_left)


## REJOIN CREW (the HUD button, the pause menu's RETRY in a room): the server places us
## behind the crew leader.
func request_rejoin() -> void:
	if crashed or not session.is_in_room():
		return
	if session.send_run_event("rejoin", _room_tick()):
		rejoin_requested = true


func send_chat(item: Dictionary) -> void:
	session.send_chat(item)


func toggle_mute(player_id: int) -> void:
	var m := session.room.member(player_id)
	if m != null and player_id != session.room.you:
		session.set_muted(player_id, not m.muted)


## Leaves the room (the HUD's LEAVE, the pause menu's QUIT): back to the online hub.
func leave() -> void:
	_award_left_run()
	session.leave()
	run.leave_room("")


# ---------------------------------------------------------------- Frame

## Once per rendered frame (Run.frame): placements, the room clock, the upload, the
## remote cars, the HUD.
func frame(real_dt: float) -> void:
	_scan()   # the last tick's events, before the run drains them
	score.flush()
	if session.has_placement():
		_apply_placement()
	if demo_remotes > 0:
		_demo_step(real_dt)
	_follow_clock()
	if run.state != Game.RUNNING or _car_clock < 0.0:
		_car_clock = _room_now()   # no car simulation to follow: the room's clock
	_upload()
	_draw_remotes()
	_follow_score(real_dt)
	if hud != null:
		hud.advance(real_dt)
	DevStats.report(&"room_ping_ms", roundi(session.ping_ms()))
	DevStats.report(&"room_remotes", session.remotes.active_count())
	DevStats.report(&"room_states_sent", session.states_sent)
	if net_traffic != null:
		_stats_frames += 1
		if _stats_frames % STATS_EVERY_FRAMES == 0:
			net_traffic.stats.report_dev_stats()
			NetTrafficStats.report_link(session.client.clock)
	# The run drains its event buffer right after this (Run.frame): read from its start.
	_scan_from = 0


## Takes the session's pending placement into start_* (s unwrapped next to the car, never
## before lap 1: nothing builds at s < 0).
func _read_placement() -> bool:
	if not session.take_placement():
		return false
	var r := RunLoop.loop_road(run.tuning)
	var ref := run.car.state.s if run.car != null and run.loop != null else r.length()
	start_s = r.unwrap_near(ref, session.placement_s)
	if start_s < r.length():
		start_s += r.length()
	start_d = session.placement_d
	start_v = session.placement_speed
	placements += 1
	return true


func _apply_placement() -> void:
	var fresh := crashed or run.state == Game.RESULTS or run.state == Game.COUNTDOWN \
		or run.state == Game.CRASH
	if not _read_placement():
		return
	# N10.2: back after a server restart: the server ended the run there (room_closed, the
	# banked score kept), so this placement starts a fresh one.
	fresh = session.take_restart_rejoin() or fresh
	if fresh:
		# The first spawn (held countdown) or the respawn after a crash-out: a fresh run
		# at the placement (Run._start_run reads start_*).
		respawns += 1
		start_valid = true
		run.room_respawn()
		return
	# A rejoin or a reconnect: the same run, somewhere else.
	teleports += 1
	run.room_teleport(start_s, start_d, start_v)
	if rejoin_requested:
		rejoin_requested = false
		run.scoring.notify_hit(run.events)   # spec: rejoin forfeits the unbanked chain
	protected_left_s = net.room_protection_s
	run.fx.start_ghost(net.room_protection_s)


## The loop's RoomClock follows the room: cycle_ms at server_now().
func _follow_clock() -> void:
	var now := session.server_tick()
	if now < 0.0 or run.loop == null or run.loop.clock == null:
		return
	var epoch := run.loop.tuning.room_clock_epoch_unix_s
	run.loop.clock.set_time(epoch + session.room.cycle_ms_at(now) / MS_PER_S)


func _room_tick() -> int:
	var now := _car_clock if _car_clock >= 0.0 else _room_now()
	return floori(now) if now >= 0.0 else 0


## One state per room tick, stamped with that tick: the car's state moved back to the
## tick's instant along its velocity (N6.2: by the car's own clock, _car_clock).
func _upload() -> void:
	var now := _car_clock
	if now < 0.0 or run.car == null:
		return
	var at := floori(now)
	if at <= session.last_sent_tick:
		return
	var st := run.car.state
	var back := (now - float(at)) / tick_rate
	var rs := NetRoomSession.RUN_DRIVING
	if crashed or run.state == Game.CRASH or run.state == Game.RESULTS:
		rs = NetRoomSession.RUN_CRASHED
	elif is_protected():
		rs = NetRoomSession.RUN_PROTECTED
	var flags := 0
	if run.car.input.brake > BRAKE_FLAG_MIN:
		flags |= NetCodec.PLAYER_FLAG_BRAKE
	if st.boost_active:
		flags |= NetCodec.PLAYER_FLAG_BOOST
	if run.sun.is_night():
		flags |= NetCodec.PLAYER_FLAG_HEADLIGHTS
	if run.lives.is_ghost() or is_protected():
		flags |= NetCodec.PLAYER_FLAG_GHOST
	var moving := run.state == Game.RUNNING
	var v := st.v if moving else 0.0
	session.send_state(at, st.s - v * cos(st.yaw) * back, st.d - v * sin(st.yaw) * back, st.yaw, v,
		st.v_lat if moving else 0.0, st.yaw_rate if moving else 0.0, run.car.input.steer, flags, rs)


func _draw_remotes() -> void:
	if view == null:
		return
	var now := session.server_tick()
	var r := session.remotes
	if now < 0.0 or run.loop == null:
		view.hide_all()
		if hud != null:
			hud.nametags.hide_all()
		return
	var road := run.loop.road
	var me := run.car.state
	var ext := net.room_extrap_max_ms / MS_PER_S * tick_rate
	r.sample_all(now - net.room_interp_delay_ms / MS_PER_S * tick_rate, ext, net.room_fade_out_s * tick_rate)
	var colors := net.room_crew_colors
	for i in r.capacity:
		var pid := r.player_id[i]
		var t := r.tracks[i]
		var m := session.room.member(pid) if pid >= 0 else null
		if pid < 0 or m == null or t.alpha <= 0.0:
			view.hide_car(i)
			if hud != null:
				hud.nametags.hide_tag(i)
				hud.strip.set_dot(i, -1.0, Color.TRANSPARENT)
			continue
		var s := road.unwrap_near(me.s, t.s)
		var ds := s - me.s
		var dd := t.d - me.d
		var opacity := t.alpha
		if absf(ds) < _car_len and absf(dd) < _car_w:
			opacity *= net.room_ghost_overlap_opacity
		elif sqrt(ds * ds + dd * dd) < net.room_ghost_near_m:
			opacity *= net.room_ghost_near_opacity
		var color := colors[m.crew_color % colors.size()] if not colors.is_empty() else Color.WHITE
		view.place(i, s, t.d, t.heading, opacity, color, t.flags & NetCodec.PLAYER_FLAG_BRAKE != 0)
		if hud != null:
			hud.strip.set_dot(i, road.wrap_s(s) / road.length(), color)
			if absf(ds) <= net.room_nametag_max_m and view.is_shown(i):
				hud.nametags.set_tag(i, view.tag_position(i, net.room_nametag_lift_m), m, color, t.alpha)
			else:
				hud.nametags.hide_tag(i)
	if hud != null:
		hud.strip.set_me(road.wrap_s(me.s) / road.length())


# ---------------------------------------------------------------- Session events

func _on_run_result(result: Dictionary) -> void:
	var pid := int(result.get("player_id", -1))
	if pid == session.room.you:
		_award_xp(int(result.get("run_seq", 0)), int(result.get("score", 0)), int(result.get("threads", 0)))
	if hud == null:
		return
	if pid == session.room.you:
		hud.show_result(result)
	else:
		var m := session.room.member(pid)
		if m != null and String(result.get("end_reason", "")) == "crashed":
			hud.add_feed(m.full_name(), RoomHud.TEXT_CRASHED_OUT, _crew_color(m))


func _on_chat(player_id: int, text: String) -> void:
	var m := session.room.member(player_id)
	if hud != null and m != null:
		hud.add_feed(m.full_name(), text, _crew_color(m))


func _on_reconnecting(on: bool) -> void:
	if hud != null:
		hud.set_reconnecting(on)


func _on_left(_reason: String, message: String) -> void:
	_award_left_run()
	run.leave_room(message)


func _on_notice(text: String) -> void:
	if hud != null:
		hud.show_notice(text)


# ---------------------------------------------------------------- Scoring (N6.2)

## The room clock this client stamps its states, hits and claims with: server_tick(), but
## across a small step back of the estimate (the first Pong after a snapshot can land
## behind the snapshot's own estimate) it keeps running at least (1 − clock_slew_max_rate)
## as fast as the wall clock until the estimate catches up. Otherwise the stamps stall
## while the car drives on, and two states a tick apart show the car moving farther than
## its speed allows (the server's `distance` offence: the run goes unverified). A step
## back larger than room_stamp_max_hold_ms is taken as it is (the stamps would otherwise run
## ahead of the room). Reset by every snapshot.
## The room time of the car's simulated state, advanced by exactly each sim tick's dt: the
## car's position follows sim time, and after a frame hitch the physics catches up in bursts
## (several ticks in one short frame) or falls behind (slow motion, pause). Stamped with the
## wall clock, such a burst puts two states a tick apart farther than the car's speed allows
## (the server's `distance` offence, measured live: +2.3 m at 51 m/s). It follows the room
## clock (_room_now) at most clock_slew_max_rate faster or slower, and jumps to it when they
## are more than room_stamp_max_hold_ms apart (a pause or slow motion: a jump forward only
## shortens the implied speed). Stamps states, hits, run events and claims.
func _advance_car_clock(dt: float) -> void:
	var target := _room_now()
	if target < 0.0:
		_car_clock = -1.0
		return
	if _car_clock < 0.0:
		_car_clock = target
		return
	_car_clock += dt * tick_rate
	var diff := target - _car_clock
	if absf(diff) > net.room_stamp_max_hold_ms / MS_PER_S * tick_rate:
		_car_clock = target
	else:
		var step := net.clock_slew_max_rate * dt * tick_rate
		_car_clock += clampf(diff, -step, step)


func _room_now() -> float:
	var now := session.server_tick()
	if now < 0.0:
		_now_tick = -1.0
		return now
	var us := session.time.now_usec()
	if _now_tick >= 0.0 and now < _now_tick:
		var least := _now_tick + float(us - _now_us) / NetRoomSession.USEC_PER_S * tick_rate \
			* (1.0 - net.clock_slew_max_rate)
		if least - now <= net.room_stamp_max_hold_ms / MS_PER_S * tick_rate:
			now = maxf(now, least)
	_now_tick = now
	_now_us = us
	return now


## The room tick a 120 Hz tick happening now belongs to: the first at or after it (a room
## tick's state describes the car at that tick).
func _stamp() -> int:
	var now := _car_clock if _car_clock >= 0.0 else _room_now()
	return ceili(now) if now >= 0.0 else 0


## The run's events not read yet (the claims), and the local total after them.
func _scan() -> void:
	if run.scoring == null or run.car == null or run.sim == null:
		return
	var ev := run.events
	var to := ev.size()
	if _scan_from > to:
		_scan_from = 0
	score.observe(ev, _scan_from, to, _tick_at, run.car.state.d, run.sim.state,
		run.scoring.banked() + run.scoring.chain())
	_scan_from = to


## Per frame: the crew around the car, the official correction easing, the HUDs.
func _follow_score(real_dt: float) -> void:
	var road := run.loop.road if run.loop != null else null
	if road != null and run.car != null and session.server_tick() >= 0.0:
		score.update_crew(session.remotes, session.room, road.wrap_s(run.car.state.s), road.length())
	score.advance(real_dt)
	_set_score_offset(score.display_offset())
	if hud != null:
		hud.set_crew(score.crew_in_range, score.crew_factor)
	DevStats.report(&"room_claims_sent", score.claims_sent)
	DevStats.report(&"room_claims_rejected", score.claims_rejected)
	DevStats.report(&"room_score_offset", score.pending_offset)


func _set_score_offset(points: int) -> void:
	var h := run.hud as Hud
	if h != null:
		h.set_score_offset(points)


func _on_train(link: int, points: int) -> void:
	if hud != null:
		hud.show_train(link)
	var h := run.hud as Hud
	if h != null:
		h.push_event(RoomHud.TEXT_TRAIN % link, Hud.PLUS + HudFormat.thousands(points), HudEventStack.Role.GOLD)


func _on_crew_train(player_id: int, link: int) -> void:
	var m := session.room.member(player_id)
	if hud != null and m != null:
		hud.add_feed(m.full_name(), RoomHud.TEXT_TRAIN % link, _crew_color(m))


func _on_sector_bonus(kind: StringName, points: int, _sector: int) -> void:
	var h := run.hud as Hud
	if h != null:
		h.push_event(String(kind).to_upper(), Hud.PLUS + HudFormat.thousands(points), HudEventStack.Role.GOLD)


## XP for an official run (spec: the garage's driver level from the banked score; MP-D9
## left room runs without it until N6), once per run, as single-player does (record_best).
func _award_xp(run_seq: int, official: int, threads: int) -> void:
	if run_seq == _xp_run_seq:
		return
	_xp_run_seq = run_seq
	if run.record_best:
		Garage.award_room_run(official, threads)


## Leaving mid-run: the room's run_result does not reach a client that left, so the run's
## XP comes from the last official banked total (score_sync).
func _award_left_run() -> void:
	if score.official_run_seq >= 0 and score.official_run_seq != _xp_run_seq and not crashed:
		_award_xp(score.official_run_seq, score.official_banked, 0)


func _crew_color(m: NetRoomMember) -> Color:
	var colors := net.room_crew_colors
	return colors[m.crew_color % colors.size()] if not colors.is_empty() else Color.WHITE


# ---------------------------------------------------------------- Dev (snaps)

## Demo players: name, name tag, crew tag, crew slot.
const DEMO_MEMBERS: Array = [["Dusty", 1234, "WB", 0], ["Kai", 55, "JDM", 1], ["NightOwl", 420, "", 2],
	["Mara", 9, "WB", 0], ["Rook", 7777, "JDM", 1], ["Vega", 31, "", 3], ["Ash", 808, "WB", 0]]
## Demo cars around yours: metres ahead, lanes to the right (one within 15 m: translucent).
## N6.2: Mara (the second crewmate) 22 m behind: two crewmates within 30 m with --remotes=4+.
const DEMO_OFFSETS: Array = [[9.0, 1], [34.0, -1], [62.0, 0], [-22.0, 1], [170.0, -1], [230.0, 0], [290.0, 1]]
## N6.2: the demo crew's session total (snaps).
const DEMO_CREW_TOTAL := 48250
const DEMO_TICK := 1000
const DEMO_YOU := 7
const DEMO_BACK_TICKS := 4
const DEMO_CREWS := 4


## Dev (snaps, `--room=demo`): the run drives in a room without a server: `--remotes=N`
## (default 3) players around the car, a quick chat on the second one's nametag,
## `--room_toast=1` the crash-out toast, `--room_menu=chat|players` the room menu open;
## N6.2: `--train=N` a TRAIN ×N link (badge and event stack), `--sector=clean` an official
## sector bonus on the event stack.
static func snap_room(r: Run, args: Dictionary) -> void:
	var nt := NetTuning.load_default()
	var road := r.loop.road
	var rs := NetRoomSession.new(NetLoopbackLink.new(NetTimeSource.new(), Rng.new(1)).client, nt, road.length())
	var n := clampi(int(args.get("remotes", 3)), 0, mini(nt.room_max_remotes, DEMO_MEMBERS.size()))
	var members: Array[Dictionary] = []
	for i in n:
		var m: Array = DEMO_MEMBERS[i]
		members.append({"player_id": i, "identity": {"account_id": str(i + 1), "display_name": m[0], "name_tag": m[1]},
			"crew_tag": m[2], "crew_slot": m[3], "flags": {"host": i == 0, "disconnected": false}})
	members.append({"player_id": DEMO_YOU, "identity": {"account_id": "99", "display_name": "You", "name_tag": 1},
		"crew_tag": "WB", "crew_slot": 0, "flags": {"host": n == 0, "disconnected": false}})
	var crews: Array[Dictionary] = []
	for slot in DEMO_CREWS:
		crews.append({"crew_slot": slot, "color": slot, "session_total": DEMO_CREW_TOTAL if slot == 0 else 0})
	var lt := r.loop.tuning
	rs.enter_demo({"room_id": 1, "code": "K7QX2M", "you": DEMO_YOU, "tick": DEMO_TICK,
		"settings": {"visibility": "private", "max_players": nt.room_max_remotes + 1, "density": "normal",
			"time_mode": "cycle", "fixed_cycle_ms": 0},
		"clock": {"cycle_ms": roundi(r.loop.clock.phase_s() * MS_PER_S), "cycle_len_ms": roundi(lt.room_cycle_s() * MS_PER_S),
			"day_len_ms": roundi(lt.room_day_s() * MS_PER_S)},
		"members": members, "crews": crews}, float(DEMO_TICK))
	var me := r.car.state
	rs.demo_place(DEMO_TICK, road.wrap_s(me.s), me.d, me.v)
	var lane := road.lane_index_at(me.d, me.s)
	for i in n:
		var o: Array = DEMO_OFFSETS[i]
		var s := me.s + float(o[0])
		var d := road.lane_center_d(clampi(lane + int(o[1]), 0, road.lane_count(s) - 1), s)
		var k := rs.remotes.acquire(i)
		var back := me.v * float(DEMO_BACK_TICKS) / rs.room.tick_rate
		rs.remotes.tracks[k].push(DEMO_TICK - DEMO_BACK_TICKS, road.wrap_s(s - back), d, 0.0, me.v, 0, NetRoomSession.RUN_DRIVING)
		rs.remotes.tracks[k].push(DEMO_TICK, road.wrap_s(s), d, 0.0, me.v, 0, NetRoomSession.RUN_DRIVING)
	if n > 1:
		var chat := rs.room.member(1)
		chat.chat_text = NetRoomChat.PHRASE_TEXT[0]
		chat.chat_at_s = float(rs.time.now_usec()) / NetRoomSession.USEC_PER_S
	r.room = RunRoom.new(r, rs)
	r.room.demo_remotes = n
	r.room.install()
	r.room.on_run_started()
	r.room.protected_left_s = 0.0
	r.fx.stop_ghost()
	if n > 1:
		r.room.hud.add_feed(rs.room.member(1).full_name(), NetRoomChat.PHRASE_TEXT[0], nt.room_crew_colors[1])
	if str(args.get("room_toast", "")) == "1":
		r.room.hud.show_result({"player_id": DEMO_YOU, "score": 48250, "distance_m": 4210, "duration_ms": 131000,
			"flags": {"verified": true, "leaderboard_eligible": true}})
	var train := int(args.get("train", 0))
	if train > 0:
		for k in train - 1:
			r.room.score.on_message({"type": "score_event", "tick": DEMO_TICK, "player_id": DEMO_YOU, "kind": "train",
				"points": 25 * (k + 2), "multiplier_gain_milli": 2000, "link": k + 2, "sector": 0, "ref_id": 41})
	var sector := str(args.get("sector", ""))
	if not sector.is_empty():
		r.room.score.on_message({"type": "score_event", "tick": DEMO_TICK, "player_id": DEMO_YOU,
			"kind": "sector_" + sector, "points": 5000, "multiplier_gain_milli": 0, "link": 0, "sector": 2, "ref_id": 0})
	match str(args.get("room_menu", "")):
		"chat":
			r.room.hud.menu.open(RoomMenu.Tab.CHAT)
		"players":
			r.room.hud.menu.open(RoomMenu.Tab.PLAYERS)
	r.room.frame(0.0)


## Dev (snaps, `--state=menu --title=rooms*`): the online hub's room flows without a server:
## rooms (the hub, rooms available), rooms_off (no server), rooms_create, rooms_code,
## rooms_browser (four public rooms), rooms_joining, rooms_failed.
static func snap_hub(r: Run, which: String) -> void:
	var hub := r.title.online_hub
	r.title.open_hub()
	if which == "rooms_off":
		hub.rooms = null
		hub.refresh()
		return
	var nt := NetTuning.load_default()
	var rooms := NetRooms.new()
	rooms.standalone = true
	var link := NetLoopbackLink.new(NetTimeSource.new(), Rng.new(1))
	rooms.set_meta(&"demo_link", link)   # the endpoints only hold weak references
	rooms.setup(null, link.client, nt, null,
		RunLoop.loop_road(r.tuning).length())
	rooms.set_process(false)
	r.add_child(rooms)
	hub.rooms = rooms
	hub.refresh()
	match which:
		"rooms_create":
			hub.open_private()
		"rooms_code":
			hub.open_code()
			hub.lobby.code_field.text = "K7QX2M"
		"rooms_browser":
			var rows: Array[Dictionary] = [
				{"room_id": 12, "players": 7, "max_players": 8, "density": "normal", "night": true},
				{"room_id": 4, "players": 5, "max_players": 8, "density": "normal", "night": false},
				{"room_id": 9, "players": 8, "max_players": 8, "density": "normal", "night": false},
				{"room_id": 21, "players": 1, "max_players": 8, "density": "normal", "night": false}]
			rooms.session.rooms_listed = rows
			hub.open_browser()
		"rooms_joining":
			hub.open_quick_join()
		"rooms_failed":
			hub.open_quick_join()
			hub.lobby.show_error(NetRoomSession.text_for("room_full"))


## Dev (snaps): the demo room's clock runs with the frames and its players keep their
## places around the car (a state per tick).
func _demo_step(real_dt: float) -> void:
	session.demo_tick += real_dt * tick_rate
	var at := floori(session.demo_tick)
	var road := run.loop.road
	var me := run.car.state
	var lane := road.lane_index_at(me.d, me.s)
	for i in demo_remotes:
		var k := session.remotes.slot_of(i)
		if k < 0 or session.remotes.tracks[k].newest_tick >= at:
			continue
		var o: Array = DEMO_OFFSETS[i]
		var s := me.s + float(o[0])
		var d := road.lane_center_d(clampi(lane + int(o[1]), 0, road.lane_count(s) - 1), s)
		session.remotes.tracks[k].push(at, road.wrap_s(s), d, 0.0, me.v, 0, NetRoomSession.RUN_DRIVING)
