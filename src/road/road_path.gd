class_name RoadPath
extends RefCounted
## The road reference line and cross-section in road space. Base contract (pure,
## headless). Spec: Architecture rule 5; World → Road; Traffic fairness rule 6.
## WP1.1 implements the seeded procedural road; tests use tests/fixtures/road/.
## See docs/CONTRACTS.md "Road space" and "RoadPath".
##
## Coordinates: `s` = meters along the reference line (plan-view arc length) in the
## direction of travel (westbound), increasing. The reference line is the center of
## the median. `d` = lateral offset in meters, POSITIVE TO THE RIGHT of travel. The
## player's carriageway is d > 0; the opposite carriageway is d < 0 (mirrored).
## Lane 0 is next to the median (leftmost, fastest); lane_count(s) - 1 is the slow lane.
##
## Tick-safe (allocation-free): sample_into, curvature_at, lane_count and every
## *_d / lane query. Director-rate (may allocate): sample, features_in,
## ensure_generated_to, forget_before.
##
## Subclasses implement sample_into, curvature_at, lane_count, features_in and the
## generation hooks. The cross-section queries below are implemented here from
## RoadTuning; override them only for tapers (e.g. a right lane ending).

var lane_width_m: float
var median_half_width_m: float
var inner_shoulder_m: float
var shoulder_m: float
var guardrail_offset_m: float


func _init(road_tuning: RoadTuning = null) -> void:
	configure_cross_section(road_tuning if road_tuning != null else Tuning.load_default().road)


func configure_cross_section(t: RoadTuning) -> void:
	lane_width_m = t.lane_width_m
	median_half_width_m = t.median_half_width_m
	inner_shoulder_m = t.inner_shoulder_m
	shoulder_m = t.shoulder_m
	guardrail_offset_m = t.guardrail_offset_m


# ---------------------------------------------------------------- Reference line (abstract)

## Fills `out` with the reference line at `s`. Allocation-free; call per tick.
## `s` must lie in the generated range (<= length_generated()).
func sample_into(_s: float, _out: RoadSample) -> void:
	push_error("RoadPath.sample_into not implemented")


## Signed curvature (1/m, + = bends right) at `s`. Allocation-free.
func curvature_at(_s: float) -> float:
	push_error("RoadPath.curvature_at not implemented")
	return 0.0


## Allocating convenience for non-tick code (tools, tests, director).
func sample(s: float) -> RoadSample:
	var out := RoadSample.new()
	sample_into(s, out)
	return out


# ---------------------------------------------------------------- Lanes (abstract count)

## Driving lanes on the player's carriageway at `s` (the opposite carriageway mirrors it).
func lane_count(_s: float) -> int:
	push_error("RoadPath.lane_count not implemented")
	return 0


func lane_width(_s: float) -> float:
	return lane_width_m


## d of lane `lane`'s center: median_half_width + inner_shoulder + (lane + 0.5) * lane_width.
func lane_center_d(lane: int, s: float) -> float:
	return lanes_left_edge_d(s) + (float(lane) + 0.5) * lane_width(s)


## Opposite carriageway, mirrored: its lane `lane` (0 = next to the median) at -lane_center_d.
func opposite_lane_center_d(lane: int, s: float) -> float:
	return -lane_center_d(lane, s)


## Lane index containing d, or -1 if d is not on a driving lane (shoulder, median, beyond).
func lane_index_at(d: float, s: float) -> int:
	var x := (d - lanes_left_edge_d(s)) / lane_width(s)
	if x < 0.0:
		return -1
	var i := int(x)
	return i if i < lane_count(s) else -1


# ---------------------------------------------------------------- Cross-section edges (player side, d > 0)

## Median barrier face (left limit of the carriageway; the barrier occupies |d| < this).
func median_barrier_d(_s: float) -> float:
	return median_half_width_m


## Left edge of lane 0 (inner shoulder is between median_barrier_d and this).
func lanes_left_edge_d(_s: float) -> float:
	return median_half_width_m + inner_shoulder_m


## Right edge of the rightmost driving lane (outer shoulder starts here).
func lanes_right_edge_d(s: float) -> float:
	return lanes_left_edge_d(s) + float(lane_count(s)) * lane_width(s)


## Outer edge of the paved outer shoulder.
func shoulder_outer_d(s: float) -> float:
	return lanes_right_edge_d(s) + shoulder_m


## Guardrail face on the outer side.
func guardrail_d(s: float) -> float:
	return shoulder_outer_d(s) + guardrail_offset_m


## True if d lies on the inner or outer shoulder (between the barriers, off the lanes).
func is_on_shoulder(d: float, s: float) -> bool:
	return (d >= median_barrier_d(s) and d < lanes_left_edge_d(s)) \
		or (d > lanes_right_edge_d(s) and d <= guardrail_d(s))


# ---------------------------------------------------------------- Forks (WP6.5, docs/FORKS.md)
# Defaults describe the plain mirrored road; ProceduralRoadPath overrides them around a
# fork. Tick-safe unless noted.

## How far the opposite carriageway sits beyond its mirrored place (m, >= 0: further
## left, the carriageways separate).
func opposite_offset_d(_s: float) -> float:
	return 0.0


## How much of the opposite carriageway exists at s (1 = all of it, 0 = none).
func opposite_width_frac(_s: float) -> float:
	return 1.0


## True where the player's left side is a guardrail at median_barrier_d(s) (no median
## barrier: the opposite carriageway is away).
func median_is_rail(_s: float) -> bool:
	return false


## Height factor of the barriers and rails at s (1 = full; a vanishing fork branch).
func rail_height_frac(_s: float) -> float:
	return 1.0


## The ground ribbon ends at these d on the right (<= the limit) and the left (>= it).
## Director rate (the mesher).
func ground_right_limit_d(_s: float) -> float:
	return INF


func ground_left_limit_d(_s: float) -> float:
	return -INF


# ---------------------------------------------------------------- Features and generation

## Appends every feature overlapping [s0, s1) to `out`, in increasing s_start.
## Director rate; may allocate.
func features_in(_s0: float, _s1: float, _out: Array[RoadFeature]) -> void:
	push_error("RoadPath.features_in not implemented")


## Furthest s that is generated and safe to sample.
func length_generated() -> float:
	push_error("RoadPath.length_generated not implemented")
	return 0.0


## Generates the road (seeded) at least up to `s`. Director rate; may allocate.
func ensure_generated_to(_s: float) -> void:
	pass


## Allows dropping road data before `s` (behind the player). Optional.
func forget_before(_s: float) -> void:
	pass
