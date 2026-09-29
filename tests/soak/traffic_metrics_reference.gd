class_name TrafficMetricsReference
extends RefCounted
## The fixed-seed reference behind the logged traffic metrics (spec: Traffic → Tests
## (headless): "Logged metrics per build ... A regression beyond ±15% on any of them
## fails the test"; plan §6: the metrics regression runs in the soak tier). Baseline:
## tests/baselines/traffic_metrics.json, rewritten only deliberately with
## `tools/soak.sh --update-baseline`. See docs/SOAK.md.
##
## "reference": REFERENCE_RUNS soak runs on the 3-lane procedural road, legs 1-8 of
## REFERENCE_LEG_M each, metrics summed over all of them. One run is chaotic (its lane
## changes per vehicle-minute vary ~17% from seed to seed); the sum of 16 brings that
## to ~4-5%, so ±15% flags real changes, not butterfly effects.
## "fast": one short run (fast tier: the pipeline and plausible values, no ±15% check).
## Both skip the impossible-window oracle (it does not change the traffic).

const SEED := 3303
const REFERENCE_RUNS := 16
const REFERENCE_LEG_M := 1500.0
const FAST_LEG_M := 400.0
const LANES := 3
const BASELINE_PATH := "res://tests/baselines/traffic_metrics.json"


static func names() -> PackedStringArray:
	return PackedStringArray(["reference"])


## Runs a reference and returns {"config": {...}, "metrics": {...}, "traces": [int]}.
static func run(which: String) -> Dictionary:
	var base := Tuning.load_default()
	var t: Tuning = base.duplicate()
	t.traffic = base.traffic.duplicate() as TrafficTuning
	t.traffic.soak_lane_counts = PackedInt32Array([LANES])
	var n := REFERENCE_RUNS if which == "reference" else 1
	var leg_m := REFERENCE_LEG_M if which == "reference" else FAST_LEG_M
	var total := TrafficMetrics.new(t)
	var traces: Array[int] = []
	var km := 0.0
	var sim_s := 0.0
	for k in n:
		var r := TrafficSoakRun.new(k, SEED, -1, leg_m, t)
		r.check_windows = false
		r.run_to_end()
		total.merge(r.metrics)
		traces.append(r.trace)
		km += r.bot.state.s / Units.M_PER_KM
		sim_s += r.time
	return {
		"config": {"seed": SEED, "runs": n, "lanes": LANES, "legs": t.traffic.soak_run_legs, "leg_m": leg_m,
			"km": km, "sim_s": sim_s},
		"metrics": total.to_dict(),
		"traces": traces,
	}


## The committed baseline ({} when missing or unreadable).
static func load_baseline() -> Dictionary:
	if not FileAccess.file_exists(BASELINE_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(BASELINE_PATH))
	return parsed as Dictionary if parsed is Dictionary else {}
