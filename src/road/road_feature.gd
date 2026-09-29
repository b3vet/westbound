class_name RoadFeature
extends RefCounted
## A marked stretch of road returned by RoadPath.features_in(). Spec: World → Road
## (blind crests, lane counts), Traffic fairness rule 6, Legs (checkpoints, forks).
## Queried at director rate (not per tick), so creating these is allowed.

enum Kind {
	BLIND_CREST,        ## s_start..s_end: the crest; director caps density for 150 m after s_end
	BLIND_BEND,         ## s_start..s_end: a bend with limited sight distance
	BEND,               ## value = signed curvature (1/m, + = right) at the apex
	LANE_COUNT_CHANGE,  ## at s_start the lane count becomes int(value); s_start..s_end is the taper
	FORK,               ## s_start..s_end = the fork's whole span (WP6.5: the opposite carriageway's veer before the split to its rejoin after the gore); value = the split s; tag = left biome, tag2 = right biome
	CHECKPOINT,         ## s_start = crossing line; value = leg index ending there; tag = landmark style
	TUNNEL,             ## s_start..s_end inside the tunnel
	SIGN,               ## warning sign at s_start; tag = what it announces; value = distance announced (m)
}

var kind: Kind = Kind.BEND
var s_start: float = 0.0
var s_end: float = 0.0
var value: float = 0.0
var tag: StringName = &""
var tag2: StringName = &""


static func make(k: Kind, from_s: float, to_s: float, v: float = 0.0, t: StringName = &"", t2: StringName = &"") -> RoadFeature:
	var f := RoadFeature.new()
	f.kind = k
	f.s_start = from_s
	f.s_end = to_s
	f.value = v
	f.tag = t
	f.tag2 = t2
	return f


## True if [s_start, s_end] intersects [s0, s1).
func overlaps(s0: float, s1: float) -> bool:
	return s_start < s1 and s_end >= s0
