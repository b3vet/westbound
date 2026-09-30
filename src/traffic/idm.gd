class_name Idm
extends RefCounted
## Intelligent Driver Model, pure and static. Spec: Traffic → Longitudinal model: IDM.
##
##   a  = a_max * [1 - (v / v0)^delta - (s* / s)^2]
##   s* = s0 + max(0, v T + v dv / (2 sqrt(a_max b)))
##
## s = bumper-to-bumper gap to the leader (m), dv = v - v_leader (closing speed, m/s),
## T = time headway (s), s0 = minimum gap (m), b = comfortable deceleration (m/s^2),
## delta = 4 (an integer: the power is repeated multiplication, so results are
## bit-identical on every platform). These functions return the raw model value;
## the 6 m/s^2 clamp (fairness rule 4) is applied by TrafficSim.
## Allocation-free; safe to call per tick.


## Full IDM acceleration. gap = INF means a free road (no leader).
static func accel(v: float, v0: float, gap: float, dv: float, a_max: float, b: float,
		headway: float, s0: float, delta: int, gap_floor: float) -> float:
	var free := 1.0 - pow_int(v / v0, delta)
	if is_inf(gap):
		return a_max * free
	var r := desired_gap(v, dv, a_max, b, headway, s0) / maxf(gap, gap_floor)
	return a_max * (free - r * r)


## Free-road term only: a_max * (1 - (v / v0)^delta).
static func free_accel(v: float, v0: float, a_max: float, delta: int) -> float:
	return a_max * (1.0 - pow_int(v / v0, delta))


## Interaction term only: -a_max * (s* / s)^2. Used for a follower that holds its
## speed (the player in MOBIL's safety check). 0 on a free road.
static func interaction_accel(v: float, gap: float, dv: float, a_max: float, b: float,
		headway: float, s0: float, gap_floor: float) -> float:
	if is_inf(gap):
		return 0.0
	var r := desired_gap(v, dv, a_max, b, headway, s0) / maxf(gap, gap_floor)
	return -a_max * r * r


## s*: the desired dynamic gap (m).
static func desired_gap(v: float, dv: float, a_max: float, b: float, headway: float, s0: float) -> float:
	return s0 + maxf(0.0, v * headway + v * dv / (2.0 * sqrt(a_max * b)))


## Steady-state gap behind a leader at the same constant speed v:
## s_e = (s0 + v T) / sqrt(1 - (v / v0)^delta). INF when v >= v0.
static func equilibrium_gap(v: float, v0: float, headway: float, s0: float, delta: int) -> float:
	var k := 1.0 - pow_int(v / v0, delta)
	if k <= 0.0:
		return INF
	return (s0 + v * headway) / sqrt(k)


## x^n for n >= 0 by repeated squaring (exact IEEE ops, no libm).
static func pow_int(x: float, n: int) -> float:
	var result := 1.0
	var base := x
	var e := n
	while e > 0:
		if e & 1:
			result *= base
		base *= base
		e >>= 1
	return result
