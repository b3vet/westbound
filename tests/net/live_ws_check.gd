extends SceneTree
## Manual live check of the client network stack against a running server (not part of the
## test tiers: no `test_` prefix). Spec: multiplayer handoff → Networking protocol →
## Connection, Clock sync. WPs N2.2 (transport, codec) and N2.3 (gateway handshake);
## docs/NET_CLIENT.md → Live check.
##
##   tools/godot.sh --headless --path . --script res://tests/net/live_ws_check.gd -- \
##       ws://127.0.0.1:8080/ws [--duration=20] [--api=http://127.0.0.1:8080] [--token=T]
##       [--map=<64 hex>] [--build=1] [--insecure] [--raw] [--echo]
##
## Default (session mode): creates a device account with `POST <api>/api/v1/auth/device`
## (the API origin defaults to the socket's; `--token=` skips this), then runs `NetClient`
## over `NetWsTransport`: Hello → Welcome, then Ping/Pong keepalive for `--duration` seconds
## (past the 8 s dead timeout), printing each clock sample. Exits 0 when the Welcome
## arrived, every ping interval got its Pong, the connection stayed up, and the clock
## agrees with the last Pong within CLOCK_OK_MS. The last line is
## `LIVE_SESSION ok ...` or `LIVE_SESSION FAIL <reason>`. Tokens are never printed.
## `--raw`: sends one Hello (the given token, or none) and prints the decoded answer.
## `--echo`: for the `/ws/echo` route, sends a PlayerState + Ping frame, expects the same
## bytes back. `--insecure` accepts any TLS certificate (local wss:// only).


## Records what NetClient's transport received, so the tool can read each Pong's tick.
class TapTransport extends NetWsTransport:
	var seen: Array[PackedByteArray] = []

	func poll() -> Array[PackedByteArray]:
		var frames := super.poll()
		seen.clear()
		seen.append_array(frames)
		return frames


const TIMEOUT_MS := 5000
const DEFAULT_DURATION_S := 20.0
const HTTP_POLL_MS := 10
const MS_PER_S := 1000.0
## Clock agreement required at the end (spec target: ±5 ms).
const CLOCK_OK_MS := 5.0
const DEFAULT_BUILD := 1
const HTTP_OK_CREATED := 201
const API_DEVICE_PATH := "/api/v1/auth/device"

var _t: NetWsTransport
var _codec := NetCodec.new()
var _sent := PackedByteArray()
var _mode := "session"
var _deadline := 0
var _url := ""
var _api := ""
var _token := ""
var _map_hex := "00".repeat(NetCodec.MAP_HASH_LEN)
var _build := DEFAULT_BUILD
var _duration_s := DEFAULT_DURATION_S
var _tls: TLSOptions = null

var _client: NetClient
var _tap: TapTransport
var _start_ms := 0
var _welcome_ms := 0
var _last_err_ms := INF
var _worst_err_ms := 0.0
var _account := ""
var _done := false


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--echo":
			_mode = "echo"
		elif a == "--raw":
			_mode = "raw"
		elif a == "--insecure":
			_tls = TLSOptions.client_unsafe()
		elif a.begins_with("--token="):
			_token = a.get_slice("=", 1)
		elif a.begins_with("--api="):
			_api = a.get_slice("=", 1)
		elif a.begins_with("--map="):
			_map_hex = a.get_slice("=", 1).to_lower()
		elif a.begins_with("--build="):
			_build = int(a.get_slice("=", 1))
		elif a.begins_with("--duration="):
			_duration_s = float(a.get_slice("=", 1))
		else:
			_url = a
	if _url.is_empty() or _map_hex.length() != 2 * NetCodec.MAP_HASH_LEN:
		printerr("usage: live_ws_check.gd -- ws[s]://host:port/ws [--duration=S] [--api=URL]"
			+ " [--token=T] [--map=HEX64] [--build=N] [--insecure] [--raw] [--echo]")
		quit(2)
		return
	if _mode == "session":
		_start_session()
		return
	_t = NetWsTransport.new(NetTuning.load_default(), _tls)
	var err := _t.connect_to_url(_url)
	if err != OK:
		printerr("connect_to_url failed: %s" % error_string(err))
		quit(1)
		return
	_deadline = Time.get_ticks_msec() + TIMEOUT_MS


func _process(_delta: float) -> bool:
	if _mode == "session":
		return _process_session()
	if _t == null:
		return true
	for f in _t.poll():
		return _on_frame(f)
	if _t.is_open() and _sent.is_empty():
		_send_first()
	if _t.get_state() == NetTransport.State.CLOSED:
		printerr("closed: %d %s" % [_t.close_code, _t.close_reason])
		quit(1)
		return true
	if Time.get_ticks_msec() > _deadline:
		printerr("timeout: no answer within %d ms" % TIMEOUT_MS)
		quit(1)
		return true
	return false


# --- session mode: HTTP device account, then NetClient ---------------------------------------

func _start_session() -> void:
	if _token.is_empty():
		if _api.is_empty():
			_api = _api_origin(_url)
		var created := _create_account(_api)
		if created.is_empty():
			_finish(false, "could not create a device account at %s%s" % [_api, API_DEVICE_PATH])
			return
		_account = String(created.get("account_id", ""))
		_token = String(created.get("access_token", ""))
		print("account %s created via POST %s%s (token not shown, %d chars)"
			% [_account, _api, API_DEVICE_PATH, _token.length()])
	var tuning := NetTuning.load_default()
	_tap = TapTransport.new(tuning, _tls)
	_client = NetClient.new(_tap, tuning)
	_client.welcomed.connect(_on_welcomed)
	_client.failed.connect(func(reason: String, message: String) -> void:
		_finish(false, "%s (%s)" % [reason, message]))
	_start_ms = Time.get_ticks_msec()
	print("connecting %s (client_build %d, map %s...)" % [_url, _build, _map_hex.left(8)])
	var err := _client.start(_url, _build, _map_hex.hex_decode(), _token)
	if err != OK:
		_finish(false, "start failed: %s" % error_string(err))


func _process_session() -> bool:
	if _done or _client == null:
		return true
	var pongs_before := _client.pongs_received
	_client.poll()
	if _client.pongs_received > pongs_before:
		_report_pongs()
	var now := Time.get_ticks_msec()
	if _client.get_state() == NetClient.State.READY:
		if now - _welcome_ms >= _duration_s * MS_PER_S:
			_summary()
			return true
	elif _client.get_state() != NetClient.State.FAILED and now - _start_ms > TIMEOUT_MS * 2:
		_finish(false, "no Welcome in time")
	return _done


func _on_welcomed(welcome: Dictionary) -> void:
	_welcome_ms = Time.get_ticks_msec()
	print("welcome %s" % JSON.stringify(welcome))


## One line per Pong: RTT, the Pong's server tick, and how far `server_now()` is from the
## tick that Pong implies right now (server tick + half the RTT).
func _report_pongs() -> void:
	var clock := _client.clock
	for f in _tap.seen:
		for m in _codec.decode_frame(f, NetCodec.Direction.SERVER_TO_CLIENT):
			if String(m.get("type", "")) != "pong":
				continue
			var tick := float(m["server_tick"]) \
				+ float(m["tick_fraction"]) / NetCodec.TICK_FRACTION_SCALE
			var rate := clock.tick_rate()
			var implied := tick + clock.last_rtt_s * 0.5 * rate
			var err_ms := (clock.server_now() - implied) / rate * MS_PER_S
			_last_err_ms = err_ms
			if _client.pongs_received > 1:
				_worst_err_ms = maxf(_worst_err_ms, absf(err_ms))
			print("pong %d  rtt %.2f ms  server_tick %.3f  server_now %.3f  err %+.3f ms  slew %+.3f ms"
				% [_client.pongs_received, clock.last_rtt_s * MS_PER_S, tick,
				clock.server_now(), err_ms, clock.slew_remaining_ms()])


func _summary() -> void:
	var elapsed_s := (Time.get_ticks_msec() - _welcome_ms) / MS_PER_S
	var interval_s := float(_client.welcome.get("ping_interval_ms", 0)) / MS_PER_S
	var expected := floori(elapsed_s / interval_s) if interval_s > 0.0 else 1
	var ok := _client.pongs_received >= expected and absf(_last_err_ms) <= CLOCK_OK_MS
	var line := "account=%s pings=%d pongs=%d (expected >= %d over %.1f s) best_rtt_ms=%.2f" \
		+ " clock_err_ms=%+.3f worst_err_ms=%.3f"
	line = line % [_client.account_id, _client.pings_sent, _client.pongs_received, expected,
		elapsed_s, _client.clock.best_rtt_s * MS_PER_S, _last_err_ms, _worst_err_ms]
	_client.close()
	_finish(ok, line)


func _finish(ok: bool, text: String) -> void:
	if _done:
		return
	_done = true
	print("LIVE_SESSION %s %s" % ["ok" if ok else "FAIL", text])
	quit(0 if ok else 1)


## ws://host:port/ws → http://host:port (wss → https).
static func _api_origin(ws_url: String) -> String:
	var rest := ws_url.trim_prefix("wss://").trim_prefix("ws://")
	var scheme := "https://" if ws_url.begins_with("wss://") else "http://"
	return scheme + rest.get_slice("/", 0)


## `POST /api/v1/auth/device` with a blocking HTTPClient loop (dev tool; no nodes needed).
## Returns the parsed JSON body, or {} on failure.
func _create_account(api: String) -> Dictionary:
	var https := api.begins_with("https://")
	var hostport := api.trim_prefix("https://").trim_prefix("http://")
	var host := hostport.get_slice(":", 0)
	var port := int(hostport.get_slice(":", 1)) if hostport.contains(":") else -1
	var http := HTTPClient.new()
	var tls: TLSOptions = null
	if https:
		tls = _tls if _tls != null else TLSOptions.client()
	if http.connect_to_host(host, port, tls) != OK:
		return {}
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while http.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		http.poll()
		OS.delay_msec(HTTP_POLL_MS)
		if Time.get_ticks_msec() > deadline:
			return {}
	if http.get_status() != HTTPClient.STATUS_CONNECTED:
		return {}
	if http.request(HTTPClient.METHOD_POST, API_DEVICE_PATH,
			PackedStringArray(["Content-Length: 0"]), "") != OK:
		return {}
	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		http.poll()
		OS.delay_msec(HTTP_POLL_MS)
		if Time.get_ticks_msec() > deadline:
			return {}
	if not http.has_response() or http.get_response_code() != HTTP_OK_CREATED:
		printerr("device account: HTTP %d" % http.get_response_code())
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


# --- raw and echo modes -------------------------------------------------------------------

func _send_first() -> void:
	if _mode == "echo":
		var st := NetPlayerState.new()
		st.set_physical(123456, 12345.678, -1.75, 0.0873, 69.44, -0.42, 0.118, -0.125,
			NetCodec.PLAYER_FLAG_BOOST, 2)
		_codec.push_player_state(st)
		_codec.push({"type": "ping", "client_time_ms": 77}, NetCodec.Direction.CLIENT_TO_SERVER)
	else:
		_codec.push({"type": "hello", "protocol_version": NetCodec.PROTOCOL_VERSION,
			"client_build": _build, "map_hash": _map_hex,
			"access_token": _token}, NetCodec.Direction.CLIENT_TO_SERVER)
	_sent = _codec.finish_frame()
	print("sent %d bytes%s" % [_sent.size(),
		": " + _sent.hex_encode() if _mode == "echo" else " (Hello)"])
	_t.send(_sent)


func _on_frame(f: PackedByteArray) -> bool:
	print("received %d bytes: %s" % [f.size(), f.hex_encode()])
	if _mode == "echo":
		var same := f == _sent
		print("echo %s" % ("matches" if same else "DIFFERS"))
		quit(0 if same else 1)
		return true
	var msgs := _codec.decode_frame(f, NetCodec.Direction.SERVER_TO_CLIENT)
	if _codec.error != "":
		printerr("decode error: %s" % _codec.error)
		quit(1)
		return true
	for m in msgs:
		print(JSON.stringify(m))
	quit(0)
	return true
