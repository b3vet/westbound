class_name WBBench
extends RefCounted
## Tick-cost benchmarks for budget tests (plan §4 merge gate item 3, §8 GDScript
## performance risk). Used from WBTest suites:
##
##   func test_traffic_tick_budget() -> void:
##       var sim := TrafficSim.new(...)        # 60 vehicles, warmed up
##       var usec := WBBench.usec_per_call(sim.step.bind(1.0 / 120.0), 200)
##       WBBench.report("traffic step, 60 vehicles", usec, 400.0)
##       le(usec, WBBench.budget(400.0), "traffic step usec")
##
## Measure a whole tick per call (Callable.call costs ~0.1-0.5 usec, see
## call_overhead_usec()), and keep the budget well above the measured local
## median: CI runners are slower and noisier than a dev machine. Rule of thumb:
## budget = 3x the median you measure locally, and never below the spec's real
## frame budget share. `WB_BENCH_SCALE` (env) multiplies every budget, e.g.
## WB_BENCH_SCALE=2 on a slow runner; it is 1.0 by default.
##
## The median of several timed batches is used, so one GC pause, scheduler
## hiccup or cold cache does not decide the result.

const DEFAULT_BATCHES := 7


## Median microseconds per call of `fn` over `batches` timed batches of
## `iterations` calls each, after `warmup` untimed calls (default: one batch).
static func usec_per_call(fn: Callable, iterations: int, warmup: int = -1,
		batches: int = DEFAULT_BATCHES) -> float:
	return float(measure(fn, iterations, warmup, batches)["median"])


## Like usec_per_call but returns every statistic:
## {"median", "min", "max": float usec per call, "batches": PackedFloat64Array}.
static func measure(fn: Callable, iterations: int, warmup: int = -1,
		batches: int = DEFAULT_BATCHES) -> Dictionary:
	assert(iterations > 0 and batches > 0, "WBBench: iterations and batches must be positive")
	for i in (iterations if warmup < 0 else warmup):
		fn.call()
	var per_call := PackedFloat64Array()
	per_call.resize(batches)
	for b in batches:
		var t0 := Time.get_ticks_usec()
		for i in iterations:
			fn.call()
		per_call[b] = float(Time.get_ticks_usec() - t0) / iterations
	var sorted := per_call.duplicate()
	sorted.sort()
	var mid := int(batches * 0.5)
	var median := sorted[mid] if batches % 2 == 1 else (sorted[mid - 1] + sorted[mid]) * 0.5
	return {"median": median, "min": sorted[0], "max": sorted[batches - 1], "batches": per_call}


## Cost of calling an empty Callable, to judge whether a measurement is dominated
## by call overhead (if so, loop inside the callable instead).
static func call_overhead_usec(iterations: int = 10000) -> float:
	return usec_per_call(_noop, iterations)


## `budget_usec` scaled by the WB_BENCH_SCALE environment variable (default 1.0).
static func budget(budget_usec: float) -> float:
	return budget_usec * scale()


static func scale() -> float:
	var s := OS.get_environment("WB_BENCH_SCALE")
	return s.to_float() if s.is_valid_float() and s.to_float() > 0.0 else 1.0


## Prints one line for the test log, e.g.
##   bench  traffic step, 60 vehicles  182.4 usec  (budget 400.0, 46%)
static func report(label: String, usec: float, budget_usec: float) -> void:
	var b := budget(budget_usec)
	print("      bench  %s  %.2f usec  (budget %.1f, %.0f%%)" % [label, usec, b, usec / b * 100.0])


static func _noop() -> void:
	pass
