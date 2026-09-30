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
## - **Traffic seam (N4.3):** NetTuning.room_local_traffic keeps the local traffic director
##   running as in loop practice. N4.3's network traffic source replaces it here
##   (use_local_traffic()); nothing else in the run changes.

const MS_PER_S := 1000.0   # lint: allow-number unit conversion
## Brake input above this reads as braking for the brake-light flag.
const BRAKE_FLAG_MIN := 0.05   # lint: allow-number input threshold, not tuning

var run: Run
var session: NetRoomSession
var net: NetTuning
var view: RemoteCarView
var hud: RoomHud

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

var _crash_banked: int = 0

var _car_len: float = 4.5
var _car_w: float = 1.9


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
	for s: Signal in [session.run_result, session.chat, session.reconnecting, session.left, session.notice]:
		for c: Dictionary in s.get_connections():
			if (c["callable"] as Callable).get_object() == self:
				s.disconnect(c["callable"])
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
	use_local_traffic(net.room_local_traffic)
	_follow_clock()
	if start_valid:
		# The run was built at the placement: drive from there, protected.
		start_valid = false
		crashed = false
		rejoin_requested = false
		protected_left_s = net.room_protection_s
		run.fx.start_ghost(net.room_protection_s)
		run.go()
	else:
		run.hold_countdown(true)   # no placement yet: wait (frame() starts it)


## N4.3 seam: true = the local traffic director (loop practice's), false = the network
## traffic source (not built yet: the director's density goes to zero).
func use_local_traffic(on: bool) -> void:
	if not on:
		run.director.set_density_scale(0.0)


## Per 120 Hz tick (RUNNING): protection counts down.
func tick(dt: float) -> void:
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
	_crash_banked = run.scoring.banked()
	_send_hit(contact, 0)


func _send_hit(contact: HitDetection.Contact, lives_left: int) -> void:
	var target := "traffic"
	if contact.source == HitDetection.HIT_BARRIER:
		target = "barrier"
	elif contact.source != HitDetection.HIT_TRAFFIC:
		target = "roadside"
	var car_id := 0   # N4.3: the network car id of the traffic slot
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
	session.leave()
	run.leave_room("")


# ---------------------------------------------------------------- Frame

## Once per rendered frame (Run.frame): placements, the room clock, the upload, the
## remote cars, the HUD.
func frame(real_dt: float) -> void:
	if session.has_placement():
		_apply_placement()
	_follow_clock()
	_upload()
	_draw_remotes()
	if hud != null:
		hud.advance(real_dt)
	DevStats.report(&"room_ping_ms", roundi(session.ping_ms()))
	DevStats.report(&"room_remotes", session.remotes.active_count())
	DevStats.report(&"room_states_sent", session.states_sent)


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
	var now := session.server_tick()
	return floori(now) if now >= 0.0 else 0


## One state per room tick, stamped with that tick: the car's state moved back to the
## tick's instant along its velocity.
func _upload() -> void:
	var now := session.server_tick()
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
	if hud == null:
		return
	var pid := int(result.get("player_id", -1))
	if pid == session.room.you:
		hud.show_result(result, _crash_banked)
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
	run.leave_room(message)


func _on_notice(text: String) -> void:
	if hud != null:
		hud.show_notice(text)


func _crew_color(m: NetRoomMember) -> Color:
	var colors := net.room_crew_colors
	return colors[m.crew_color % colors.size()] if not colors.is_empty() else Color.WHITE
