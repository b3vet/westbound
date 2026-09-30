extends Node
## Manual live check of the real run in a room against a running server (not part of the
## test tiers). Player A is the game's Run (RunRoom: placements, the upload from the real
## car at 120 Hz, protection, the crash-out and respawn) driven by a lane-keeping bot; player
## B is a bare NetRoomSession watching A. The server's plausibility checks judge A's
## states: the check reads the server's `/metrics` and expects no offence of any kind.
## Spec: multiplayer handoff → Players (your car is yours; plausibility checks; crash-out).
## WP N5.2; docs/ROOMS_CLIENT.md → Live check.
##
##   tools/godot.sh --headless --path . res://tests/net/live_room_run_check.tscn -- \
##       http://127.0.0.1:18652 --metrics=http://127.0.0.1:19652
##
## A scene (not a SceneTree script) so the autoloads the run needs exist. Refuses the
## production host. Last line: `LIVE_ROOM_RUN ok (0 failed)` or `... FAIL (n failed)`.

const RUN_SCENE := preload("res://src/run/run.tscn")
const TIMEOUT_MS := 5000
const HTTP_POLL_MS := 10
const HTTP_OK_CREATED := 201
const HTTP_OK := 200
const API_DEVICE_PATH := "/api/v1/auth/device"
const PRODUCTION := "westbound.sipsakrandevu.com"
const MS_PER_S := 1000.0
const DRIVE_S := 10.0
const BOT_SEED := 5

var _api := ""
var _metrics := ""
var _failed := 0
var _run: Run
var _a: NetRoomSession
var _b: NetRoomSession


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--metrics="):
			_metrics = a.trim_prefix("--metrics=").trim_suffix("/")
		elif not a.begins_with("--"):
			_api = a.trim_suffix("/")
	if _api.is_empty() or _api.contains(PRODUCTION):
		printerr("usage: live_room_run_check.tscn -- http://127.0.0.1:PORT [--metrics=http://127.0.0.1:MPORT]")
		get_tree().quit(2)
		return
	_main.call_deferred()


func _process(_dt: float) -> void:
	if _b != null:
		_b.poll()


func _row(step: String, ok: bool, detail: String = "") -> void:
	if not ok:
		_failed += 1
	print("%-22s %s    %s" % [step, "ok" if ok else "FAIL", detail])


func _wait(cond: Callable, seconds: float = 8.0) -> bool:
	var until := Time.get_ticks_msec() + roundi(seconds * MS_PER_S)
	while Time.get_ticks_msec() < until:
		if cond.call():
			return true
		await get_tree().process_frame
	return bool(cond.call())


func _sleep(seconds: float) -> void:
	var until := Time.get_ticks_msec() + roundi(seconds * MS_PER_S)
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame


func _main() -> void:
	var t := NetTuning.load_default()
	var l := RunLoop.loop_road(Tuning.load_default()).length()
	var ws := _api.replace("https://", "wss://").replace("http://", "ws://") + "/ws"
	var ta := _create_account()
	var tb := _create_account()
	_row("accounts", not ta.is_empty() and not tb.is_empty())
	if ta.is_empty() or tb.is_empty():
		_finish()
		return
	var token_a := String(ta["access_token"])
	var token_b := String(tb["access_token"])
	_run = RUN_SCENE.instantiate() as Run
	_run.record_best = false
	_run.crash_cinematic = false
	add_child(_run)
	var rooms := NetRooms.new()
	rooms.standalone = true
	rooms.setup(null, NetWsTransport.new(t), t, null, l)
	rooms.session.configure(ws, t.client_build, MapInfo.loop_hash(), func() -> String: return token_a)
	add_child(rooms)
	_a = rooms.session
	_a.joined.connect(func(_r: NetRoomState) -> void: _run.start_room(_a))
	_a.create_room("normal", "cycle")
	_row("A creates, the run starts", await _wait(func() -> bool: return _run.room != null and _run.state == Game.RUNNING),
		"code %s, s %.0f, protected %s" % [_a.room.code, _run.car.state.s, _run.room.is_protected()])
	var bot := SandboxBot.new(_run.road, _run.sim.state, _run.car.params, BOT_SEED)
	bot.mode = SandboxBot.Mode.KEEP
	bot.v_target = _run.car.state.v
	bot.length_m = _run.car.car.length_m
	bot.width_m = _run.car.car.width_m
	_run.drive_controller = bot
	_b = NetRoomSession.new(NetWsTransport.new(t), t, l)
	_b.configure(ws, t.client_build, MapInfo.loop_hash(), func() -> String: return token_b)
	_b.join_code(_a.room.code)
	_row("B joins by code", await _wait(func() -> bool: return _b.is_in_room()), _b.room.players_text())

	await _sleep(DRIVE_S)
	var slot := _b.remotes.slot_of(_a.room.you)
	var seen_v := 0.0
	var gap := INF
	if slot >= 0:
		var now := _b.server_tick()
		_b.remotes.sample_all(now - t.room_interp_delay_ms / MS_PER_S * t.tick_rate_hz,
			t.room_extrap_max_ms / MS_PER_S * t.tick_rate_hz, t.room_fade_out_s * t.tick_rate_hz)
		seen_v = _b.remotes.tracks[slot].speed
		gap = absf(_run.loop.road.signed_delta(_run.car.state.s, _b.remotes.tracks[slot].s))
	_row("B sees A drive", slot >= 0 and seen_v > 10.0,
		"%.1f m/s, %.1f m behind A's car (100 ms at speed = %.1f m); A sent %d states" % [seen_v, gap,
		_run.car.state.v * t.room_interp_delay_ms / MS_PER_S, _a.states_sent])

	# Crash-out: two hits after the protection; the server respawns A 3 s later.
	_run.force_hit(HitDetection.HIT_BARRIER)
	await _sleep(Tuning.load_default().lives.ghost_period_s + 0.2)
	_run.force_hit(HitDetection.HIT_BARRIER)
	var crashed := await _wait(func() -> bool: return _run.room.crashed, 2.0)
	var respawned := await _wait(func() -> bool: return _run.room.respawns >= 1 and _run.state == Game.RUNNING)
	_row("crash-out, respawn", crashed and respawned, "respawns %d, lives %d" % [_run.room.respawns, _run.lives.lives])
	_run.drive_controller = bot
	await _sleep(3.0)

	if not _metrics.is_empty():
		var m := _fetch(_metrics + "/metrics")
		var offences := 0
		for line in m.split("\n"):
			if line.begins_with("wb_room_offences_total{"):
				offences += int(line.get_slice(" ", 1))
		_row("no offences", not m.is_empty() and offences == 0, "wb_room_offences_total = %d (server plausibility)" % offences)
	_a.close()
	_b.close()
	_finish()


func _finish() -> void:
	print("LIVE_ROOM_RUN %s (%d failed)" % ["ok" if _failed == 0 else "FAIL", _failed])
	get_tree().quit(0 if _failed == 0 else 1)


func _create_account() -> Dictionary:
	var body := _http(_api, HTTPClient.METHOD_POST, API_DEVICE_PATH, HTTP_OK_CREATED)
	var parsed: Variant = JSON.parse_string(body)
	return parsed if parsed is Dictionary else {}


func _fetch(url: String) -> String:
	var origin := url.get_slice("/", 0) + "//" + url.get_slice("/", 2)
	return _http(origin, HTTPClient.METHOD_GET, url.trim_prefix(origin), HTTP_OK)


func _http(origin: String, method: HTTPClient.Method, path: String, want: int) -> String:
	var hostport := origin.trim_prefix("https://").trim_prefix("http://")
	var host := hostport.get_slice(":", 0)
	var port := int(hostport.get_slice(":", 1)) if hostport.contains(":") else -1
	var http := HTTPClient.new()
	if http.connect_to_host(host, port, TLSOptions.client() if origin.begins_with("https://") else null) != OK:
		return ""
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while http.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		http.poll()
		OS.delay_msec(HTTP_POLL_MS)
		if Time.get_ticks_msec() > deadline:
			return ""
	if http.request(method, path, PackedStringArray(["Content-Length: 0"]), "") != OK:
		return ""
	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		http.poll()
		OS.delay_msec(HTTP_POLL_MS)
		if Time.get_ticks_msec() > deadline:
			return ""
	if not http.has_response() or http.get_response_code() != want:
		return ""
	var body := PackedByteArray()
	while http.get_status() == HTTPClient.STATUS_BODY:
		http.poll()
		body.append_array(http.read_response_body_chunk())
		OS.delay_msec(HTTP_POLL_MS)
		if Time.get_ticks_msec() > deadline:
			return ""
	return body.get_string_from_utf8()
