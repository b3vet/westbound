class_name LoopTuning
extends Resource
## The loop test mode (N3.2): a single-player practice run on the multiplayer loop.
## Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → The loop map, Time of day in multiplayer
## (the room clock: 32 min, 22 day / 10 night, UTC-derived; night ×2), Traffic → Server
## simulation ("Normal density is 10 vehicles per km per lane"), Scoring in multiplayer
## (sectors replace checkpoints). docs/LOOP_MAP.md → Loop test mode; docs/RUN.md.
## Saved as data/tuning/loop.tres. Until the orchestrator adds `Tuning.loop`, load it with
## LoopTuning.load_default().

const PATH := "res://data/tuning/loop.tres"

@export_group("Room clock")
## The shared day/night cycle: this long, the first room_day_min of it day.
@export var room_cycle_min: float = 32.0
@export var room_day_min: float = 22.0
## UTC second at which a cycle starts (0 = the Unix epoch: every public room worldwide has
## night at the same moments).
@export var room_clock_epoch_unix_s: float = 0.0   # not in spec: any fixed epoch works
## The night's sky: from sunset to the night keyframe over this long, then night, then the
## last room_dawn_s run the dawn up to morning (sky_t 1 == 0), where the day starts.
@export var room_nightfall_s: float = 45.0   # not in spec
@export var room_dawn_s: float = 60.0   # not in spec

@export_group("Traffic")
## The director drives the loop at this leg's mix, headway, set-piece unlocks and
## chances (DirectorTuning's leg ramp), ...
@export var director_leg: int = 5   # not in spec: mid ramp (the loop is not a journey)
## ... at this density: the spec's "normal" room density, vehicles per km per lane.
@export var density_per_km_lane: float = 10.0
## Per section (desert, canyon, coast, city, farmland in loop_v1's order), % of that
## density: the city is the densest (the handoff's section table). Missing entries: 100.
@export var section_density_pct: PackedFloat64Array = [90.0, 100.0, 100.0, 130.0, 90.0]   # not in spec
## Set pieces left out on the loop: those that reshape the road's lanes or close lanes
## (the loop's own road works zones are the server's, N4/N6).
@export var excluded_set_pieces: Array[StringName] = [&"merge_zone", &"road_works"]


func room_cycle_s() -> float:
	return Units.min_to_s(room_cycle_min)


func room_day_s() -> float:
	return Units.min_to_s(room_day_min)


## % of the density in section `i` (100 past the list).
func section_density_frac(i: int) -> float:
	if i < 0 or i >= section_density_pct.size():
		return 1.0
	return Units.pct_to_frac(section_density_pct[i])


static func load_default() -> LoopTuning:
	return load(PATH) as LoopTuning
