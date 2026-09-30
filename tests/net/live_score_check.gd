extends Node
## Manual live check of multiplayer scoring against a running server (not part of the test
## tiers). The game's Run drives in a private room (RunRoom: placements, the upload, the
## server's streamed traffic) with a weaving bot that passes the traffic; its own Scoring's
## events go up as claims (NetScoreClient), the server verifies them against its traffic and
## the uploaded states. The check reads the server's `/metrics` (`wb_room_claims_total` by
## verdict and reason, plausibility offences) and the client's side (claims sent, rejections
## seen, score syncs, the official score next to the local one). Spec: multiplayer handoff →
## Scoring in multiplayer ("honest clients get more than 99% of their claims accepted").
## WP N6.2; docs/ROOMS_CLIENT.md → Scoring in a room → Live check.
##
##   tools/godot.sh --headless --path . res://tests/net/live_score_check.tscn -- \
##       http://127.0.0.1:18652 --metrics=http://127.0.0.1:19652 [--drive=90] [--density=rush]
##       [--speed=<the bot's cruise, m/s>]
##
## A scene (the run needs the autoloads). Refuses the production host. Last line:
## `LIVE_SCORE ok (0 failed)` or `... FAIL (n failed)`.

const RUN_SCENE := preload("res://src/run/run.tscn")
const TIMEOUT_MS := 5000
const HTTP_POLL_MS := 10
const HTTP_OK_CREATED := 201
const HTTP_OK := 200
const API_DEVICE_PATH := "/api/v1/auth/device"
const PRODUCTION := "westbound.sipsakrandevu.com"
const MS_PER_S := 1000.0
const DRIVE_S := 90.0
const BOT_SEED := 11
## The bot's cruise speed (m/s): well above the traffic's, so it passes.
const BOT_SPEED := 44.0
const DENSITY := "normal"
const REPORT_EVERY_S := 15.0
## Spec: more than 99 % of an honest client's claims accepted.
const MIN_ACCEPTANCE_PCT := 99.0
const MIN_CLAIMS := 20

var _api := ""
var _metrics := ""
var _drive_s := DRIVE_S
var _density := DENSITY
var _bot_speed := BOT_SPEED
var _failed := 0
var _run: Run
var _a: NetRoomSession
var _bot: SandboxBot
## The server's distance check replayed on this client's own uploads (diagnostics).
var _prev_tick: int = -1
var _prev_s_mm: int = 0
var _prev_v: float = 0.0
var _prev_ticks: int = 0
var _prev_ms: int = 0
var _motion_flags: int = 0
var _prev_car_s: float = 0.0
var _prev_now: float = 0.0
var _prev_lives: int = 0
const ACCEL_CAP := 14.4
const SLACK_M := 2.0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--metrics="):
			_metrics = a.trim_prefix("--metrics=").trim_suffix("/")
		elif a.begins_with("--drive="):
			_drive_s = float(a.trim_prefix("--drive="))
		elif a.begins_with("--density="):
			_density = a.trim_prefix("--density=")
		elif a.begins_with("--speed="):
			_bot_speed = float(a.trim_prefix("--speed="))
		elif not a.begins_with("--"):
			_api = a.trim_suffix("/")
	if _api.is_empty() or _api.contains(PRODUCTION) or _metrics.is_empty():
		printerr("usage: live_score_check.tscn -- http://127.0.0.1:PORT --metrics=http://127.0.0.1:MPORT [--drive=S]")
		get_tree().quit(2)
		return
	_main.call_deferred()


func _row(step: String, ok: bool, detail: String = "") -> void:
	if not ok:
		_failed += 1
	print("%-24s %s    %s" % [step, "ok" if ok else "FAIL", detail])


func _wait(cond: Callable, seconds: float = 8.0) -> bool:
	var until := Time.get_ticks_msec() + roundi(seconds * MS_PER_S)
	while Time.get_ticks_msec() < until:
		if cond.call():
			return true
		await get_tree().process_frame
	return bool(cond.call())


func _main() -> void:
	var t := NetTuning.load_default()
	var l := RunLoop.loop_road(Tuning.load_default()).length()
	var ws := _api.replace("https://", "wss://").replace("http://", "ws://") + "/ws"
	var ta := _create_account()
	_row("account", not ta.is_empty())
	if ta.is_empty():
		_finish()
		return
	var token := String(ta["access_token"])
	var before := _claims_metrics()
	var offences_before := _offences()
	_run = RUN_SCENE.instantiate() as Run
	_run.record_best = false
	_run.crash_cinematic = false
	add_child(_run)
	var rooms := NetRooms.new()
	rooms.standalone = true
	rooms.setup(null, NetWsTransport.new(t), t, null, l)
	rooms.session.configure(ws, t.client_build, MapInfo.loop_hash(), func() -> String: return token)
	add_child(rooms)
	_a = rooms.session
	_a.joined.connect(func(_r: NetRoomState) -> void: _run.start_room(_a))
	_a.create_room(_density, "cycle")
	_row("room, the run starts", await _wait(func() -> bool: return _run.room != null and _run.state == Game.RUNNING),
		"code %s, %s traffic, the bot at %.0f m/s" % [_a.room.code, _density, _bot_speed])
	_row("traffic streamed", await _wait(func() -> bool: return _run.room.net_traffic != null, 10.0))
	_bot = SandboxBot.new(_run.road, _run.sim.state, _run.car.params, BOT_SEED)
	_bot.mode = SandboxBot.Mode.WEAVE
	_bot.v_target = _bot_speed
	_bot.length_m = _run.car.car.length_m
	_bot.width_m = _run.car.car.width_m
	_bot.target_lane = _run.road.lane_index_at(_run.car.state.d, _run.car.state.s)
	_run.drive_controller = _bot

	var start := Time.get_ticks_msec()
	var next_report := REPORT_EVERY_S
	while float(Time.get_ticks_msec() - start) / MS_PER_S < _drive_s:
		await get_tree().process_frame
		if _run.room == null:
			break
		_check_motion()
		if _run.state == Game.RUNNING and _run.car.controller != _bot:
			_run.drive_controller = _bot   # a respawn built the car again
		var el := float(Time.get_ticks_msec() - start) / MS_PER_S
		if el >= next_report:
			next_report += REPORT_EVERY_S
			var cur := _run.room.score
			print("  %3.0f s  claims sent %d (skipped %d, unmatched threads %d), rejected %d, syncs %d, local banked %d, official banked %d, respawns %d; %.1f m/s, lane changes %d, cars %d, fps %d" % [
				el, cur.claims_sent, cur.claims_skipped, cur.threads_unmatched, cur.claims_rejected, cur.syncs,
				_run.scoring.banked(), cur.official_banked, _run.room.respawns, _run.car.state.v, _bot.lane_changes,
				_run.sim.state.count, Engine.get_frames_per_second()])
	var crashes := _run.room.respawns if _run.room != null else 0
	# Let the last claims be decided (the server waits up to 1 s for evidence).
	var until := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
	var sc := _run.room.score if _run.room != null else null
	var after := _claims_metrics()
	var accepted := int(after.get("accepted", 0)) - int(before.get("accepted", 0))
	var rejected := int(after.get("rejected", 0)) - int(before.get("rejected", 0))
	var reasons := ""
	for k: String in after:
		if k.begins_with("reason:"):
			var n := int(after[k]) - int(before.get(k, 0))
			if n > 0:
				reasons += " %s=%d" % [k.trim_prefix("reason:"), n]
	var decided := accepted + rejected
	var pct := 100.0 * float(accepted) / float(maxi(decided, 1))
	if sc != null:
		_row("claims sent", sc.claims_sent >= MIN_CLAIMS, "%d sent (skipped %d, dropped %d, unmatched threads %d); %d rejections seen by the client; %d respawns" % [
			sc.claims_sent, sc.claims_skipped, sc.claims_dropped, sc.threads_unmatched, sc.claims_rejected, crashes])
		_row("official score", sc.syncs > 0, "%d syncs; official banked %d (run %d), local banked %d, last correction %d, unverified %s" % [
			sc.syncs, sc.official_banked, sc.official_run_seq, _run.scoring.banked(), sc.pending_offset, sc.unverified])
	_row("server acceptance", decided >= MIN_CLAIMS and pct >= MIN_ACCEPTANCE_PCT,
		"%d of %d accepted (%.2f %%)%s; late %d" % [accepted, decided, pct,
		(", rejected:" + reasons) if not reasons.is_empty() else "", int(after.get("late", 0)) - int(before.get("late", 0))])
	var offences := _offences() - offences_before
	_row("no offences", offences_before >= 0 and offences == 0, "wb_room_offences_total +%d (server plausibility); client-side distance flags %d" % [
		offences, _motion_flags])
	_a.close()
	_finish()


## Each new uploaded state against the one before, as plausibility.rs judges `distance`.
func _check_motion() -> void:
	var st: NetPlayerState = _a.get("_out")
	var now_ms := Time.get_ticks_msec()
	if st == null or st.tick == _prev_tick:
		return
	var l := RunLoop.loop_road(Tuning.load_default()).length()
	if _prev_tick >= 0:
		var dt := float(st.tick - _prev_tick) / 20.0
		var ds := fposmod(float(st.s_mm - _prev_s_mm) / 1000.0 + l * 0.5, l) - l * 0.5
		var v := float(st.speed_cms) / 100.0
		var peak := maxf(v, _prev_v) + ACCEL_CAP * dt * 0.5
		if ds > peak * dt + SLACK_M and _motion_flags < 10:
			_motion_flags += 1
			print("  motion: ticks %d->%d ds %.2f m > %.2f (v %.1f/%.1f); frame %d ms, physics ticks %d, time_scale %.2f; car s moved %.2f m, stamp clock moved %.3f ticks; lives %d->%d, ghost %s, state %s, placements %d, teleports %d" % [
				_prev_tick, st.tick, ds, peak * dt + SLACK_M, _prev_v, v, now_ms - _prev_ms, _run.tick_count - _prev_ticks,
				Engine.time_scale, _run.car.state.s - _prev_car_s, float(_run.room.get("_now_tick")) - _prev_now,
				_prev_lives, _run.lives.lives, _run.lives.is_ghost(), _run.state, _run.room.placements, _run.room.teleports])
	_prev_tick = st.tick
	_prev_s_mm = st.s_mm
	_prev_v = float(st.speed_cms) / 100.0
	_prev_ticks = _run.tick_count
	_prev_ms = now_ms
	_prev_car_s = _run.car.state.s
	_prev_now = float(_run.room.get("_now_tick"))
	_prev_lives = _run.lives.lives


## Plausibility offences so far (every kind), -1 without the metrics.
func _offences() -> int:
	var m := _fetch(_metrics + "/metrics")
	if m.is_empty():
		return -1
	var n := 0
	for line in m.split("\n"):
		if line.begins_with("wb_room_offences_total{"):
			n += int(line.get_slice(" ", 1))
	return n


## The server's claim counters: accepted, rejected, reason:<r>, late.
func _claims_metrics() -> Dictionary:
	var out := {}
	var m := _fetch(_metrics + "/metrics")
	for line in m.split("\n"):
		if line.begins_with("wb_room_claims_total{verdict=\"accepted\"}"):
			out["accepted"] = int(line.get_slice(" ", 1))
		elif line.begins_with("wb_room_claims_total{verdict=\"rejected\""):
			var n := int(line.get_slice(" ", 1))
			out["rejected"] = int(out.get("rejected", 0)) + n
			var r := line.get_slice("reason=\"", 1).get_slice("\"", 0)
			out["reason:" + r] = n
		elif line.begins_with("wb_room_claims_late_total"):
			out["late"] = int(line.get_slice(" ", 1))
	return out


func _finish() -> void:
	print("LIVE_SCORE %s (%d failed)" % ["ok" if _failed == 0 else "FAIL", _failed])
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
