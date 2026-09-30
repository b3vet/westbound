extends WBTest
## Rng: determinism and stream independence. Spec: Architecture rule 2.


func _draw(rng: Rng, n: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for i in n:
		out.append(rng.unit())
	return out


func test_same_seed_same_sequence() -> void:
	eq(_draw(Rng.new(1234), 100), _draw(Rng.new(1234), 100))


func test_different_seeds_differ() -> void:
	ne(_draw(Rng.new(1), 16), _draw(Rng.new(2), 16))


func test_derived_streams_are_independent_of_parent_draws() -> void:
	var a := Rng.new(99)
	var b := Rng.new(99)
	_draw(b, 500)  # consuming the parent must not change derived streams
	eq(_draw(a.derive(Rng.STREAM_TRAFFIC), 32), _draw(b.derive(Rng.STREAM_TRAFFIC), 32))


func test_derived_streams_differ_by_name() -> void:
	var r := Rng.new(7)
	ne(_draw(r.derive(Rng.STREAM_ROAD), 16), _draw(r.derive(Rng.STREAM_TRAFFIC), 16))


func test_derive_seed_is_pinned() -> void:
	# Pinned values: changing the derivation silently breaks Daily Drive and ghosts.
	eq(Rng.fnv1a32(""), 2166136261)
	eq(Rng.fnv1a32("a"), 0xE40C292C)
	eq(Rng.daily_seed(2026, 9, 28), Rng.daily_seed(2026, 9, 28))
	ne(Rng.daily_seed(2026, 9, 28), Rng.daily_seed(2026, 9, 29))
	ge(Rng.derive_seed(123, "x"), 0)


func test_ranges() -> void:
	var r := Rng.new(5)
	for i in 1000:
		var f := r.float_range(-2.0, 3.0)
		if not (check(f >= -2.0 and f < 3.0, "float_range out of bounds: %s" % f)):
			return
		var n := r.int_range(1, 6)
		if not check(n >= 1 and n <= 6, "int_range out of bounds: %d" % n):
			return


func test_pick_weighted_respects_zero_weights() -> void:
	var r := Rng.new(11)
	var weights := PackedFloat64Array([0.0, 1.0, 0.0, 3.0])
	var counts := [0, 0, 0, 0]
	for i in 4000:
		counts[r.pick_weighted(weights)] += 1
	eq(counts[0], 0)
	eq(counts[2], 0)
	near(float(counts[3]) / float(counts[1]), 3.0, 0.4)
