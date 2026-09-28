extends WBTest
## Self-test of the assertion library: failures are recorded, passes are not.


func test_assertions_record_failures() -> void:
	var t := WBTest.new()
	t.eq(1, 2)
	t.near(1.0, 1.5, 0.1)
	t.within_pct(105.0, 100.0, 0.01)
	t.check(false, "boom")
	t.finite(NAN)
	eq(t._take_failures().size(), 5)


func test_assertions_pass_quietly() -> void:
	var t := WBTest.new()
	t.eq(1, 1.0)
	t.near(1.0, 1.05, 0.1)
	t.within_pct(104.0, 100.0, 0.05)
	t.lt(1.0, 2.0)
	t.ge(2.0, 2.0)
	eq(t._take_failures().size(), 0)
