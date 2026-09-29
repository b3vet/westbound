class_name LoopRoadPath
extends RoadPath
# lint: sim
## The multiplayer loop as a RoadPath (N3.1): a fixed, closed, one-way highway loop of
## 25 km. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → The loop map ("s wraps modulo L");
## docs/MULTIPLAYER_PLAN.md MP-D3; World → Road; docs/CONTRACTS.md §2-§3.
## docs/LOOP_MAP.md.
##
##   var road := LoopRoadPath.load_default()          # data/maps/loop_v1.tres
##   road.sample_into(s, out)                         # any s: taken modulo L
##
## Built once by LoopGen from a LoopMapDef (seed + hand edits); every query answers for
## any s, taken modulo L (length()). The table is ProceduralRoadPath's (Hermite heading
## and elevation, positions along the mid-cell heading), closed at the seam, so sampling
## is O(1) and allocation-free like the procedural road's. The world repeats exactly
## every lap (positions, elevation, lanes, features); the heading is continuous in s:
## heading(s + L) = heading(s) + total_turn (-TAU), so heading differences taken along
## the road never jump at the seam.
##
## Unwrapped s: a client may keep counting s past L (world systems build chunks at
## s + k L, which land on the same ground); features_in reports every lap's features at
## their unwrapped s (value of CHECKPOINT = lap * sector_count + sector + 1).
## wrap_s / lap_of / signed_delta give the wrapped forms (the server's u32 mm s).
##
## Sky and glare: the loop turns through every heading, so the single-player sun rule
## (heading 15-30 deg off the sun) cannot hold everywhere. The loop keeps the part of it
## that matters (LoopValidator): no straight heads within sun_offset_min_deg of due west
## (the loop crosses west once, inside a canyon bend), and the coast's straights, the
## bridge and the sunset view head 15-30 deg left of the sun with the sea on the sun's
## side, as the coast biome requires. The room clock drives the sky (the sun stays at
## world heading 0).
##
## Not part of the RoadFeature contract (the kinds are frozen): ramps, road works zones,
## spawn points and elevated zones live in `layout` (and the road-space file).

## Hermite basis coefficient (h01 = u^2 (3 - 2u)), as ProceduralRoadPath's.
const _HERMITE_3 := 3.0   # lint: allow-number cubic Hermite basis coefficient

var layout: LoopLayout
var def: LoopMapDef

var _L: float
var _inv_L: float
var _dx: float
var _inv_dx: float
var _n: int
var _turn: float
var _h: PackedFloat64Array
var _k: PackedFloat64Array
var _e: PackedFloat64Array
var _g: PackedFloat64Array
var _x: PackedFloat64Array
var _z: PackedFloat64Array
var _lanes_base: int
var _lane_s: PackedFloat64Array
var _lane_n: PackedInt32Array
var _lane_taper: PackedFloat64Array
var _sectors: int


## `tuning` defaults to Tuning.load_default().
func _init(map_def: LoopMapDef, tuning: Tuning = null) -> void:
	var t := tuning if tuning != null else Tuning.load_default()
	super(t.road)
	def = map_def
	layout = LoopGen.generate(map_def, t)
	var o := layout
	_L = o.length_m
	_inv_L = 1.0 / _L
	_dx = o.dx
	_inv_dx = 1.0 / _dx
	_n = o.n
	_turn = o.total_turn
	_h = o.h
	_k = o.k
	_e = o.e
	_g = o.g
	_x = o.x
	_z = o.z
	_lanes_base = o.lanes_base
	_lane_s = o.lane_s
	_lane_n = o.lane_n
	_lane_taper = o.lane_taper
	_sectors = maxi(o.sector_s.size(), 1)


## The committed loop (data/maps/loop_v1.tres) with the default tuning.
static func load_default(tuning: Tuning = null) -> LoopRoadPath:
	return LoopRoadPath.new(LoopMapDef.load_default(), tuning)


# ---------------------------------------------------------------- Wrap math (tick-safe)

## Loop length L (m).
func length() -> float:
	return _L


## s modulo L, in [0, L).
func wrap_s(s: float) -> float:
	var r := s - floorf(s * _inv_L) * _L
	if r >= _L:
		r -= _L
	elif r < 0.0:
		r += _L
	return r


## Lap index of an unwrapped s (s in [q L, (q + 1) L) is lap q).
func lap_of(s: float) -> int:
	return int(floor((s - wrap_s(s)) * _inv_L + 0.5))


## Wrapped signed distance from a to b along the loop, in [-L/2, L/2): how far b is
## ahead of a (negative: behind). The rule for every distance comparison on the loop.
func signed_delta(a: float, b: float) -> float:
	return wrap_s(b - a + _L * 0.5) - _L * 0.5


# ---------------------------------------------------------------- Reference line (tick rate)

func sample_into(s: float, out: RoadSample) -> void:
	var lap := floorf(s * _inv_L)
	var r := s - lap * _L
	if r >= _L:
		r -= _L
		lap += 1.0
	elif r < 0.0:
		r += _L
		lap -= 1.0
	var f := r * _inv_dx
	var j := int(f)
	if j > _n - 1:
		j = _n - 1
	var u := f - float(j)
	var u2 := u * u
	var h01 := u2 * (_HERMITE_3 - 2.0 * u)
	var h11 := u2 * (u - 1.0)
	var h10 := h11 - u2 + u
	var h00 := 1.0 - h01
	var h0 := _h[j]
	var h1 := _h[j + 1]
	var k0 := _k[j]
	var k1 := _k[j + 1]
	var g0 := _g[j]
	var g1 := _g[j + 1]
	var heading := h00 * h0 + h01 * h1 + _dx * (h10 * k0 + h11 * k1)
	var elevation := h00 * _e[j] + h01 * _e[j + 1] + _dx * (h10 * g0 + h11 * g1)
	var m := u * 0.5
	var m2 := m * m
	var m01 := m2 * (_HERMITE_3 - 2.0 * m)
	var m11 := m2 * (m - 1.0)
	var mid_h := (1.0 - m01) * h0 + m01 * h1 + _dx * ((m11 - m2 + m) * k0 + m11 * k1)
	var ds := u * _dx
	out.s = s
	out.curvature = k0 + u * (k1 - k0)
	out.set_frame(heading + lap * _turn, g0 + u * (g1 - g0))
	out.set_position(_x[j] + ds * sin(mid_h), elevation, _z[j] - ds * cos(mid_h))


func curvature_at(s: float) -> float:
	var f := wrap_s(s) * _inv_dx
	var j := mini(int(f), _n - 1)
	var u := f - float(j)
	return _k[j] + u * (_k[j + 1] - _k[j])


## World heading at s (rad, right-positive, continuous across laps). Tick-safe.
func heading_at(s: float) -> float:
	var lap := floorf(s * _inv_L)
	var r := s - lap * _L
	if r >= _L:
		r -= _L
		lap += 1.0
	elif r < 0.0:
		r += _L
		lap -= 1.0
	var f := r * _inv_dx
	var j := mini(int(f), _n - 1)
	var u := f - float(j)
	var u2 := u * u
	var h01 := u2 * (_HERMITE_3 - 2.0 * u)
	var h11 := u2 * (u - 1.0)
	return (1.0 - h01) * _h[j] + h01 * _h[j + 1] + _dx * ((h11 - u2 + u) * _k[j] + h11 * _k[j + 1]) + lap * _turn


## Road elevation at s (m). Tick-safe.
func elevation_at(s: float) -> float:
	var f := wrap_s(s) * _inv_dx
	var j := mini(int(f), _n - 1)
	var u := f - float(j)
	var u2 := u * u
	var h01 := u2 * (_HERMITE_3 - 2.0 * u)
	var h11 := u2 * (u - 1.0)
	return (1.0 - h01) * _e[j] + h01 * _e[j + 1] + _dx * ((h11 - u2 + u) * _g[j] + h11 * _g[j + 1])


## Grade (rise/run) at s. Tick-safe.
func grade_at(s: float) -> float:
	var f := wrap_s(s) * _inv_dx
	var j := mini(int(f), _n - 1)
	var u := f - float(j)
	return _g[j] + u * (_g[j + 1] - _g[j])


# ---------------------------------------------------------------- Lanes (tick rate)

func lane_count(s: float) -> int:
	var i := _lane_s.bsearch(wrap_s(s), false)
	return _lanes_base if i == 0 else _lane_n[i - 1]


## Right edge of the driving lanes, following the smoothstep taper of the lane change in
## force (as ProceduralRoadPath's; the mesh draws the same edge).
func lanes_right_edge_d(s: float) -> float:
	var r := wrap_s(s)
	var i := _lane_s.bsearch(r, false)
	var nl := float(_lanes_base)
	if i > 0:
		var j := i - 1
		nl = float(_lane_n[j])
		var s0 := _lane_s[j]
		var taper := _lane_taper[j]
		if taper > 0.0 and r < s0 + taper:
			var n0 := float(_lanes_base if j == 0 else _lane_n[j - 1])
			nl = lerpf(n0, nl, smoothstep(s0, s0 + taper, r))
	return lanes_left_edge_d(s) + nl * lane_width(s)


# ---------------------------------------------------------------- Sections

func section_count() -> int:
	return layout.section_ids.size()


## Section index at s (0 desert, 1 canyon, 2 coast, 3 city, 4 farmland in loop_v1).
func section_at(s: float) -> int:
	return layout.section_at(s)


func section_id(i: int) -> StringName:
	return layout.section_ids[i]


func section_start(i: int) -> float:
	return layout.section_length_m * float(i)


## Lane flow speed (m/s) of `lane` of `lane_count` lanes in the section at s (the
## section's own list, else TrafficTuning's convention).
func lane_flow_speed_mps(lane: int, lanes: int, s: float) -> float:
	var list := def.sections[section_at(s)].lane_flow_speeds_from_right_kmh
	var i := clampi(lanes - 1 - lane, 0, list.size() - 1)
	return Units.kmh_to_mps(list[i])


## The sections as a BiomePlan over `laps` laps (one leg per section, then the first
## section's biome): hand it to a BiomeDirector (`director.plan`) before its setup so the
## look, props and landmark styles follow the loop. Director rate.
func biome_plan(laps: int = 1) -> BiomePlan:
	var ids: Array[StringName] = []
	for lap in maxi(laps, 1):
		ids.append_array(layout.section_ids)
	return BiomePlan.from_ids(ids, layout.section_ids[0], layout.section_length_m)


# ---------------------------------------------------------------- Features and generation

## Every feature overlapping [s0, s1) at its unwrapped s, sorted by s_start (then kind).
## Director rate (allocates copies).
func features_in(s0: float, s1: float, out: Array[RoadFeature]) -> void:
	if s1 <= s0:
		return
	var found: Array[RoadFeature] = []
	var q0 := int(floor(s0 * _inv_L)) - 1
	var q1 := int(floor(s1 * _inv_L))
	for lap in range(q0, q1 + 1):
		var off := float(lap) * _L
		for f in layout.features:
			var a := f.s_start + off
			if a >= s1:
				break
			if f.s_end + off >= s0:
				var v := f.value
				if f.kind == RoadFeature.Kind.CHECKPOINT:
					v += float(lap * _sectors)
				found.append(RoadFeature.make(f.kind, a, f.s_end + off, v, f.tag, f.tag2))
	found.sort_custom(ProceduralRoadPath._feature_before)
	out.append_array(found)


## The loop exists everywhere.
func length_generated() -> float:
	return INF


# ---------------------------------------------------------------- Diagnostics

## Hash of the table and every feature (determinism tests, the editor).
func trace_hash() -> int:
	var hsh := 0
	hsh = TraceHash.mix_f64_array(hsh, _h, _h.size())
	hsh = TraceHash.mix_f64_array(hsh, _k, _k.size())
	hsh = TraceHash.mix_f64_array(hsh, _e, _e.size())
	hsh = TraceHash.mix_f64_array(hsh, _g, _g.size())
	hsh = TraceHash.mix_f64_array(hsh, _x, _x.size())
	hsh = TraceHash.mix_f64_array(hsh, _z, _z.size())
	hsh = TraceHash.mix_f64_array(hsh, _lane_s, _lane_s.size())
	hsh = TraceHash.mix_i32_array(hsh, _lane_n, _lane_n.size())
	for f in layout.features:
		hsh = TraceHash.mix_int(hsh, f.kind)
		hsh = TraceHash.mix_float(hsh, f.s_start)
		hsh = TraceHash.mix_float(hsh, f.s_end)
		hsh = TraceHash.mix_float(hsh, f.value)
	return hsh
