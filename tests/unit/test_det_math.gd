extends WBTest
## DetMath (src/core/det_math.gd): deterministic transcendentals. WP N8.2;
## docs/DETERMINISM.md. Accuracy against this machine's libm (in ulp), the shared vectors
## (westbound-server/crates/sim/vectors/detmath.json, also checked bit for bit by the Rust
## port), edge cases, identities, and the cost per call.

const VECTORS := "res://westbound-server/crates/sim/vectors/detmath.json"
const ACCURACY_N := 20000
const SEED := 20260930

var _bits := PackedByteArray()


func before_all() -> void:
	_bits.resize(8)


func _key(x: float) -> int:
	_bits.encode_double(0, x)
	var b := _bits.decode_s64(0)
	return b if b >= 0 else -(b & 0x7FFFFFFFFFFFFFFF)


## Distance in units in the last place (0 = the same bits; both NaN = 0).
func _ulps(a: float, b: float) -> int:
	if is_nan(a) and is_nan(b):
		return 0
	if is_nan(a) or is_nan(b):
		return 1 << 62
	return absi(_key(a) - _key(b))


func _hx(x: float) -> String:
	_bits.encode_double(0, x)
	return "%08x%08x" % [_bits.decode_u32(4), _bits.decode_u32(0)]


func _unhx(h: String) -> float:
	_bits.encode_u32(4, h.substr(0, 8).hex_to_int())
	_bits.encode_u32(0, h.substr(8, 8).hex_to_int())
	return _bits.decode_double(0)


## Max ulp error of `f` against `ref` over n inputs drawn by `draw`.
func _max_ulps(f: Callable, ref: Callable, draw: Callable, n: int) -> Array:
	var rng := Rng.new(SEED)
	var worst := 0
	var at := 0.0
	for i in n:
		var x: float = draw.call(rng)
		var u := _ulps(f.call(x), ref.call(x))
		if u > worst:
			worst = u
			at = x
	return [worst, at]


func _check_ulps(label: String, f: Callable, ref: Callable, draw: Callable, bound: int) -> void:
	var r := _max_ulps(f, ref, draw, ACCURACY_N)
	print("      %s: max %d ulp vs libm (at %s)" % [label, r[0], r[1]])
	le(r[0], bound, "%s within %d ulp of libm (worst at %s)" % [label, bound, r[1]])


static func _wide(rng: Rng) -> float:
	return rng.float_range(-1.0, 1.0) * pow(10.0, rng.float_range(-6.0, 4.0))


func test_sin_cos_tan_accuracy() -> void:
	var small := func(rng: Rng) -> float: return rng.float_range(-4.0, 4.0)
	_check_ulps("sin [-4, 4]", DetMath.sin, func(x: float) -> float: return sin(x), small, 1)
	_check_ulps("cos [-4, 4]", DetMath.cos, func(x: float) -> float: return cos(x), small, 1)
	_check_ulps("sin wide", DetMath.sin, func(x: float) -> float: return sin(x), _wide, 1)
	_check_ulps("cos wide", DetMath.cos, func(x: float) -> float: return cos(x), _wide, 1)
	_check_ulps("tan [-1.5, 1.5]", DetMath.tan, func(x: float) -> float: return tan(x),
		func(rng: Rng) -> float: return rng.float_range(-1.5, 1.5), 2)
	_check_ulps("tan wide", DetMath.tan, func(x: float) -> float: return tan(x), _wide, 2)


func test_atan_asin_accuracy() -> void:
	_check_ulps("atan wide", DetMath.atan, func(x: float) -> float: return atan(x),
		func(rng: Rng) -> float: return rng.float_range(-1.0, 1.0) * pow(10.0, rng.float_range(-8.0, 8.0)), 1)
	_check_ulps("asin", DetMath.asin, func(x: float) -> float: return asin(x),
		func(rng: Rng) -> float: return rng.float_range(-1.0, 1.0), 2)
	var rng := Rng.new(SEED)
	var worst := 0
	for i in ACCURACY_N:
		var y := rng.float_range(-1.0, 1.0) * pow(10.0, rng.float_range(-3.0, 3.0))
		var x := rng.float_range(-1.0, 1.0) * pow(10.0, rng.float_range(-3.0, 3.0))
		worst = maxi(worst, _ulps(DetMath.atan2(y, x), atan2(y, x)))
	print("      atan2: max %d ulp vs libm" % worst)
	le(worst, 2, "atan2 within 2 ulp")


func test_exp_log_pow_accuracy() -> void:
	_check_ulps("exp [-30, 30]", DetMath.exp, func(x: float) -> float: return exp(x),
		func(rng: Rng) -> float: return rng.float_range(-30.0, 30.0), 1)
	_check_ulps("exp small", DetMath.exp, func(x: float) -> float: return exp(x),
		func(rng: Rng) -> float: return rng.float_range(-0.5, 0.0), 1)
	_check_ulps("exp [-740, 705]", DetMath.exp, func(x: float) -> float: return exp(x),
		func(rng: Rng) -> float: return rng.float_range(-740.0, 705.0), 1)
	_check_ulps("log", DetMath.log, func(x: float) -> float: return log(x),
		func(rng: Rng) -> float: return pow(10.0, rng.float_range(-300.0, 300.0)), 1)
	_check_ulps("log near 1", DetMath.log, func(x: float) -> float: return log(x),
		func(rng: Rng) -> float: return rng.float_range(0.5, 2.0), 1)
	var rng := Rng.new(SEED)
	var worst := 0
	for i in ACCURACY_N:
		var x := rng.float_range(0.05, 3.0)
		var y := rng.float_range(-4.0, 4.0)
		worst = maxi(worst, _ulps(DetMath.pow(x, y), pow(x, y)))
	print("      pow (x 0.05..3, y -4..4): max %d ulp vs libm" % worst)
	le(worst, 16, "pow within 16 ulp at moderate y log x")
	for n in range(-6, 7):
		le(_ulps(DetMath.pow(0.93, float(n)), pow(0.93, float(n))), 2, "pow integer %d" % n)


func test_shared_vectors_bit_exact() -> void:
	var text := FileAccess.get_file_as_string(VECTORS)
	if not check(not text.is_empty(), "vectors present (tools/server_data/export_sim_data.gd)"):
		return
	var doc: Dictionary = JSON.parse_string(text)
	var total := 0
	var bad := 0
	for item: Array in doc["cases"]:
		var fname := String(item[0])
		var args: Array[float] = []
		for i in range(1, item.size() - 1):
			args.append(_unhx(String(item[i])))
		var want := _unhx(String(item[item.size() - 1]))
		var got := DetMathVectors.call_fn(fname, args)
		total += 1
		if _ulps(got, want) != 0:
			bad += 1
			if bad <= 5:
				fail("%s(%s) = %s, the vectors say %s" % [fname, args, _hx(got), _hx(want)])
	gt(total, 3000, "a few thousand cases")
	eq(bad, 0, "every vector bit-exact")


func test_edge_cases() -> void:
	eq(DetMath.sin(0.0), 0.0)
	eq(DetMath.cos(0.0), 1.0)
	eq(DetMath.tan(0.0), 0.0)
	eq(DetMath.exp(0.0), 1.0)
	eq(DetMath.log(1.0), 0.0)
	eq(DetMath.atan(0.0), 0.0)
	eq(DetMath.atan2(0.0, 1.0), 0.0)
	eq(DetMath.atan2(0.0, -1.0), DetMath.PI_HI)
	eq(DetMath.atan2(1.0, 0.0), PI / 2.0)
	eq(DetMath.atan2(-1.0, 0.0), -PI / 2.0)
	eq(DetMath.atan(INF), PI / 2.0)
	eq(DetMath.atan(-INF), -PI / 2.0)
	eq(DetMath.exp(-INF), 0.0)
	eq(DetMath.exp(INF), INF)
	eq(DetMath.exp(1000.0), INF)
	eq(DetMath.exp(-800.0), 0.0)
	check(DetMath.exp(-740.0) > 0.0, "exp(-740) is a subnormal, not 0")
	eq(DetMath.log(0.0), -INF)
	eq(DetMath.log(INF), INF)
	check(is_nan(DetMath.log(-1.0)), "log(-1) NaN")
	check(is_nan(DetMath.sin(INF)), "sin(inf) NaN")
	check(is_nan(DetMath.cos(NAN)), "cos(NaN) NaN")
	check(is_nan(DetMath.asin(1.5)), "asin(1.5) NaN")
	eq(DetMath.asin(1.0), PI / 2.0)
	eq(DetMath.pow(2.0, 10.0), 1024.0)
	eq(DetMath.pow(-2.0, 3.0), -8.0)
	eq(DetMath.pow(2.0, -2.0), 0.25)
	eq(DetMath.pow(0.0, 0.5), 0.0)
	eq(DetMath.pow(9.0, 0.5), 3.0)
	check(is_nan(DetMath.pow(-2.0, 0.5)), "pow(-2, 0.5) NaN")
	var denorm_min := DetMath.scalbn(1.0, -1074)
	check(denorm_min > 0.0 and denorm_min * 0.5 == 0.0, "scalbn reaches the smallest subnormal")
	eq(DetMath.scalbn(1.5, 1023), 1.5 * pow(2.0, 1023.0))
	eq(DetMath.scalbn(1.0, 1024), INF)
	eq(DetMath.log(denorm_min), log(denorm_min))
	var dmax := DetMath.scalbn(2.0 - DetMath.TWO_M52, DetMath.EXP_MAX)
	eq(DetMath.log(dmax), log(dmax))


func test_sin_cos_matches_sin_and_cos() -> void:
	var rng := Rng.new(SEED)
	var bad := 0
	for i in 5000:
		var x := _wide(rng)
		var s := DetMath.sin_cos(x)
		if _ulps(s, DetMath.sin(x)) != 0 or _ulps(DetMath.cos_out, DetMath.cos(x)) != 0:
			bad += 1
	eq(bad, 0, "sin_cos = (sin, cos) bit for bit")


func test_cost_per_call() -> void:
	var xs := PackedFloat64Array()
	var rng := Rng.new(SEED)
	for i in 1000:
		xs.append(rng.float_range(-0.6, 0.6))
	var loops := {
		"DetMath.sin": func() -> float:
			var a := 0.0
			for x in xs:
				a += DetMath.sin(x)
			return a,
		"DetMath.sin_cos": func() -> float:
			var a := 0.0
			for x in xs:
				a += DetMath.sin_cos(x) + DetMath.cos_out
			return a,
		"DetMath.exp": func() -> float:
			var a := 0.0
			for x in xs:
				a += DetMath.exp(x)
			return a,
		"DetMath.atan2": func() -> float:
			var a := 0.0
			for x in xs:
				a += DetMath.atan2(x, 1.5)
			return a,
		"DetMath.tan": func() -> float:
			var a := 0.0
			for x in xs:
				a += DetMath.tan(x)
			return a,
		"libm sin (reference)": func() -> float:
			var a := 0.0
			for x in xs:
				a += sin(x)
			return a,
	}
	for label: String in loops:
		var usec := WBBench.usec_per_call(loops[label], 5) / float(xs.size())
		WBBench.report("%s per call" % label, usec, 5.0)
		le(usec, WBBench.budget(5.0), label)
