extends SceneTree
## WebSocket echo check against westbound-server (multiplayer N0 gate, docs/SERVER.md).
##   tools/godot.sh --headless --script res://tools/net_echo_check.gd -- \
##       [--url=wss://localhost:8443/ws/echo] [--insecure] [--timeout=10] [--size=1024]
## Connects, sends one binary message, expects the same bytes back, closes, prints
## "NET_ECHO ok <url> bytes=<n> rtt_ms=<ms>" and exits 0. Any failure prints
## "NET_ECHO FAIL <reason>" and exits 1; bad arguments exit 2.
## --insecure accepts any certificate (local Caddy `tls internal` is self-signed).
## Dev tool only: the game itself always verifies certificates.

const DEFAULT_URL := "wss://localhost:8443/ws/echo"
const DEFAULT_TIMEOUT_S := 10.0
const DEFAULT_SIZE := 1024
## Largest payload the server accepts (spec: 16 KB inbound max).
const MAX_SIZE := 16384
const MS_PER_S := 1000.0
const BYTE_PATTERN_MUL := 31
const BYTE_PATTERN_ADD := 7
const BYTE_RANGE := 256
const CLOSE_NORMAL := 1000

var _peer := WebSocketPeer.new()
var _url := DEFAULT_URL
var _payload := PackedByteArray()
var _sent_ms := -1
var _deadline_ms := 0
var _finished := false


func _initialize() -> void:
	var timeout_s := DEFAULT_TIMEOUT_S
	var size := DEFAULT_SIZE
	var insecure := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--url="):
			_url = a.get_slice("=", 1)
		elif a == "--insecure":
			insecure = true
		elif a.begins_with("--timeout="):
			timeout_s = float(a.get_slice("=", 1))
		elif a.begins_with("--size="):
			size = int(a.get_slice("=", 1))
		else:
			printerr("net_echo_check: unknown argument %s" % a)
			_finish(2)
			return
	if size < 1 or size > MAX_SIZE or timeout_s <= 0.0:
		printerr("net_echo_check: --size must be 1..%d and --timeout positive" % MAX_SIZE)
		_finish(2)
		return
	_payload.resize(size)
	for i in size:
		_payload[i] = (i * BYTE_PATTERN_MUL + BYTE_PATTERN_ADD) % BYTE_RANGE
	var tls: TLSOptions = TLSOptions.client_unsafe() if insecure else TLSOptions.client()
	var err := _peer.connect_to_url(_url, tls)
	if err != OK:
		_fail("connect_to_url error %d" % err)
		return
	_deadline_ms = Time.get_ticks_msec() + int(timeout_s * MS_PER_S)


func _process(_delta: float) -> bool:
	if _finished:
		return true
	_peer.poll()
	var state := _peer.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if _sent_ms < 0:
			var err := _peer.send(_payload, WebSocketPeer.WRITE_MODE_BINARY)
			if err != OK:
				_fail("send error %d" % err)
				return true
			_sent_ms = Time.get_ticks_msec()
		while _peer.get_available_packet_count() > 0:
			var packet := _peer.get_packet()
			if _peer.was_string_packet():
				continue
			if packet == _payload:
				var rtt := Time.get_ticks_msec() - _sent_ms
				print("NET_ECHO ok %s bytes=%d rtt_ms=%d" % [_url, packet.size(), rtt])
				_peer.close(CLOSE_NORMAL)
				_finish(0)
			else:
				_fail("echo differs (%d bytes back, %d sent)" % [packet.size(), _payload.size()])
			return true
	elif state == WebSocketPeer.STATE_CLOSED:
		_fail("closed (code %d, reason '%s')" % [_peer.get_close_code(), _peer.get_close_reason()])
		return true
	if Time.get_ticks_msec() > _deadline_ms:
		_fail("timeout (state %d)" % state)
		return true
	return false


func _fail(reason: String) -> void:
	print("NET_ECHO FAIL %s: %s" % [_url, reason])
	_finish(1)


func _finish(code: int) -> void:
	_finished = true
	quit(code)
