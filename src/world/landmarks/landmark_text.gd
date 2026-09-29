class_name LandmarkText
extends RefCounted
## The words on checkpoint signs and landmarks (WP5.3). Spec: Core loop → Legs and
## checkpoints ("warning signs announce each checkpoint at 1 km and 500 m"), World →
## Checkpoint landmarks ("big sign gantry with the leg name and distance"). The spec
## names legs by their biome ("each leg is one biome"), so a leg reads
## "LEG 3 — DESERT MESAS", or "LEG 3" when no biome name is known. Pure: strings only,
## called at placement (director rate), never per frame.

const DASH := " — "
## N3.2, the loop: sector gantries instead of checkpoints (a CHECKPOINT's value is
## lap × sectors + gantry + 1; the stretch from gantry g is sector g + 1).
const START_FINISH := "START / FINISH"
const GANTRY := "GANTRY "
const FINISH := "FINISH "
const NEXT_GANTRY := "NEXT GANTRY "
const SECTOR := "SECTOR"


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


## Lines of the lane-ends panel before a lane drop (the right lane ends: tunnels).
static func lane_ends_sign() -> PackedStringArray:
	return PackedStringArray(["LANE ENDS", "MERGE LEFT"])


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


## WP6.5 forks: the roadside sign before a fork, one branch per line so both names read
## at speed (the sign's place gives the distance, 1 km and 500 m, like the checkpoint
## warnings): < LEFT / RIGHT >.
static func fork_sign(_metres: float, left_name: String, right_name: String) -> PackedStringArray:
	var l := left_name.strip_edges().to_upper()
	var r := right_name.strip_edges().to_upper()
	return PackedStringArray(["< " + (l if l != "" else "?"), (r if r != "" else "?") + " >"])


## "< DESERT MESAS   CANYON PASS >" (upper case; a missing name reads "?").
static func fork_names(left_name: String, right_name: String) -> String:
	var l := left_name.strip_edges().to_upper()
	var r := right_name.strip_edges().to_upper()
	return "< %s   %s >" % [l if l != "" else "?", r if r != "" else "?"]


## Lines of a fork checkpoint's landmark (the sign gantry over the split).
static func fork_landmark(kind: StringName, cp_leg: int, left_name: String, right_name: String) -> PackedStringArray:
	var names := fork_names(left_name, right_name)
	match kind:
		BiomeDef.LANDMARK_SIGN_GANTRY:
			return PackedStringArray([names, "LEG %d  —  PICK YOUR SIDE" % (cp_leg + 1), "CHECKPOINT"])
		BiomeDef.LANDMARK_TOLL_GANTRY:
			return PackedStringArray(["EXPRESS", "CHECKPOINT", names])
		BiomeDef.LANDMARK_TUNNEL_PORTAL:
			return PackedStringArray(["CHECKPOINT", names])
	return PackedStringArray()


# ---------------------------------------------------------------- The loop (N3.2)

## The gantry index (0 = start / finish) of a loop CHECKPOINT value.
static func loop_gantry(value: int, sectors: int) -> int:
	return posmod(value - 1, maxi(sectors, 1))


## "SECTOR 2 — CANYON PASS": the sector that starts at gantry `gantry`.
static func sector(gantry: int, biome_name: String) -> String:
	var n := "SECTOR %d" % (gantry + 1)
	if biome_name.strip_edges() == "":
		return n
	return n + DASH + biome_name.strip_edges().to_upper()


## Lines of a loop gantry's landmark (LandmarkBuilds line order per kind): the gantry of
## CHECKPOINT value `value`, the sector it starts and the distance to the next gantry.
static func loop_landmark(kind: StringName, value: int, sectors: int, next_name: String,
		next_dist_m: float) -> PackedStringArray:
	var g := loop_gantry(value, sectors)
	var next := sector(g, next_name)
	match kind:
		BiomeDef.LANDMARK_TOLL_GANTRY:
			return PackedStringArray(["EXPRESS", START_FINISH if g == 0 else SECTOR, next])
		BiomeDef.LANDMARK_SIGN_GANTRY:
			return PackedStringArray([next, NEXT_GANTRY + distance(next_dist_m), START_FINISH if g == 0 else SECTOR])
		BiomeDef.LANDMARK_TUNNEL_PORTAL:
			return PackedStringArray([START_FINISH if g == 0 else SECTOR, next])
	return PackedStringArray()


## Lines of the roadside sign `metres` before loop gantry value `value`: GANTRY 1 KM (or
## FINISH 1 KM before the start / finish line) / the sector it starts.
static func loop_warning_sign(metres: float, value: int, sectors: int, next_name: String) -> PackedStringArray:
	var g := loop_gantry(value, sectors)
	return PackedStringArray([(FINISH if g == 0 else GANTRY) + distance(metres), sector(g, next_name)])
