class_name RoadHull
extends RefCounted
## Oriented boxes in road space (plan view) and the hull-to-hull clearance between two
## of them. Spec: Lives, hits and crashes ("collision boxes are oriented boxes in road
## space, inset 8 cm from the visual body"); Scoring → Scoring events (close pass:
## "minimum hull-to-hull clearance"; thread: "lateral clearance").
##
## A box is its center (s, d), its heading relative to the road `yaw` (rad, + nose
## right, so its forward axis is (cos yaw, sin yaw) in (s, d)), its half-length and its
## half-width. Callers pass hull half-sizes, i.e. already inset by
## LivesTuning.collision_inset_m. Road space is treated as locally Cartesian (the
## boxes are a few meters long on a road with radius >= 1,200 m).
##
## Pure and allocation-free (scalars only): safe to call per tick.


## Minimum distance between the two boxes; 0 when they overlap or touch.
static func clearance(s1: float, d1: float, yaw1: float, hl1: float, hw1: float,
		s2: float, d2: float, yaw2: float, hl2: float, hw2: float) -> float:
	var c1 := cos(yaw1)
	var n1 := sin(yaw1)
	var c2 := cos(yaw2)
	var n2 := sin(yaw2)
	var ds := s2 - s1
	var dd := d2 - d1
	# Separating-axis test on the four box axes: forward (c, n) and right (-n, c).
	if not (_separated(ds, dd, c1, n1, c1, n1, hl1, hw1, c2, n2, hl2, hw2)
			or _separated(ds, dd, -n1, c1, c1, n1, hl1, hw1, c2, n2, hl2, hw2)
			or _separated(ds, dd, c2, n2, c1, n1, hl1, hw1, c2, n2, hl2, hw2)
			or _separated(ds, dd, -n2, c2, c1, n1, hl1, hw1, c2, n2, hl2, hw2)):
		return 0.0
	# Disjoint convex polygons: the closest pair always includes a vertex of one of
	# them, so the minimum over the 8 corner-to-box distances is exact.
	var best := INF
	for i in 2:
		var sx := float(i * 2 - 1)
		for j in 2:
			var sy := float(j * 2 - 1)
			var ps := s1 + sx * hl1 * c1 - sy * hw1 * n1
			var pd := d1 + sx * hl1 * n1 + sy * hw1 * c1
			best = minf(best, point_distance(ps, pd, s2, d2, c2, n2, hl2, hw2))
			ps = s2 + sx * hl2 * c2 - sy * hw2 * n2
			pd = d2 + sx * hl2 * n2 + sy * hw2 * c2
			best = minf(best, point_distance(ps, pd, s1, d1, c1, n1, hl1, hw1))
	return best


## Distance from point (ps, pd) to the solid box centered at (cs, cd) with forward axis
## (c, n) = (cos yaw, sin yaw); 0 inside.
static func point_distance(ps: float, pd: float, cs: float, cd: float, c: float, n: float,
		hl: float, hw: float) -> float:
	var rs := ps - cs
	var rd := pd - cd
	var x := maxf(absf(rs * c + rd * n) - hl, 0.0)
	var y := maxf(absf(-rs * n + rd * c) - hw, 0.0)
	return sqrt(x * x + y * y)


static func _separated(ds: float, dd: float, ax: float, ay: float,
		c1: float, n1: float, hl1: float, hw1: float,
		c2: float, n2: float, hl2: float, hw2: float) -> bool:
	var r1 := hl1 * absf(c1 * ax + n1 * ay) + hw1 * absf(-n1 * ax + c1 * ay)
	var r2 := hl2 * absf(c2 * ax + n2 * ay) + hw2 * absf(-n2 * ax + c2 * ay)
	return absf(ds * ax + dd * ay) > r1 + r2
