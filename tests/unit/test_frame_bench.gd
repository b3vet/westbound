extends WBTest
## WBFrameBench (tests/lib/frame_bench.gd, WP9.10): load-robust frame-cost benches.
## Synthetic drives (no clock): OS noise that lands on a different frame each pass is
## filtered out; a frame that is expensive in every pass (a real regression) is not.

const BUDGET := 1000.0
const CHEAP := 100
const SPIKE := 9000

var _pass: int = 0
var _calls: int = 0


func before_each() -> void:
	_pass = 0
	_calls = 0


## 200 cheap frames; pass p gets a "preemption" on frames 10 + p .. 19 + p (5 % of the
## drive: well into the p99.5 and the worst frame of any single pass).
func _noisy_drive() -> PackedInt64Array:
	var out := PackedInt64Array()
	out.resize(200)
	out.fill(CHEAP)
	for i in range(10, 20):
		out[i + _pass * 20] = SPIKE
	_pass += 1
	return out


## The same, plus frame 150 costs SPIKE in every pass (a deterministic regression).
func _regressed_drive() -> PackedInt64Array:
	var out := _noisy_drive()
	out[150] = SPIKE
	return out


func _counted_drive() -> PackedInt64Array:
	_calls += 1
	return _regressed_drive()


func test_quantile() -> void:
	var s := PackedInt64Array([5, 1, 4, 2, 3])
	eq(WBFrameBench.quantile(s, 1.0), 5.0, "worst")
	eq(WBFrameBench.quantile(s, 0.5), 3.0, "median")
	eq(WBFrameBench.quantile(s, 0.0), 1.0, "best")
	eq(WBFrameBench.quantile(PackedInt64Array(), 0.5), 0.0, "empty")
	eq(s, PackedInt64Array([5, 1, 4, 2, 3]), "the input is not sorted in place")


func test_per_frame_min() -> void:
	var runs: Array[PackedInt64Array] = [PackedInt64Array([3, 9, 5]), PackedInt64Array([7, 2, 6]),
		PackedInt64Array([4, 8, 1])]
	eq(WBFrameBench.per_frame_min(runs), PackedInt64Array([3, 2, 1]))


func test_uneven_passes_are_an_error() -> void:
	expect_errors(1)
	var runs: Array[PackedInt64Array] = [PackedInt64Array([3, 9]), PackedInt64Array([7])]
	check(WBFrameBench.per_frame_min(runs).is_empty(), "no answer from a non-deterministic drive")


func test_noise_on_different_frames_is_filtered() -> void:
	var single := WBFrameBench.quantile(_noisy_drive(), WBFrameBench.WORST)
	eq(single, float(SPIKE), "one pass alone: the spike is the worst frame")
	_pass = 0
	var m := WBFrameBench.measure_tail(_noisy_drive, WBFrameBench.WORST)
	eq(m[0], float(CHEAP), "per-frame minimum over three passes: the frames' own cost")
	eq(m[1], float(SPIKE), "the single-pass tail is kept for the log")
	_pass = 0
	le(WBFrameBench.tail_within("synthetic noisy drive", _noisy_drive, WBFrameBench.P995, BUDGET), BUDGET)


func test_a_frame_expensive_every_time_still_fails() -> void:
	var usec := WBFrameBench.tail_within("synthetic regressed drive", _counted_drive, WBFrameBench.WORST, BUDGET)
	eq(usec, float(SPIKE), "the regressed frame survives the minimum")
	gt(usec, WBBench.budget(BUDGET), "over budget: the bench fails")
	eq(_calls, WBFrameBench.DEFAULT_PASSES * WBFrameBench.DEFAULT_ATTEMPTS, "measured twice before failing")


func test_within_budget_measures_once() -> void:
	_calls = 0
	var drive := func() -> PackedInt64Array:
		_calls += 1
		var out := PackedInt64Array()
		out.resize(50)
		out.fill(CHEAP)
		return out
	le(WBFrameBench.tail_within("synthetic cheap drive", drive, WBFrameBench.P995, BUDGET), BUDGET)
	eq(_calls, WBFrameBench.DEFAULT_PASSES, "no retry when the first measurement fits")
