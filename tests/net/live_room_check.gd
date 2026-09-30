extends SceneTree
## Manual live check of the room client against a running server (not part of the test
## tiers: no `test_` prefix). Two throwaway device accounts drive a private room together
## over real WebSockets: create + join by code, placements, 20 Hz states both ways and the
## remote tracks, the room clock against UTC, a crash-out with the run_result and the respawn
## placement 3 s later, REJOIN CREW behind the crew leader, a dropped socket reconnecting
## into the same seat, and leaving. Spec: multiplayer handoff → Players, Rooms, Time of day
## in multiplayer; docs/SERVER.md → Rooms → For the client. WP N5.2; docs/ROOMS_CLIENT.md →
## Live check.
##
##   tools/godot.sh --headless --path . --script res://tests/net/live_room_check.gd -- http://127.0.0.1:18480
##
## Refuses the production host. The last line is `LIVE_ROOM ok (0 failed)` or
## `LIVE_ROOM FAIL (n failed)`. Tokens are never printed.

const TIMEOUT_MS := 5000
const HTTP_POLL_MS := 10
const HTTP_OK_CREATED := 201
const API_DEVICE_PATH := "/api/v1/auth/device"
const PRODUCTION := "westbound.sipsakrandevu.com"
const WAIT_S := 8.0
const TICK_HZ := 20.0
const SPEED := 30.0
const MS_PER_S := 1000.0

## One simulated driver: a session, and a car at constant speed from its last placement.
class Driver:
	extends RefCounted
	var label: String
	var transport: NetWsTransport
	var rs: NetRoomSession
	var s0: float = 0.0
	var d: float = 0.0
	var tick0: int = 0
	var placed: bool = false
	var placements: int = 0
	var results: Array[Dictionary] = []
	var events: Array[String] = []

	func _init(name_: String, l: float, t: NetTuning, token: String, url: String) -> void:
		label = name_
		transport = NetWsTransport.new(t)
		rs = NetRoomSession.new(transport, t, l)
		rs.configure(url, t.client_build, MapInfo.loop_hash(), func() -> String: return token)
		rs.run_result.connect(func(r: Dictionary) -> void: results.append(r))
		rs.room_changed.connect(func() -> void: events.append("changed"))
		rs.reconnecting.connect(func(on: bool) -> void: events.append("reconnecting %s" % on))
		rs.rejoined.connect(func(_r: NetRoomState) -> void: events.append("rejoined"))

	## Takes a new placement; sends this tick's state (s at the tick along the placement).
	func drive() -> void:
		if rs.take_placement():
			s0 = rs.placement_s
			d = rs.placement_d
			tick0 = rs.placement_tick
			placed = true
			placements += 1
		var now := rs.server_tick()
		if not placed or now < 0.0:
			return
		var t := floori(now)
		var rs_state := NetRoomSession.RUN_PROTECTED if t - tick0 < roundi(3.0 * TICK_HZ) else NetRoomSession.RUN_DRIVING
		rs.send_state(t, s_at(t), d, 0.0, SPEED, 0.0, 0.0, 0.0, 0, rs_state)

	func s_at(t: float) -> float:
		return s0 + SPEED * (t - float(tick0)) / TICK_HZ


var _api := ""
var _failed := 0
var _drivers: Array[Driver] = []
var _l: float = 0.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty() or args[0].contains(PRODUCTION):
		printerr("usage: live_room_check.gd -- http://127.0.0.1:PORT   (never the production host)")
		quit(2)
		return
	_api = args[0].trim_suffix("/")
	_main.call_deferred()


func _process(_dt: float) -> bool:
	for dr in _drivers:
		dr.rs.poll()
		dr.drive()
	return false


func _row(step: String, ok: bool, detail: String = "") -> void:
	if not ok:
		_failed += 1
	print("%-22s %s    %s" % [step, "ok" if ok else "FAIL", detail])


func _wait(cond: Callable, seconds: float = WAIT_S) -> bool:
	var until := Time.get_ticks_msec() + roundi(seconds * MS_PER_S)
	while Time.get_ticks_msec() < until:
		if cond.call():
			return true
		await process_frame
	return bool(cond.call())


func _sleep(seconds: float) -> void:
	var until := Time.get_ticks_msec() + roundi(seconds * MS_PER_S)
	while Time.get_ticks_msec() < until:
		await process_frame


func _main() -> void:
	await process_frame
	var t := NetTuning.load_default()
	_l = _loop_length()
	var ws := _api.replace("https://", "wss://").replace("http://", "ws://") + "/ws"
	var ta := _create_account()
	var tb := _create_account()
	_row("accounts", not ta.is_empty() and not tb.is_empty(), "A %s, B %s" % [ta.get("account_id", "?"), tb.get("account_id", "?")])
	if ta.is_empty() or tb.is_empty():
		_finish()
		return
	var a := Driver.new("A", _l, t, String(ta["access_token"]), ws)
	var b := Driver.new("B", _l, t, String(tb["access_token"]), ws)
	_drivers = [a, b]

	a.rs.create_room("normal", "cycle")
	_row("create", await _wait(func() -> bool: return a.rs.is_in_room()),
		"code %s, you %d, host %s" % [a.rs.room.code, a.rs.room.you, a.rs.room.is_host()])
	_row("placed", await _wait(func() -> bool: return a.placed), "s %.1f d %.2f tick %d" % [a.s0, a.d, a.tick0])
	b.rs.join_code(a.rs.room.code)
	_row("join by code", await _wait(func() -> bool: return b.rs.is_in_room() and b.placed),
		"B is player %d; placed %.1f m from A" % [b.rs.room.you, absf(_ahead(a.s_at(b.tick0), b.s0))])
	_row("members", await _wait(func() -> bool: return a.rs.room.members.size() == 2), a.rs.room.players_text())

	# States both ways: each sees the other's track where the other says it is.
	await _sleep(3.0)
	var sa := a.rs.remotes.slot_of(b.rs.room.you)
	var sb := b.rs.remotes.slot_of(a.rs.room.you)
	var ok_tracks := sa >= 0 and sb >= 0
	var err_a := INF
	var err_b := INF
	if ok_tracks:
		var now := a.rs.server_tick()
		var render := now - t.room_interp_delay_ms / MS_PER_S * TICK_HZ
		a.rs.remotes.sample_all(render, t.room_extrap_max_ms / MS_PER_S * TICK_HZ, t.room_fade_out_s * TICK_HZ)
		err_a = absf(_ahead(b.s_at(render), a.rs.remotes.tracks[sa].s))
		var now_b := b.rs.server_tick()
		var render_b := now_b - t.room_interp_delay_ms / MS_PER_S * TICK_HZ
		b.rs.remotes.sample_all(render_b, t.room_extrap_max_ms / MS_PER_S * TICK_HZ, t.room_fade_out_s * TICK_HZ)
		err_b = absf(_ahead(a.s_at(render_b), b.rs.remotes.tracks[sb].s))
	_row("remote tracks", ok_tracks and err_a < 1.0 and err_b < 1.0,
		"A sees B within %.3f m, B sees A within %.3f m (100 ms behind); states sent %d / %d" % [err_a, err_b,
		a.rs.states_sent, b.rs.states_sent])
	var utc := fposmod(Time.get_unix_time_from_system() - LoopTuning.load_default().room_clock_epoch_unix_s,
		LoopTuning.load_default().room_cycle_s())
	var clock_err := absf(a.rs.room.cycle_ms_at(a.rs.server_tick()) / MS_PER_S - utc)
	_row("room clock", clock_err < 1.0, "cycle %.1f s, UTC phase %.1f s (err %.3f s)" % [
		a.rs.room.cycle_ms_at(a.rs.server_tick()) / MS_PER_S, utc, clock_err])

	# Crash-out: B reports lives_left 0; everyone gets the run_result; the respawn 3 s later.
	var before := b.placements
	var t_crash := Time.get_ticks_msec()
	b.rs.send_hit(floori(b.rs.server_tick()), "traffic", 0, 0)
	_row("run_result", await _wait(func() -> bool: return not a.results.is_empty() and not b.results.is_empty()),
		"%s, distance %d m, verified %s" % [String(b.results[0].get("end_reason", "?")) if not b.results.is_empty() else "?",
		int(b.results[0].get("distance_m", 0)) if not b.results.is_empty() else 0,
		b.results[0].get("flags", {}).get("verified", false) if not b.results.is_empty() else false])
	var respawned := await _wait(func() -> bool: return b.placements > before)
	_row("respawn", respawned, "after %.1f s" % ((Time.get_ticks_msec() - t_crash) / MS_PER_S))
	await _sleep(1.0)

	# Rejoin crew: A goes behind the crew leader (B).
	before = a.placements
	a.rs.send_run_event("rejoin", floori(a.rs.server_tick()))
	var rejoined := await _wait(func() -> bool: return a.placements > before)
	var behind := _ahead(a.s0, b.s_at(a.tick0))
	_row("rejoin crew", rejoined and behind > 0.0 and behind < 120.0, "placed %.1f m behind B" % behind)

	# A dropped socket: B reconnects into the same seat.
	var pid := b.rs.room.you
	b.transport.close(1001, "network switch")
	var back := await _wait(func() -> bool: return b.events.has("rejoined"))
	_row("reconnect", back and b.rs.room.you == pid and b.rs.is_in_room(),
		"%s; player %d again" % [", ".join(b.events.filter(func(e: String) -> bool: return e != "changed")), b.rs.room.you])

	b.rs.leave()
	_row("leave", await _wait(func() -> bool: return a.rs.room.members.size() == 1), a.rs.room.players_text())
	a.rs.close()
	b.rs.close()
	_finish()


## The loop's length from the committed map (no RunLoop: a SceneTree script has no
## autoloads, and the road stack needs them).
static func _loop_length() -> float:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(MapInfo.LOOP_V1_PATH))
	return float((d as Dictionary).get("length_mm", 0)) / MS_PER_S if d is Dictionary else 0.0


func _ahead(from_s: float, to_s: float) -> float:
	return fposmod(to_s - from_s + _l * 0.5, _l) - _l * 0.5


func _finish() -> void:
	print("LIVE_ROOM %s (%d failed)" % ["ok" if _failed == 0 else "FAIL", _failed])
	quit(0 if _failed == 0 else 1)


func _create_account() -> Dictionary:
	var https := _api.begins_with("https://")
	var hostport := _api.trim_prefix("https://").trim_prefix("http://")
	var host := hostport.get_slice(":", 0)
	var port := int(hostport.get_slice(":", 1)) if hostport.contains(":") else -1
	var http := HTTPClient.new()
	if http.connect_to_host(host, port, TLSOptions.client() if https else null) != OK:
		return {}
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while http.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		http.poll()
		OS.delay_msec(HTTP_POLL_MS)
		if Time.get_ticks_msec() > deadline:
			return {}
	if http.request(HTTPClient.METHOD_POST, API_DEVICE_PATH, PackedStringArray(["Content-Length: 0"]), "") != OK:
		return {}
	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		http.poll()
		OS.delay_msec(HTTP_POLL_MS)
		if Time.get_ticks_msec() > deadline:
			return {}
	if not http.has_response() or http.get_response_code() != HTTP_OK_CREATED:
		return {}
	var body := PackedByteArray()
	while http.get_status() == HTTPClient.STATUS_BODY:
		http.poll()
		body.append_array(http.read_response_body_chunk())
		OS.delay_msec(HTTP_POLL_MS)
		if Time.get_ticks_msec() > deadline:
			return {}
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	return parsed if parsed is Dictionary else {}
