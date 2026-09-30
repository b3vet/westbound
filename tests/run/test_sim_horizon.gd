extends WBTest
## N8.2: the simulation never reads the quality tier's view distance (docs/QUALITY.md →
## Simulation safety; docs/DETERMINISM.md). The director's spawn distance, the leg
## planner's horizon and the fork candidates read RoadTuning.sim_horizon_m; the tier's
## view distance is rendering only. The same Daily run at the low and the high tier's
## view distance is the same run, bit for bit (WP8.4 measured them differing from second
## 10 before).

const DATE := "2026-09-30"
const SECONDS := 20

var _host: Node
var _trace: DailyTrace


func after_each() -> void:
	if _trace != null:
		_trace.finish()
		_trace = null
	if _host != null:
		_host.free()
		_host = null
	await tree.process_frame


func test_the_horizon_covers_every_tier() -> void:
	var t := Tuning.load_default()
	for v in t.quality.view_distance_m:
		ge(t.road.sim_horizon_m, v, "the spawn distance is past every tier's fog (fairness rule 5)")


## Per-second trace hashes and leg planner horizons of the Daily run at view distance `view_m`.
func _drive(view_m: float) -> Array:
	_host = Node.new()
	tree.root.add_child(_host)
	_trace = DailyTrace.new(DailyTuning.resolve())
	_trace.start(_host, DATE, SECONDS, view_m)
	var run := _trace.run
	near(run.builder.view_distance_m(), view_m, 1e-9, "the builder draws at %.0f m" % view_m)
	near(run.director.fog_end_m, run.tuning.road.sim_horizon_m, 1e-9, "the director spawns at the horizon")
	var hashes := PackedInt64Array()
	var planned := PackedFloat64Array()
	var hz := _trace.tick_hz
	for k in SECONDS * hz:
		run.tick()
		if k % 2 == 1:
			run.frame(1.0 / 60.0)
		if (k + 1) % hz == 0:
			hashes.append(run.trace_hash())
			planned.append(run.legs._planned_to)
	_trace.finish()
	_trace = null
	_host.free()
	_host = null
	await tree.process_frame
	return [hashes, planned]


func test_low_and_high_tier_play_the_same_run() -> void:
	var q := Tuning.load_default().quality
	var low: Array = await _drive(q.view_distance_m[0])
	var high: Array = await _drive(q.view_distance_m[q.view_distance_m.size() - 1])
	eq(low[1], high[1], "the leg planner looks exactly as far ahead")
	var a: PackedInt64Array = low[0]
	var b: PackedInt64Array = high[0]
	eq(a.size(), b.size())
	for i in a.size():
		if a[i] != b[i]:
			fail("the runs differ from second %d (the view distance reached the simulation)" % (i + 1))
			break
