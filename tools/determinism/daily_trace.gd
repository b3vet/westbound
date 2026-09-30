extends SceneTree
## Native side of the cross-platform determinism check (WP8.4, M8 gate; docs/DAILY.md →
## Determinism check): runs DailyTrace's scripted Daily run headless and prints its trace
## (a hash line per simulated second). The web build prints the same lines for
## `?determinism=daily&date=...&seconds=...`; tools/determinism/compare.sh diffs them.
##
##   tools/godot.sh --headless --path . --script res://tools/determinism/daily_trace.gd -- \
##       [--date=2026-09-30] [--seconds=60] [--driver=script|bot] [--detail=<second>] \
##       [--view_m=<m>, 0 = the device's quality tier's] [--replay=1] \
##       [--out=/tmp/native.log]
##
## The game's classes are loaded at run time (a --script main loop compiles before the
## autoloads exist, like tools/verifier/record_sample_replay.gd).

const TRACE_PATH := "res://src/meta/daily/daily_trace.gd"
const TUNING_PATH := "res://src/meta/daily/daily_tuning.gd"
const DEFAULT_DATE := "2026-09-30"
const MSEC_PER_S := 1000.0


func _initialize() -> void:
	_main.call_deferred()


func _main() -> void:
	await process_frame
	var args := _args(OS.get_cmdline_user_args())
	var t: Resource = (load(TUNING_PATH) as GDScript).call(&"resolve")
	var trace: Object = (load(TRACE_PATH) as GDScript).new(t)
	var date := String(args.get("date", DEFAULT_DATE))
	var secs := int(String(args.get("seconds", str(roundi(float(t.get(&"check_seconds")))))))
	trace.set(&"detail_second", int(String(args.get("detail", "0"))))
	if args.has("driver"):
		trace.set(&"driver_kind", StringName(String(args["driver"])))
	trace.set(&"record_replay", String(args.get("replay", "0")) == "1")
	var host := Node.new()
	host.name = "DailyTraceHost"
	root.add_child(host)
	var out_path := String(args.get("out", ""))
	var out: FileAccess = null
	if not out_path.is_empty():
		out = FileAccess.open(out_path, FileAccess.WRITE)
	var t0 := Time.get_ticks_msec()
	trace.call(&"start", host, date, secs, float(String(args.get("view_m", "-1"))))
	var step := int(t.get(&"check_web_ticks_per_step"))
	var done := false
	while not done:
		done = trace.call(&"step_ticks", step)
		for line: String in trace.call(&"take_lines"):
			print(line)
			if out != null:
				out.store_line(line)
				out.flush()
	if out != null:
		out.close()
	printerr("daily_trace: %d s simulated in %.1f s" % [secs, float(Time.get_ticks_msec() - t0) / MSEC_PER_S])
	trace.call(&"finish")
	host.queue_free()
	await process_frame
	quit(0)


static func _args(raw: PackedStringArray) -> Dictionary:
	var out := {}
	for a in raw:
		if a.begins_with("--") and a.contains("="):
			var eq := a.find("=")
			out[a.substr(2, eq - 2)] = a.substr(eq + 1)
	return out
