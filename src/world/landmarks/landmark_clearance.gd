class_name LandmarkClearance
extends RefCounted
## Where the checkpoint landmarks and their warning signs stand, as road-space boxes the
## roadside keeps clear (WP5.5). Spec: World → Road ("Roadside rhythm: light poles every
## 50 m, reflector posts every 25 m, ... sign gantries, billboards, fences"), World →
## Checkpoint landmarks, Core loop → Legs and checkpoints (a landmark at every
## checkpoint, warning signs at 1 km and 500 m). docs/LANDMARKS.md → Roadside clearance.
##
##   var c := LandmarkClearance.new()
##   c.setup(road, landmark_tuning, biome_director)   # director may be null
##   c.prepare(s_lo, s_hi)                            # when a window moves
##   if c.blocks_upright(aabb, s, d, yaw): skip        # per placement, allocation-free
##
## A pure function of the road's features (CHECKPOINT and checkpoint SIGN), each
## checkpoint's style (LandmarkClearance.resolve_style: the feature tag the biome
## director fills, else the default style) and the LandmarkTuning spans
## (LandmarkBuilds.clearance_zones), so it is deterministic and known before the
## Landmarks node places anything. Zones are (s range, signed d range, floor height):
## an instance is blocked when its footprint (s and d extent) overlaps a zone and it
## reaches above the zone's floor. Along s every zone grows by clearance_margin_m.
##
## Zones are cached for [cov_lo, cov_hi): `prepare` refills (one feature query, the only
## allocation) when a range is not covered or the biome plan changed; the queries only
## read the packed arrays.
##
## Panel signs: checkpoint warnings and (WP6.4c) the lane-ends signs before a tunnel's
## lane drop, both Landmarks.is_panel_sign.
##
## Road tunnels (WP6.4a): every TUNNEL feature adds the zones of the road-built tunnel
## (LandmarkBuilds.road_tunnel_clearance_zones) as ZONE_TUNNEL. Queries take a mask of
## zone kinds (default all): canyon cliffs ask only for ZONE_LANDMARK, so their rock
## runs on through a tunnel's hill.

## Style when neither the feature nor a biome gives one (Landmarks.default_style).
const DEFAULT_STYLE := BiomeDef.LANDMARK_SIGN_GANTRY
## Zone kinds (bit mask for the queries).
const ZONE_LANDMARK := 1
const ZONE_TUNNEL := 2
const ZONE_ALL := ZONE_LANDMARK | ZONE_TUNNEL
## Yaws this close to 0 or PI use the mesh's box; others its footprint circle.
const YAW_EPS := 1e-6   # lint: allow-number angle tolerance, not tuning

var road: RoadPath
var tuning: LandmarkTuning
var biome_director: BiomeDirector
## Non-empty: every checkpoint has this style (previews).
var style_override: StringName = &""
var default_style: StringName = DEFAULT_STYLE
## Refills so far (tests: prepare is cached).
var refills: int = 0

var _s0 := PackedFloat64Array()
var _s1 := PackedFloat64Array()
var _d0 := PackedFloat64Array()
var _d1 := PackedFloat64Array()
var _floor := PackedFloat64Array()
var _kind := PackedInt32Array()
var _count: int = 0
var _cov_lo: float = INF
var _cov_hi: float = -INF
var _plan_version: int = -1
## How far a landmark's zones reach before and after its checkpoint (all styles).
var _reach_before: float = 0.0
var _reach_after: float = 0.0
var _found: Array[RoadFeature] = []
var _scratch := PackedFloat64Array()


func setup(road_path: RoadPath, landmark_tuning: LandmarkTuning, director: BiomeDirector = null,
		override_style: StringName = &"") -> void:
	road = road_path
	tuning = landmark_tuning
	biome_director = director
	style_override = override_style
	invalidate()
	# The reach of every style (lateral bounds vary with the section, s extents do not).
	_reach_before = 0.0
	_reach_after = 0.0
	var x := LandmarkSection.at(road, 0.0)
	for kind in LandmarkBuilds.kinds():
		_scratch.clear()
		LandmarkBuilds.clearance_zones(kind, x, tuning, _scratch)
		for i in range(0, _scratch.size(), LandmarkBuilds.ZONE_FLOATS):
			_reach_before = maxf(_reach_before, -_scratch[i])
			_reach_after = maxf(_reach_after, _scratch[i + 1])
	_scratch.clear()
	LandmarkBuilds.sign_clearance_zones(0.0, tuning, _scratch)
	for i in range(0, _scratch.size(), LandmarkBuilds.ZONE_FLOATS):
		_reach_after = maxf(_reach_after, _scratch[i + 1])
	# Road tunnels are reported as features spanning the bore; their hips reach past it.
	_reach_before = maxf(_reach_before, LandmarkBuilds.road_tunnel_reach_m(tuning))
	_reach_after = maxf(_reach_after, LandmarkBuilds.road_tunnel_reach_m(tuning))
	_reach_before += tuning.clearance_margin_m
	_reach_after += tuning.clearance_margin_m


## Forget the cached zones (the next query refills).
func invalidate() -> void:
	_count = 0
	_cov_lo = INF
	_cov_hi = -INF


## The style of a checkpoint feature: the override, else its tag (the biome director
## fills it), else the director's style for that leg, else `default`.
static func resolve_style(f: RoadFeature, director: BiomeDirector, forced: StringName,
		fallback: StringName) -> StringName:
	if forced != &"":
		return forced
	if f.tag != &"" and LandmarkBuilds.kinds().has(f.tag):
		return f.tag
	if director != null:
		var style := director.checkpoint_style(int(f.value), f.s_start)
		if LandmarkBuilds.kinds().has(style):
			return style
	return fallback


func style_for(f: RoadFeature) -> StringName:
	return resolve_style(f, biome_director, style_override, default_style)


## Makes sure the zones of every landmark touching [s_lo, s_hi] are cached. Call when a
## window moves (director rate); a no-op while the range stays covered.
func prepare(s_lo: float, s_hi: float) -> void:
	var version := biome_director.plan_version if biome_director != null else 0
	if s_lo >= _cov_lo and s_hi <= _cov_hi and version == _plan_version:
		return
	_refill(s_lo, s_hi, version)


## True when a footprint (s_lo..s_hi, d_lo..d_hi) reaching `top_m` high overlaps a zone
## of a kind in `mask`. Allocation-free unless the range is not prepared (then it
## refills first).
func blocks(s_lo: float, s_hi: float, d_lo: float, d_hi: float, top_m: float, mask: int = ZONE_ALL) -> bool:
	if s_lo < _cov_lo or s_hi > _cov_hi:
		prepare(s_lo, s_hi)
	for i in _count:
		if s_hi >= _s0[i] and s_lo <= _s1[i] and d_hi >= _d0[i] and d_lo <= _d1[i] and top_m > _floor[i] \
				and (_kind[i] & mask) != 0:
			return true
	return false


## An upright mesh instance (bounds `aabb`) at (s, d), turned by `yaw` (right-positive,
## relative to the road) and scaled by sx/sy/sz: the box footprint at yaw 0 or PI, else
## its footprint circle. This is how Roadside layers and StreetLampPools ask, so both
## drop exactly the same poles.
func blocks_upright(aabb: AABB, s: float, d: float, yaw: float, sx: float = 1.0, sy: float = 1.0,
		sz: float = 1.0, mask: int = ZONE_ALL) -> bool:
	var top := aabb.end.y * sy
	var w := wrapf(yaw, -PI, PI)
	if absf(w) < YAW_EPS:
		# Local +x is +d, local -z is +s.
		return blocks(s - aabb.end.z * sz, s - aabb.position.z * sz, d + aabb.position.x * sx,
			d + aabb.end.x * sx, top, mask)
	if absf(absf(w) - PI) < YAW_EPS:
		return blocks(s + aabb.position.z * sz, s + aabb.end.z * sz, d - aabb.end.x * sx,
			d - aabb.position.x * sx, top, mask)
	var rx := maxf(absf(aabb.position.x), absf(aabb.end.x))
	var rz := maxf(absf(aabb.position.z), absf(aabb.end.z))
	var r := sqrt(rx * rx + rz * rz) * maxf(sx, sz)
	return blocks(s - r, s + r, d - r, d + r, top, mask)


## A mesh stretched along the road from s0 to s1 at d (fence segments): its thickness
## across, its height. On the left side (d < 0) the mesh is turned around, so its +x
## (away from the road) reaches toward -d.
func blocks_segment(aabb: AABB, s0: float, s1: float, d: float, mask: int = ZONE_ALL) -> bool:
	var d_lo := d + aabb.position.x if d >= 0.0 else d - aabb.end.x
	var d_hi := d + aabb.end.x if d >= 0.0 else d - aabb.position.x
	return blocks(minf(s0, s1), maxf(s0, s1), d_lo, d_hi, aabb.end.y, mask)


## Every cached zone overlapping [s0, s1], ZONE_FLOATS each (s from, s to, d from, d to,
## floor), margins included. Director rate (appends to `out`).
func zones_in(s0: float, s1: float, out: PackedFloat64Array) -> void:
	prepare(s0, s1)
	for i in _count:
		if _s1[i] >= s0 and _s0[i] <= s1:
			out.append(_s0[i])
			out.append(_s1[i])
			out.append(_d0[i])
			out.append(_d1[i])
			out.append(_floor[i])


func zone_count() -> int:
	return _count


# ---------------------------------------------------------------- Internals

func _refill(s_lo: float, s_hi: float, version: int) -> void:
	refills += 1
	_plan_version = version
	_cov_lo = s_lo - tuning.clearance_cache_pad_m
	_cov_hi = s_hi + tuning.clearance_cache_pad_m
	_count = 0
	if road == null:
		return
	var q_lo := maxf(0.0, _cov_lo - _reach_after)
	var q_hi := _cov_hi + _reach_before
	# Features are reported only where the road is generated (director rate, as
	# Landmarks and RoadBuilder do; the table does not depend on how far it goes).
	road.ensure_generated_to(q_hi)
	_found.clear()
	road.features_in(q_lo, q_hi, _found)
	if biome_director != null:
		biome_director.tag_checkpoints(_found)
	for f in _found:
		_scratch.clear()
		var anchor := f.s_start
		var kind := ZONE_LANDMARK
		if f.kind == RoadFeature.Kind.CHECKPOINT:
			LandmarkBuilds.clearance_zones(style_for(f), LandmarkSection.at(road, anchor), tuning, _scratch)
		elif Landmarks.is_panel_sign(f):
			LandmarkBuilds.sign_clearance_zones(road.guardrail_d(anchor) + tuning.sign_setback_m, tuning, _scratch)
		elif f.kind == RoadFeature.Kind.TUNNEL:
			LandmarkBuilds.road_tunnel_clearance_zones(LandmarkSection.at(road, anchor), f.s_end - f.s_start, tuning,
				_scratch)
			kind = ZONE_TUNNEL
		else:
			continue
		for i in range(0, _scratch.size(), LandmarkBuilds.ZONE_FLOATS):
			_add(anchor + _scratch[i] - tuning.clearance_margin_m, anchor + _scratch[i + 1] + tuning.clearance_margin_m,
				_scratch[i + 2], _scratch[i + 3], _scratch[i + 4], kind)
	_found.clear()


func _add(s0: float, s1: float, d0: float, d1: float, floor_m: float, kind: int) -> void:
	if _count >= _s0.size():
		var n := maxi(_count + 1, _s0.size() * 2)
		_s0.resize(n)
		_s1.resize(n)
		_d0.resize(n)
		_d1.resize(n)
		_floor.resize(n)
		_kind.resize(n)
	_s0[_count] = s0
	_s1[_count] = s1
	_d0[_count] = d0
	_d1[_count] = d1
	_floor[_count] = floor_m
	_kind[_count] = kind
	_count += 1
