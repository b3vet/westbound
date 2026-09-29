class_name LandmarkSection
extends RefCounted
## The road cross-section a landmark build is made for (WP5.3). Spec: World → Road
## (divided highway, lanes 3.6 m, shoulders 3.0 m, median barrier); docs/CONTRACTS.md
## §2 (d right-positive from the median centre, positive-side edges). Builds are
## cached per section key, so a lane-count change gets its own build.

var lanes: int = 3
var lane_width: float = 3.6
var median_barrier_d: float = 0.5
var lanes_left_edge_d: float = 1.7
var lanes_right_edge_d: float = 12.5
var shoulder_outer_d: float = 15.5
var guardrail_d: float = 16.0


static func at(road: RoadPath, s: float) -> LandmarkSection:
	var x := LandmarkSection.new()
	x.lanes = road.lane_count(s)
	x.lane_width = road.lane_width(s)
	x.median_barrier_d = road.median_barrier_d(s)
	x.lanes_left_edge_d = road.lanes_left_edge_d(s)
	x.lanes_right_edge_d = road.lanes_right_edge_d(s)
	x.shoulder_outer_d = road.shoulder_outer_d(s)
	x.guardrail_d = road.guardrail_d(s)
	return x


## Centre of lane `i` (0 = next to the median) on the player's carriageway.
func lane_center(i: int) -> float:
	return lanes_left_edge_d + (float(i) + 0.5) * lane_width


## Cache key: builds for equal keys are identical.
func key() -> String:
	return "%d/%.3f/%.3f/%.3f/%.3f" % [lanes, lane_width, median_barrier_d, lanes_left_edge_d, guardrail_d]
