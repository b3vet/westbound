extends SceneTree
## One shard of the traffic soak (spec: Traffic → Tests (headless), 10,000 simulated
## km). tools/soak.sh starts one process per shard and merges their JSON. See
## docs/SOAK.md.
##
##   godot --headless --path . --script res://tests/soak/soak_main.gd -- \
##       --shard=0 --shards=4 --km=10000 [--seed=N] [--legs=8] [--leg-km=3.5] \
##       [--out=tests/out/soak/shard_0.json] [--no-windows] [--all-pieces] [--canyon] [--runs=I,J,...]
##   --runs: exactly these run indices (resume an interrupted soak into another
##   shard_N.json in the same directory, then `tools/soak.sh --merge --out=DIR`)
##   godot ... -- --metrics=fast|reference --out=FILE     # a metrics reference run only
##   godot ... -- --density [--lanes=3,4] [--legs=1,...,8] [--profile=scripted|bot|soak] [--seeds=3]
##       [--run-legs=2] [--out=FILE]                   # the D11 density survey (DensitySurvey)
##       [--cap=N] [--density-last=X] [--headway-last=X] [--before] [--gain-min=X] [--gain-max=X]
##       [--weights=PCT,...] [--flows=KMH,...] [--gain-rate=X]   # what-ifs
##       [--racer=FIRST,LAST] [--aggressive=FIRST,LAST] [--jitter=PCT] [--tolerance=KMH] [--lookahead=M]
##       [--set=profile.field=X;...]                  # fast-traffic what-ifs (plan D15)
##       [--breather=PCT] [--peak=PCT]                # wave density what-ifs (plan D17)
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
	if args.has("density"):
		quit(_density(args))
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
	if args.has("runs"):
		# Explicit run indices (resuming an interrupted soak into extra shard files).
		for x in String(args["runs"]).split(","):
			mine.append(int(x))
	else:
		for k in n_runs:
			if (k + floori(float(k) / float(shards))) % shards == shard:
				mine.append(k)
	print("soak shard %d/%d: runs %d of %d (%.1f km each), seed %d" % [shard, shards, mine.size(), n_runs, run_km,
		base_seed])
	# --canyon: every run on the canyon's road (curves, crests, tunnels and their lane drops).
	var biome: BiomeDef = BiomePlan.load_biome(&"canyon") if args.has("canyon") else null
	for r in mine:
		var run := TrafficSoakRun.new(r, base_seed, legs, leg_m, null, 0, biome, args.has("all-pieces"),
			TrafficSoakRun.BOT_PASSABILITY)
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


## The D11 density survey (DensitySurvey): one line per (lanes, leg) cell, JSON to `out`.
func _density(args: Dictionary) -> int:
	var lane_counts: Array[int] = []
	for x in String(args.get("lanes", "3,4")).split(","):
		lane_counts.append(int(x))
	var legs: Array[int] = []
	for x in String(args.get("legs", "1,2,3,4,5,6,7,8")).split(","):
		legs.append(int(x))
	var profile := StringName(String(args.get("profile", String(DensitySurvey.SCRIPTED))))
	var seeds := int(args.get("seeds", "3"))
	var run_legs := int(args.get("run-legs", "2"))
	# Overrides for exploring numbers (tuning stays the source of truth).
	var base := Tuning.load_default()
	var t: Tuning = base.duplicate()
	t.traffic = base.traffic.duplicate() as TrafficTuning
	t.director = base.director.duplicate() as DirectorTuning
	if args.has("cap"):
		t.traffic.max_active_vehicles = int(args["cap"])
	if args.has("density-last"):
		t.director.density_last_per_km_lane = float(args["density-last"])
	if args.has("before"):
		# The WP3.3 director (plan D11 "before"): no gain, no top-up, the spec's ramp and cap.
		t.director.density_gain_min = 1.0
		t.director.density_gain_max = 1.0
		t.director.density_topup_max_per_batch = 0
		t.director.headway_scale_last = 1.0
		t.director.density_last_per_km_lane = 16.0
		t.traffic.max_active_vehicles = 60
	if args.has("headway-last"):
		t.director.headway_scale_last = float(args["headway-last"])
	if args.has("weights"):
		var w := PackedFloat64Array()
		for x in String(args["weights"]).split(","):
			w.append(float(x))
		t.traffic.spawn_profile_weights_pct = w
	if args.has("flows"):
		var fl := PackedFloat64Array()
		for x in String(args["flows"]).split(","):
			fl.append(float(x))
		t.traffic.lane_flow_speeds_from_right_kmh = fl
	if args.has("gain-min"):
		t.director.density_gain_min = float(args["gain-min"])
	if args.has("gain-max"):
		t.director.density_gain_max = float(args["gain-max"])
	if args.has("gain-rate"):
		t.director.density_gain_rate_per_s = float(args["gain-rate"])
	if args.has("set-pieces"):
		t.director.set_piece_chance_first_pct = float(args["set-pieces"])
		t.director.set_piece_chance_last_pct = float(args["set-pieces"])
	# Fast traffic (plan D15, WP6.6).
	if args.has("racer"):
		var r := String(args["racer"]).split(",")
		t.director.racer_share_first_pct = float(r[0])
		t.director.racer_share_last_pct = float(r[r.size() - 1])
	if args.has("aggressive"):
		var g := String(args["aggressive"]).split(",")
		t.director.aggressive_share_first_pct = float(g[0])
		t.director.aggressive_share_last_pct = float(g[g.size() - 1])
	if args.has("jitter"):
		t.traffic.spawn_v0_jitter_pct = float(args["jitter"])
	if args.has("breather"):
		t.director.wave_breather_density_pct = float(args["breather"])
	if args.has("peak"):
		t.director.wave_peak_density_pct = float(args["peak"])
	if args.has("fill"):
		t.director.wave_fill_min_mult = float(args["fill"])
	if args.has("lookahead"):
		t.traffic.idm_lookahead_m = float(args["lookahead"])
	if args.has("tolerance"):
		t.traffic.spawn_lane_speed_tolerance_kmh = float(args["tolerance"])
	var held: Array[Resource] = []   # keeps the edited profiles cached for the registry
	if args.has("set"):
		for item in String(args["set"]).split(";", false):
			var kv := item.split("=")
			var path := kv[0].split(".")
			var prof := load(TrafficRegistry.PROFILE_DIR + path[0] + ".tres") as DriverProfile
			var old: Variant = prof.get(path[1])
			if typeof(old) == TYPE_INT:
				prof.set(path[1], int(kv[1]))
			else:
				prof.set(path[1], float(kv[1]))
			held.append(prof)
			print("set %s.%s = %s (was %s)" % [path[0], path[1], kv[1], str(old)])
	var rows: Array[Dictionary] = []
	var t0 := Time.get_ticks_msec()
	for lanes in lane_counts:
		for leg in legs:
			var row := DensitySurvey.cell(lanes, leg, profile, seeds, run_legs, t)
			rows.append(row)
			print(DensitySurvey.format_row(row))
	print("density survey: %d cells, %.0f s" % [rows.size(), (Time.get_ticks_msec() - t0) / 1000.0])
	var out := String(args.get("out", ""))
	if not out.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out).get_base_dir())
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(rows, "  "))
			f.close()
	return 0 if _errors.messages.is_empty() else 1
