class_name FixtureRoadPath
extends RoadPath
## Shared base for the exact test roads (constant lane count, flat cross-section,
## optional hand-placed features, infinite length). Not a test suite: the runner
## skips tests/fixtures.

var _lanes: int
var _length: float
var _features: Array[RoadFeature] = []


func _init(lanes: int, road_tuning: RoadTuning = null, length_m: float = INF) -> void:
	super(road_tuning)
	_lanes = lanes
	_length = length_m


func lane_count(_s: float) -> int:
	return _lanes


func length_generated() -> float:
	return _length


func add_feature(f: RoadFeature) -> void:
	_features.append(f)
	_features.sort_custom(func(a: RoadFeature, b: RoadFeature) -> bool: return a.s_start < b.s_start)


func features_in(s0: float, s1: float, out: Array[RoadFeature]) -> void:
	for f in _features:
		if f.overlaps(s0, s1):
			out.append(f)
