extends WBTest
## The traffic soak (spec: Traffic → Tests (headless): "10,000 simulated km with a bot
## driver produce zero impossible windows and zero traffic-to-traffic collisions";
## "zero lane changes shorter than the minimum signal time, and zero no-ambush
## violations"; determinism "the same seed gives an identical traffic trace (hash of
## all vehicle states every second)"; Lives → rear-end prevention). The full 10,000 km
## runs sharded with tools/soak.sh (docs/SOAK.md); here: a tiny version (fast tier),
## a short one (soak tier) and the determinism of runs across shards.

const SEED := 3303


## Gate counters of a run result (TrafficSoakRun.result()) must all be 0.
const GATES: Array[String] = [
	"collision_pairs", "signal_violations", "unsignaled_moves", "ambush_violations", "decel_violations",
	"brake_flag_violations", "rear_end_normal", "impossible_traffic",
]


func _gate(res: Dictionary, label: String) -> void:
	print("      %s: %d lanes, %.1f km, %.0f s, peak %d | signals %d moves %d | collisions %d signal %d unsignaled %d ambush %d decel %d brake %d | contacts %d (rear-end %d, normal %d) | windows %d checks, impossible %d (player-induced %d)" % [
		label, res["lanes"], res["km"], res["sim_s"], res["peak_active"], res["signals"], res["moves"],
		res["collision_pairs"], res["signal_violations"], res["unsignaled_moves"], res["ambush_violations"],
		res["decel_violations"], res["brake_flag_violations"], res["contact_episodes"], res["rear_end_episodes"],
		res["rear_end_normal"], res["window_checks"], res["impossible_windows"], res["impossible_player_induced"]])
	for k in GATES:
		eq(int(res[k]), 0, "%s: %s" % [label, k])
	for m: String in res["messages"]:
		print("        ", m)
	for w: Dictionary in res["window_examples"]:
		print("        window ", JSON.stringify(w))
	check(bool(res["finished"]), "%s finished its distance" % label)
	gt(int(res["spawned_ahead"]), 10, "%s: traffic spawned" % label)
	gt(int(res["window_checks"]), 0, "%s: impossible-window checks ran" % label)


func test_tiny_soak_leg8_dense() -> void:
	# Leg-8 density, 2 x 600 m, with every check (fast tier).
	var r := TrafficSoakRun.new(0, SEED, 2, 600.0, null, 8)
	r.run_to_end()
	_gate(r.result(), "tiny leg 8")


func _trace_of(runs: PackedInt32Array, base_seed: int) -> PackedInt64Array:
	var out := PackedInt64Array()
	for k in runs:
		var r := TrafficSoakRun.new(k, base_seed, 2, 300.0)
		r.check_windows = false
		r.run_to_end()
		gt(r.time, 5.0, "the trace covers several seconds")
		out.append(r.trace)
	return out


func test_trace_is_deterministic_across_runs_and_shards() -> void:
	# Shard 0 of 1 runs 0 then 1; shard 1 of 2 runs only 1; a second process-like
	# repeat of both: run 1's trace (both carriageways + the player, every second) is
	# identical whatever ran before it.
	var one_shard := _trace_of(PackedInt32Array([0, 1]), SEED)
	var two_shards := _trace_of(PackedInt32Array([1]), SEED)
	var again := _trace_of(PackedInt32Array([0, 1]), SEED)
	eq(one_shard[1], two_shards[0], "run 1 alone == run 1 after run 0")
	eq(one_shard, again, "two runs of the same seeds")
	ne(one_shard[0], one_shard[1], "different runs differ")
	var other := _trace_of(PackedInt32Array([1]), SEED + 1)
	ne(other[0], one_shard[1], "a different base seed differs")


func soak_short_soak_every_lane_count() -> void:
	# One run per soak lane count (3, 3, 2, 4), legs 1-8 of 1 km: every rule, per tick.
	var t := Tuning.load_default()
	for k in t.traffic.soak_lane_counts.size():
		var r := TrafficSoakRun.new(k, SEED, -1, 1000.0)
		r.run_to_end()
		_gate(r.result(), "run %d" % k)
