class_name NetTrafficWire
extends RefCounted
# lint: sim
## Conversions between the traffic messages' wire units and the client's road space, in
## one place. Spec: multiplayer handoff → Networking protocol (quantization), The loop map
## ("s wraps modulo L"); docs/PROTOCOL.md §3–§4; plan MP-D6 (lane numbering, ramp lane 7).
## docs/NET_TRAFFIC.md → Wire conventions. WP N4.3. Pure and allocation-free.
##
## - **Lanes:** the sim counts lanes from the median (0 = leftmost, TrafficState.lane); the
##   wire counts from the right (0 = rightmost). `wire = n - 1 - lane` with n the lane
##   count at the car's s. Wire lane 7 (RAMP_LANE) is the ramp pseudo-lane, the sim's
##   lane n (one right of the rightmost lane).
## - **d:** the sim is right-positive (CONTRACTS §2); the wire's `d_cm` is left-positive
##   (PROTOCOL.md §3), so the sign flips here.
## - **s:** the wire carries s wrapped into [0, L) on the loop (u32 mm); the client keeps s
##   unwrapped and places each wire s at the lap nearest the player
##   (LoopRoadPath.unwrap_near's rule, generalised to any RoadPath.period_m()). An open road
##   (period 0) is not wrapped.
## - **Durations** are whole milliseconds; ticks are the room's 20 Hz ticks.

## MP-D6: wire lane value of the ramp pseudo-lane (the loop has at most 4 lanes).
const RAMP_LANE := 7
const MS_PER_S := 1000.0   # lint: allow-number unit conversion


## Wire lane (0 = rightmost, 7 = ramp) → sim lane (0 = next to the median) with `lanes`
## lanes at the car's s. An impossible value (a lane the road does not have) is clamped.
static func lane_from_wire(wire_lane: int, lanes: int) -> int:
	if wire_lane == RAMP_LANE:
		return lanes
	return clampi(lanes - 1 - wire_lane, 0, maxi(lanes - 1, 0))


## Sim lane → wire lane (the ramp pseudo-lane, lane >= lanes, is RAMP_LANE).
static func lane_to_wire(lane: int, lanes: int) -> int:
	if lane >= lanes:
		return RAMP_LANE
	return clampi(lanes - 1 - lane, 0, RAMP_LANE - 1)


## Wire d (cm, left-positive) → sim d (m, right-positive).
static func d_from_wire(d_cm: int) -> float:
	return -NetCodec.d_from_wire(d_cm)


## Sim d (m, right-positive) → wire d (cm, left-positive, clamped to the protocol range).
static func d_to_wire(d_m: float) -> int:
	return NetCodec.d_to_wire(-d_m)


## s into the wire's range: [0, period) on a periodic road, unchanged on an open one.
static func s_wrap(road: RoadPath, s: float) -> float:
	var period := road.period_m()
	if period <= 0.0:
		return s
	var r := s - floorf(s / period) * period
	if r >= period:
		r -= period
	elif r < 0.0:
		r += period
	return r


## A wire s (m) at the lap nearest `ref_s` (the player's unwrapped s).
static func s_unwrap(road: RoadPath, s_wire: float, ref_s: float) -> float:
	var period := road.period_m()
	if period <= 0.0:
		return s_wire
	return ref_s + s_wrap(road, s_wire - ref_s + period * 0.5) - period * 0.5


## Milliseconds → seconds.
static func ms_to_s(ms: int) -> float:
	return float(ms) / MS_PER_S


## Seconds → whole milliseconds (u16 range for durations).
static func s_to_ms(seconds: float) -> int:
	return clampi(roundi(seconds * MS_PER_S), 0, NetCodec.U16_MAX)
