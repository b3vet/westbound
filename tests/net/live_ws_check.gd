extends SceneTree
## Manual live check of NetWsTransport + NetCodec against a running server (not part of the
## test tiers: no `test_` prefix). Spec: multiplayer handoff → Networking protocol →
## Connection. WP N2.2; docs/NET_CLIENT.md → Live check.
##
##   tools/godot.sh --headless --path . --script res://tests/net/live_ws_check.gd -- \
##       ws://127.0.0.1:8080/ws [--echo] [--token=...] [--insecure]
##
## Default: sends a Hello (all-zero map hash) and prints the decoded answer (Welcome, or an
## Error such as map_mismatch / auth_failed; either proves framing and the codec agree).
## `--echo`: for an echo endpoint, sends a PlayerState + Ping frame and expects the same
## bytes back. `--insecure` accepts any TLS certificate (local wss:// only). Exit status 0
## on success, 1 on failure or a 5 s timeout.

const TIMEOUT_MS := 5000

var _t: NetWsTransport
var _codec := NetCodec.new()
var _sent := PackedByteArray()
var _echo := false
var _deadline := 0
var _url := ""
var _token := "live-check"


func _initialize() -> void:
	var tls: TLSOptions = null
	for a in OS.get_cmdline_user_args():
		if a == "--echo":
			_echo = true
		elif a == "--insecure":
			tls = TLSOptions.client_unsafe()
		elif a.begins_with("--token="):
			_token = a.get_slice("=", 1)
		else:
			_url = a
	if _url.is_empty():
		printerr("usage: live_ws_check.gd -- ws[s]://host:port/ws [--echo] [--token=T]")
		quit(2)
		return
	_t = NetWsTransport.new(NetTuning.load_default(), tls)
	var err := _t.connect_to_url(_url)
	if err != OK:
		printerr("connect_to_url failed: %s" % error_string(err))
		quit(1)
		return
	_deadline = Time.get_ticks_msec() + TIMEOUT_MS


func _process(_delta: float) -> bool:
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


func _send_first() -> void:
	if _echo:
		var st := NetPlayerState.new()
		st.set_physical(123456, 12345.678, -1.75, 0.0873, 69.44, -0.42, 0.118, -0.125,
			NetCodec.PLAYER_FLAG_BOOST, 2)
		_codec.push_player_state(st)
		_codec.push({"type": "ping", "client_time_ms": 77}, NetCodec.Direction.CLIENT_TO_SERVER)
	else:
		_codec.push({"type": "hello", "protocol_version": NetCodec.PROTOCOL_VERSION,
			"client_build": 1, "map_hash": "00".repeat(NetCodec.MAP_HASH_LEN),
			"access_token": _token}, NetCodec.Direction.CLIENT_TO_SERVER)
	_sent = _codec.finish_frame()
	print("sent %d bytes: %s" % [_sent.size(), _sent.hex_encode()])
	_t.send(_sent)


func _on_frame(f: PackedByteArray) -> bool:
	print("received %d bytes: %s" % [f.size(), f.hex_encode()])
	if _echo:
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
