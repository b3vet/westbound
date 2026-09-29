class_name NetTransport
extends RefCounted
## Transport interface: one bidirectional stream of binary frames to the server. Spec:
## multiplayer handoff → Networking protocol → Client transport interface; docs/PROTOCOL.md
## §1–2. WP N2.2. Implementations: NetWsTransport (WebSocketPeer), NetLoopbackTransport
## (in-process, virtual clock; tests and a later offline mode). A UDP transport for native
## builds may follow.
##
## **Ordering contract:** a frame is delivered whole or not at all, but nothing above the
## transport may assume frames arrive in order, exactly once, or at all, except the lobby
## (party / room commands and events), which may rely on the WebSocket's TCP ordering.
## Room traffic tolerates reordering and loss: every state carries its tick and intents
## carry absolute ticks.
##
## Polling model: the owner calls `poll()` once per frame; it returns the frames received
## since the last poll (the returned Array is reused and valid until the next poll) and
## updates `get_state()`. `state_changed` fires from inside `poll()`, `connect_to_url()` or
## `close()`.
##
##   var t := NetWsTransport.new(NetTuning.load_default())
##   t.connect_to_url("wss://westbound.sipsakrandevu.com/ws")
##   ... each frame: for frame in t.poll(): handle(frame)
##   t.send(codec.finish_frame())

signal state_changed(new_state: State)

enum State { CLOSED, CONNECTING, OPEN, CLOSING }

## WebSocket close code and reason once CLOSED (-1 / "" when unknown or never opened).
var close_code: int = -1
var close_reason: String = ""

var _state: State = State.CLOSED
var _received: Array[PackedByteArray] = []


## Starts connecting (the name avoids Object.connect). Returns OK or an Error; the result
## of the attempt shows up in `get_state()` after later polls.
func connect_to_url(_url: String) -> Error:
	return ERR_UNAVAILABLE


## Queues one binary frame. ERR_UNCONFIGURED when not OPEN, ERR_BUSY when the outbound
## buffer is full (the frame is dropped; room traffic is re-sent next tick anyway).
func send(_frame: PackedByteArray) -> Error:
	return ERR_UNAVAILABLE


## Pumps the transport; returns the frames received since the last poll.
func poll() -> Array[PackedByteArray]:
	_received.clear()
	return _received


## Starts a clean close. `poll()` reports CLOSED once it completes.
func close(_code: int = 1000, _reason: String = "") -> void:
	pass


func get_state() -> State:
	return _state


func is_open() -> bool:
	return _state == State.OPEN


func _set_state(s: State) -> void:
	if s == _state:
		return
	_state = s
	state_changed.emit(s)
