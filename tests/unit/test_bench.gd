extends WBTest
## Sanity tests for the tick-cost benchmark helper (tests/lib/bench.gd).

var _sink := 0.0


func _work(n: int) -> void:
	var acc := 0.0
	for i in n:
		acc += sqrt(float(i))
	_sink += acc


func test_measure_statistics_are_ordered_and_finite() -> void:
	var m := WBBench.measure(_work.bind(200), 20, 5, 5)
	var batches: PackedFloat64Array = m["batches"]
	eq(batches.size(), 5)
	finite(m["median"])
	gt(m["min"], 0.0, "a 200-iteration loop takes measurable time")
	le(m["min"], m["median"])
	le(m["median"], m["max"])


func test_more_work_costs_more() -> void:
	var small := WBBench.usec_per_call(_work.bind(100), 20)
	var large := WBBench.usec_per_call(_work.bind(2000), 20)
	gt(large, small * 4.0, "20x the work should cost clearly more (small=%s large=%s)" % [small, large])


func test_even_batch_count_takes_middle_mean() -> void:
	var m := WBBench.measure(_work.bind(50), 10, 0, 4)
	var sorted: PackedFloat64Array = m["batches"].duplicate()
	sorted.sort()
	near(m["median"], (sorted[1] + sorted[2]) * 0.5, 1e-9)


func test_budget_pattern() -> void:
	# The pattern later WPs use: a generous budget, scaled for slow runners.
	var usec := WBBench.usec_per_call(_work.bind(10), 1000)
	WBBench.report("sqrt loop x10", usec, 200.0)
	le(usec, WBBench.budget(200.0))
	var overhead := WBBench.call_overhead_usec(2000)
	finite(overhead)
	lt(overhead, 50.0, "Callable.call overhead is sub-microsecond on any sane machine")


func test_budget_scale_defaults_to_one() -> void:
	if OS.get_environment("WB_BENCH_SCALE").is_empty():
		eq(WBBench.scale(), 1.0)
		eq(WBBench.budget(40.0), 40.0)
	else:
		near(WBBench.budget(40.0), 40.0 * WBBench.scale(), 1e-9)
