class_name NetClient
extends RefCounted
## One server connection: transport, handshake, keepalive and clock sync. Spec: multiplayer
## handoff → Networking protocol → Connection ("Hello {protocol_version, client_build,
## map_hash} → Welcome or Error. Incompatible versions get a clear 'please update' error";
## "a ping every 2 s; the connection is considered dead after 8 s of silence") and Clock
## sync; docs/PROTOCOL.md §1, §5. WP N2.2.
##
## Pure RefCounted driven by `poll()` once per frame (a Node adapter owns it later); time
## comes from the injected NetTimeSource. Lifecycle:
##   IDLE → start() → CONNECTING → socket open, Hello sent → HANDSHAKING
##        → Welcome → READY (Ping every interval, Pong feeds `clock`)
##        → fatal Error / silence / socket closed / bad frame → FAILED (`failure_reason`,
##          `failure_message` for the player) ; close() → CLOSED.
##
## `failure_reason` is the server's error code (`update_required`, `server_outdated`,
## `map_mismatch`, `auth_failed`, `banned`, ...) or a local reason (REASON_*).
## `user_message(reason)` is the English text to show. Welcome's `ping_interval_ms` and
## `timeout_ms` override the tuning defaults when non-zero.
##
## Everything decoded after Welcome is handed out as a NetServerFrame via `frame_received`
## (batches in its arrays, other messages in `frame.messages`); Welcome, Pong and Error are
## handled here as well. The frame object is reused: consume it inside the signal.
## Room messages may arrive reordered or not at all on a later UDP transport (NetTransport).

signal state_changed(new_state: State)
## Handshake accepted. `welcome` is the vector-JSON Welcome.
signal welcomed(welcome: Dictionary)
## The connection is over. `reason`: server error code or REASON_*; `message`: player text.
signal failed(reason: String, message: String)
## Every Error message (fatal or not), e.g. `room_full` after a join attempt.
signal server_error(code: String, fatal: bool, detail: String)
## A decoded frame while READY.
signal frame_received(frame: NetServerFrame)

enum State { IDLE, CONNECTING, HANDSHAKING, READY, CLOSED, FAILED }

const REASON_CONNECT_FAILED := "connect_failed"
const REASON_HANDSHAKE_TIMEOUT := "handshake_timeout"
const REASON_TIMEOUT := "timeout"
const REASON_CLOSED := "closed"
const REASON_MALFORMED := "malformed"
const REASON_PROTOCOL := "protocol_error"
const REASON_NOT_READY := "not_ready"

const CLOSE_NORMAL := 1000
const CLOSE_PROTOCOL := 1002
const USEC_PER_MS := 1000
const USEC_PER_S := 1000000.0

const _MESSAGES := {
	"update_required": "A new version of Westbound is out. Please update to play online.",
	"server_outdated": "Westbound Online is being updated. Please try again in a few minutes.",
	"map_mismatch": "Your map data is out of date. Please update Westbound to play online.",
	"auth_failed": "Sign-in failed. Please try again.",
	"banned": "This account can't play online.",
	"server_full": "The server is full right now. Please try again soon.",
	"rate_limited": "Too many requests. Please wait a moment and try again.",
	"connect_failed": "Can't reach the Westbound server. Check your connection and try again.",
	"handshake_timeout": "The Westbound server didn't answer. Please try again.",
	"timeout": "Lost connection to the Westbound server.",
	"closed": "The Westbound server closed the connection.",
}
const _GENERIC_MESSAGE := "Something went wrong talking to the Westbound server. Please try again."

var clock: NetClock
var codec: NetCodec
## The last decoded frame (reused).
var frame: NetServerFrame
var account_id: String = ""
var welcome: Dictionary = {}
var failure_reason: String = ""
var failure_message: String = ""
var pings_sent: int = 0
var pongs_received: int = 0

var _transport: NetTransport
var _tuning: NetTuning
var _time: NetTimeSource
var _state: State = State.IDLE
var _hello: Dictionary = {}
var _ping_interval_us: int = 0
var _dead_timeout_us: int = 0
var _state_since_us: int = 0
var _last_recv_us: int = 0
var _last_ping_us: int = 0


func _init(transport: NetTransport, tuning: NetTuning = null,
		time_source: NetTimeSource = null) -> void:
	_transport = transport
	_tuning = tuning if tuning != null else NetTuning.load_default()
	_time = time_source if time_source != null else NetTimeSource.new()
	clock = NetClock.new(_tuning, _time)
	codec = NetCodec.new()
	frame = NetServerFrame.new()


## Player-facing text for a failure reason (server error code or REASON_*).
static func user_message(reason: String) -> String:
	return String(_MESSAGES.get(reason, _GENERIC_MESSAGE))


## True for the "please update" family (the store has a newer build).
static func needs_update(reason: String) -> bool:
	return reason == "update_required" or reason == "map_mismatch"


func get_state() -> State:
	return _state


func is_ready() -> bool:
	return _state == State.READY


## Opens the connection and sends Hello once the socket is open. `map_hash` is the 32-byte
## SHA-256 of the road-space file; `access_token` comes from the HTTP API (session.gd).
func start(url: String, client_build: int, map_hash: PackedByteArray,
		access_token: String = "") -> Error:
	if _state != State.IDLE and _state != State.CLOSED and _state != State.FAILED:
		return ERR_ALREADY_IN_USE
	if map_hash.size() != NetCodec.MAP_HASH_LEN or client_build < 0 \
			or client_build > NetCodec.U32_MAX:
		return ERR_INVALID_PARAMETER
	_hello = {
		"type": "hello", "protocol_version": NetCodec.PROTOCOL_VERSION,
		"client_build": client_build, "map_hash": map_hash.hex_encode(),
		"access_token": access_token,
	}
	codec.clear_frame()
	if codec.push(_hello, NetCodec.Direction.CLIENT_TO_SERVER) != "":
		codec.clear_frame()
		return ERR_INVALID_PARAMETER
	codec.clear_frame()
	account_id = ""
	welcome = {}
	failure_reason = ""
	failure_message = ""
	pings_sent = 0
	pongs_received = 0
	clock.reset()
	clock.set_tick_rate(_tuning.tick_rate_hz)
	_ping_interval_us = _tuning.ping_interval_usec()
	_dead_timeout_us = _tuning.dead_timeout_usec()
	var err := _transport.connect_to_url(url)
	if err != OK:
		_fail(REASON_CONNECT_FAILED)
		return err
	_set_state(State.CONNECTING)
	return OK


## Drives the connection: receives and handles frames, sends keepalive pings, detects
## timeouts. Call once per frame.
func poll() -> void:
	if _state == State.IDLE or _state == State.CLOSED or _state == State.FAILED:
		_transport.poll()
		return
	var frames := _transport.poll()
	var now := _time.now_usec()
	if _state == State.CONNECTING:
		match _transport.get_state():
			NetTransport.State.OPEN:
				_last_recv_us = now
				if not _send_dict(_hello):
					_fail(REASON_CONNECT_FAILED)
					return
				_set_state(State.HANDSHAKING)
			NetTransport.State.CLOSED:
				_fail(REASON_CONNECT_FAILED)
				return
			_:
				if now - _state_since_us > roundi(_tuning.connect_timeout_s * USEC_PER_S):
					_fail(REASON_CONNECT_FAILED)
				return
	for bytes in frames:
		_on_frame(bytes, now)
		if _state != State.HANDSHAKING and _state != State.READY:
			return
	if _transport.get_state() == NetTransport.State.CLOSED:
		_fail(REASON_CLOSED)
		return
	if _state == State.HANDSHAKING:
		if now - _state_since_us > roundi(_tuning.handshake_timeout_s * USEC_PER_S):
			_fail(REASON_HANDSHAKE_TIMEOUT)
		return
	if now - _last_recv_us >= _dead_timeout_us:
		_fail(REASON_TIMEOUT)
		return
	if now - _last_ping_us >= _ping_interval_us:
		_send_ping(now)


## Sends vector-JSON messages (client → server) as one frame. Returns "" or an error kind.
func send_messages(msgs: Array) -> String:
	if _state != State.READY:
		return REASON_NOT_READY
	var bytes := codec.encode_frame(msgs, NetCodec.Direction.CLIENT_TO_SERVER)
	if codec.error != "":
		return codec.error
	return "" if _transport.send(bytes) == OK else REASON_CLOSED


## Hot path: sends this tick's PlayerState as one frame.
func send_player_state(st: NetPlayerState) -> String:
	if _state != State.READY:
		return REASON_NOT_READY
	codec.clear_frame()
	var err := codec.push_player_state(st)
	if err != "":
		codec.clear_frame()
		return err
	return "" if _transport.send(codec.finish_frame()) == OK else REASON_CLOSED


## Closes the connection on purpose (no `failed` signal).
func close() -> void:
	if _state == State.CLOSED or _state == State.IDLE:
		return
	_transport.close(CLOSE_NORMAL, "bye")
	_set_state(State.CLOSED)


func _on_frame(bytes: PackedByteArray, now: int) -> void:
	_last_recv_us = now
	var err := codec.decode_server_frame_into(bytes, frame)
	if err != "":
		_fail(REASON_MALFORMED, CLOSE_PROTOCOL)
		return
	var other := frame.ps_count + frame.sp_count + frame.ds_count + frame.in_count \
		+ frame.co_count
	for msg: Dictionary in frame.messages:
		match String(msg["type"]):
			"welcome":
				if _state != State.HANDSHAKING:
					_fail(REASON_PROTOCOL, CLOSE_PROTOCOL)
					return
				_on_welcome(msg, now)
			"error":
				_on_error(msg)
				if _state == State.FAILED:
					return
			"pong":
				pongs_received += 1
				clock.on_pong(msg["client_time_ms"], msg["server_tick"], msg["tick_fraction"])
			_:
				other += 1
	if other > 0:
		if _state != State.READY:
			_fail(REASON_PROTOCOL, CLOSE_PROTOCOL)
			return
		frame_received.emit(frame)


func _on_welcome(msg: Dictionary, now: int) -> void:
	welcome = msg
	account_id = msg["account_id"]
	clock.set_tick_rate(float(msg["tick_rate_hz"]))
	var ping_ms: int = msg["ping_interval_ms"]
	var timeout_ms: int = msg["timeout_ms"]
	if ping_ms > 0:
		_ping_interval_us = ping_ms * USEC_PER_MS
	if timeout_ms > 0:
		_dead_timeout_us = timeout_ms * USEC_PER_MS
	_set_state(State.READY)
	_send_ping(now)
	welcomed.emit(msg)


func _on_error(msg: Dictionary) -> void:
	var code: String = msg["code"]
	var fatal: bool = msg["fatal"]
	server_error.emit(code, fatal, String(msg["detail"]))
	if fatal:
		_fail(code)


func _send_ping(now: int) -> void:
	_last_ping_us = now
	if _send_dict({"type": "ping", "client_time_ms": clock.ping_time_ms()}):
		pings_sent += 1


func _send_dict(msg: Dictionary) -> bool:
	codec.clear_frame()
	if codec.push(msg, NetCodec.Direction.CLIENT_TO_SERVER) != "":
		codec.clear_frame()
		return false
	return _transport.send(codec.finish_frame()) == OK


func _fail(reason: String, close_code: int = CLOSE_NORMAL) -> void:
	if _state == State.FAILED:
		return
	failure_reason = reason
	failure_message = user_message(reason)
	if _transport.get_state() != NetTransport.State.CLOSED:
		_transport.close(close_code, reason)
	_set_state(State.FAILED)
	failed.emit(reason, failure_message)


func _set_state(s: State) -> void:
	if s == _state:
		return
	_state = s
	_state_since_us = _time.now_usec()
	state_changed.emit(s)
