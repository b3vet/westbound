extends RefCounted
## A tiny scripted server for the net client tests, on the server end of a NetLoopbackLink.
## Mirrors the protocol crate's handshake (docs/PROTOCOL.md §5: version, build, map hash,
## token, first failure wins; every handshake error is fatal) and answers Ping with Pong
## carrying its room clock. Not a test file (no `test_` prefix); preload it.

const C2S := NetCodec.Direction.CLIENT_TO_SERVER
const S2C := NetCodec.Direction.SERVER_TO_CLIENT
const USEC_PER_S := 1000000.0

var transport: NetLoopbackTransport
var time: NetTimeSource
var codec := NetCodec.new()

## Server room clock = (local seconds + offset_s) × tick_rate.
var offset_s: float = 1234.5
var tick_rate: float = 20.0
## Pong outside a room carries tick 0 / fraction 0.
var in_room: bool = true
var answer_pings: bool = true
## Read and drop everything (a hung server).
var silent: bool = false

var min_protocol: int = NetCodec.PROTOCOL_VERSION
var max_protocol: int = NetCodec.PROTOCOL_VERSION
var min_client_build: int = 0
var map_hash_hex: String = "0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186"
var banned_token: String = "banned-token"
var account_id: String = "9223372036854775807"
var ping_interval_ms: int = 2000
var timeout_ms: int = 8000

var established: bool = false
var hellos: Array[Dictionary] = []
var pings: int = 0
var errors_sent: PackedStringArray = []
var decode_errors: PackedStringArray = []


func _init(link: NetLoopbackLink) -> void:
	transport = link.server
	time = link.time


func poll() -> void:
	for f in transport.poll():
		if silent:
			continue
		var msgs := codec.decode_frame(f, C2S)
		if codec.error != "":
			decode_errors.append(codec.error)
			_reject("malformed", "Malformed message.")
			continue
		for m in msgs:
			_handle(m)
			if transport.get_state() != NetTransport.State.OPEN:
				return


func server_ticks() -> float:
	return (time.now_usec() / USEC_PER_S + offset_s) * tick_rate


func send(msgs: Array) -> void:
	var bytes := codec.encode_frame(msgs, S2C)
	assert(codec.error == "", "fake server: cannot encode %s: %s" % [msgs, codec.error])
	transport.send(bytes)


func send_raw(bytes: PackedByteArray) -> void:
	transport.send(bytes)


func _handle(m: Dictionary) -> void:
	match String(m["type"]):
		"hello":
			hellos.append(m)
			if established:
				_reject("malformed", "Malformed message.")
				return
			var version: int = m["protocol_version"]
			if version < min_protocol:
				_reject("update_required", "Please update Westbound to play online.")
			elif version > max_protocol:
				_reject("server_outdated",
					"The server is being updated. Try again in a few minutes.")
			elif int(m["client_build"]) < min_client_build:
				_reject("update_required", "Please update Westbound to play online.")
			elif m["map_hash"] != map_hash_hex:
				_reject("map_mismatch", "Your map data is out of date. Please update Westbound.")
			elif String(m["access_token"]).is_empty():
				_reject("auth_failed", "Sign-in failed. Please try again.")
			elif m["access_token"] == banned_token:
				_reject("banned", "This account is banned from online play.")
			else:
				established = true
				send([{"type": "welcome", "protocol_version": NetCodec.PROTOCOL_VERSION,
					"server_build": 7, "account_id": account_id, "tick_rate_hz": int(tick_rate),
					"ping_interval_ms": ping_interval_ms, "timeout_ms": timeout_ms,
					"max_frame_bytes": NetCodec.MAX_FRAME_LEN}])
		"ping":
			if not established:
				_reject("handshake_required", "Hello must be the first message.")
				return
			pings += 1
			if answer_pings:
				send([_pong(m["client_time_ms"])])
		_:
			if not established:
				_reject("handshake_required", "Hello must be the first message.")


func _pong(echo: int) -> Dictionary:
	var tick := 0
	var frac := 0
	if in_room:
		var t := server_ticks()
		tick = floori(t)
		frac = mini(roundi((t - tick) * NetCodec.TICK_FRACTION_SCALE), NetCodec.U16_MAX)
	return {"type": "pong", "client_time_ms": echo, "server_tick": tick, "tick_fraction": frac}


func _reject(code: String, detail: String) -> void:
	errors_sent.append(code)
	send([{"type": "error", "code": code, "fatal": true, "detail": detail}])
	transport.close(1000, code)
