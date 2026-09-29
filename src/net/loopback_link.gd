class_name NetLoopbackLink
extends RefCounted
## An in-process network link between two NetLoopbackTransport endpoints (`client`,
## `server`), driven by a NetTimeSource (usually NetVirtualTime) and a seeded Rng. Spec:
## multiplayer handoff → Testing (simulated link: "configurable latency, jitter and loss";
## acceptance at 150 ms RTT, ±30 ms jitter, 2 % loss). WP N2.2. Used by tests and a later
## offline mode.
##
## Each frame gets its own one-way delay `latency_s ± jitter_s` (uniform) and is dropped
## with probability `loss`. By default the link behaves like a datagram path: frames may be
## lost and, when jitter exceeds the send spacing, reordered; set `ordered` to deliver in
## send order (a TCP-like stream: late frames hold back the ones behind them). `down` drops
## everything in both directions (a dead link, for keepalive tests). With the same seed and
## the same sends, delivery is identical.
##
## The link owns both endpoints; they only hold weak references back (no reference cycle),
## so keep the link alive as long as its endpoints are in use.
##
##   var time := NetVirtualTime.new()
##   var link := NetLoopbackLink.new(time, Rng.new(1))
##   link.latency_s = 0.075; link.jitter_s = 0.015; link.loss = 0.02
##   link.client.connect_to_url("loop://server")   # both ends OPEN after connect_delay_s
##   time.advance_s(0.2); link.server.poll(); link.client.poll()

## One-way base delay.
var latency_s: float = 0.0
## One-way delay varies uniformly within ±jitter_s (never below zero).
var jitter_s: float = 0.0
## Probability that a frame is lost, per frame and direction.
var loss: float = 0.0
## Deliver in send order per direction (TCP-like) instead of datagram semantics.
var ordered: bool = false
## Drop every frame in both directions.
var down: bool = false
## Delay from connect_to_url() until both ends are OPEN; < 0 means one round trip.
var connect_delay_s: float = -1.0
## Refuse connection attempts (the client goes CLOSED after the connect delay).
var refuse: bool = false

var client: NetLoopbackTransport
var server: NetLoopbackTransport
var time: NetTimeSource

var sent_frames: int = 0
var lost_frames: int = 0

var _rng: Rng


func _init(time_source: NetTimeSource, rng: Rng) -> void:
	time = time_source
	_rng = rng
	client = NetLoopbackTransport.new(self)
	server = NetLoopbackTransport.new(self)
	client._peer_ref = weakref(server)
	server._peer_ref = weakref(client)


## Send time → delivery time (usec) for one frame, or -1 when it is lost.
func schedule(from_usec: int) -> int:
	sent_frames += 1
	if down or (loss > 0.0 and _rng.chance(loss)):
		lost_frames += 1
		return -1
	var delay := latency_s
	if jitter_s > 0.0:
		delay += _rng.float_range(-jitter_s, jitter_s)
	return from_usec + roundi(maxf(delay, 0.0) * NetVirtualTime.USEC_PER_S)


func connect_delay_usec() -> int:
	var d := connect_delay_s if connect_delay_s >= 0.0 else latency_s * 2.0
	return roundi(d * NetVirtualTime.USEC_PER_S)


func latency_usec() -> int:
	return roundi(latency_s * NetVirtualTime.USEC_PER_S)
