class_name NetVirtualTime
extends NetTimeSource
## Hand-driven NetTimeSource for tests and offline simulation: time only moves when
## `advance_*` is called. Spec: multiplayer handoff → Testing → Client (clock sync on a
## simulated link). WP N2.2.

const USEC_PER_S := 1000000.0

var usec: int = 0


func _init(start_usec: int = 0) -> void:
	usec = start_usec


func now_usec() -> int:
	return usec


func advance_usec(d: int) -> void:
	usec += maxi(d, 0)


func advance_s(seconds: float) -> void:
	advance_usec(roundi(seconds * USEC_PER_S))
