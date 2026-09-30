class_name RunContext
extends RefCounted
## Per-run determinism context. Spec: Architecture rule 2 (one run seed derives
## per-subsystem RNGs: road, traffic, props, events); Modes at launch (Journey,
## Daily Drive).
##
## Created once per run by run.gd and handed to every seeded system. Streams are
## derived by name from the run seed (Rng.derive), so draws in one subsystem never
## shift another. A system that needs more independent streams derives them from its
## own stream (e.g. `ctx.rng_traffic.derive(&"passability")`), never from global RNG.

const MODE_JOURNEY := &"journey"
const MODE_DAILY := &"daily"

var run_seed: int
var mode: StringName
var tuning: Tuning

var rng_road: Rng
var rng_traffic: Rng
var rng_props: Rng
var rng_events: Rng


## `run_tuning` defaults to Tuning.load_default().
func _init(seed_value: int, run_mode: StringName = MODE_JOURNEY, run_tuning: Tuning = null) -> void:
	run_seed = seed_value
	mode = run_mode
	tuning = run_tuning if run_tuning != null else Tuning.load_default()
	var root := Rng.new(run_seed)
	rng_road = root.derive(Rng.STREAM_ROAD)
	rng_traffic = root.derive(Rng.STREAM_TRAFFIC)
	rng_props = root.derive(Rng.STREAM_PROPS)
	rng_events = root.derive(Rng.STREAM_EVENTS)


## Daily Drive context: the seed comes from the UTC date, identical for everyone.
static func daily(year: int, month: int, day: int, run_tuning: Tuning = null) -> RunContext:
	return RunContext.new(Rng.daily_seed(year, month, day), MODE_DAILY, run_tuning)
