class_name DetMathVectors
extends RefCounted
## The DetMath parity vectors (WP N8.2; docs/DETERMINISM.md): fixed inputs for every
## function (edge cases, range-reduction and branch boundaries, and seeded random inputs
## over the ranges the simulation uses and far beyond). export_sim_data.gd writes them
## with DetMath's results as westbound-server/crates/sim/vectors/detmath.json; the Rust
## port (crates/sim/tests/detmath.rs) and tests/unit/test_det_math.gd check every case
## bit for bit.

const SEED := 20260930
const FUNCS: Array[String] = ["sin", "cos", "tan", "atan", "atan2", "asin", "exp", "log", "pow"]
const RANDOM_PER_FN := 300


static func call_fn(fname: String, a: Array[float]) -> float:
	match fname:
		"sin":
			return DetMath.sin(a[0])
		"cos":
			return DetMath.cos(a[0])
		"tan":
			return DetMath.tan(a[0])
		"atan":
			return DetMath.atan(a[0])
		"atan2":
			return DetMath.atan2(a[0], a[1])
		"asin":
			return DetMath.asin(a[0])
		"exp":
			return DetMath.exp(a[0])
		"log":
			return DetMath.log(a[0])
		"pow":
			return DetMath.pow(a[0], a[1])
	push_error("DetMathVectors: unknown function %s" % fname)
	return NAN


## Every case as [function, arg, (arg2)].
static func cases() -> Array:
	var out := []
	var rng := Rng.new(SEED)
	# Godot's parser reads -0.0 as 0.0 and flushes literals below ~1e-307 to 0: build those.
	var zero := 0.0
	var neg_zero := -zero
	var denorm_min := DetMath.scalbn(1.0, -1074)
	var normal_min := DetMath.scalbn(1.0, DetMath.EXP_MIN)
	var common: Array[float] = [0.0, neg_zero, denorm_min, -denorm_min, normal_min, 1e-300, 1e-12, -1e-9, 1e-5,
		0.1, -0.25, 0.5, 1.0, -1.0, 2.0, 3.0, 10.0, -100.0, 1e3, 1e5, -1.6e6, 1e10, 1e300, INF, -INF, NAN]
	var trig: Array[float] = common.duplicate()
	for k in range(-12, 13):
		var x := float(k) * DetMath.PIO2_HI
		trig.append(x)
		trig.append(x + 1e-9)
		trig.append(x - 3e-13)
	trig.append_array([DetMath.PIO4, -DetMath.PIO4, DetMath.PIO4 + 1e-16, DetMath.TAN_BIG,
		DetMath.TAN_BIG - 1e-12, 0.6, -0.6, 0.2618])
	for fname: String in ["sin", "cos", "tan"]:
		for x in trig:
			out.append([fname, x])
		for i in RANDOM_PER_FN:
			var x := rng.float_range(-1.0, 1.0) * (1.0 if i % 3 == 0 else (8.0 if i % 3 == 1 else 3000.0))
			out.append([fname, x])
	var at: Array[float] = common.duplicate()
	for b: float in [DetMath.ATAN_7_16, DetMath.ATAN_11_16, DetMath.ATAN_19_16, DetMath.ATAN_39_16,
			DetMath.TWO_66]:
		at.append_array([b, -b, b * (1.0 - 1e-15), b * (1.0 + 1e-15)])
	for x in at:
		out.append(["atan", x])
	for i in RANDOM_PER_FN:
		out.append(["atan", rng.float_range(-1.0, 1.0) * pow(10.0, rng.float_range(-6.0, 6.0))])
	var a2: Array[float] = [0.0, neg_zero, 1.0, -1.0, 30.0, -30.0, 1e-300, 1e300, INF, -INF, NAN]
	for y in a2:
		for x in a2:
			out.append(["atan2", y, x])
	for i in RANDOM_PER_FN:
		var sc := 50.0 if i % 2 == 0 else 1.0
		out.append(["atan2", rng.float_range(-1.0, 1.0) * sc, rng.float_range(-1.0, 1.0) * 60.0])
	for x: float in [0.0, neg_zero, 1.0, -1.0, 0.5, -0.5, 0.999999, 1.0000001, -2.0, 1e-10, INF, NAN]:
		out.append(["asin", x])
	for i in RANDOM_PER_FN:
		out.append(["asin", rng.float_range(-1.0, 1.0)])
	var ex: Array[float] = common.duplicate()
	ex.append_array([DetMath.HALF_LN2, -DetMath.HALF_LN2, DetMath.THREE_HALF_LN2, -DetMath.THREE_HALF_LN2,
		DetMath.EXP_TINY, -DetMath.EXP_TINY, 709.78, 709.79, -708.4, -740.0, -745.1, -745.2, 88.7, -87.3])
	for x in ex:
		out.append(["exp", x])
	for i in RANDOM_PER_FN:
		var sc := 0.5 if i % 3 == 0 else (30.0 if i % 3 == 1 else 700.0)
		out.append(["exp", rng.float_range(-1.0, 1.0) * sc])
	var lg: Array[float] = common.duplicate()
	lg.append_array([DetMath.SQRT2, DetMath.SQRT2 * (1.0 - 1e-16), 0.7071067811865476, normal_min * 1.5,
		DetMath.scalbn(2.0 - DetMath.TWO_M52, DetMath.EXP_MAX), 1.0 + 1e-15, 1.0 - 1e-16])
	for x in lg:
		out.append(["log", x])
	for i in RANDOM_PER_FN:
		out.append(["log", pow(10.0, rng.float_range(-300.0, 300.0)) if i % 2 == 0 else rng.float_range(0.3, 3.0)])
	var pw: Array[float] = [0.0, neg_zero, 1.0, -1.0, 2.0, -2.0, 0.5, 3.0, -3.0, 10.0, 0.93, 1e-300, INF, -INF, NAN]
	for x in pw:
		for y in pw:
			out.append(["pow", x, y])
	for i in RANDOM_PER_FN:
		var y := float(rng.int_range(-12, 12)) if i % 3 == 0 else rng.float_range(-4.0, 4.0)
		out.append(["pow", rng.float_range(0.01, 5.0) * (-1.0 if i % 7 == 0 else 1.0), y])
	return out
