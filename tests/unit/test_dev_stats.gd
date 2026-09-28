extends WBTest
## DevStats static registry (src/ui/dev_stats.gd). Spec: Tech stack → Testing.


func before_each() -> void:
	DevStats.reset()


func after_all() -> void:
	DevStats.reset()


func test_report_and_get() -> void:
	eq(DevStats.get_value(DevStats.VEHICLES, -1), -1, "default before any report")
	check(not DevStats.has_value(DevStats.VEHICLES))
	DevStats.report(DevStats.VEHICLES, 42)
	eq(DevStats.get_value(DevStats.VEHICLES, -1), 42)
	DevStats.report(DevStats.VEHICLES, 7)
	eq(DevStats.get_value(DevStats.VEHICLES), 7, "report overwrites")
	DevStats.report(DevStats.THERMAL, &"serious")
	eq(DevStats.get_value(DevStats.THERMAL), &"serious")
	check(DevStats.get_value(&"never_reported") == null, "missing key -> null default")


func test_reset_clears_values() -> void:
	DevStats.report(DevStats.VEHICLES, 3)
	DevStats.report_sim_tick_usec(100)
	DevStats.reset()
	check(not DevStats.has_value(DevStats.VEHICLES))
	eq(DevStats.sim_tick_sample_count(), 0)
	eq(DevStats.get_sim_tick_avg_usec(), 0.0)
	eq(DevStats.get_sim_tick_max_usec(), 0)


func test_sim_tick_window_is_one_second_of_ticks() -> void:
	eq(DevStats.sim_tick_window(), Engine.physics_ticks_per_second)


func test_sim_tick_average_before_window_fills() -> void:
	DevStats.report_sim_tick_usec(100)
	DevStats.report_sim_tick_usec(200)
	DevStats.report_sim_tick_usec(600)
	eq(DevStats.sim_tick_sample_count(), 3)
	near(DevStats.get_sim_tick_avg_usec(), 300.0, 1e-9)
	eq(DevStats.get_sim_tick_max_usec(), 600)


func test_sim_tick_average_rolls() -> void:
	var n := DevStats.sim_tick_window()
	# A full window of slow ticks, then a full window of fast ones: only the
	# fast ones remain.
	for _i in n:
		DevStats.report_sim_tick_usec(1000)
	near(DevStats.get_sim_tick_avg_usec(), 1000.0, 1e-9)
	for _i in n:
		DevStats.report_sim_tick_usec(10)
	eq(DevStats.sim_tick_sample_count(), n, "count caps at the window")
	near(DevStats.get_sim_tick_avg_usec(), 10.0, 1e-9)
	eq(DevStats.get_sim_tick_max_usec(), 10)
	# Half a window more of 30 us: average of n/2 x 10 and n/2 x 30.
	var half := floori(n / 2.0)
	for _i in half:
		DevStats.report_sim_tick_usec(30)
	var expected := (float(n - half) * 10.0 + float(half) * 30.0) / float(n)
	near(DevStats.get_sim_tick_avg_usec(), expected, 1e-9)
	eq(DevStats.get_sim_tick_max_usec(), 30)
