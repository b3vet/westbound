class_name LaneChangeRoadPath
extends StraightRoadPath
## Dev/test road: a straight fixture whose lane count changes at `change_s`
## (spec: World → Road, "tunnels and road works drop to 2"). With `with_feature`
## it also reports the LANE_COUNT_CHANGE feature (taper over change_s..change_s +
## taper_m, as RoadFeature documents); without it, lane_count(s) just steps and the
## road builder falls back to its default taper.

var lanes_before: int
var lanes_after: int
var change_s: float


func _init(before: int = 3, after: int = 2, at_s: float = 400.0, taper_m: float = 150.0,
		with_feature: bool = true, road_tuning: RoadTuning = null, heading_rad: float = 0.0,
		grade_value: float = 0.0) -> void:
	super(before, road_tuning, heading_rad, grade_value)
	lanes_before = before
	lanes_after = after
	change_s = at_s
	if with_feature:
		add_feature(RoadFeature.make(RoadFeature.Kind.LANE_COUNT_CHANGE, at_s, at_s + taper_m, float(after)))


func lane_count(s: float) -> int:
	return lanes_after if s >= change_s else lanes_before
