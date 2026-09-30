extends WBTest
## The governor through a real Run (M9 gate: "the governor steps down and back up under a
## forced thermal state"), and simulation safety: a governor stepping mid-run through all
## four rungs and back changes nothing in the run's trace. Since N8.2 the view-distance
## rung applies live (the simulation reads RoadTuning.sim_horizon_m, never the view
## distance); the WP9.1 hold (governor_view_distance_between_runs) still works when on. Spec: Performance budget →
## Adaptive governor; Architecture rule 2 (same seed + same inputs = same run). WP9.1,
## docs/QUALITY.md → Simulation safety.
##
## The run is DailyTrace's scripted Daily run (the real Run scene, manual ticks, open-loop
## inputs) with the device's view distance (not pinned), so a view-distance change would
## reach the simulation as it does in the game. The `Quality` autoload's governor gets short
## timings (the rules are timed in tests/platform/test_governor.gd) and a forced thermal
## script; frames come every 2 ticks (60 fps), every 4 at the 30 fps rung.

const DATE := "2026-09-30"
const SECONDS := 30
const THERMAL_SCRIPT := "serious:9,nominal"
const TICKS_60 := 2
const TICKS_30 := 4

static var _base: PackedInt64Array = PackedInt64Array()
static var _base_ticks: int = 0
## The leg planner's horizon (LegTracker._planned_to) per second of the base run: how far
## ahead checkpoints are queued (the queue is part of the trace hash).
static var _base_planned: PackedFloat64Array = PackedFloat64Array()
static var _hold_default: bool = false

var _host: Node
var _trace: DailyTrace
var _rungs: Array[int] = []


func before_all() -> void:
	_hold_default = (Quality.tuning as QualityTuning).governor_view_distance_between_runs
	_base_ticks = Engine.physics_ticks_per_second
	Settings.reset_to_defaults()
	_restore_quality()
	if _base.is_empty():
		_base = _drive(false)
		_base_planned = _planned.duplicate()


func after_each() -> void:
	_restore_quality()
	(Quality.tuning as QualityTuning).governor_view_distance_between_runs = _hold_default
	if _trace != null:
		_trace.finish()
		_trace = null
	if _host != null:
		_host.free()
		_host = null
	_reset_time()
	await tree.process_frame


func _restore_quality() -> void:
	Quality.thermal.clear_force()
	Quality.governor.configure(Quality.tuning)
	Quality.set_governor_rung(0)


func _fast() -> QualityTuning:
	var f := (Quality.tuning as QualityTuning).duplicate() as QualityTuning
	f.governor_window_s = 1.0
	f.governor_step_down_interval_s = 2.0
	f.governor_step_up_after_s = 3.0
	f.governor_relapse_window_s = 1.0
	return f


func _on_governor_changed(rung: int) -> void:
	_rungs.append(rung)


## Per-second trace hashes of the run; with `govern`, the governor runs every frame under
## the forced thermal script. Records the rungs in _rungs.
func _drive(govern: bool) -> PackedInt64Array:
	_host = Node.new()
	tree.root.add_child(_host)
	_trace = DailyTrace.new(DailyTuning.resolve())
	_trace.start(_host, DATE, SECONDS, 0.0)   # 0: the device's view distance, not pinned
	var run := _trace.run
	var hz := _trace.tick_hz
	if govern:
		Quality.governor.configure(_fast())
		check(Quality.thermal.apply_override(THERMAL_SCRIPT))
		_rungs.clear()
		Events.governor_changed.connect(_on_governor_changed)
	var out := PackedInt64Array()
	_planned.clear()
	var since_frame := 0
	for k in SECONDS * hz:
		run.tick()
		since_frame += 1
		var every := TICKS_30 if Quality.max_fps <= 30 else TICKS_60
		if since_frame >= every:
			var frame_s := float(since_frame) / float(hz)
			since_frame = 0
			run.frame(frame_s)
			if govern:
				Quality.step_governor(frame_s)
				_watch(run)
		if (k + 1) % hz == 0:
			out.append(run.trace_hash())
			_planned.append(run.legs._planned_to)
	if govern:
		Events.governor_changed.disconnect(_on_governor_changed)
	_trace = null
	# Freed now (not queued): a slow motion the run started ends with it (TimeScale
	# restores the tick rate on exit), before the next run reads the base tick rate.
	_host.free()
	_host = null
	_reset_time()
	return out


func _reset_time() -> void:
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = _base_ticks


var _planned: PackedFloat64Array = PackedFloat64Array()
var _views: PackedFloat64Array = PackedFloat64Array()
var _builder_views: PackedFloat64Array = PackedFloat64Array()
var _cooling_seen: bool = false


func _watch(run: Run) -> void:
	_views.append(Quality.view_distance_m)
	_builder_views.append(run.builder.view_distance_m())
	_cooling_seen = _cooling_seen or Quality.is_cooling()


## N8.2 (the default: no hold): the view-distance rung applies mid-run (the builder
## follows it), and the run's trace and its leg planner horizon are exactly an ungoverned
## run's.
func test_forced_thermal_steps_down_and_back_up_without_changing_the_run() -> void:
	(Quality.tuning as QualityTuning).governor_view_distance_between_runs = false
	_views.clear()
	_builder_views.clear()
	_cooling_seen = false
	var governed := _drive(true)
	eq(_rungs, [1, 2, 3, 4, 3, 2, 1, 0] as Array[int], "all four rungs down, then back to the tier")
	check(_cooling_seen, "the cooling icon showed")
	eq(Quality.governor_rung, 0)
	_check_same_run(governed)
	var lo := _builder_views[0]
	for v in _builder_views:
		lo = minf(lo, v)
	near(lo, _builder_views[0] - (Quality.tuning as QualityTuning).governor_view_distance_step_m, 1e-9,
		"the builder followed the rung mid-run (rendering only)")


## The WP9.1 hold, switched on: the view distance stays put through the run, and the run
## is again the ungoverned one.
func test_the_hold_still_holds_the_view_through_a_run() -> void:
	(Quality.tuning as QualityTuning).governor_view_distance_between_runs = true
	_views.clear()
	_builder_views.clear()
	var governed := _drive(true)
	_check_same_run(governed)
	near(_views[_views.size() - 1], _views[0], 1e-9, "Quality's view distance held through the run")
	for v in _builder_views:
		if not is_equal_approx(v, _builder_views[0]):
			fail("the road builder's view distance changed mid-run: %.1f" % v)
			break


func _check_same_run(governed: PackedInt64Array) -> void:
	eq(governed.size(), _base.size())
	for i in _base.size():
		if governed[i] != _base[i]:
			fail("the run's trace changed at second %d (a governor step reached the simulation)" % (i + 1))
			break
	eq(_planned, _base_planned, "the leg planner looked exactly as far ahead")
