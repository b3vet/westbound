class_name Tuning
extends Resource
## Root of every gameplay constant. Spec: Architecture rule 3 ("all constants in data");
## plan deviation D3 (one sub-resource per system, each in its own file).
##
## data/tuning.tres (this, orchestrator-owned) references data/tuning/<system>.tres
## (owned by the WP that owns the system). Fields hold the spec's numbers in the
## spec's units with unit suffixes; convert with Units or the per-class helpers.
##
##   var t := Tuning.load_default()
##   var min_v := t.scoring.min_speed_mps()
##
## Pure sims never call load_default() themselves: they get their params from the
## caller (usually RunContext.tuning), so tests can pass modified copies.

const DEFAULT_PATH := "res://data/tuning.tres"

@export var quality: QualityTuning
@export var road: RoadTuning
@export var vehicle: VehicleTuning
@export var controls: ControlsTuning
@export var camera: CameraTuning
@export var traffic: TrafficTuning
@export var director: DirectorTuning
@export var passability: PassabilityTuning
@export var scoring: ScoringTuning
@export var lives: LivesTuning
@export var sun: SunTuning
@export var legs: LegsTuning
@export var feel: FeelTuning
@export var hud: HudTuning
@export var progression: ProgressionTuning
## Traffic rendering (WP3.1; visual only).
@export var traffic_view: TrafficViewTuning
## Crash cinematic (WP4.2; visual only).
@export var crash: CrashTuning
## Checkpoint landmarks and warning signs (WP5.3; visual only).
@export var landmarks: LandmarkTuning
## Night lighting: headlight cones, high beams, lamp pools (WP5.4; visual only).
@export var night: NightTuning
## Multiplayer client: keepalive, clock sync, server URL (N2.2).
@export var net: NetTuning
## Loop practice mode on loop_v1: room clock, sectors, per-section traffic (N3.2).
@export var loop: LoopTuning

static var _default: Tuning


## The shared tuning loaded from DEFAULT_PATH (cached after the first call).
## Treat it as read-only; tests that tweak values should work on duplicate(true).
static func load_default() -> Tuning:
	if _default == null:
		_default = load(DEFAULT_PATH) as Tuning
		assert(_default != null, "Tuning: cannot load %s" % DEFAULT_PATH)
	return _default


## Names of sub-resources that are missing (empty when complete).
func missing_sections() -> PackedStringArray:
	var out := PackedStringArray()
	for section: String in section_names():
		if get(section) == null:
			out.append(section)
	return out


static func section_names() -> PackedStringArray:
	return PackedStringArray([
		"quality", "road", "vehicle", "controls", "camera", "traffic", "director",
		"passability", "scoring", "lives", "sun", "legs", "feel", "hud", "progression", "traffic_view", "crash", "landmarks", "night", "net", "loop",
	])
