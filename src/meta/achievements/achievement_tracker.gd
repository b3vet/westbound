class_name AchievementTracker
extends RefCounted
# lint: sim
## Achievement progress (WP8.3): what each metric stands at and which achievements it
## unlocks. Spec: Garage and progression (Achievements); Scoring (the scoring events, the
## multiplier, chain and banking); Core loop (legs and checkpoints, leg bonuses, night,
## the journey goal); Run end (the results). docs/ACHIEVEMENTS.md.
##
## Pure and headless: no nodes, no autoloads. AchievementService (src/platform/
## achievements.gd) feeds it the Events bus and the run's results and does the side
## effects (the save, the toast, the haptic tick, the platform mirror). It only listens:
## nothing here reaches gameplay.
##
##   var t := AchievementTracker.new(catalog)
##   t.bind(save_section)                     # unlocked ids and saved progress
##   t.set_profile(level, cars, streak, threads)
##   t.begin_run(mode, legs_count, totals_count)
##   t.on_scored(kind, points, multiplier, clearance_m)   # ... every bus event
##   t.end_run(results)                       # the Events.run_over payload
##   for k in t.pending_count: unlock(t.pending[k])      # then t.clear_pending()
##
## The event handlers run in the run's drain, every frame (multiplier_changed fires most
## frames): they are allocation-free (pre-sized packed arrays; a def list per metric).
## An achievement is queued in `pending` the moment its metric reaches its threshold,
## and marked unlocked at once, so it is queued exactly once.
##
## Metrics and their scope:
##   RUN      best of one run ("10 threads in one run"); the saved value is the best run
##   TOTAL    adds up across finished runs ("100 threads in total"); live in a run
##   PROFILE  the garage's numbers (driver level, cars unlocked, best Daily streak)

enum Metric {
	THREADS_RUN, CLOSE_PASSES_RUN, HAIRLINE_RUN, MULTIPLIER_RUN, CHAIN_RUN, SCORE_RUN,
	TOP_SPEED_RUN, LEG_RUN, COAST_RUN, CLEAN_COAST_RUN, CLEAN_LEGS_RUN, HEAT_LEGS_RUN,
	NIGHTS_RUN, NIGHT_THREADS_RUN,
	THREADS_TOTAL, SET_PIECES_TOTAL, OBJECTIVES_TOTAL, DAILY_RUNS_TOTAL, LOOP_RUNS_TOTAL,
	LEVEL, CARS, DAILY_STREAK,
}
enum Scope { RUN, TOTAL, PROFILE }

## Metric ids (AchievementDef.metric; the save's progress keys), in Metric order.
const METRIC_IDS: Array[StringName] = [
	&"threads_run", &"close_passes_run", &"hairline_run", &"multiplier_run", &"chain_run", &"score_run",
	&"top_speed_run", &"leg_run", &"coast_run", &"clean_coast_run", &"clean_legs_run", &"heat_legs_run",
	&"nights_run", &"night_threads_run",
	&"threads_total", &"set_pieces_total", &"objectives_total", &"daily_runs_total", &"loop_runs_total",
	&"level", &"cars", &"daily_streak",
]
const METRIC_SCOPES: Array[int] = [
	Scope.RUN, Scope.RUN, Scope.RUN, Scope.RUN, Scope.RUN, Scope.RUN,
	Scope.RUN, Scope.RUN, Scope.RUN, Scope.RUN, Scope.RUN, Scope.RUN,
	Scope.RUN, Scope.RUN,
	Scope.TOTAL, Scope.TOTAL, Scope.TOTAL, Scope.TOTAL, Scope.TOTAL,
	Scope.PROFILE, Scope.PROFILE, Scope.PROFILE,
]

## Save section keys (Save.section("achievements")).
const KEY_UNLOCKED := "unlocked"
const KEY_PROGRESS := "progress"

## Score event kinds (Events.PASS ... THREAD).
const KIND_CLOSE_PASS := &"close_pass"
const KIND_THREAD := &"thread"
## Mode ids that count a run of their own (RunContext.MODE_DAILY, Run.MODE_LOOP).
const MODE_DAILY := &"daily"
const MODE_LOOP := &"loop"
## checkpoint_crossed summary keys (RunEvents.SUMMARY_CLEAN, SUMMARY_HEAT).
const SUMMARY_CLEAN := &"clean"
const SUMMARY_HEAT := &"heat"

var catalog: AchievementCatalog
## A run is being tracked (between begin_run and end_run / abort_run).
var active: bool = false
var mode: StringName = &""
## Achievement indices (catalog order) that reached their threshold and were not yet
## handed on: pending[0 .. pending_count).
var pending := PackedInt32Array()
var pending_count: int = 0

## This run's values (RUN: the run's value; TOTAL: the run's share).
var _run := PackedFloat64Array()
## Saved values: RUN the best run, TOTAL the total of finished runs, PROFILE the garage's.
var _best := PackedFloat64Array()
var _threshold := PackedFloat64Array()
var _unlocked := PackedByteArray()
var _by_metric: Array[PackedInt32Array] = []
var _hairline_m: float = 0.0
## The run's road counts legs and the coast (the journey road, not loop sectors).
var _legs_mode: bool = false
## The run counts toward the lifetime totals the garage keeps (its XP modes).
var _totals_mode: bool = false
var _night: bool = false
var _hits: int = 0
var _legs_done: int = 0
var _pieces_open: int = 0
var _piece_hit: bool = false


func _init(achievement_catalog: AchievementCatalog) -> void:
	catalog = achievement_catalog
	var n := METRIC_IDS.size()
	_run.resize(n)
	_best.resize(n)
	_by_metric.resize(n)
	for m in n:
		_by_metric[m] = PackedInt32Array()
	var defs := catalog.achievements.size()
	_threshold.resize(defs)
	_unlocked.resize(defs)
	pending.resize(defs)
	for i in defs:
		var def := catalog.achievements[i]
		_threshold[i] = AchievementCatalog.internal_threshold(def)
		var m := metric_index(def.metric)
		if m >= 0:
			_by_metric[m].append(i)
	_hairline_m = catalog.hairline_clearance_m


## The Metric for an id (-1 when unknown).
static func metric_index(metric_id: StringName) -> int:
	return METRIC_IDS.find(metric_id)


func count() -> int:
	return _threshold.size()


# ---------------------------------------------------------------- Save

## Reads the save section: which achievements are unlocked and the saved progress.
## Forgets any run in progress.
func bind(section: Dictionary) -> void:
	active = false
	_run.fill(0.0)
	_best.fill(0.0)
	_unlocked.fill(0)
	pending_count = 0
	var unlocked := _dict(section, KEY_UNLOCKED)
	for i in count():
		if unlocked.has(String(catalog.achievements[i].id)):
			_unlocked[i] = 1
	var progress := _dict(section, KEY_PROGRESS)
	for m in METRIC_IDS.size():
		var v: Variant = progress.get(String(METRIC_IDS[m]))
		if (v is int or v is float) and is_finite(float(v)):
			_best[m] = maxf(float(v), 0.0)


## Writes the saved progress into the section (run end; allocates).
func write_progress(section: Dictionary) -> void:
	var progress := _dict(section, KEY_PROGRESS)
	if not section.has(KEY_PROGRESS):
		section[KEY_PROGRESS] = progress
	for m in METRIC_IDS.size():
		progress[String(METRIC_IDS[m])] = _best[m]


## The garage's numbers (Garage.profile()): driver level, cars unlocked, best Daily
## streak and lifetime threads. Checks the achievements that read them.
func set_profile(level: int, cars: int, daily_streak: int, threads: int) -> void:
	_best[Metric.LEVEL] = float(level)
	_best[Metric.CARS] = float(cars)
	_best[Metric.DAILY_STREAK] = maxf(_best[Metric.DAILY_STREAK], float(daily_streak))
	_best[Metric.THREADS_TOTAL] = maxf(_best[Metric.THREADS_TOTAL], float(threads))
	for m: int in [Metric.LEVEL, Metric.CARS, Metric.DAILY_STREAK, Metric.THREADS_TOTAL]:
		_check(m)


func is_unlocked(i: int) -> bool:
	return _unlocked[i] != 0


## Checks every achievement against its metric now (a bind, a new catalog).
func evaluate_all() -> void:
	for m in METRIC_IDS.size():
		_check(m)


func clear_pending() -> void:
	pending_count = 0


# ---------------------------------------------------------------- Values

## Metric `m` now: RUN the best run (this one included), TOTAL the total with this run,
## PROFILE the garage's value.
func value(m: int) -> float:
	match METRIC_SCOPES[m]:
		Scope.RUN:
			return maxf(_best[m], _run[m]) if active else _best[m]
		Scope.TOTAL:
			return _best[m] + (_run[m] if active else 0.0)
	return _best[m]


## This run's value of metric `m` (0 outside a run).
func run_value(m: int) -> float:
	return _run[m] if active else 0.0


## Achievement `i`'s metric value and its threshold (tracker units).
func value_of(i: int) -> float:
	var m := metric_index(catalog.achievements[i].metric)
	return value(m) if m >= 0 else 0.0


func threshold_of(i: int) -> float:
	return _threshold[i]


## 0..1 toward achievement `i` (1 once unlocked).
func progress_of(i: int) -> float:
	if is_unlocked(i):
		return 1.0
	var t := _threshold[i]
	if t <= 0.0:
		return 0.0
	return clampf(value_of(i) / t, 0.0, 1.0)


# ---------------------------------------------------------------- Run

## A run starts (Events.run_started). `legs_count`: its road has legs and the coast
## (Journey, Daily Drive); `totals_count`: it counts toward the lifetime threads.
func begin_run(run_mode: StringName, legs_count: bool, totals_count: bool) -> void:
	active = true
	mode = run_mode
	_legs_mode = legs_count
	_totals_mode = totals_count
	_run.fill(0.0)
	_night = false
	_hits = 0
	_legs_done = 0
	_pieces_open = 0
	_piece_hit = false
	if _legs_mode:
		_set_max(Metric.LEG_RUN, 1.0)


## The run was left without results (QUIT, a new run over a live one): its values are
## dropped; what it unlocked stays.
func abort_run() -> void:
	active = false
	_run.fill(0.0)


## The run's results (Events.run_over): top speed, the final score, the leg count, the
## run counters. The run's values then become the saved ones.
func end_run(results: Dictionary) -> void:
	if not active:
		return
	var top_kmh: Variant = results.get(RunStats.TOP_SPEED_KMH, 0.0)
	if (top_kmh is float or top_kmh is int) and is_finite(float(top_kmh)):
		_set_max(Metric.TOP_SPEED_RUN, Units.kmh_to_mps(float(top_kmh)))
	var score: Variant = results.get(RunStats.SCORE, 0)
	if score is int or score is float:
		_set_max(Metric.SCORE_RUN, float(score))
	if _legs_mode:
		var legs: Variant = results.get(RunStats.LEGS_COMPLETED, 0)
		if legs is int or legs is float:
			_set_max(Metric.LEG_RUN, float(legs) + 1.0)
		if bool(results.get(RunStats.COAST_REACHED, false)):
			_set_max(Metric.COAST_RUN, 1.0)
	if mode == MODE_DAILY:
		_add(Metric.DAILY_RUNS_TOTAL, 1.0)
	elif mode == MODE_LOOP:
		_add(Metric.LOOP_RUNS_TOTAL, 1.0)
	for m in METRIC_IDS.size():
		match METRIC_SCOPES[m]:
			Scope.RUN:
				_best[m] = maxf(_best[m], _run[m])
			Scope.TOTAL:
				_best[m] += _run[m]
	active = false
	_run.fill(0.0)


# ---------------------------------------------------------------- Bus events (allocation-free)

func on_scored(kind: StringName, _points: int, multiplier: float, clearance_m: float) -> void:
	if not active:
		return
	if kind == KIND_THREAD:
		_add(Metric.THREADS_RUN, 1.0)
		if _totals_mode:
			_add(Metric.THREADS_TOTAL, 1.0)
		if _night:
			_add(Metric.NIGHT_THREADS_RUN, 1.0)
	elif kind == KIND_CLOSE_PASS:
		_add(Metric.CLOSE_PASSES_RUN, 1.0)
		if clearance_m >= 0.0 and clearance_m <= _hairline_m:
			_add(Metric.HAIRLINE_RUN, 1.0)
	_set_max(Metric.MULTIPLIER_RUN, multiplier)


func on_multiplier_changed(multiplier: float) -> void:
	if active:
		_set_max(Metric.MULTIPLIER_RUN, multiplier)


func on_chain_banked(amount: int, banked_total: int) -> void:
	if not active:
		return
	_set_max(Metric.CHAIN_RUN, float(amount))
	_set_max(Metric.SCORE_RUN, float(banked_total))


func on_bonus_awarded(banked_total: int) -> void:
	if active:
		_set_max(Metric.SCORE_RUN, float(banked_total))


func on_hit() -> void:
	if not active:
		return
	_hits += 1
	if _pieces_open > 0:
		_piece_hit = true


func on_checkpoint_crossed(summary: Dictionary) -> void:
	if not active or not _legs_mode:
		return
	_legs_done += 1
	_set_max(Metric.LEG_RUN, float(_legs_done) + 1.0)
	if bool(summary.get(SUMMARY_CLEAN, false)):
		_add(Metric.CLEAN_LEGS_RUN, 1.0)
	if bool(summary.get(SUMMARY_HEAT, false)):
		_add(Metric.HEAT_LEGS_RUN, 1.0)


func on_coast_reached() -> void:
	if not active or not _legs_mode:
		return
	_set_max(Metric.COAST_RUN, 1.0)
	if _hits == 0:
		_set_max(Metric.CLEAN_COAST_RUN, 1.0)


func on_night_started() -> void:
	if active:
		_night = true


## Dawn ends a night the run drove through from its start: a full night survived.
func on_dawn_started() -> void:
	if not active:
		return
	if _night:
		_add(Metric.NIGHTS_RUN, 1.0)
	_night = false


func on_morning_reached() -> void:
	_night = false


func on_set_piece_started() -> void:
	if not active:
		return
	if _pieces_open == 0:
		_piece_hit = false
	_pieces_open += 1


## A set piece driven through without a hit counts toward the lifetime total.
func on_set_piece_ended() -> void:
	if not active or _pieces_open == 0:
		return
	_pieces_open -= 1
	if not _piece_hit:
		_add(Metric.SET_PIECES_TOTAL, 1.0)
	if _pieces_open == 0:
		_piece_hit = false


func on_objective_completed() -> void:
	if active:
		_add(Metric.OBJECTIVES_TOTAL, 1.0)


# ---------------------------------------------------------------- Internals

func _add(m: int, amount: float) -> void:
	_run[m] += amount
	_check(m)


func _set_max(m: int, v: float) -> void:
	if v > _run[m]:
		_run[m] = v
		_check(m)


func _check(m: int) -> void:
	var v := value(m)
	for i in _by_metric[m]:
		if _unlocked[i] == 0 and v >= _threshold[i]:
			_unlocked[i] = 1
			pending[pending_count] = i
			pending_count += 1


static func _dict(d: Dictionary, key: String) -> Dictionary:
	var v: Variant = d.get(key)
	return v if v is Dictionary else {}
