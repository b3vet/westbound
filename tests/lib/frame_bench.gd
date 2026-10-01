class_name WBFrameBench
extends RefCounted
## Frame-cost benches (the p99.5 or the worst frame of a timed drive) that hold on a
## loaded machine without hiding a real regression. WP9.10; plan §4 merge gate item 3;
## docs/TOOLS.md → WBFrameBench.
##
## The problem: a tail statistic of one timed drive is at the mercy of the OS. One
## preemption (a parallel test run, a CI neighbour, a busy editor) adds milliseconds
## to whichever frame it lands in, and the worst frame or the p99.5 is exactly where
## that shows. The subject's own cost, though, is deterministic: the same drive does
## the same work in the same frames every time (prefetches, swaps and placements
## depend on the position and the seed, never on the clock).
##
## So:
##   1. The drive runs `passes` times, each on a fresh subject with its own warm-up,
##      recording every timed frame's cost in frame order.
##   2. Each frame's cost is its minimum over the passes. Load only ever adds time, so
##      that is the frame's own cost plus the least noise any pass saw: a spike has to
##      hit the same frame in every pass to survive.
##   3. The tail (q = 0.995 for the p99.5, 1.0 for the worst frame) is taken over those
##      per-frame minima.
##   4. Over budget, the whole measurement runs once more and the lower tail counts:
##      the test fails only if both attempts are over.
##
## What still fails: a frame that is expensive every time (more work in a prefetch, a
## swap that rebuilds too much, a placement that got slower) is expensive in every pass
## and every attempt, so its minimum is over budget. What it no longer catches is a
## hitch that lands on a different frame each drive; the benched systems have none by
## construction (no clock in their work, no GC in GDScript), and the single-pass tail
## is still printed next to the result so a drift shows in the log.
##
##   func test_frame_cost_while_driving() -> void:
##       var usec := WBFrameBench.tail_within("water ribbon p99.5 frame", _drive,
##               WBFrameBench.P995, 1500.0)
##       le(usec, WBBench.budget(1500.0), "p99.5 water frame usec")
##
## `_drive` builds its subject, warms it up, and returns PackedInt64Array: each timed
## frame's Time.get_ticks_usec() delta, in order (the same count every pass).

const DEFAULT_PASSES := 3
const DEFAULT_ATTEMPTS := 2
const P995 := 0.995
const WORST := 1.0


## The q-quantile (0..1; 1 = the worst) of `samples`, nearest-rank below.
static func quantile(samples: PackedInt64Array, q: float) -> float:
	if samples.is_empty():
		return 0.0
	var sorted := samples.duplicate()
	sorted.sort()
	return float(sorted[int(float(sorted.size() - 1) * clampf(q, 0.0, 1.0))])


## Each frame's minimum cost over the passes (all passes the same length).
static func per_frame_min(passes: Array[PackedInt64Array]) -> PackedInt64Array:
	if passes.is_empty():
		return PackedInt64Array()
	var out := passes[0].duplicate()
	for p in range(1, passes.size()):
		var costs := passes[p]
		if costs.size() != out.size():
			push_error("WBFrameBench: pass %d timed %d frames, pass 0 timed %d (the drive must be deterministic)"
					% [p, costs.size(), out.size()])
			return PackedInt64Array()
		for i in out.size():
			out[i] = mini(out[i], costs[i])
	return out


## One measurement: `passes` drives, the q-quantile of the per-frame minima. Returns
## [tail of the minima, tail of the first pass alone] (usec).
static func measure_tail(drive: Callable, q: float, passes: int = DEFAULT_PASSES) -> PackedFloat64Array:
	assert(passes > 0, "WBFrameBench: passes must be positive")
	var runs: Array[PackedInt64Array] = []
	for p in passes:
		var costs: PackedInt64Array = drive.call()
		runs.append(costs)
	var mins := per_frame_min(runs)
	if mins.is_empty():
		return PackedFloat64Array([INF, INF])
	return PackedFloat64Array([quantile(mins, q), quantile(runs[0], q)])


## The bench: measure_tail, once more if over the (WB_BENCH_SCALE-scaled) budget, and
## the lower tail reported and returned. Assert on it with le(..., WBBench.budget(b)).
static func tail_within(label: String, drive: Callable, q: float, budget_usec: float,
		passes: int = DEFAULT_PASSES, attempts: int = DEFAULT_ATTEMPTS) -> float:
	var best := INF
	var single := INF
	var used := 0
	for a in maxi(attempts, 1):
		used = a + 1
		var m := measure_tail(drive, q, passes)
		if m[0] < best:
			best = m[0]
			single = m[1]
		if m[0] <= WBBench.budget(budget_usec):
			break
		if a + 1 < attempts:
			print("      bench  %s  %.2f usec over budget (attempt %d/%d), measuring again" % [label, m[0], a + 1, attempts])
	WBBench.report("%s [per-frame min of %d passes, attempt %d; single pass %.0f]" % [label, passes, used, single],
			best, budget_usec)
	return best
