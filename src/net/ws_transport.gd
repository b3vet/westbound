class_name NetWsTransport
extends NetTransport
## NetTransport over Godot's WebSocketPeer (native and web). Spec: multiplayer handoff →
## Networking protocol → Connection ("one wss://<domain>/ws connection per client") and
## Client transport interface; docs/PROTOCOL.md §1. WP N2.2.
##
## Binary frames only: a text frame from the server is a protocol violation and closes the
## connection (1003). Inbound frames larger than NetCodec.MAX_FRAME_LEN are dropped and
## close the connection (1009) before they reach the codec. Outbound frames are refused
## with ERR_BUSY when they would overflow the outbound buffer (tuning
## `ws_outbound_buffer_kb`), instead of letting WebSocketPeer fail. TLS: `wss://` uses the
## platform trust store by default (`TLSOptions.client()`); pass other options (a pinned
## CA, or `TLSOptions.client_unsafe()` for a local dev server) to the constructor.
##
## TCP delivers in order, but callers must not rely on it outside the lobby (NetTransport).

const CLOSE_NORMAL := 1000
const CLOSE_UNSUPPORTED_DATA := 1003
const CLOSE_TOO_BIG := 1009
const BYTES_PER_KB := 1024

var _tuning: NetTuning
var _tls: TLSOptions
var _ws: WebSocketPeer
var _url: String = ""


func _init(tuning: NetTuning = null, tls: TLSOptions = null) -> void:
	_tuning = tuning if tuning != null else NetTuning.load_default()
	_tls = tls


func connect_to_url(url: String) -> Error:
	if _state != State.CLOSED:
		return ERR_ALREADY_IN_USE
	_url = url
	close_code = -1
	close_reason = ""
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = _tuning.ws_inbound_buffer_kb * BYTES_PER_KB
	_ws.outbound_buffer_size = _tuning.ws_outbound_buffer_kb * BYTES_PER_KB
	_ws.max_queued_packets = _tuning.ws_max_queued_packets
	var err := _ws.connect_to_url(url, _tls)
	if err != OK:
		_ws = null
		return err
	_set_state(State.CONNECTING)
	return OK


func send(frame: PackedByteArray) -> Error:
	if _state != State.OPEN or _ws == null:
		return ERR_UNCONFIGURED
	if frame.is_empty() or frame.size() > NetCodec.MAX_FRAME_LEN:
		return ERR_INVALID_PARAMETER
	if _ws.get_current_outbound_buffered_amount() + frame.size() > _ws.outbound_buffer_size:
		return ERR_BUSY
	return _ws.send(frame, WebSocketPeer.WRITE_MODE_BINARY)


func poll() -> Array[PackedByteArray]:
	_received.clear()
	if _ws == null:
		return _received
	_ws.poll()
	var ws_state := _ws.get_ready_state()
	if ws_state == WebSocketPeer.STATE_OPEN or ws_state == WebSocketPeer.STATE_CLOSING:
		while _ws.get_available_packet_count() > 0:
			var pkt := _ws.get_packet()
			if _ws.get_packet_error() != OK:
				continue
			if not _ws.was_string_packet() and pkt.size() <= NetCodec.MAX_FRAME_LEN:
				_received.append(pkt)
			elif ws_state == WebSocketPeer.STATE_OPEN:
				var too_big := pkt.size() > NetCodec.MAX_FRAME_LEN
				_ws.close(CLOSE_TOO_BIG if too_big else CLOSE_UNSUPPORTED_DATA,
					"frame too large" if too_big else "binary frames only")
				ws_state = WebSocketPeer.STATE_CLOSING
				break
	match ws_state:
		WebSocketPeer.STATE_CONNECTING:
			_set_state(State.CONNECTING)
		WebSocketPeer.STATE_OPEN:
			_set_state(State.OPEN)
		WebSocketPeer.STATE_CLOSING:
			_set_state(State.CLOSING)
		WebSocketPeer.STATE_CLOSED:
			close_code = _ws.get_close_code()
			close_reason = _ws.get_close_reason()
			_ws = null
			_set_state(State.CLOSED)
	return _received


func close(code: int = CLOSE_NORMAL, reason: String = "") -> void:
	if _ws == null:
		return
	var ws_state := _ws.get_ready_state()
	if ws_state == WebSocketPeer.STATE_CONNECTING or ws_state == WebSocketPeer.STATE_OPEN:
		_ws.close(code, reason)
		_set_state(State.CLOSING)


## Bytes queued but not yet sent (backpressure indicator for the dev HUD).
func buffered_amount() -> int:
	return _ws.get_current_outbound_buffered_amount() if _ws != null else 0


func get_url() -> String:
	return _url
