class_name Mobil
extends RefCounted
## MOBIL lane-change criteria, pure and static. Spec: Traffic → Lane changes: MOBIL.
##
##   incentive:  (a~c - ac) + p [(a~n - an) + (a~o - ao)] > delta_a_th + a_bias
##   safety:     a~n >= -b_safe
##
## c = the changing car, n = its new follower in the target lane, o = its old follower;
## "~" marks accelerations after the change. p = politeness.
##
## Keep-right bias (asymmetric, as in MOBIL's European rule): a_bias raises the
## threshold for moves to the left and lowers it for moves to the right, so with
## a_bias > delta_a_th a driver drifts back right when it costs nothing.
## Player safety: when the player would be the new follower, b_safe tightens to
## TrafficTuning.player_b_safe_mps2 (2 m/s^2); see b_safe_for().
## Allocation-free; safe to call per tick.


static func incentive(a_c_new: float, a_c: float, a_n_new: float, a_n: float,
		a_o_new: float, a_o: float, p: float) -> float:
	return (a_c_new - a_c) + p * ((a_n_new - a_n) + (a_o_new - a_o))


## The threshold the incentive must exceed for a move in this direction.
static func threshold(a_th: float, a_bias: float, to_right: bool) -> float:
	return a_th - a_bias if to_right else a_th + a_bias


static func accepts(incentive_value: float, a_th: float, a_bias: float, to_right: bool) -> bool:
	return incentive_value > threshold(a_th, a_bias, to_right)


## The new follower's acceleration after the change must not be below -b_safe.
static func is_safe(a_n_new: float, b_safe: float) -> bool:
	return a_n_new >= -b_safe


## b_safe for this new follower: tightened to player_b_safe when it is the player.
static func b_safe_for(profile_b_safe: float, follower_is_player: bool, player_b_safe: float) -> float:
	return minf(profile_b_safe, player_b_safe) if follower_is_player else profile_b_safe
