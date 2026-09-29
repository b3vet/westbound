class_name RunLoop
extends RefCounted
## The loop test mode (N3.2): a single-player practice run on the multiplayer loop
## (`loop_v1`). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → The loop map ("s wraps modulo
## L"), Time of day in multiplayer (the room clock, night ×2, the HUD clock), Traffic
## (normal density), Scoring in multiplayer ("Sectors replace checkpoints"; "No sun
## meter"); milestone N3 ("the loop drives cleanly end-to-end in single-player test
## mode"). docs/LOOP_MAP.md → Loop test mode, docs/RUN.md → Loop mode.
##
## The run owns one; in loop mode (Run.MODE_LOOP) it swaps the procedural road for
## LoopRoadPath and:
## - **Wrap design:** s stays unwrapped and monotonic everywhere on the client (the car,
##   traffic, scoring, hits, legs, the world nodes, the camera): the run starts at
##   s = L + the first spawn point (lap 1) and keeps counting. Only road queries wrap:
##   LoopRoadPath answers any s modulo L, reports features at their unwrapped s and keeps
##   the heading continuous, so distances between the car and traffic, gantries or chunks
##   are plain differences (= the wrapped signed difference while they are < L/2 apart)
##   and nothing sees the seam. float64 s loses no precision in hours (at 70 m/s, 10 h is
##   2.5e6 m: steps of 5e-10 m). Wrapped s comes in only from the server (N4:
##   LoopRoadPath.unwrap_near).
## - **The look:** the director's plan is the loop's periodic plan (biome_plan(0)); the
##   elevated city is the loop's zone (layout.elevated_s0/_s1, every lap).
## - **Off:** forks, the finale, the journey bonus, Chase the Sun (the sun clock, lifts,
##   hesitation's sink), leg objectives, and the set pieces in excluded_set_pieces.
## - **Sectors:** the loop's CHECKPOINT features are its sector gantries, so LegTracker
##   runs them as legs: a crossing banks the chain, pays Clean / Pace / Threads / Heat
##   and a clean sector restores a life (legs_to_coast never reached).
## - **Room clock:** RoomClock (UTC at the run start, then the sim's dt) drives sky_t and
##   night ×2; the HUD shows it (HudLoopFeed) instead of the sun bar.
## - **Traffic:** the director at LoopTuning.director_leg, density
##   density_per_km_lane × the section's share, and the section's lane flow speeds
##   (written into the run's own TrafficTuning copy when the player enters a section).

## LegsTuning.legs_to_coast in loop mode: never reached.
const LEGS_NEVER := 1 << 30
## Dev places (place_s): metres before a feature, and fractions into a section.
const PLACE_LEAD_M := 120.0   # lint: allow-number dev snap position, not tuning
const PLACE_DESERT := 0.4   # lint: allow-number dev snap position, not tuning
const PLACE_CANYON := 0.25   # lint: allow-number dev snap position, not tuning
const PLACE_COAST := 0.15   # lint: allow-number dev snap position, not tuning
const PLACE_FARMLAND := 0.35   # lint: allow-number dev snap position, not tuning

var tuning: LoopTuning
var road: LoopRoadPath
var clock: RoomClock
## The HUD's loop values (the clock, the sector), filled once per frame.
var feed := HudLoopFeed.new()
## UTC seconds the room clock starts from; NAN = the wall clock at the run start (the
## Run node reads it; tests set it for exact replays).
var clock_start_unix_s: float = NAN
## Section the player is in (-1 before the first tick).
var section: int = -1
## The dev DENS knob, times the loop's own density.
var dev_density_scale: float = 1.0
var night: bool = false

var _flow: Array[PackedFloat64Array] = []
var _traffic: TrafficTuning
var _director: TrafficDirector
var _director_tuning: DirectorTuning

static var _cached_road: LoopRoadPath


func _init(loop_tuning: LoopTuning = null) -> void:
	tuning = loop_tuning if loop_tuning != null else LoopTuning.load_default()


## The committed loop (generated once per process: LoopGen takes ~0.1 s).
static func loop_road(t: Tuning) -> LoopRoadPath:
	if _cached_road == null:
		_cached_road = LoopRoadPath.load_default(t)
	return _cached_road


## The run's tuning in loop mode: a copy of `base` whose TrafficTuning follows the
## section's flow speeds, whose legs never reach the coast, and whose set-piece unlock
## order leaves out excluded_set_pieces. Sub-resources the loop does not change are
## shared.
func run_tuning(base: Tuning) -> Tuning:
	var t := base.duplicate() as Tuning
	t.traffic = base.traffic.duplicate() as TrafficTuning
	t.legs = base.legs.duplicate() as LegsTuning
	t.legs.legs_to_coast = LEGS_NEVER
	t.director = base.director.duplicate() as DirectorTuning
	var order: Array[StringName] = []
	for id in base.director.set_piece_unlock_order:
		if not tuning.excluded_set_pieces.has(id):
			order.append(id)
	t.director.set_piece_unlock_order = order
	return t


## A new run: the road, the clock, the per-section flow speeds.
func setup(run_tuning_copy: Tuning) -> void:
	road = loop_road(run_tuning_copy)
	_traffic = run_tuning_copy.traffic
	_director_tuning = run_tuning_copy.director
	_flow.clear()
	for i in road.section_count():
		_flow.append(road.def.sections[i].lane_flow_speeds_from_right_kmh)
	clock = RoomClock.new(tuning, run_tuning_copy.sun)
	clock.set_time(clock_start_unix_s if not is_nan(clock_start_unix_s) else 0.0)
	night = clock.is_night()
	section = -1
	feed.reset()


## Where the run starts: lap 1, at the first spawn point past the start / finish gantry.
func start_s() -> float:
	var o := road.layout
	return road.length() + (o.spawn_s[0] if not o.spawn_s.is_empty() else o.sector_s[0])


## The periodic biome plan (hand it to the BiomeDirector before its setup).
func biome_plan() -> BiomePlan:
	return road.biome_plan(0)


## After BiomeFeatures.setup, before the first build: the loop's elevated city.
func apply_features(features: BiomeFeatures) -> void:
	if features.elevated != null and features.elevated.plan != null:
		var o := road.layout
		features.elevated.plan.set_zones(o.elevated_s0, o.elevated_s1, road.length())


## The run's new director: its leg, and the section at s.
func bind_director(director: TrafficDirector, s: float) -> void:
	_director = director
	director.set_leg(tuning.director_leg, s)
	section = -1
	enter_section(road.section_at(s), s)


## The player entered section `i`: its flow speeds and density (director rate, a few
## times a lap). Deterministic: called from the tick.
func enter_section(i: int, _s: float) -> void:
	if i == section:
		return
	section = i
	_traffic.lane_flow_speeds_from_right_kmh = _flow[i]
	if _director != null:
		_director.set_density_scale(density_scale(i))
		_director.set_biome(BiomePlan.load_biome(road.section_id(i)))


## The director's density scale in section i: the loop's density x the section's share
## over the leg's own target, times the dev knob.
func density_scale(i: int) -> float:
	var leg_target := maxf(_director_tuning.density_per_km_lane(tuning.director_leg), 1.0)
	return tuning.density_per_km_lane * tuning.section_density_frac(i) / leg_target * dev_density_scale


## Per tick: the room clock (sky_t, night ×2; night_started / morning_reached into
## `out`) and the section at the player. Returns the sky_t to show. Allocation-free
## except on a section change.
func tick(dt: float, player_s: float, out: ScoreEventBuffer) -> float:
	clock.advance(dt)
	var n := clock.is_night()
	if n != night:
		night = n
		out.push(SunClock.KIND_NIGHT_STARTED if n else SunClock.KIND_MORNING_REACHED)
	var i := road.section_at(player_s)
	if i != section:
		enter_section(i, player_s)
	return clock.sky_t()


## Once per frame: the HUD's clock and sector values.
func fill_feed(player_s: float, sector_distance_m: float) -> void:
	feed.active = true
	feed.cycle_frac = clock.cycle_frac()
	feed.day_frac = clock.day_frac()
	feed.night = clock.is_night()
	feed.flip_in_s = clock.seconds_to_flip()
	feed.sector_distance_m = sector_distance_m
	feed.lap = road.lap_of(player_s)
	feed.sector = sector_at(player_s) + 1
	feed.sectors = road.layout.sector_s.size()


## Dev (snaps, the web export smoke's `&at=`): the s (lap 1, unwrapped) of a named place:
## start, desert, canyon, tunnel, crest, coast, bridge, city (the middle of the elevated
## zone), ramp, farmland, seam (just before the start / finish line), or metres into the
## lap. Places at a feature stand PLACE_LEAD_M before it.
func place_s(at: String) -> float:
	var o := road.layout
	var lap := road.length()
	var sec := o.section_length_m
	match at:
		"start":
			return start_s()
		"desert":
			return lap + road.section_start(0) + sec * PLACE_DESERT
		"canyon":
			return lap + road.section_start(1) + sec * PLACE_CANYON
		"tunnel":
			return lap + o.tunnel_s0[0] - PLACE_LEAD_M
		"crest":
			for f in o.features:
				if f.kind == RoadFeature.Kind.BLIND_CREST:
					return lap + f.s_start - PLACE_LEAD_M
		"coast":
			return lap + road.section_start(2) + sec * PLACE_COAST
		"bridge":
			return lap + o.bridge_s0 - PLACE_LEAD_M
		"city":
			return lap + (o.elevated_s0[0] + o.elevated_s1[0]) * 0.5
		"ramp":
			return lap + o.ramp_s[0] - PLACE_LEAD_M
		"farmland":
			return lap + road.section_start(4) + sec * PLACE_FARMLAND
		"seam":
			return lap * 2.0 - PLACE_LEAD_M
	return lap + float(at) if at.is_valid_float() else start_s()


## Index of the sector the player is in (0-based: from gantry k to gantry k + 1).
func sector_at(s: float) -> int:
	var r := road.wrap_s(s)
	var o := road.layout
	var k := o.sector_s.size() - 1
	for j in o.sector_s.size():
		if o.sector_s[j] <= r:
			k = j
	return k


func hash_into(h: int) -> int:
	h = clock.hash_into(h)
	return TraceHash.mix_int(h, section)
