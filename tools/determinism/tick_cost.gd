extends SceneTree
## Simulation tick cost on the determinism check's run (N8.2, docs/DETERMINISM.md → Cost):
## the scripted Daily run (DailyTrace, car 0, infinite lives), timing only Run.tick() (the
## 120 Hz simulation: the car's physics, forks, traffic and the director, lives and hits,
## scoring, sun, legs, stats), with Run.frame() every 2 ticks outside the timing as the
## game does. Prints the mean and the p50 / p99 per tick over the whole run. The pure
## steps' own costs are the WBBench lines of the fast tier (vehicle, traffic, scoring,
## hit detection, lives).
##
##   tools/godot.sh --headless --path . --script res://tools/determinism/tick_cost.gd -- \
##       [--date=2026-09-30] [--seconds=120] [--driver=script|bot] [--repeat=3]

const TRACE_PATH := "res://src/meta/daily/daily_trace.gd"
const TUNING_PATH := "res://src/meta/daily/daily_tuning.gd"
const DEFAULT_DATE := "2026-09-30"


func _initialize() -> void:
	_main.call_deferred()


func _main() -> void:
	await process_frame
	var args := _args(OS.get_cmdline_user_args())
	var repeat := int(String(args.get("repeat", "3")))
	var secs := int(String(args.get("seconds", "120")))
	var date := String(args.get("date", DEFAULT_DATE))
	var driver := String(args.get("driver", "script"))
	for r in repeat:
		await _once(date, secs, driver)
	quit(0)


func _once(date: String, secs: int, driver: String) -> void:
	var t: Resource = (load(TUNING_PATH) as GDScript).call(&"resolve")
	var trace: Object = (load(TRACE_PATH) as GDScript).new(t)
	trace.set(&"driver_kind", StringName(driver))
	var host := Node.new()
	root.add_child(host)
	trace.call(&"start", host, date, secs, -1.0)
	var run: Node = trace.get(&"run")
	var hz := int(trace.get(&"tick_hz"))
	var n := secs * hz
	var times := PackedInt64Array()
	times.resize(n)
	for i in n:
		var t0 := Time.get_ticks_usec()
		run.call(&"tick")
		times[i] = Time.get_ticks_usec() - t0
		if i % 2 == 1:
			run.call(&"frame", 1.0 / 60.0)
	var sorted := times.duplicate()
	sorted.sort()
	var total := 0
	for x in times:
		total += x
	var line := "tick_cost date=%s driver=%s seconds=%d mean=%.1f p50=%d p99=%d max=%d usec" % [date, driver, secs,
		float(total) / float(n), sorted[n >> 1], sorted[int(n * 0.99)], sorted[n - 1]]
	print(line)
	trace.call(&"finish")
	host.queue_free()
	await process_frame


static func _args(raw: PackedStringArray) -> Dictionary:
	var out := {}
	for a in raw:
		if a.begins_with("--") and a.contains("="):
			var eq := a.find("=")
			out[a.substr(2, eq - 2)] = a.substr(eq + 1)
	return out
