class_name NetLoopbackTransport
extends NetTransport
## One end of a NetLoopbackLink: an in-process NetTransport on a virtual clock. Spec:
## multiplayer handoff → Networking protocol → Client transport interface; Testing. WP N2.2.
##
## The client end connects with `connect_to_url()` (the URL is only recorded); both ends
## turn OPEN after the link's connect delay. Frames sent by one end arrive at the other's
## `poll()` once the virtual clock reaches their delivery time. `close()` closes this end
## at once and the peer one latency later (after the frames already in flight). The
## ordering contract of NetTransport applies: by default frames can be lost or reordered.

var url: String = ""

var _link_ref: WeakRef
var _peer_ref: WeakRef
var _open_at_usec: int = -1
var _close_at_usec: int = -1
## Inbound queue sorted by delivery time (stable for equal times).
var _due := PackedInt64Array()
var _frames: Array[PackedByteArray] = []
## Latest scheduled delivery, for `ordered` links.
var _last_due_usec: int = 0


func _init(link: NetLoopbackLink) -> void:
	_link_ref = weakref(link)


func connect_to_url(url_: String) -> Error:
	if _state != State.CLOSED:
		return ERR_ALREADY_IN_USE
	var link := _link()
	var peer := _peer()
	if link == null or peer == null:
		return ERR_UNCONFIGURED
	url = url_
	close_code = -1
	close_reason = ""
	var at := link.time.now_usec() + link.connect_delay_usec()
	_reset_queue()
	_open_at_usec = at
	_set_state(State.CONNECTING)
	if not link.refuse:
		peer._accept(at)
	return OK


func send(frame: PackedByteArray) -> Error:
	if _state != State.OPEN:
		return ERR_UNCONFIGURED
	if frame.is_empty() or frame.size() > NetCodec.MAX_FRAME_LEN:
		return ERR_INVALID_PARAMETER
	var link := _link()
	var peer := _peer()
	if link == null or peer == null:
		return ERR_UNCONFIGURED
	var at := link.schedule(link.time.now_usec())
	if at >= 0:
		peer._enqueue(frame, at)
	return OK


func poll() -> Array[PackedByteArray]:
	_received.clear()
	var link := _link()
	if link == null:
		return _received
	var now := link.time.now_usec()
	if _state == State.CONNECTING and _open_at_usec >= 0 and now >= _open_at_usec:
		_open_at_usec = -1
		if link.refuse:
			close_code = -1
			close_reason = "connection refused"
			_set_state(State.CLOSED)
		else:
			_set_state(State.OPEN)
	if _state == State.OPEN or _state == State.CLOSING:
		while not _frames.is_empty() and _due[0] <= now:
			_received.append(_frames.pop_front())
			_due.remove_at(0)
	if _close_at_usec >= 0 and now >= _close_at_usec and _frames.is_empty():
		_close_at_usec = -1
		_set_state(State.CLOSED)
	return _received


func close(code: int = 1000, reason: String = "") -> void:
	if _state == State.CLOSED:
		return
	close_code = code
	close_reason = reason
	_open_at_usec = -1
	_reset_queue()
	_set_state(State.CLOSED)
	var link := _link()
	var peer := _peer()
	if link != null and peer != null:
		peer._remote_closed(link.time.now_usec() + link.latency_usec(), code, reason)


## Frames waiting for delivery (tests).
func pending() -> int:
	return _frames.size()


func _accept(at_usec: int) -> void:
	_reset_queue()
	close_code = -1
	close_reason = ""
	_open_at_usec = at_usec
	_set_state(State.CONNECTING)


func _enqueue(frame: PackedByteArray, at_usec: int) -> void:
	if _state == State.CLOSED:
		return
	var link := _link()
	var at := at_usec
	if link != null and link.ordered:
		at = maxi(at, _last_due_usec)
	_last_due_usec = maxi(_last_due_usec, at)
	var i := _frames.size()
	while i > 0 and _due[i - 1] > at:
		i -= 1
	_due.insert(i, at)
	_frames.insert(i, frame)


func _remote_closed(at_usec: int, code: int, reason: String) -> void:
	if _state == State.CLOSED:
		return
	close_code = code
	close_reason = reason
	if _state == State.CONNECTING:
		_open_at_usec = -1
		_set_state(State.CLOSED)
		return
	# Frames already in flight still arrive; then the close.
	_close_at_usec = maxi(at_usec, _last_due_usec)


func _link() -> NetLoopbackLink:
	return _link_ref.get_ref() as NetLoopbackLink


func _peer() -> NetLoopbackTransport:
	return _peer_ref.get_ref() as NetLoopbackTransport if _peer_ref != null else null


func _reset_queue() -> void:
	_due.clear()
	_frames.clear()
	_last_due_usec = 0
	_close_at_usec = -1
