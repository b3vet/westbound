class_name DevStats
extends RefCounted
## Static registry of dev-HUD numbers. Spec: Tech stack → Testing (dev HUD) and
## Performance budget.
##
## Systems report values here without knowing the HUD exists:
##   DevStats.report(DevStats.VEHICLES, active_count)
##   DevStats.report_sim_tick_usec(Time.get_ticks_usec() - t0)
## The dev HUD (src/ui/dev_hud.gd) reads them a few times per second.
##
## Reporting allocates nothing: values go into one Dictionary under fixed
## StringName keys (a key's slot is created once, on its first report) and sim
## tick times into a ring buffer sized once at class load.

const VEHICLES := &"vehicles"
const THERMAL := &"thermal"
const QUALITY_TIER := &"quality_tier"
const GOVERNOR_RUNG := &"governor_rung"
const MAX_FPS := &"max_fps"
const DRAW_CALL_BUDGET := &"draw_call_budget"
const TRIANGLE_BUDGET := &"triangle_budget"

static var _values: Dictionary = {}
## Ring buffer of the last `sim_tick_window()` tick times (one second of ticks).
static var _tick_usec: PackedInt64Array = PackedInt64Array()
static var _tick_next: int = 0
static var _tick_count: int = 0
static var _tick_sum_usec: int = 0


static func _static_init() -> void:
	_tick_usec.resize(maxi(Engine.physics_ticks_per_second, 1))


## Store `value` under `key` (overwrites).
static func report(key: StringName, value: Variant) -> void:
	_values[key] = value


static func get_value(key: StringName, default: Variant = null) -> Variant:
	return _values.get(key, default)


static func has_value(key: StringName) -> bool:
	return _values.has(key)


## Record one simulation tick's cost. Keeps a rolling window of one second.
static func report_sim_tick_usec(usec: int) -> void:
	var n := _tick_usec.size()
	if _tick_count == n:
		_tick_sum_usec -= _tick_usec[_tick_next]
	else:
		_tick_count += 1
	_tick_usec[_tick_next] = usec
	_tick_sum_usec += usec
	_tick_next = (_tick_next + 1) % n


## Number of samples in the rolling sim-tick window.
static func sim_tick_window() -> int:
	return _tick_usec.size()


static func sim_tick_sample_count() -> int:
	return _tick_count


## Rolling average of the reported sim tick times, in microseconds (0 if none).
static func get_sim_tick_avg_usec() -> float:
	if _tick_count == 0:
		return 0.0
	return float(_tick_sum_usec) / float(_tick_count)


## Worst sim tick in the rolling window, in microseconds (0 if none).
static func get_sim_tick_max_usec() -> int:
	var worst := 0
	for i in _tick_count:
		worst = maxi(worst, _tick_usec[i])
	return worst


## Forget everything (tests, new runs).
static func reset() -> void:
	_values.clear()
	_tick_usec.fill(0)
	_tick_next = 0
	_tick_count = 0
	_tick_sum_usec = 0
