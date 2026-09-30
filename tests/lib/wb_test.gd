class_name WBTest
extends RefCounted
## Base class for headless tests. Discovered by tests/run_all.gd.
##
## Put tests in `tests/**/test_<system>.gd`, extending WBTest:
##   - methods named `test_*` run in the fast tier (every commit, CI);
##   - methods named `soak_*` run in the soak tier (pre-gate, on demand).
## Methods may `await` (e.g. `await tree.process_frame`) when they need the tree.
## Assertions record a failure and return false; they never abort the method, so
## `if not check(...): return` when later lines depend on it.

## The running SceneTree. Tests that need nodes add them under `tree.root`
## and must free them in after_each().
var tree: SceneTree

var _failures: PackedStringArray = []
var _expected_errors: int = 0


# ---------------------------------------------------------------- Lifecycle hooks

func before_all() -> void:
	pass


func before_each() -> void:
	pass


func after_each() -> void:
	pass


func after_all() -> void:
	pass


# ---------------------------------------------------------------- Assertions

func check(condition: bool, message: String = "") -> bool:
	if not condition:
		_fail("check failed", message)
	return condition


func fail(message: String) -> void:
	_fail("fail", message)


func eq(actual: Variant, expected: Variant, message: String = "") -> bool:
	if typeof(actual) != typeof(expected) and not (_is_number(actual) and _is_number(expected)):
		_fail("expected %s (%s), got %s (%s)" % [
			var_to_str(expected), type_string(typeof(expected)),
			var_to_str(actual), type_string(typeof(actual))], message)
		return false
	if actual != expected:
		_fail("expected %s, got %s" % [var_to_str(expected), var_to_str(actual)], message)
		return false
	return true


func ne(actual: Variant, unexpected: Variant, message: String = "") -> bool:
	if actual == unexpected:
		_fail("did not expect %s" % var_to_str(unexpected), message)
		return false
	return true


## |actual - expected| <= tolerance (absolute).
func near(actual: float, expected: float, tolerance: float, message: String = "") -> bool:
	if is_nan(actual) or absf(actual - expected) > tolerance:
		_fail("expected %s ± %s, got %s" % [expected, tolerance, actual], message)
		return false
	return true


## |actual - expected| <= fraction * |expected| (relative, e.g. 0.05 for ±5%).
func within_pct(actual: float, expected: float, fraction: float, message: String = "") -> bool:
	var tol := absf(expected) * fraction
	if is_nan(actual) or absf(actual - expected) > tol:
		_fail("expected %s ±%s%% (±%s), got %s (%+.2f%%)" % [
			expected, fraction * 100.0, tol, actual,
			(actual - expected) / expected * 100.0 if expected != 0.0 else INF], message)
		return false
	return true


func lt(actual: float, bound: float, message: String = "") -> bool:
	if not (actual < bound):
		_fail("expected < %s, got %s" % [bound, actual], message)
		return false
	return true


func le(actual: float, bound: float, message: String = "") -> bool:
	if not (actual <= bound):
		_fail("expected <= %s, got %s" % [bound, actual], message)
		return false
	return true


func gt(actual: float, bound: float, message: String = "") -> bool:
	if not (actual > bound):
		_fail("expected > %s, got %s" % [bound, actual], message)
		return false
	return true


func ge(actual: float, bound: float, message: String = "") -> bool:
	if not (actual >= bound):
		_fail("expected >= %s, got %s" % [bound, actual], message)
		return false
	return true


func finite(value: float, message: String = "") -> bool:
	if is_nan(value) or is_inf(value):
		_fail("expected a finite number, got %s" % value, message)
		return false
	return true


## Declare that the current test deliberately triggers `count` engine errors
## (push_error, script errors). Otherwise any logged error fails the test.
func expect_errors(count: int) -> void:
	_expected_errors += count


# ---------------------------------------------------------------- Runner interface

func _take_expected_errors() -> int:
	var n := _expected_errors
	_expected_errors = 0
	return n


func _take_failures() -> PackedStringArray:
	var out := _failures
	_failures = PackedStringArray()
	return out


func _fail(what: String, message: String) -> void:
	var line := what if message.is_empty() else "%s: %s" % [message, what]
	_failures.append(line)


static func _is_number(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT
