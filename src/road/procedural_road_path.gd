class_name ProceduralRoadPath
extends RoadPath
# lint: sim
## The seeded, endless procedural road (WP1.1). Spec: World → Road (radius >=
## 1,200 m, grades <= 5%, occasional blind crests), Traffic fairness rule 6 (blind
## crests and bends, warning signs), Core loop → Sky timeline and Cameras → Glare
## rule (sun 15-30 deg off the camera axis), Legs and checkpoints (checkpoint every
## leg, signs at 1 km and 500 m), Architecture rules 2, 5, 6, 7.
## See docs/CONTRACTS.md §2-§3, §9, §12.
##
##   var road := ProceduralRoadPath.new(ctx)     # ctx: RunContext (seed + tuning)
##   road.ensure_generated_to(player_s + ahead)  # director rate
##   road.sample_into(s, out)                    # tick rate, allocation-free
##   road.forget_before(player_s - behind)       # director rate
##
## Pipeline: RoadPlanGen (straights, clothoid transitions, arcs; the sun band) and
## RoadProfileGen (grade tangents + parabolic vertical curves; blind crests) emit
## analytic elements from their own streams (ctx.rng_road.derive(&"plan"/&"profile")).
## Those are sampled every sample_spacing_m into a dense table, built in fixed
## blocks of generation_block_m on a global grid (s_i = i * spacing), so the table
## is identical however far ahead / in what increments ensure_generated_to() runs.
##
## sample_into() is O(1): index = floor(s / spacing), then cubic Hermite on heading
## (with curvature as slope) and on elevation (with grade as slope), linear on
## curvature and grade. Positions: x_i + t sin(h_mid), z_i - t cos(h_mid) with h_mid
## the Hermite heading halfway to s (the table integrates with the same rule, so
## position is continuous across grid points).
##
## Biomes (WP6.4a, docs/BIOMES.md): set_biome_plan(plan) (the run's BiomeDirector does
## it at setup) restarts generation with per-leg road rules latched from the plan
## (BiomeRoadRules): curve and crest frequency, bend sight clearance, the leg's lane
## count (changed biome_lane_change_after_m past the checkpoint, tapered) and road
## tunnels (TUNNEL features, tunnel_lanes inside with a taper before the first portal
## and the lanes back after the last exit, a "lane ends" SIGN before the drop). Legs
## are latched in order, one leg past the generated table. Without a plan the road is
## exactly the plain generator: 3 lanes, no tunnels.
##
## Lane tapers: lane_count(s) steps at a change's s_start; the right lane edge
## (lanes_right_edge_d, and so shoulder_outer_d / guardrail_d) follows a smoothstep
## over the change's taper, like the road mesh, so the barrier the player can hit is
## the one drawn.
##
## Forks (WP6.5, docs/FORKS.md): `set_forks(forks, origin_x, origin_z)` gives the path
## the forks it meets (RoadFork: split, its branch side, the right branch's shift) and
## restarts generation. The plan generator holds a straight approach and takes this
## path's branch at each split; the lanes split there (left lanes left, the rest right,
## no taper), then widen back to the branch biome's count; the gore-side shoulder and
## rail open with the gap between the branches; the opposite carriageway veers away
## before the split and comes back after the gore (opposite_offset_d / _width_frac);
## the right branch's left side is a rail. `hold_at_forks` (the run's main path) stops
## length_generated() at an unresolved split, so no world system builds on a branch the
## player may not take. `swap_state(other)` adopts the other branch path's state (the
## player picked it). FORK features span each fork; checkpoint SIGNs before a fork carry
## tag2 SIGN_FORK_TAG2 and its CHECKPOINT the sign gantry style.
##
## Determinism: curvature, heading, grade, elevation, lane counts and every feature
## come from Rng draws (PCG32, integer-exact) combined with + - * / only; branches
## never depend on sin/cos/atan/sqrt results (the one sqrt, in the crest constant,
## is of tuning values and IEEE sqrt is correctly rounded anyway). World x/z use
## sin/cos and feed rendering only.

const STREAM_PLAN := &"plan"
const STREAM_PROFILE := &"profile"
## SIGN tags (what the sign announces).
const SIGN_CHECKPOINT := &"checkpoint"
const SIGN_BEND := &"bend"
const SIGN_CREST := &"crest"
## A lane drop ahead (value = distance to the taper's start).
const SIGN_LANE_ENDS := &"lane_ends"
const STREAM_TUNNELS := &"tunnels"
## tag2 of the checkpoint SIGN features announcing a fork (Landmarks draws fork signs).
const SIGN_FORK_TAG2 := &"fork"
## Fork checkpoints are sign gantries over the split (their signs name both branches).
const FORK_LANDMARK := BiomeDef.LANDMARK_SIGN_GANTRY
## Hermite basis coefficient (h01 = u^2 (3 - 2u)).
const _HERMITE_3 := 3.0   # lint: allow-number cubic Hermite basis coefficient

var _plan: RoadPlanGen
var _profile: RoadProfileGen

var _dx: float
var _inv_dx: float
var _block_n: int
## Global grid index of table entry 0, and the table length.
var _base_i: int = 0
var _n: int = 0
var _h := PackedFloat64Array()
var _k := PackedFloat64Array()
var _e := PackedFloat64Array()
var _g := PackedFloat64Array()
var _x := PackedFloat64Array()
var _z := PackedFloat64Array()

var _leg_length: float
var _checkpoint_warnings := PackedFloat64Array()

## The per-leg biome rules (null without a plan).
var biome_rules: BiomeRoadRules

var _ctx: RunContext
var _tuning: RoadTuning
## Lanes before the first retained change.
var _lanes_default: int
var _lanes_min: int
var _lanes_max: int
var _lane_taper: float
## Lane changes, sorted by s: from _lane_change_s[i] on the count is _lane_change_count[i],
## the edge tapering over _lane_change_taper[i].
var _lane_change_s := PackedFloat64Array()
var _lane_change_count := PackedInt32Array()
var _lane_change_taper := PackedFloat64Array()
var _lane_features: Array[RoadFeature] = []
var _tunnel_features: Array[RoadFeature] = []
var _lane_signs: Array[RoadFeature] = []
## Legs whose lanes and tunnels are scheduled (with a plan).
var _latched_leg: int = 0
var _tunnel_seed: int = 0

var _forgotten_s: float = 0.0
## Hazard signs are generated with their bend / crest, which starts this much later.
var _sign_lookahead: float

## Forks this path meets (WP6.5), increasing split.
var forks: Array[RoadFork] = []
## The run's main path: length_generated() stops at an unresolved fork's split (+ the
## hold margin) until the run resolves it (RoadFork.resolved).
var hold_at_forks: bool = false
## World position of s = 0 (a right branch path is the road translated to the right).
var _origin_x: float = 0.0
var _origin_z: float = 0.0
var _fork_smp := RoadSample.new()
var _fork_sib := RoadSample.new()


func _init(ctx: RunContext) -> void:
	super(ctx.tuning.road)
	var t := ctx.tuning.road
	_ctx = ctx
	_tuning = t
	_tunnel_seed = ctx.rng_road.derive(STREAM_TUNNELS).get_seed()
	_plan = RoadPlanGen.new(ctx.rng_road.derive(STREAM_PLAN), t)
	_profile = RoadProfileGen.new(ctx.rng_road.derive(STREAM_PROFILE), t)
	_dx = t.sample_spacing_m
	_inv_dx = 1.0 / _dx
	_block_n = t.generation_block_samples()
	assert(_block_n >= 2, "generation block shorter than two samples")
	_leg_length = ctx.tuning.legs.leg_length_m()
	for w in ctx.tuning.legs.checkpoint_warning_distances_m:
		_checkpoint_warnings.append(w)
	_lanes_default = t.lanes_default
	_lanes_min = t.lanes_min
	_lanes_max = t.lanes_max
	_lane_taper = t.lane_taper_length_m
	_sign_lookahead = t.hazard_sign_distance_m
	ensure_generated_to(0.0)


## Road rules per leg from `plan` (null = the plain generator). Restarts generation
## from s = 0 (same seed, same streams) and regenerates as far as before, and clears
## every scheduled lane change: call it once, before anything samples beyond the start
## straight or schedules lanes (the run's BiomeDirector does it at setup). Director rate.
func set_biome_plan(plan: BiomePlan) -> void:
	biome_rules = BiomeRoadRules.new(plan, _tuning) if plan != null else null
	_restart()


## The forks this path meets and where s = 0 lies in the world (WP6.5; see the header).
## Restarts generation like set_biome_plan (call it at setup, or when the path is made).
func set_forks(list: Array[RoadFork], origin_x: float = 0.0, origin_z: float = 0.0) -> void:
	forks = list.duplicate()
	forks.sort_custom(func(a: RoadFork, b: RoadFork) -> bool: return a.split_s < b.split_s)
	_origin_x = origin_x
	_origin_z = origin_z
	_restart()


func _restart() -> void:
	var gen_to := _table_end()
	if biome_rules != null:
		biome_rules = BiomeRoadRules.new(biome_rules.plan, _tuning)
	_plan = RoadPlanGen.new(_ctx.rng_road.derive(STREAM_PLAN), _tuning)
	_profile = RoadProfileGen.new(_ctx.rng_road.derive(STREAM_PROFILE), _tuning)
	_plan.biome_rules = biome_rules
	_profile.biome_rules = biome_rules
	var splits := PackedFloat64Array()
	var sides := PackedInt32Array()
	for f in forks:
		splits.append(f.split_s)
		sides.append(f.side)
		f.pose_known = false
		if biome_rules != null:
			biome_rules.hold_rules(f.split_s, f.gore_end_s(), f.checkpoint)
	_plan.set_forks(splits, sides)
	_base_i = 0
	_n = 0
	_h.clear()
	_k.clear()
	_e.clear()
	_g.clear()
	_x.clear()
	_z.clear()
	_forgotten_s = 0.0
	_lanes_default = _tuning.lanes_default
	if biome_rules != null:
		_lanes_default = biome_rules.lanes_for_leg(1)
	_lane_change_s.clear()
	_lane_change_count.clear()
	_lane_change_taper.clear()
	_lane_features.clear()
	_tunnel_features.clear()
	_lane_signs.clear()
	_latched_leg = 0
	ensure_generated_to(gen_to)


# ---------------------------------------------------------------- Reference line (tick rate)

func sample_into(s: float, out: RoadSample) -> void:
	var f := s * _inv_dx
	var j := int(floor(f)) - _base_i
	if j > _n - 2:
		j = _n - 2
	elif j < 0:
		j = 0
	var u := f - float(j + _base_i)
	var u2 := u * u
	var h01 := u2 * (_HERMITE_3 - 2.0 * u)
	var h11 := u2 * (u - 1.0)
	var h10 := h11 - u2 + u   # u^3 - 2u^2 + u
	var h00 := 1.0 - h01
	var h0 := _h[j]
	var h1 := _h[j + 1]
	var k0 := _k[j]
	var k1 := _k[j + 1]
	var g0 := _g[j]
	var g1 := _g[j + 1]
	var heading := h00 * h0 + h01 * h1 + _dx * (h10 * k0 + h11 * k1)
	var elevation := h00 * _e[j] + h01 * _e[j + 1] + _dx * (h10 * g0 + h11 * g1)
	# Heading halfway between the grid point and s (Hermite basis at u / 2).
	var m := u * 0.5
	var m2 := m * m
	var m01 := m2 * (_HERMITE_3 - 2.0 * m)
	var m11 := m2 * (m - 1.0)
	var mid_h := (1.0 - m01) * h0 + m01 * h1 + _dx * ((m11 - m2 + m) * k0 + m11 * k1)
	var ds := u * _dx
	out.s = s
	out.curvature = k0 + u * (k1 - k0)
	out.set_frame(heading, g0 + u * (g1 - g0))
	out.set_position(_x[j] + ds * sin(mid_h), elevation, _z[j] - ds * cos(mid_h))


func curvature_at(s: float) -> float:
	var f := s * _inv_dx
	var j := int(floor(f)) - _base_i
	if j > _n - 2:
		j = _n - 2
	elif j < 0:
		j = 0
	var u := f - float(j + _base_i)
	return _k[j] + u * (_k[j + 1] - _k[j])


## World heading at `s` (rad, right-positive, 0 = -Z = toward the sun). Tick-safe.
func heading_at(s: float) -> float:
	var f := s * _inv_dx
	var j := int(floor(f)) - _base_i
	if j > _n - 2:
		j = _n - 2
	elif j < 0:
		j = 0
	var u := f - float(j + _base_i)
	var u2 := u * u
	var h01 := u2 * (_HERMITE_3 - 2.0 * u)
	var h11 := u2 * (u - 1.0)
	return (1.0 - h01) * _h[j] + h01 * _h[j + 1] + _dx * ((h11 - u2 + u) * _k[j] + h11 * _k[j + 1])


## Road elevation at `s` (m). Tick-safe.
func elevation_at(s: float) -> float:
	var f := s * _inv_dx
	var j := int(floor(f)) - _base_i
	if j > _n - 2:
		j = _n - 2
	elif j < 0:
		j = 0
	var u := f - float(j + _base_i)
	var u2 := u * u
	var h01 := u2 * (_HERMITE_3 - 2.0 * u)
	var h11 := u2 * (u - 1.0)
	return (1.0 - h01) * _e[j] + h01 * _e[j + 1] + _dx * ((h11 - u2 + u) * _g[j] + h11 * _g[j + 1])


## Grade (rise/run) at `s`. Tick-safe.
func grade_at(s: float) -> float:
	var f := s * _inv_dx
	var j := int(floor(f)) - _base_i
	if j > _n - 2:
		j = _n - 2
	elif j < 0:
		j = 0
	var u := f - float(j + _base_i)
	return _g[j] + u * (_g[j + 1] - _g[j])


# ---------------------------------------------------------------- Lanes

## Tick-safe: a binary search over the (few) scheduled changes.
func lane_count(s: float) -> int:
	var i := _lane_change_s.bsearch(s, false)
	return _lanes_default if i == 0 else _lane_change_count[i - 1]


## Right edge of the driving lanes, following the smoothstep taper of the lane change
## in force (the road mesh draws the same edge). Tick-safe.
func lanes_right_edge_d(s: float) -> float:
	var i := _lane_change_s.bsearch(s, false)
	var n := float(_lanes_default)
	if i > 0:
		var j := i - 1
		n = float(_lane_change_count[j])
		var s0 := _lane_change_s[j]
		var taper := _lane_change_taper[j]
		if taper > 0.0 and s < s0 + taper:
			var n0 := float(_lanes_default if j == 0 else _lane_change_count[j - 1])
			n = lerpf(n0, n, smoothstep(s0, s0 + taper, s))
	return lanes_left_edge_d(s) + n * lane_width(s)


## Schedules a lane-count change: from `s_start` on the player carriageway has
## `count` lanes (the opposite side mirrors it), the edge tapering over `taper_m`
## (default lane_taper_length_m). Hook for the director / set pieces (biomes and road
## tunnels schedule their own, BiomeRoadRules). Changes may come in any order (they are
## kept sorted) but must lie ahead of any s already sampled, and come in the same order
## for the same seed (determinism is the caller's). A change at an s that already has
## one replaces it. Director rate. Returns false (and ignores it) before the retained road.
func schedule_lane_count(s_start: float, count: int, taper_m: float = -1.0) -> bool:
	if s_start < _forgotten_s:
		push_error("ProceduralRoadPath.schedule_lane_count: s %.1f is behind the retained road" % s_start)
		return false
	var c := clampi(count, _lanes_min, _lanes_max)
	var taper := _lane_taper if taper_m < 0.0 else taper_m
	var f := RoadFeature.make(RoadFeature.Kind.LANE_COUNT_CHANGE, s_start, s_start + taper, float(c))
	var i := _lane_change_s.bsearch(s_start, true)
	if i < _lane_change_s.size() and _lane_change_s[i] == s_start:
		_lane_change_count[i] = c
		_lane_change_taper[i] = taper
		_lane_features[i] = f
		return true
	_lane_change_s.insert(i, s_start)
	_lane_change_count.insert(i, c)
	_lane_change_taper.insert(i, taper)
	_lane_features.insert(i, f)
	return true


# ---------------------------------------------------------------- Forks: cross-section (tick rate)

func lane_width(s: float) -> float:
	return lane_width_m * _vanish(s)


func lanes_left_edge_d(s: float) -> float:
	return (median_half_width_m + inner_shoulder_m) * _vanish(s)


## The right branch's gore side opens with the gap (inner shoulder, then its rail).
func median_barrier_d(s: float) -> float:
	var k := _vanish(s)
	var f := _branch_fork(s)
	if f != null and f.side == ForkPlan.RIGHT:
		var g := f.gore_open(_fork_deviation(f, s))
		if g < 1.0:
			return (median_half_width_m + (inner_shoulder_m + f.cushion_half_m) * (1.0 - g)) * k
	return median_half_width_m * k


## The left branch's gore side (its right) opens with the gap.
func shoulder_outer_d(s: float) -> float:
	var sh := shoulder_m
	var f := _branch_fork(s)
	if f != null and f.side == ForkPlan.LEFT:
		var g := f.gore_open(_fork_deviation(f, s))
		sh = shoulder_m * g - f.cushion_half_m * (1.0 - g)
	return lanes_right_edge_d(s) + sh * _vanish(s)


func guardrail_d(s: float) -> float:
	var off := guardrail_offset_m
	var f := _branch_fork(s)
	if f != null and f.side == ForkPlan.LEFT:
		off *= f.gore_open(_fork_deviation(f, s))
	return shoulder_outer_d(s) + off * _vanish(s)


func opposite_lane_center_d(lane: int, s: float) -> float:
	var d := -lane_center_d(lane, s)
	var f := _span_fork(s)
	if f == null:
		return d
	if f.side == ForkPlan.RIGHT and s < f.split_s:
		d -= f.shift_m
	d -= f.opposite_offset(s)
	if f.opposite_width(s) < 1.0:
		d -= f.hide_m
	return d


func opposite_offset_d(s: float) -> float:
	var f := _span_fork(s)
	return f.opposite_offset(s) if f != null else 0.0


func opposite_width_frac(s: float) -> float:
	var f := _span_fork(s)
	return f.opposite_width(s) if f != null else 1.0


func median_is_rail(s: float) -> bool:
	var f := _branch_or_rejoin_fork(s)
	return f != null and f.rail_on_left(s)


func rail_height_frac(s: float) -> float:
	return _vanish(s)


## The fork whose span (veer before the split to the rejoin after it) contains s.
func fork_span_at(s: float) -> RoadFork:
	return _span_fork(s)


## The fork this path is on the branch of at s (split to the gore's end), or null.
func fork_branch_at(s: float) -> RoadFork:
	return _branch_fork(s)


## The gore-side deviation of this path's branch at s (0 outside a branch).
func fork_deviation_at(s: float) -> float:
	var f := _branch_fork(s)
	return _fork_deviation(f, s) if f != null else 0.0


## Ground limits (director rate: reads the sibling branch). The left branch's ground
## reaches the right branch's rail; the right branch has none on its left (the left
## branch's covers the gore); both open back to full width once the other has vanished.
func ground_right_limit_d(s: float) -> float:
	var f := _branch_fork(s)
	if f == null or f.side != ForkPlan.LEFT:
		return INF
	var r := f.gore_ground_release(s)
	if r >= 1.0:
		return INF
	var u := _sibling_rail_d(f, s)
	if is_inf(u):
		return INF
	return u + r * _tuning.ground_ribbon_width_m


func ground_left_limit_d(s: float) -> float:
	var f := _branch_fork(s)
	if f == null or f.side != ForkPlan.RIGHT:
		return -INF
	var r := f.gore_ground_release(s)
	if r >= 1.0:
		return -INF
	return median_barrier_d(s) - r * _tuning.ground_ribbon_width_m


## The fork's resolution: the main path stops holding at it.
func resolve_fork(index: int) -> void:
	for f in forks:
		if f.index == index:
			f.resolved = true


## After the choice, this (not taken) branch narrows to nothing from `s` on.
func vanish_from(index: int, s: float) -> void:
	for f in forks:
		if f.index == index:
			f.vanish_s = s


## Adopts `other`'s whole state (the player picked the other branch; both paths come from
## the same seed and agree up to the split) and gives it this one's. Director rate.
func swap_state(other: ProceduralRoadPath) -> void:
	var p := _plan
	_plan = other._plan
	other._plan = p
	var pr := _profile
	_profile = other._profile
	other._profile = pr
	var br := biome_rules
	biome_rules = other.biome_rules
	other.biome_rules = br
	var fl := forks
	forks = other.forks
	other.forks = fl
	var i := _base_i
	_base_i = other._base_i
	other._base_i = i
	i = _n
	_n = other._n
	other._n = i
	var a := _h
	_h = other._h
	other._h = a
	a = _k
	_k = other._k
	other._k = a
	a = _e
	_e = other._e
	other._e = a
	a = _g
	_g = other._g
	other._g = a
	a = _x
	_x = other._x
	other._x = a
	a = _z
	_z = other._z
	other._z = a
	i = _lanes_default
	_lanes_default = other._lanes_default
	other._lanes_default = i
	a = _lane_change_s
	_lane_change_s = other._lane_change_s
	other._lane_change_s = a
	var ci := _lane_change_count
	_lane_change_count = other._lane_change_count
	other._lane_change_count = ci
	a = _lane_change_taper
	_lane_change_taper = other._lane_change_taper
	other._lane_change_taper = a
	var lf := _lane_features
	_lane_features = other._lane_features
	other._lane_features = lf
	lf = _tunnel_features
	_tunnel_features = other._tunnel_features
	other._tunnel_features = lf
	lf = _lane_signs
	_lane_signs = other._lane_signs
	other._lane_signs = lf
	i = _latched_leg
	_latched_leg = other._latched_leg
	other._latched_leg = i
	var fs := _forgotten_s
	_forgotten_s = other._forgotten_s
	other._forgotten_s = fs
	fs = _origin_x
	_origin_x = other._origin_x
	other._origin_x = fs
	fs = _origin_z
	_origin_z = other._origin_z
	other._origin_z = fs


func _vanish(s: float) -> float:
	for f in forks:
		if s > f.vanish_s:
			return f.vanish_factor(s)
	return 1.0


func _span_fork(s: float) -> RoadFork:
	for f in forks:
		if s >= f.span_start_s() and s < f.span_end_s():
			return f
	return null


func _branch_fork(s: float) -> RoadFork:
	for f in forks:
		if f.in_branch(s):
			return f
	return null


func _branch_or_rejoin_fork(s: float) -> RoadFork:
	for f in forks:
		if s >= f.split_s and s < f.span_end_s():
			return f
	return null


## The branch's deviation at s from the table (linear between samples; tick-safe).
func _fork_deviation(f: RoadFork, s: float) -> float:
	if not f.pose_known or _n < 2:
		return 0.0
	var fi := s * _inv_dx
	var j := int(floor(fi)) - _base_i
	if j > _n - 2:
		j = _n - 2
	elif j < 0:
		j = 0
	var u := fi - float(j + _base_i)
	return f.deviation(_x[j] + u * (_x[j + 1] - _x[j]), _z[j] + u * (_z[j + 1] - _z[j]))


## Where the sibling (right) branch's left rail crosses this path's cross-section at s
## (d on this path), or INF without a sibling.
func _sibling_rail_d(f: RoadFork, s: float) -> float:
	var sib := f.sibling
	if sib == null or s > sib._table_end():
		return INF
	sample_into(s, _fork_smp)
	sib.sample_into(s, _fork_sib)
	var rail := sib.median_barrier_d(s)
	var qx := _fork_sib.pos_x + float(_fork_sib.right.x) * rail - _fork_smp.pos_x
	var qz := _fork_sib.pos_z + float(_fork_sib.right.z) * rail - _fork_smp.pos_z
	var rx := float(_fork_smp.right.x)
	var rz := float(_fork_smp.right.z)
	var tx := float(_fork_sib.tangent.x)
	var tz := float(_fork_sib.tangent.z)
	var den := rx * tz - rz * tx
	if absf(den) <= 0.0:
		return qx * rx + qz * rz
	return (qx * tz - qz * tx) / den


# ---------------------------------------------------------------- Features

## Every feature overlapping [s0, s1), sorted by s_start (ties by kind). Only the
## generated range is reported: the query stops at length_generated(), so call
## ensure_generated_to(s1) first. Director rate.
func features_in(s0: float, s1: float, out: Array[RoadFeature]) -> void:
	var hi := minf(s1, length_generated())
	# A hazard sign comes into existence with its bend / crest, one sign distance later.
	_plan.generate_to(hi + _sign_lookahead)
	_profile.generate_to(hi + _sign_lookahead)
	var found: Array[RoadFeature] = []
	for list: Array[RoadFeature] in [_plan.bends, _plan.blind_bends, _plan.signs, _profile.crests,
			_profile.signs, _lane_features, _tunnel_features, _lane_signs]:
		for f in list:
			if f.s_start >= hi:
				break
			if f.overlaps(s0, hi):
				found.append(f)
	_checkpoints_in(s0, hi, found)
	for f in forks:
		if f.span_start_s() < hi and f.span_end_s() >= s0:
			found.append(RoadFeature.make(RoadFeature.Kind.FORK, f.span_start_s(), f.span_end_s(), f.split_s,
				f.left_id, f.right_id))
	found.sort_custom(_feature_before)
	out.append_array(found)


static func _feature_before(a: RoadFeature, b: RoadFeature) -> bool:
	if a.s_start != b.s_start:
		return a.s_start < b.s_start
	return a.kind < b.kind


## CHECKPOINT at every leg end (value = leg index, 1-based) and SIGN (tag
## SIGN_CHECKPOINT, value = announced distance) at each warning distance before it.
func _checkpoints_in(s0: float, s1: float, found: Array[RoadFeature]) -> void:
	var max_w := 0.0
	for w in _checkpoint_warnings:
		max_w = maxf(max_w, w)
	var k_first := maxi(1, int(floor(s0 / _leg_length)))
	var k_last := int(floor((s1 + max_w) / _leg_length))
	for k in range(k_first, k_last + 1):
		var cp := float(k) * _leg_length
		var fork := _fork_at_checkpoint(k)
		for w in _checkpoint_warnings:
			var sign_s := cp - w
			if sign_s >= s0 and sign_s < s1 and sign_s >= 0.0:
				found.append(RoadFeature.make(RoadFeature.Kind.SIGN, sign_s, sign_s, w, SIGN_CHECKPOINT,
					SIGN_FORK_TAG2 if fork != null else &""))
		if cp >= s0 and cp < s1:
			found.append(RoadFeature.make(RoadFeature.Kind.CHECKPOINT, cp, cp, float(k),
				FORK_LANDMARK if fork != null else &""))


func _fork_at_checkpoint(k: int) -> RoadFork:
	for f in forks:
		if f.checkpoint == k:
			return f
	return null


# ---------------------------------------------------------------- Generation

func length_generated() -> float:
	var g := _table_end()
	if hold_at_forks:
		for f in forks:
			if not f.resolved:
				return minf(g, f.split_s + f.hold_margin_m)
	return g


## End of the generated table (ignores the fork hold).
func _table_end() -> float:
	return float(_base_i + _n - 1) * _dx


## End of the generated table, ignoring the fork hold (the run's fork manager).
func table_end() -> float:
	return _table_end()


## World x / z of s = 0 (a right branch path's translation; WP6.5).
func origin_offset_x() -> float:
	return _origin_x


func origin_offset_z() -> float:
	return _origin_z


## Extends the table in whole blocks until it covers `s`. Director rate.
func ensure_generated_to(s: float) -> void:
	while _table_end() < s:
		_build_block()


## Drops table blocks (and elements / features) entirely before `s`. The block
## containing `s` is kept, so sampling at >= s stays valid. Memory stays bounded
## by (ensure_generated_to distance - forget distance). Director rate.
func forget_before(s: float) -> void:
	var last_block := _base_i + _n - 1 - _block_n   # keep at least one block
	var new_base := mini(int(floor(s * _inv_dx / float(_block_n))) * _block_n, last_block)
	if new_base <= _base_i:
		return
	var drop := new_base - _base_i
	_h = _h.slice(drop)
	_k = _k.slice(drop)
	_e = _e.slice(drop)
	_g = _g.slice(drop)
	_x = _x.slice(drop)
	_z = _z.slice(drop)
	_base_i = new_base
	_n -= drop
	_forgotten_s = float(new_base) * _dx
	_plan.forget_before(_forgotten_s)
	_profile.forget_before(_forgotten_s)
	RoadPlanGen.drop_features_before(_tunnel_features, _forgotten_s)
	RoadPlanGen.drop_features_before(_lane_signs, _forgotten_s)
	# Keep the change in force at _forgotten_s (its taper may still run) and fold the
	# ones before it into the base count.
	var keep := _lane_change_s.bsearch(_forgotten_s, false) - 1
	if keep > 0:
		_lanes_default = _lane_change_count[keep - 1]
		_lane_change_s = _lane_change_s.slice(keep)
		_lane_change_count = _lane_change_count.slice(keep)
		_lane_change_taper = _lane_change_taper.slice(keep)
		_lane_features.assign(_lane_features.slice(keep))


## First s still sampleable after forget_before().
func first_retained_s() -> float:
	return float(_base_i) * _dx


## Diagnostics for memory tests and the dev HUD: table samples, elements and
## features currently held.
func retained_sample_count() -> int:
	return _n


func retained_element_count() -> int:
	return _plan.el_s0.size() + _profile.el_s0.size()


func retained_feature_count() -> int:
	return _plan.bends.size() + _plan.blind_bends.size() + _plan.signs.size() \
		+ _profile.crests.size() + _profile.signs.size() + _lane_features.size() \
		+ _tunnel_features.size() + _lane_signs.size()


## Crest sight distance (m) for a convex vertical curve with grade change `a` and
## length `length_m` (the rule BLIND_CREST uses; for tests and tools).
func crest_sight_distance(a: float, length_m: float) -> float:
	return _profile.crest_sight_distance(a, length_m)


func _build_block() -> void:
	var first := _base_i + _n   # global index of the first new sample
	var count := _block_n + 1 if _n == 0 else _block_n
	var last_s := float(first + count - 1) * _dx
	_latch_to(last_s + _leg_length)
	_plan.generate_to(last_s + _dx)
	_profile.generate_to(last_s + _dx)
	var size := _n + count
	_h.resize(size)
	_k.resize(size)
	_e.resize(size)
	_g.resize(size)
	_x.resize(size)
	_z.resize(size)
	for c in count:
		var j := _n + c
		var s := float(first + c) * _dx
		_plan.eval(s)
		_profile.eval(s)
		_h[j] = _plan.out_heading
		_k[j] = _plan.out_curvature
		_e[j] = _profile.out_elevation
		_g[j] = _profile.out_grade
		if j == 0:
			_x[j] = _origin_x
			_z[j] = _origin_z
		else:
			# Same rule as sample_into at u = 1: Hermite heading at the midpoint.
			var mid_h := (_h[j - 1] + _h[j]) * 0.5 + _dx * (_k[j - 1] - _k[j]) * 0.5 * 0.5 * 0.5
			_x[j] = _x[j - 1] + _dx * sin(mid_h)
			_z[j] = _z[j - 1] - _dx * cos(mid_h)
	_n = size
	for f in forks:
		if not f.pose_known and f.split_s <= last_s:
			var js := roundi(f.split_s * _inv_dx) - _base_i
			if js >= 0 and js < _n:
				f.pose_known = true
				f.split_x = _x[js]
				f.split_z = _z[js]
				f.right_x = cos(_h[js])
				f.right_z = sin(_h[js])


# ---------------------------------------------------------------- Biome legs (WP6.4a)

## Schedules the lanes and tunnels of every leg up to the one containing `s`, in leg
## order (director rate; only with a plan).
func _latch_to(s: float) -> void:
	if biome_rules == null:
		return
	var last := biome_rules.leg_at(s)
	while _latched_leg < last:
		_latched_leg += 1
		_latch_leg(_latched_leg)


## Leg k: its biome's lane count (after the checkpoint that starts it) and its tunnels.
func _latch_leg(k: int) -> void:
	var t := _tuning
	var s0 := float(k - 1) * _leg_length
	var lanes := biome_rules.lanes_for_leg(k)
	var fork := _fork_at_checkpoint(k - 1)
	if fork != null:
		_latch_fork_lanes(fork, biome_rules.lanes_for_leg(k - 1), lanes)
		_latch_tunnels(k, s0, lanes, fork.span_end_s())
		return
	if k > 1 and lanes != biome_rules.lanes_for_leg(k - 1):
		_schedule_internal(s0 + t.biome_lane_change_after_m, lanes, t.biome_lane_taper_m)
	_latch_tunnels(k, s0, lanes)


## The fork's lanes on this path's branch: the trunk's split at the split (left lanes
## left, the rest right, no taper), then back to the branch biome's count. The right
## branch's path counts only its lanes over the approach too (its reference line is the
## trunk's shifted by the left lanes).
func _latch_fork_lanes(f: RoadFork, trunk: int, lanes: int) -> void:
	f.lanes_trunk = trunk
	f.lanes_left = (trunk + 1) >> 1
	var mine := f.lanes_left if f.side == ForkPlan.LEFT else f.lanes_right()
	if f.side == ForkPlan.RIGHT:
		_schedule_exact(f.split_s - f.approach_m, mine, 0.0)
	_schedule_exact(f.split_s, mine, 0.0)
	_schedule_exact(f.split_s + f.widen_after_m, lanes, f.widen_taper_m)


## Road tunnels of leg k (seeded per leg: the same whatever else was generated). The
## tunnels share one narrowed section: tunnel_lanes from the drop's taper (ending
## tunnel_lane_lead_m before the first portal) to tunnel_lane_trail_m after the last exit.
func _latch_tunnels(k: int, s0: float, lanes: int, lo_min: float = -INF) -> void:
	var t := _tuning
	var mean := biome_rules.tunnel_scale_for_leg(k) * t.tunnels_per_leg
	if mean <= 0.0 or t.tunnel_max_per_leg_count <= 0:
		return
	var rng := Rng.new(TraceHash.mix_int(_tunnel_seed, k))
	var n := int(floor(mean))
	if rng.chance(mean - float(n)):
		n += 1
	n = mini(n, t.tunnel_max_per_leg_count)
	var narrow := lanes > t.tunnel_lanes
	var taper := _lane_taper if narrow else 0.0
	var lead := t.tunnel_lane_lead_m + taper
	var trail := t.tunnel_lane_trail_m + taper
	var max_warning := 0.0
	for w in _checkpoint_warnings:
		max_warning = maxf(max_warning, w)
	var lo := maxf(s0 + t.tunnel_leg_margin_after_m, lo_min)
	var hi := s0 + _leg_length - max_warning - t.tunnel_leg_margin_before_m
	var lengths := PackedFloat64Array()
	var gaps := PackedFloat64Array()
	for i in n:
		lengths.append(rng.float_range(t.tunnel_length_min_m, t.tunnel_length_max_m))
		gaps.append(rng.float_range(t.tunnel_gap_min_m, t.tunnel_gap_max_m))
	var slack_u := rng.unit()
	# Drop tunnels from the end until the section fits the leg's window.
	while n > 0:
		var need := lead + trail
		for i in n:
			need += lengths[i] + (gaps[i] if i > 0 else 0.0)
		if need <= hi - lo:
			var start := lo + slack_u * (hi - lo - need)
			var portal := start + lead
			if narrow:
				_schedule_internal(start, t.tunnel_lanes, taper)
				if start - t.lane_ends_sign_distance_m >= 0.0:
					_lane_signs.append(RoadFeature.make(RoadFeature.Kind.SIGN, start - t.lane_ends_sign_distance_m,
						start - t.lane_ends_sign_distance_m, t.lane_ends_sign_distance_m, SIGN_LANE_ENDS))
			var s_exit := portal
			for i in n:
				if i > 0:
					portal = s_exit + gaps[i]
				s_exit = portal + lengths[i]
				_tunnel_features.append(RoadFeature.make(RoadFeature.Kind.TUNNEL, portal, s_exit, lengths[i]))
			if narrow:
				_schedule_internal(s_exit + t.tunnel_lane_trail_m, lanes, taper)
			return
		n -= 1


func _schedule_internal(s_start: float, count: int, taper_m: float) -> void:
	schedule_lane_count(s_start, count, taper_m)


## A fork's lane step: not clamped to lanes_min (a branch may carry one lane).
func _schedule_exact(s_start: float, count: int, taper_m: float) -> void:
	var f := RoadFeature.make(RoadFeature.Kind.LANE_COUNT_CHANGE, s_start, s_start + taper_m, float(count))
	var i := _lane_change_s.bsearch(s_start, true)
	if i < _lane_change_s.size() and _lane_change_s[i] == s_start:
		_lane_change_count[i] = count
		_lane_change_taper[i] = taper_m
		_lane_features[i] = f
		return
	_lane_change_s.insert(i, s_start)
	_lane_change_count.insert(i, count)
	_lane_change_taper.insert(i, taper_m)
	_lane_features.insert(i, f)
