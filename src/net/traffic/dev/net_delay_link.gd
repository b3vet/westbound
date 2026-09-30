class_name NetDelayLink
extends RefCounted
## One direction of a simulated network path for the network traffic harness: latency,
## jitter and loss on a virtual clock. Spec: multiplayer handoff → Testing → Netcode
## harness ("connect through an in-process delay layer with configurable latency, jitter
## and loss"; acceptance at 150 ms RTT, ±30 ms jitter, 2 % loss). docs/NET_TRAFFIC.md →
## The fake authority. WP N4.3.
##
## Each frame gets a one-way delay of `latency_s` ± `jitter_s` (uniform). Two loss models:
## - STREAM (the WebSocket over TCP, the default): a lost frame is retransmitted after
##   `rto_s` (again with probability `loss`), and frames arrive in send order, so a
##   retransmission holds back everything behind it (head-of-line blocking). Nothing is
##   ever lost; loss shows up as a late burst.
## - DATAGRAM (a later UDP transport): a lost frame is gone, and jitter may reorder frames.
## With the same seed and the same sends, delivery is identical.

enum Mode { STREAM, DATAGRAM }

var latency_s: float = 0.0
var jitter_s: float = 0.0
var loss: float = 0.0
var rto_s: float = 0.0
var mode: Mode = Mode.STREAM

var sent: int = 0
var lost: int = 0               ## DATAGRAM: dropped; STREAM: retransmissions
var bytes: int = 0

var _rng: Rng
var _due := PackedInt64Array()
var _frames: Array[PackedByteArray] = []
var _last_due: int = 0


func _init(rng: Rng) -> void:
	_rng = rng


## The acceptance link of NetTuning's "Netcode test link" group (one direction: half the
## round trip, half the round-trip jitter).
func configure(net: NetTuning, link_mode: Mode = Mode.STREAM, with_loss: bool = true) -> void:
	latency_s = net.test_link_rtt_ms * 0.5 / NetClock.MS_PER_S
	jitter_s = net.test_link_jitter_ms * 0.5 / NetClock.MS_PER_S
	loss = net.test_link_loss if with_loss else 0.0
	rto_s = net.test_link_rto_ms / NetClock.MS_PER_S
	mode = link_mode


## Sends `frame` at `at_usec` (virtual time).
func send(frame: PackedByteArray, at_usec: int) -> void:
	sent += 1
	bytes += frame.size()
	var delay := latency_s
	if jitter_s > 0.0:
		delay += _rng.float_range(-jitter_s, jitter_s)
	if loss > 0.0:
		while _rng.chance(loss):
			lost += 1
			if mode == Mode.DATAGRAM:
				return
			delay += rto_s
	var due := at_usec + roundi(maxf(delay, 0.0) * NetClock.USEC_PER_S)
	if mode == Mode.STREAM:
		due = maxi(due, _last_due)
		_last_due = due
	var k := _due.size()
	while k > 0 and _due[k - 1] > due:
		k -= 1
	_due.insert(k, due)
	_frames.insert(k, frame)


## Delivery time of the next frame (INF-like max int when none).
func next_due() -> int:
	return _due[0] if not _due.is_empty() else 9223372036854775807


## Takes the next frame (call when next_due() <= now).
func take() -> PackedByteArray:
	var f: PackedByteArray = _frames.pop_front()
	_due.remove_at(0)
	return f


func pending() -> int:
	return _due.size()
