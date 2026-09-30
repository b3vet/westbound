class_name NoAmbush
extends RefCounted
## The no-ambush predicate, pure and static. Spec: Traffic → Fairness rules 2 ("A car
## may not start a lane change into space the player is predicted to occupy within
## the next 1.5 s, using the player's current s, v and lateral velocity plus a 1.0 m
## margin").
##
## Definition used by TrafficSim (and restated in docs/TRAFFIC.md):
## - the car's target space: its own body at the target lane center, moving along the
##   road at its current speed (box center (s_c + v_c t, d_target), size len_c x w_c);
## - the player's predicted space: its body moving at its current road-frame velocity
##   (center (s_p + v_p t, d_p + v_lat_p t)), grown by `margin` on every side;
## - violation: the two boxes overlap at some t in [0, window].
## Both boxes move linearly, so per axis the overlap times form an open interval,
## solved exactly; the predicate is their intersection with [0, window].
## Allocation-free; safe to call per tick.


static func violates(car_s: float, car_v: float, car_length: float, car_width: float, target_d: float,
		p_s: float, p_v: float, p_d: float, p_v_lat: float, p_length: float, p_width: float,
		window: float, margin: float) -> bool:
	var half_s := (car_length + p_length) * 0.5 + margin
	var half_d := (car_width + p_width) * 0.5 + margin
	# Longitudinal: |(p_s - car_s) + (p_v - car_v) t| < half_s
	var lo := 0.0
	var hi := window
	var ds := p_s - car_s
	var rs := p_v - car_v
	if rs == 0.0:
		if absf(ds) >= half_s:
			return false
	else:
		var t1 := (-half_s - ds) / rs
		var t2 := (half_s - ds) / rs
		lo = maxf(lo, minf(t1, t2))
		hi = minf(hi, maxf(t1, t2))
	# Lateral: |(p_d - target_d) + p_v_lat t| < half_d
	var dd := p_d - target_d
	if p_v_lat == 0.0:
		if absf(dd) >= half_d:
			return false
	else:
		var u1 := (-half_d - dd) / p_v_lat
		var u2 := (half_d - dd) / p_v_lat
		lo = maxf(lo, minf(u1, u2))
		hi = minf(hi, maxf(u1, u2))
	return lo < hi
