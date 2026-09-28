class_name RoadProfileGen
extends RefCounted
# lint: sim
## Vertical profile of the procedural road: constant-grade tangents joined by
## parabolic vertical curves (grade linear in s, so the grade is continuous), with
## occasional deliberate blind crests. Spec: World → Road (grades up to 5%,
## occasional blind crests), Traffic fairness rule 6. Used by ProceduralRoadPath.
##
## Elements: grade g = g0 + dg t, elevation e = e0 + g0 t + dg t^2 / 2, all exact
## + - * / on seeded draws (bit-identical on every platform).
##
## Blind crests are computed from the geometry, not from intent: every convex
## vertical curve (grade decreasing by A over length L, radius R = L / A) gets the
## standard crest sight distance for an eye at sight_eye_height_m (h1) over an
## object sight_object_height_m (h2) tall, with c = (sqrt(h1) + sqrt(h2))^2:
##   S <= L:  S^2 = 2 c R          S > L:  S = L / 2 + c / A
## and is flagged BLIND_CREST when S < blind_sight_distance_m. The only root is of
## the two tuning heights (IEEE sqrt is correctly rounded, so c is identical on
## every platform); the branches compare squares. Normal vertical curves keep
## R >= vertical_radius_min_m, which is never blind when 2 c R_min >= S_blind^2
## (the curve with the smallest radius has the shortest sight for any grade change),
## so blind crests are exactly the deliberate ones.

var el_s0 := PackedFloat64Array()
var el_len := PackedFloat64Array()
var el_e0 := PackedFloat64Array()
var el_g0 := PackedFloat64Array()
var el_dg := PackedFloat64Array()
var end_s: float = 0.0

## BLIND_CREST and SIGN features, each list in increasing s_start.
var crests: Array[RoadFeature] = []
var signs: Array[RoadFeature] = []

## Output of eval().
var out_elevation: float = 0.0
var out_grade: float = 0.0

## (sqrt(h1) + sqrt(h2))^2 of the crest sight rule.
var sight_c: float

var _rng: Rng
var _cursor: int = 0
var _e: float = 0.0
var _g: float = 0.0
var _pending_crest: bool = false
var _started: bool = false

var _start_len: float
var _grade_max: float
var _grade_typical: float
var _len_min: float
var _len_max: float
var _vr_min: float
var _vr_max: float
var _soft_limit: float
var _crest_chance: float
var _crest_grade_min: float
var _crest_vr_min: float
var _crest_vr_max: float
var _sight_min: float
var _sign_distance: float


func _init(rng: Rng, t: RoadTuning) -> void:
	_rng = rng
	_start_len = t.start_straight_m
	_grade_max = t.max_grade_frac()
	_grade_typical = minf(Units.pct_to_frac(t.grade_typical_pct), _grade_max)
	_len_min = t.grade_length_min_m
	_len_max = t.grade_length_max_m
	_vr_min = t.vertical_radius_min_m
	_vr_max = t.vertical_radius_max_m
	_soft_limit = t.elevation_soft_limit_m
	_crest_chance = t.crest_chance_frac
	_crest_grade_min = minf(Units.pct_to_frac(t.crest_grade_min_pct), _grade_max)
	_crest_vr_min = t.crest_vertical_radius_min_m
	_crest_vr_max = t.crest_vertical_radius_max_m
	_sight_min = t.blind_sight_distance_m
	_sign_distance = t.hazard_sign_distance_m
	var root_sum := sqrt(t.sight_eye_height_m) + sqrt(t.sight_object_height_m)
	sight_c = root_sum * root_sum


## Generates elements until they cover at least `s`. Director rate.
func generate_to(s: float) -> void:
	if not _started:
		_started = true
		_push(_start_len, 0.0, 0.0)
	while end_s < s:
		_add_step()


## Elevation and grade at `s` into out_elevation / out_grade (s non-decreasing, < end_s).
func eval(s: float) -> void:
	var n := el_s0.size()
	while _cursor + 1 < n and el_s0[_cursor + 1] <= s:
		_cursor += 1
	var t := s - el_s0[_cursor]
	var g0 := el_g0[_cursor]
	var dg := el_dg[_cursor]
	out_grade = g0 + dg * t
	out_elevation = el_e0[_cursor] + (g0 + dg * t * 0.5) * t


## Crest sight distance for a convex vertical curve of grade change `a` (> 0) and
## length `length`: see the class comment. Returns S.
func crest_sight_distance(a: float, length: float) -> float:
	var two_c_r := 2.0 * sight_c * length / a
	if two_c_r <= length * length:
		return sqrt(two_c_r)
	return length * 0.5 + sight_c / a


## True when that crest hides an object closer than blind_sight_distance_m.
## Arithmetic only (same branch as crest_sight_distance, compared squared).
func is_blind_crest(a: float, length: float) -> bool:
	var two_c_r := 2.0 * sight_c * length / a
	if two_c_r <= length * length:
		return two_c_r < _sight_min * _sight_min
	return length * 0.5 + sight_c / a < _sight_min


func forget_before(s: float) -> void:
	var drop := 0
	while drop < _cursor and el_s0[drop] + el_len[drop] <= s:
		drop += 1
	if drop > 0:
		el_s0 = el_s0.slice(drop)
		el_len = el_len.slice(drop)
		el_e0 = el_e0.slice(drop)
		el_g0 = el_g0.slice(drop)
		el_dg = el_dg.slice(drop)
		_cursor -= drop
	RoadPlanGen.drop_features_before(crests, s)
	RoadPlanGen.drop_features_before(signs, s)


# ---------------------------------------------------------------- Generation

## One vertical curve (to a new grade) followed by one constant-grade tangent.
func _add_step() -> void:
	var g1 := _g
	var g2: float
	var radius: float
	if _pending_crest or _rng.chance(_crest_chance):
		if g1 >= _crest_grade_min:
			# Over the top: the deliberate crest.
			g2 = -_rng.float_range(_crest_grade_min, _grade_max)
			radius = _rng.float_range(_crest_vr_min, _crest_vr_max)
			_pending_crest = false
		else:
			# Climb first; the crest follows on the next step.
			g2 = _rng.float_range(_crest_grade_min, _grade_max)
			radius = _rng.float_range(_vr_min, _vr_max)
			_pending_crest = true
	else:
		g2 = _rng.float_range(-_grade_typical, _grade_typical)
		if (_e > _soft_limit and g2 > 0.0) or (_e < -_soft_limit and g2 < 0.0):
			g2 = -g2
		radius = _rng.float_range(_vr_min, _vr_max)
	var a := g1 - g2
	var length := absf(a) * radius
	if length > 0.0:
		var s_start := end_s
		_push(length, g1, (g2 - g1) / length)
		if a > 0.0 and is_blind_crest(a, length):
			crests.append(RoadFeature.make(RoadFeature.Kind.BLIND_CREST, s_start, end_s,
				crest_sight_distance(a, length)))
			var sign_s := s_start - _sign_distance
			if sign_s >= 0.0:
				signs.append(RoadFeature.make(RoadFeature.Kind.SIGN, sign_s, sign_s, _sign_distance,
					ProceduralRoadPath.SIGN_CREST))
	_g = g2
	_push(_rng.float_range(_len_min, _len_max), g2, 0.0)


## Appends an element starting at end_s with the running elevation, then advances
## the running elevation and grade exactly (e += (g0 + dg L / 2) L).
func _push(length: float, g0: float, dg: float) -> void:
	el_s0.append(end_s)
	el_len.append(length)
	el_e0.append(_e)
	el_g0.append(g0)
	el_dg.append(dg)
	_e += (g0 + dg * length * 0.5) * length
	end_s += length
