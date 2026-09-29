class_name RoadPlanGen
extends RefCounted
# lint: sim
## Plan view (horizontal alignment) of the procedural road: a seeded stream of
## straights, clothoid transitions and arcs. Spec: World → Road (radius >= 1,200 m,
## long gentle curves), Core loop → Sky timeline and Cameras → Glare rule (sun
## 15-30 deg off the camera axis), Traffic fairness rule 6 (warning signs).
## Used by ProceduralRoadPath; see docs/CONTRACTS.md §3.
##
## Elements: curvature is linear in s inside each element (k = k0 + dk t), so the
## curvature is continuous everywhere (straight -> ramp 0..k -> arc k -> ramp k..0)
## and heading(s) = h0 + k0 t + dk t^2 / 2 is exact. Everything here is + - * / on
## seeded draws: no trig, so heading and curvature are bit-identical on every
## platform. World positions (trig) are integrated by ProceduralRoadPath.
##
## Sun rule (the sun's azimuth is world heading 0, "due west"): the heading stays in
## the band sun_offset_min_deg..sun_offset_max_deg on one side ("sun side" +1 = the
## road heads right of the sun, -1 = left). Normal bends only move the heading
## inside the band. Every sun_side_switch_min_km..max_km the road changes side in
## ONE bend at sun_side_switch_radius_m whose constant-radius arc spans the whole
## +-sun_offset_min_deg zone (its transitions lie outside the zone), so each switch
## spends exactly 2 * sun_offset_min * switch_radius of road inside the zone
## (628 m at defaults) and the heading is otherwise always inside the band.
##
## Generation is sequential and draws only from its own stream, so the element list
## is the same however far ahead or in whatever increments generate_to() is called.
##
## Biomes (WP6.4a): with `biome_rules` (the latched per-leg biome rules), each
## section reads the curve frequency scale of the leg it starts in: straights are drawn / scale (desert < 1: long straights;
## canyon > 1: more bends) and, above 1, bend radii come from the tighter
## [min, min + (max - min) / scale]. The bend sight clearance for BLIND_BEND is the
## biome's (cliffs). The number of draws never changes, and at scale 1 (or without a
## plan) every value is bit-identical to the plain generator.
##
## Sun side per leg (WP6.4c): a leg whose biome requires a side (BiomeRoadRules
## .sun_side_for_leg: the coast keeps the sun over its sea) is honoured like this. Each
## section first draws its straight, then looks for the first requiring leg within
## straight + one bend + `sun_lookahead_m` (two forced sections: the shortest straight
## and the longest bend, a preparing bend and the switch). Found on the other side: the
## switch is forced now (shortest straight, then the usual switch, or the preparing bend
## away from the sun first), so it ends before the leg starts; found on this side: the
## scheduled switches wait. The road's first side is the required one when a requiring
## leg starts within the start straight + sun_lookahead_m. The heading stays inside the
## 15-30 deg band everywhere except inside the switch bends, as before, and only the
## seeded draws decide: deterministic by seed and plan. Without requiring legs nothing
## changes (bit-identical).

## Forks (WP6.5, docs/FORKS.md): `set_forks(splits, sides)`. A section that would run
## into a fork's approach (fork_approach_straight_m before its split) instead ends with a
## bend to the middle of the sun band (when there is room) and a straight to the split;
## at the split this path takes its branch: one bend of fork_branch_deflection_deg to its
## side (left = -1) at fork_branch_radius_m, then fork_straight_after_m of straight. The
## branch bends are mirror images within the band and draw no random numbers, so every
## path of a run is identical up to the split, and after it until the other branch is
## out of sight.

## Plan-view sight distance past an obstruction `m` inside the driving line on an
## arc of radius R (middle-ordinate rule): S^2 = 8 R m.
const MIDDLE_ORDINATE_FACTOR := 8.0   # lint: allow-number geometry constant, not tuning

# Element storage (structure of arrays; index 0 is the oldest element kept).
var el_s0 := PackedFloat64Array()
var el_len := PackedFloat64Array()
var el_k0 := PackedFloat64Array()
var el_dk := PackedFloat64Array()
var el_h0 := PackedFloat64Array()
## End s of the generated elements.
var end_s: float = 0.0

## BEND, BLIND_BEND and SIGN features, each list in increasing s_start.
var bends: Array[RoadFeature] = []
var blind_bends: Array[RoadFeature] = []
var signs: Array[RoadFeature] = []

## Output of eval().
var out_heading: float = 0.0
var out_curvature: float = 0.0

## Optional: per-leg curve frequency and bend sight clearance (null = the defaults).
var biome_rules: BiomeRoadRules

var _rng: Rng
var _cursor: int = 0
var _h: float = 0.0
var _side: float = 1.0
var _next_switch_s: float = 0.0
var _started: bool = false

var _start_straight: float
var _straight_min: float
var _straight_max: float
var _radius_min: float
var _radius_max: float
var _defl_min: float
var _defl_max: float
var _ramp_min: float
var _ramp_max: float
var _band_lo: float
var _band_hi: float
var _switch_min: float
var _switch_max: float
var _switch_radius: float
var _switch_ramp_margin: float
var _sharp_radius: float
var _sign_distance: float
var _bend_sight_sq_min: float
var _bend_sight_factor: float
var _bend_sight_clearance: float
## Longest bend of any kind (normal, preparing, switch) incl. its transitions, and the
## road a forced switch may need (two sections of the shortest straight + that bend).
var _bend_max: float
## How far past a section's straight and bend a requiring leg is looked for.
var sun_lookahead_m: float = 0.0

## Fork splits (increasing) and this path's branch at each (-1 left, +1 right).
var fork_s := PackedFloat64Array()
var fork_side := PackedInt32Array()
var _fork_i: int = 0
var _fork_approach: float = 0.0
var _fork_defl: float = 0.0
var _fork_radius: float = 0.0
var _fork_after: float = 0.0
## A section this close to a split counts as starting at it (float noise).
const FORK_EPS_M := 1e-6   # lint: allow-number numeric tolerance, not tuning


func _init(rng: Rng, t: RoadTuning) -> void:
	_rng = rng
	_start_straight = t.start_straight_m
	_straight_min = t.straight_min_m
	_straight_max = t.straight_max_m
	_radius_min = t.min_curve_radius_m
	_radius_max = maxf(t.curve_radius_max_m, t.min_curve_radius_m)
	_defl_min = deg_to_rad(t.curve_deflection_min_deg)
	_defl_max = deg_to_rad(t.curve_deflection_max_deg)
	_ramp_min = t.transition_min_m
	_ramp_max = t.transition_max_m
	_band_lo = deg_to_rad(t.sun_offset_min_deg)
	_band_hi = deg_to_rad(t.sun_offset_max_deg)
	_switch_min = Units.km_to_m(t.sun_side_switch_min_km)
	_switch_max = Units.km_to_m(t.sun_side_switch_max_km)
	_switch_radius = maxf(t.sun_side_switch_radius_m, t.min_curve_radius_m)
	# Heading change of the longest transition at the switch radius: a switch starts
	# and ends at least this far inside the band so its transitions stay out of the zone.
	_switch_ramp_margin = _ramp_max / (2.0 * _switch_radius)
	_sharp_radius = t.sharp_bend_radius_m
	_sign_distance = t.hazard_sign_distance_m
	# Bend sight distance, compared squared (no sqrt in the branch).
	_bend_sight_clearance = t.bend_sight_clearance_m
	_bend_sight_factor = MIDDLE_ORDINATE_FACTOR * _bend_sight_clearance
	_bend_sight_sq_min = t.blind_sight_distance_m * t.blind_sight_distance_m
	var arc_max := maxf(2.0 * _band_hi * _switch_radius, maxf(_band_hi - _band_lo, _defl_max) * _radius_max)
	_bend_max = 2.0 * _ramp_max + arc_max
	sun_lookahead_m = 2.0 * (_straight_min + _bend_max)
	_fork_approach = t.fork_approach_straight_m
	_fork_defl = deg_to_rad(t.fork_branch_deflection_deg)
	_fork_radius = maxf(t.fork_branch_radius_m, t.min_curve_radius_m)
	_fork_after = t.fork_straight_after_m
	assert(_band_hi - _band_lo >= 2.0 * _defl_min, "sun band narrower than two minimum bends")
	assert(_band_lo + _switch_ramp_margin < _band_hi, "switch transitions do not fit in the sun band")


## The forks this path meets: split positions (increasing) and its branch side at each.
## Set before generating past the first approach.
func set_forks(splits: PackedFloat64Array, sides: PackedInt32Array) -> void:
	fork_s = splits.duplicate()
	fork_side = sides.duplicate()
	_fork_i = 0
	while _fork_i < fork_s.size() and fork_s[_fork_i] < end_s - FORK_EPS_M:
		_fork_i += 1


## Generates elements until they cover at least `s`. Director rate.
func generate_to(s: float) -> void:
	if not _started:
		_start()
	while end_s < s:
		_add_section()


## Heading and curvature at `s` into out_heading / out_curvature. `s` must not go
## backwards between calls (the cursor only moves forward) and must be < end_s.
func eval(s: float) -> void:
	var n := el_s0.size()
	while _cursor + 1 < n and el_s0[_cursor + 1] <= s:
		_cursor += 1
	var t := s - el_s0[_cursor]
	var k0 := el_k0[_cursor]
	var dk := el_dk[_cursor]
	out_curvature = k0 + dk * t
	out_heading = el_h0[_cursor] + (k0 + dk * t * 0.5) * t


## Drops elements and features that end before `s` (and before the eval cursor).
func forget_before(s: float) -> void:
	var drop := 0
	while drop < _cursor and el_s0[drop] + el_len[drop] <= s:
		drop += 1
	if drop > 0:
		el_s0 = el_s0.slice(drop)
		el_len = el_len.slice(drop)
		el_k0 = el_k0.slice(drop)
		el_dk = el_dk.slice(drop)
		el_h0 = el_h0.slice(drop)
		_cursor -= drop
	RoadPlanGen.drop_features_before(bends, s)
	RoadPlanGen.drop_features_before(blind_bends, s)
	RoadPlanGen.drop_features_before(signs, s)


## Removes the leading features of a sorted list that end before `s`.
static func drop_features_before(list: Array[RoadFeature], s: float) -> void:
	var drop := 0
	while drop < list.size() and list[drop].s_end < s:
		drop += 1
	if drop > 0:
		list.assign(list.slice(drop))


# ---------------------------------------------------------------- Generation

func _start() -> void:
	_started = true
	_side = 1.0 if _rng.chance(0.5) else -1.0
	var need := _sun_side_ahead(0.0, _start_straight + sun_lookahead_m)
	if need != 0:
		_side = float(need)
	_h = _side * _rng.float_range(_band_lo, _band_hi)
	_next_switch_s = _rng.float_range(_switch_min, _switch_max)
	_push(_start_straight, 0.0, 0.0, _h)


## One straight followed by one bend.
func _add_section() -> void:
	if _fork_i < fork_s.size() and end_s >= fork_s[_fork_i] - FORK_EPS_M:
		_add_fork_branch(fork_side[_fork_i])
		_fork_i += 1
		return
	var scale := biome_rules.curve_scale_at(end_s) if biome_rules != null else 1.0
	if scale <= 0.0:
		scale = 1.0
	var straight := _rng.float_range(_straight_min, _straight_max) / scale
	if _fork_i < fork_s.size() and fork_s[_fork_i] - _fork_approach - end_s < straight + 2.0 * _bend_max:
		_add_fork_approach(fork_s[_fork_i])
		return
	# The sun side a leg ahead requires (0 = none within reach): switch now, or hold.
	var need := _sun_side_ahead(end_s, end_s + straight + _bend_max + sun_lookahead_m)
	var forced := need != 0 and float(need) != _side
	if forced:
		straight = _straight_min
	_push(straight, 0.0, 0.0, _h)
	var r_max := _radius_max
	if scale > 1.0:
		r_max = _radius_min + (_radius_max - _radius_min) / scale
	var off := _side * _h   # current sun offset, in [band_lo, band_hi]
	var ramp := _rng.float_range(_ramp_min, _ramp_max)
	if forced or (end_s >= _next_switch_s and need == 0):
		if off >= _band_lo + _switch_ramp_margin:
			_add_side_switch(ramp)
			return
		# Too close to the zone for a clean switch: first bend away from the sun,
		# far enough that the switch can start on the next section.
		var target := _rng.float_range(_band_lo + _switch_ramp_margin, _band_hi)
		_add_bend(_side * (target - off), _rng.float_range(_radius_min, r_max), ramp)
		return
	var room_up := _band_hi - off
	var room_down := off - _band_lo
	var dir := 0.0
	if room_up >= _defl_min and room_down >= _defl_min:
		dir = 1.0 if _rng.unit() * (room_up + room_down) < room_up else -1.0
	elif room_up >= _defl_min:
		dir = 1.0
	elif room_down >= _defl_min:
		dir = -1.0
	else:
		return   # unreachable with a valid band (asserted in _init)
	var room := room_up if dir > 0.0 else room_down
	var mag := _rng.float_range(_defl_min, minf(_defl_max, room))
	_add_bend(_side * dir * mag, _rng.float_range(_radius_min, r_max), ramp)


## The sun side required by the first leg overlapping [a, b] that requires one (0 when
## none, or without biome rules).
func _sun_side_ahead(a: float, b: float) -> int:
	if biome_rules == null:
		return 0
	for k in range(biome_rules.leg_at(a), biome_rules.leg_at(b) + 1):
		var need := biome_rules.sun_side_for_leg(k)
		if need != 0:
			return need
	return 0


## The road into a fork: a bend to the middle of the sun band (when it fits before the
## approach), then straight to the split. No random draws.
func _add_fork_approach(split: float) -> void:
	var room := split - _fork_approach - end_s
	if room >= _bend_max:
		_push(room - _bend_max, 0.0, 0.0, _h)
		var off := _side * _h
		var mid := 0.5 * (_band_lo + _band_hi)
		_add_bend(_side * (mid - off), _fork_radius, _ramp_min)
	if split > end_s:
		_push(split - end_s, 0.0, 0.0, _h)


## At a split: this path's branch bend (side -1 left, +1 right), then the straight while
## the other branch is in sight. No random draws.
func _add_fork_branch(side: int) -> void:
	if side != 0:
		_add_bend(float(side) * _fork_defl, _fork_radius, _ramp_min)
	_push(_fork_after, 0.0, 0.0, _h)


func _add_side_switch(ramp: float) -> void:
	var target_off := _rng.float_range(_band_lo + _switch_ramp_margin, _band_hi)
	var target_h := -_side * target_off
	_add_bend(target_h - _h, _switch_radius, ramp)
	_side = -_side
	_next_switch_s = end_s + _rng.float_range(_switch_min, _switch_max)


## A bend changing the heading by `dh` (signed): transition, arc at `radius`,
## transition. A bend too small for two full transitions has no arc: its
## transitions shorten (never below transition_min_m) and, if they reach that
## floor, its peak curvature drops below 1 / radius, so the curvature rate never
## exceeds (1 / min radius) / transition_min_m.
func _add_bend(dh: float, radius: float, ramp: float) -> void:
	var mag := absf(dh)
	if mag <= 0.0:
		return
	var kmag := 1.0 / radius
	var arc := mag * radius - ramp
	if arc < 0.0:
		arc = 0.0
		ramp = maxf(mag * radius, _ramp_min)
		kmag = mag / ramp
	var k := kmag if dh > 0.0 else -kmag
	var eff_radius := 1.0 / kmag
	var h_start := _h
	var s_start := end_s
	var h := h_start
	_push(ramp, 0.0, k / ramp, h)
	h += k * ramp * 0.5
	if arc > 0.0:
		_push(arc, k, 0.0, h)
		h += k * arc
	_push(ramp, k, -k / ramp, h)
	_h = h_start + dh
	bends.append(RoadFeature.make(RoadFeature.Kind.BEND, s_start, end_s, k))
	var sight_factor := _bend_sight_factor
	if biome_rules != null:
		var clearance := biome_rules.bend_sight_clearance_at(s_start, _bend_sight_clearance)
		if clearance != _bend_sight_clearance:
			sight_factor = MIDDLE_ORDINATE_FACTOR * clearance
	if sight_factor * eff_radius < _bend_sight_sq_min:
		blind_bends.append(RoadFeature.make(RoadFeature.Kind.BLIND_BEND, s_start, end_s,
			sqrt(sight_factor * eff_radius)))
	var sign_s := s_start - _sign_distance
	if eff_radius <= _sharp_radius and sign_s >= 0.0:
		signs.append(RoadFeature.make(RoadFeature.Kind.SIGN, sign_s, sign_s, _sign_distance,
			ProceduralRoadPath.SIGN_BEND))


func _push(length: float, k0: float, dk: float, h0: float) -> void:
	el_s0.append(end_s)
	el_len.append(length)
	el_k0.append(k0)
	el_dk.append(dk)
	el_h0.append(h0)
	end_s += length
