class_name LandmarkText
extends RefCounted
## The words on checkpoint signs and landmarks (WP5.3). Spec: Core loop → Legs and
## checkpoints ("warning signs announce each checkpoint at 1 km and 500 m"), World →
## Checkpoint landmarks ("big sign gantry with the leg name and distance"). The spec
## names legs by their biome ("each leg is one biome"), so a leg reads
## "LEG 3 — DESERT MESAS", or "LEG 3" when no biome name is known. Pure: strings only,
## called at placement (director rate), never per frame.

const DASH := " — "


## "1 KM", "3.5 KM", "500 M" (the world's signs are metric).
static func distance(metres: float) -> String:
	if metres >= 1000.0:
		var km := metres / 1000.0
		if is_equal_approx(km, roundf(km)):
			return "%d KM" % roundi(km)
		return "%.1f KM" % km
	return "%d M" % roundi(metres)


static func leg(index: int, biome_name: String) -> String:
	if biome_name.strip_edges() == "":
		return "LEG %d" % index
	return "LEG %d%s%s" % [index, DASH, biome_name.strip_edges().to_upper()]


## Lines of the roadside warning sign `metres` before the checkpoint that starts
## leg `next_leg`: CHECKPOINT <distance> / the next leg.
static func warning_sign(metres: float, next_leg: int, next_name: String) -> PackedStringArray:
	return PackedStringArray(["CHECKPOINT " + distance(metres), leg(next_leg, next_name)])


## Lines of a checkpoint landmark (LandmarkBuilds line order per kind) at the end of
## leg `cp_leg`; the next checkpoint is `next_dist_m` further on.
static func landmark(kind: StringName, cp_leg: int, next_name: String, next_dist_m: float) -> PackedStringArray:
	var next := leg(cp_leg + 1, next_name)
	match kind:
		BiomeDef.LANDMARK_TOLL_GANTRY:
			return PackedStringArray(["EXPRESS", "CHECKPOINT", next])
		BiomeDef.LANDMARK_SIGN_GANTRY:
			return PackedStringArray([next, "NEXT CHECKPOINT " + distance(next_dist_m), "CHECKPOINT"])
		BiomeDef.LANDMARK_TUNNEL_PORTAL:
			return PackedStringArray(["CHECKPOINT", next])
	return PackedStringArray()
