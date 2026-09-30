class_name NetTimeSource
extends RefCounted
## Monotonic time for the net layer, in microseconds. Spec: multiplayer handoff →
## Networking protocol → Clock sync. WP N2.2.
##
## Production uses this base class (Time.get_ticks_usec, monotonic since engine start).
## Tests and the loopback link inject NetVirtualTime so latency, keepalive and clock sync
## run on a virtual clock, deterministically and without waiting.


func now_usec() -> int:
	return Time.get_ticks_usec()
