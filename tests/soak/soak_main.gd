extends SceneTree
## One shard of the traffic soak (spec: Traffic → Tests (headless), 10,000 simulated
## km). tools/soak.sh starts one process per shard and merges their JSON. See
## docs/SOAK.md.
##
##   godot --headless --path . --script res://tests/soak/soak_main.gd -- \
##       --shard=0 --shards=4 --km=10000 [--seed=N] [--legs=8] [--leg-km=3.5] \
##       [--out=tests/out/soak/shard_0.json] [--no-windows]
##   godot ... -- --metrics=fast|reference --out=FILE     # a metrics reference run only
##
## Runs are numbered 0..ceil(km / run_km)-1; shard i runs every r with
## (r + r / N) % N == i: round robin, rotated by one every N runs, so the lane-count
## cycle of the runs (TrafficTuning.soak_lane_counts) spreads over the shards instead of
## giving one shard every 4-lane run. Each run is seeded by its index alone
## (TrafficSoakRun), so any sharding gives the same per-run traces. The JSON is rewritten after every run (partial results survive a
## kill), and a progress line is printed every PROGRESS_S of wall time.

const DEFAULT_SEED := 20260928
const PROGRESS_S := 60.0

## Engine errors while the soak runs (a runtime error would otherwise go unnoticed).
class ErrorCapture extends Logger:
	var _mutex := Mutex.new()
	var messages := PackedStringArray()

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		_mutex.lock()
		if messages.size() < 20:
			messages.append("%s (%s:%d %s)" % [rationale if not rationale.is_empty() else code, file.get_file(), line, function])
		_mutex.unlock()


var _errors := ErrorCapture.new()


func _initialize() -> void:
	_main.call_deferred()


func _main() -> void:
	OS.add_logger(_errors)
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "true"
	if args.has("metrics"):
		quit(_metrics(String(args["metrics"]), String(args.get("out", ""))))
		return
	var shard := int(args.get("shard", "0"))
	var shards := maxi(1, int(args.get("shards", "1")))
	var t := Tuning.load_default()
	var km := float(args.get("km", str(t.traffic.soak_distance_km)))
	var base_seed := int(args.get("seed", str(DEFAULT_SEED)))
	var legs := int(args.get("legs", str(t.traffic.soak_run_legs)))
	var leg_m := float(args.get("leg-km", str(t.legs.leg_length_km))) * Units.M_PER_KM
	var out_path := String(args.get("out", "res://tests/out/soak/shard_%d.json" % shard))
	var windows := not args.has("no-windows")
	var run_km := leg_m * float(legs) / Units.M_PER_KM
	var n_runs := ceili(km / run_km - 1e-9)
	var runs: Array[Dictionary] = []
	var t0 := Time.get_ticks_msec()
	var last_print := t0
	var done_km := 0.0
	var mine := PackedInt32Array()
	for k in n_runs:
		if (k + floori(float(k) / float(shards))) % shards == shard:
			mine.append(k)
	print("soak shard %d/%d: runs %d of %d (%.1f km each), seed %d" % [shard, shards, mine.size(), n_runs, run_km,
		base_seed])
	for r in mine:
		var run := TrafficSoakRun.new(r, base_seed, legs, leg_m)
		run.check_windows = windows
		while not run.finished:
			run.advance(60.0)
			var now := Time.get_ticks_msec()
			if now - last_print >= PROGRESS_S * 1000.0:
				last_print = now
				var km_now := done_km + run.bot.state.s / Units.M_PER_KM
				print("  shard %d: %.0f km, run %d leg %d, %.0f s wall, %.1f km/wall-min, violations %d, impossible %d" % [
					shard, km_now, r, run.leg, (now - t0) / 1000.0, km_now / maxf((now - t0) / 60000.0, 1e-9),
					run.checker.total_violations(), run.impossible_windows])
		var res := run.result()
		done_km += float(res["km"])
		runs.append(res)
		_write(out_path, shard, shards, base_seed, legs, leg_m, windows, runs, Time.get_ticks_msec() - t0)
	print("soak shard %d done: %d runs, %.1f km, %.0f s wall, %d engine errors" % [shard, runs.size(), done_km,
		(Time.get_ticks_msec() - t0) / 1000.0, _errors.messages.size()])
	_write(out_path, shard, shards, base_seed, legs, leg_m, windows, runs, Time.get_ticks_msec() - t0)
	quit(0 if _errors.messages.is_empty() else 1)


func _write(path: String, shard: int, shards: int, base_seed: int, legs: int, leg_m: float, windows: bool,
		runs: Array[Dictionary], wall_ms: int) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path).get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		printerr("soak: cannot write %s" % path)
		return
	f.store_string(JSON.stringify({
		"shard": shard, "shards": shards, "seed": base_seed, "legs": legs, "leg_m": leg_m, "windows": windows,
		"wall_s": wall_ms / 1000.0, "engine_errors": Array(_errors.messages), "runs": runs,
	}, "  "))
	f.close()


## Metrics reference runs (TrafficMetricsReference) into `out` as JSON.
func _metrics(which: String, out: String) -> int:
	var cfgs := TrafficMetricsReference.names() if which == "all" else PackedStringArray([which])
	var doc := {}
	for n in cfgs:
		var t0 := Time.get_ticks_msec()
		doc[n] = TrafficMetricsReference.run(n)
		print("metrics %s: %s (%.0f s)" % [n, JSON.stringify(doc[n]["metrics"]), (Time.get_ticks_msec() - t0) / 1000.0])
	if out.is_empty():
		return 0
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out).get_base_dir())
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		printerr("soak: cannot write %s" % out)
		return 1
	f.store_string(JSON.stringify(doc, "  ", true))
	f.close()
	return 0 if _errors.messages.is_empty() else 1
