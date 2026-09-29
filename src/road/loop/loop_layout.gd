class_name LoopLayout
extends RefCounted
# lint: sim
## Everything LoopGen generates for one loop (N3.1): the closed dense table, the
## elements, and every feature in road space. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md →
## The loop map. docs/LOOP_MAP.md. Pure data: LoopRoadPath answers the RoadPath queries
## from it, LoopExport writes the road-space file from it, LoopValidator checks it and
## the loop editor draws it. Every feature position lies in [0, length_m) (a zone may
## end past length_m when it crosses the seam) and is a whole number of millimetres.

## Ramp kinds.
const RAMP_OFF := 0
const RAMP_ON := 1

var def: LoopMapDef
var length_m: float = 0.0
var section_length_m: float = 0.0
var section_ids: Array[StringName] = []
var section_lanes := PackedInt32Array()

# ---- Dense table (N + 1 entries, s_i = i * dx; entry N is the seam, equal to entry 0
# except for the heading, which is entry 0's + total_turn).
var dx: float = 0.0
var n: int = 0
var h := PackedFloat64Array()
var k := PackedFloat64Array()
var e := PackedFloat64Array()
var g := PackedFloat64Array()
var x := PackedFloat64Array()
var z := PackedFloat64Array()
## Heading change over one lap (-TAU: the loop turns left, counterclockwise from above).
var total_turn: float = 0.0
## Plan-position gap at the seam before it was spread over the lap (m), the Newton
## iterations it took, and the heading mismatch of the elements at the seam (rad).
var closure_residual_m: float = 0.0
var closure_iterations: int = 0
var closure_heading_error: float = 0.0
## Elevation (m) and grade mismatch of the profile elements at the seam.
var closure_elevation_error: float = 0.0
var closure_grade_error: float = 0.0

## The elements (and BEND / BLIND_BEND / SIGN features) and the vertical profile.
var plan: RoadPlanGen
var profile: RoadProfileGen

# ---- Plan design (flattened over sections, in driving order).
var bend_section := PackedInt32Array()
var bend_s0 := PackedFloat64Array()
var bend_s1 := PackedFloat64Array()
var bend_dh := PackedFloat64Array()
var bend_radius := PackedFloat64Array()
var bend_transition := PackedFloat64Array()
var straight_section := PackedInt32Array()
var straight_s0 := PackedFloat64Array()
var straight_len := PackedFloat64Array()

# ---- Profile design: PVIs (s, elevation, vertical curve length and radius, crest flag).
var pvi_s := PackedFloat64Array()
var pvi_e := PackedFloat64Array()
var pvi_vc_len := PackedFloat64Array()
var pvi_radius := PackedFloat64Array()
var pvi_crest := PackedInt32Array()

# ---- Lanes: from lane_s[i] on the count is lane_n[i], the right edge tapering over
# lane_taper[i] (sorted by s); lanes_base before the first (= the last one's count).
var lanes_base: int = 0
var lane_s := PackedFloat64Array()
var lane_n := PackedInt32Array()
var lane_taper := PackedFloat64Array()

var tunnel_s0 := PackedFloat64Array()
var tunnel_s1 := PackedFloat64Array()
## Lanes inside each tunnel.
var tunnel_lanes := PackedInt32Array()

var sector_s := PackedFloat64Array()
var sector_style: Array[StringName] = []
## The suspension bridge (the bridge sector's landmark) with its backstays.
var bridge_s0: float = 0.0
var bridge_s1: float = 0.0

var ramp_s := PackedFloat64Array()
var ramp_len := PackedFloat64Array()
var ramp_kind := PackedInt32Array()
var ramp_pair := PackedInt32Array()
var ramp_section := PackedInt32Array()

## Road works: [s0, s1] including both tapers; closure_lanes lanes closed from the right.
var closure_s0 := PackedFloat64Array()
var closure_s1 := PackedFloat64Array()
var closure_section := PackedInt32Array()

var spawn_s := PackedFloat64Array()
var spawn_lane := PackedInt32Array()

var elevated_s0 := PackedFloat64Array()
var elevated_s1 := PackedFloat64Array()

## Every feature of one lap, sorted by s_start (then kind).
var features: Array[RoadFeature] = []

# ---- Tunable parameters (the editor's fields): key, generated value, value in use,
# suggested range and where on the loop it acts.
var param_key := PackedStringArray()
var param_default := PackedFloat64Array()
var param_value := PackedFloat64Array()
var param_min := PackedFloat64Array()
var param_max := PackedFloat64Array()
var param_s := PackedFloat64Array()

## Problems met while generating (a feature that could not be placed, ...).
var issues := PackedStringArray()


func section_count() -> int:
	return section_ids.size()


## Section index containing s (any s; wraps).
func section_at(s: float) -> int:
	var i := int(floor(wrap_s(s) / section_length_m))
	return clampi(i, 0, section_ids.size() - 1)


func wrap_s(s: float) -> float:
	var r := fposmod(s, length_m)
	return r if r < length_m else 0.0


## Wrapped signed distance from a to b along the loop, in [-L/2, L/2).
func signed_delta(a: float, b: float) -> float:
	return fposmod(b - a + length_m * 0.5, length_m) - length_m * 0.5


## Largest |curvature| of the table over [a, b] (wraps; b >= a).
func max_abs_curvature(a: float, b: float) -> float:
	var worst := 0.0
	var i0 := int(floor(a / dx))
	var i1 := int(ceil(b / dx))
	for i in range(i0, i1 + 1):
		worst = maxf(worst, absf(k[posmod(i, n)]))
	return worst


## True when [a0, a1] and [b0, b1] come closer than `margin` on the loop.
func zones_meet(a0: float, a1: float, b0: float, b1: float, margin: float) -> bool:
	for lap in range(-1, 2):
		var off := float(lap) * length_m
		if a0 - margin <= b1 + off and b0 + off <= a1 + margin:
			return true
	return false


func param_index(key: String) -> int:
	return param_key.find(key)
