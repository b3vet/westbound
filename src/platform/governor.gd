class_name Governor
extends RefCounted
## Adaptive governor (WP9.1). Spec: Performance budget → Adaptive governor ("If the device
## reports serious thermal state, or more than 10% of frames miss vsync over a 10-second
## window, the governor steps down one rung every 10 seconds ... It steps back up one rung
## after 60 seconds of nominal state, and never above the tier the user picked"). The
## rungs themselves are applied by Quality.compute(). docs/QUALITY.md → Governor.
##
## Pure: frame times, the target frame time and the thermal level in, a rung out. The
## `Quality` autoload feeds it once per frame and applies the rung; nothing here reads the
## clock, the scene or the simulation, so the same inputs give the same rungs (tests drive
## it with synthetic frames). Allocation-free per tick: the frame window is a ring buffer
## and a frame-time histogram, both sized in configure().
##
##   var g := Governor.new()
##   g.configure(quality_tuning)
##   if g.tick(frame_s, target_frame_s, thermal_level, in_gameplay):
##       quality.set_governor_rung(g.rung)
##
## Rules (timings from QualityTuning.governor_*):
##   - Pressure: the thermal level is serious or critical, or (while sampling) the window
##     holds governor_window_s of frames and more than governor_miss_frac of them missed
##     vsync (took longer than governor_miss_factor target frame intervals).
##   - Under pressure: one rung down, at most one per governor_step_down_interval_s since
##     the last change (the first one can come at once).
##   - Calm: thermal nominal and a full window with at most governor_up_miss_frac misses.
##     After the up wait (governor_step_up_after_s) of unbroken calm: one rung up.
##     Anything between (thermal fair, misses in the band): hold, and the calm time
##     restarts. Hysteresis: the band, the 10 s / 60 s asymmetry, and the backoff below.
##   - Backoff: a step down within governor_relapse_window_s of a step up multiplies the
##     up wait by governor_up_backoff_factor (up to governor_step_up_max_s); a relapse
##     window without one resets it.
##   - Not sampling (menus, pause, loading): frames are ignored and the calm time holds;
##     thermal pressure still steps down. Sampling restarts with an empty window.
##   - Rungs that change nothing for the current tier (set_useful) are skipped both ways.
##   - The rung is an offset below the user's tier: 0 is the tier itself, so the governor
##     can never go above it.
# lint: sim

enum Reason { NONE, FRAMES, THERMAL }
## What the governor sees now (dev HUD): not sampling, calm (counting toward a step up),
## holding (the hysteresis band, thermal fair, or the window still filling), or pressure.
enum Pressure { IDLE, CALM, HOLD, FRAMES, THERMAL }

const RUNG_NONE := 0
const RUNG_MAX := 4
## Thermal levels (Thermal.level()): 0 nominal, 1 fair, 2 serious, 3 critical.
const LEVEL_NOMINAL := 0
const LEVEL_SERIOUS := 2
const PRESSURE_NAMES: PackedStringArray = ["idle", "calm", "hold", "frames", "thermal"]
const REASON_NAMES: PackedStringArray = ["none", "frames", "thermal"]
const MS_PER_S := 1000.0   # lint: allow-number unit conversion

## Current offset below the user's tier (0 = none).
var rung: int = RUNG_NONE
var pressure: Pressure = Pressure.IDLE
## Why the last step down happened (NONE after returning to rung 0).
var last_reason: Reason = Reason.NONE
## True while a thermal step is part of the offset (cleared back at rung 0): the HUD's
## cooling icon.
var thermal_throttled: bool = false
var steps_down: int = 0
var steps_up: int = 0

# Parameters (seconds, fractions).
var window_s: float = 0.0
var miss_frac: float = 0.0
var up_miss_frac: float = 0.0
var miss_factor: float = 0.0
var down_interval_s: float = 0.0
var up_after_base_s: float = 0.0
var up_after_max_s: float = 0.0
var up_backoff: float = 1.0
var relapse_s: float = 0.0
var ignore_frame_s: float = 0.0
var percentile: float = 0.0
var bin_s: float = 0.0

var _up_after_s: float = 0.0
var _since_change_s: float = 0.0
var _calm_s: float = 0.0
var _last_up: bool = false
var _sampling: bool = false
## 1 where stepping onto that rung changes something (index = rung).
var _useful := PackedByteArray()

# The frame window: a ring of frame times, their miss flags and histogram bins.
var _dt := PackedFloat64Array()
var _miss := PackedByteArray()
var _bin := PackedInt32Array()
var _hist := PackedInt32Array()
var _head: int = 0
var _count: int = 0
var _win_s: float = 0.0
var _misses: int = 0


## Reads the governor numbers from a QualityTuning (or a double: missing fields take the
## QualityTuning defaults) and sizes the window. Resets the state.
func configure(t: Resource) -> void:
	var d := QualityTuning.new()
	window_s = _num(t, d, &"governor_window_s")
	miss_frac = _num(t, d, &"governor_miss_frac")
	up_miss_frac = _num(t, d, &"governor_up_miss_frac")
	miss_factor = _num(t, d, &"governor_miss_factor")
	down_interval_s = _num(t, d, &"governor_step_down_interval_s")
	up_after_base_s = _num(t, d, &"governor_step_up_after_s")
	up_after_max_s = maxf(_num(t, d, &"governor_step_up_max_s"), up_after_base_s)
	up_backoff = maxf(_num(t, d, &"governor_up_backoff_factor"), 1.0)
	relapse_s = _num(t, d, &"governor_relapse_window_s")
	ignore_frame_s = _num(t, d, &"governor_ignore_frame_s")
	percentile = clampf(_num(t, d, &"governor_report_percentile"), 0.0, 1.0)
	bin_s = maxf(_num(t, d, &"governor_hist_bin_ms"), 0.0) / MS_PER_S
	var max_s := _num(t, d, &"governor_hist_max_ms") / MS_PER_S
	# Room for the window at twice the gameplay frame rate (uncapped frames drop the oldest).
	var fps := maxf(_num(t, d, &"gameplay_fps"), 1.0)
	var cap := ceili(window_s * fps * 2.0) + 1
	_dt.resize(cap)
	_miss.resize(cap)
	_bin.resize(cap)
	_hist.resize(maxi(ceili(max_s / maxf(bin_s, 1e-9)), 1) + 1)   # lint: allow-number divide guard; +1: the overflow bin
	_useful.resize(RUNG_MAX + 1)
	_useful.fill(1)
	reset()


static func _num(t: Resource, d: Resource, key: StringName) -> float:
	if t != null and key in t:
		return float(t.get(key))
	return float(d.get(key))


## Back to rung 0 with an empty window and the base up wait.
func reset() -> void:
	rung = RUNG_NONE
	pressure = Pressure.IDLE
	last_reason = Reason.NONE
	thermal_throttled = false
	steps_down = 0
	steps_up = 0
	_up_after_s = up_after_base_s
	_since_change_s = down_interval_s
	_calm_s = 0.0
	_last_up = false
	_sampling = false
	clear_window()


func clear_window() -> void:
	_head = 0
	_count = 0
	_win_s = 0.0
	_misses = 0
	_hist.fill(0)


## Whether stepping onto `r` (1..RUNG_MAX) changes anything for the current tier.
func set_useful(r: int, useful: bool) -> void:
	if r > RUNG_NONE and r <= RUNG_MAX:
		_useful[r] = 1 if useful else 0


func is_useful(r: int) -> bool:
	return r > RUNG_NONE and r <= RUNG_MAX and _useful[r] == 1


## An outside change of the rung (a dev or test override): the timers restart from it.
func set_rung(r: int) -> void:
	var nr := clampi(r, RUNG_NONE, RUNG_MAX)
	if nr == rung:
		return
	rung = nr
	_since_change_s = 0.0
	_calm_s = 0.0
	_last_up = false
	if rung == RUNG_NONE:
		thermal_throttled = false
		last_reason = Reason.NONE


## One frame. `frame_s`: its real duration; `target_frame_s`: the frame interval at the
## current cap; `thermal_level`: 0..3; `sampling`: in gameplay (frames count). True when
## the rung changed.
func tick(frame_s: float, target_frame_s: float, thermal_level: int, sampling: bool) -> bool:
	var dt := clampf(frame_s, 0.0, ignore_frame_s)
	_since_change_s += dt
	if _last_up and _since_change_s >= relapse_s:
		_up_after_s = up_after_base_s
	if sampling != _sampling:
		_sampling = sampling
		clear_window()
	if sampling and frame_s > 0.0 and frame_s <= ignore_frame_s:
		_push(frame_s, frame_s > target_frame_s * miss_factor)
	var full := sampling and window_full()
	var hot_thermal := thermal_level >= LEVEL_SERIOUS
	var hot_frames := full and miss_fraction() > miss_frac
	if hot_thermal or hot_frames:
		pressure = Pressure.THERMAL if hot_thermal else Pressure.FRAMES
		_calm_s = 0.0
		if _since_change_s >= down_interval_s:
			return _step_down(Reason.THERMAL if hot_thermal else Reason.FRAMES)
		return false
	if thermal_level > LEVEL_NOMINAL:
		pressure = Pressure.HOLD if sampling else Pressure.IDLE
		_calm_s = 0.0
		return false
	if not sampling:
		pressure = Pressure.IDLE
		return false
	if not full:
		pressure = Pressure.HOLD   # the window is still filling: calm time holds
		return false
	if miss_fraction() > up_miss_frac:
		pressure = Pressure.HOLD
		_calm_s = 0.0
		return false
	pressure = Pressure.CALM
	if rung == RUNG_NONE:
		return false
	_calm_s += dt
	if _calm_s >= _up_after_s:
		return _step_up()
	return false


## The cooling icon: the governor is active and (unless `any_reason`) a thermal step is
## part of the offset.
func cooling(any_reason: bool) -> bool:
	return rung > RUNG_NONE and (any_reason or thermal_throttled)


## The current wait for a step up (grows with relapses).
func up_wait_s() -> float:
	return _up_after_s


## Seconds of unbroken calm so far.
func calm_s() -> float:
	return _calm_s


func since_change_s() -> float:
	return _since_change_s


func window_full() -> bool:
	return _count > 0 and _win_s >= window_s


func window_seconds() -> float:
	return _win_s


func frames_in_window() -> int:
	return _count


func miss_fraction() -> float:
	return float(_misses) / float(_count) if _count > 0 else 0.0


## The window's frame time at percentile `p` (0..1), rounded up to the histogram bin (0
## with no frames). Allocation-free.
func frame_percentile_s(p: float) -> float:
	if _count == 0:
		return 0.0
	var want := maxi(ceili(p * float(_count)), 1)
	var acc := 0
	for b in _hist.size():
		acc += _hist[b]
		if acc >= want:
			return float(b + 1) * bin_s
	return float(_hist.size()) * bin_s


## The dev HUD's percentile (governor_report_percentile, p95).
func frame_report_s() -> float:
	return frame_percentile_s(percentile)


func pressure_name() -> String:
	return PRESSURE_NAMES[pressure]


func reason_name() -> String:
	return REASON_NAMES[last_reason]


func _step_down(reason: Reason) -> bool:
	var r := _next_down()
	if r < 0:
		return false
	if _last_up and _since_change_s < relapse_s:
		_up_after_s = minf(_up_after_s * up_backoff, up_after_max_s)
	rung = r
	_since_change_s = 0.0
	_calm_s = 0.0
	_last_up = false
	last_reason = reason
	if reason == Reason.THERMAL:
		thermal_throttled = true
	steps_down += 1
	return true


func _step_up() -> bool:
	rung = _next_up()
	_since_change_s = 0.0
	_calm_s = 0.0
	_last_up = true
	if rung == RUNG_NONE:
		thermal_throttled = false
		last_reason = Reason.NONE
	steps_up += 1
	return true


## The next useful rung below the current one (-1: none left).
func _next_down() -> int:
	for r in range(rung + 1, RUNG_MAX + 1):
		if _useful[r] == 1:
			return r
	return -1


## The next useful rung above the current one (0: back to the tier).
func _next_up() -> int:
	for r in range(rung - 1, RUNG_NONE, -1):
		if _useful[r] == 1:
			return r
	return RUNG_NONE


func _push(frame_s: float, missed: bool) -> void:
	var cap := _dt.size()
	if cap == 0:
		return
	if _count == cap:
		_pop()
	var i := (_head + _count) % cap
	var b := mini(int(frame_s / bin_s), _hist.size() - 1) if bin_s > 0.0 else _hist.size() - 1
	_dt[i] = frame_s
	_miss[i] = 1 if missed else 0
	_bin[i] = b
	_hist[b] += 1
	_count += 1
	_win_s += frame_s
	if missed:
		_misses += 1
	# Keep just enough frames to cover the window.
	while _count > 1 and _win_s - _dt[_head] >= window_s:
		_pop()


func _pop() -> void:
	var i := _head
	_win_s -= _dt[i]
	_hist[_bin[i]] -= 1
	if _miss[i] == 1:
		_misses -= 1
	_head = (_head + 1) % _dt.size()
	_count -= 1
