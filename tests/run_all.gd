extends SceneTree
## Headless test runner. Spec: Tech stack → Testing.
##
##   tools/test.sh                      # fast tier (what CI runs)
##   tools/test.sh --tier=soak          # soak tier only
##   tools/test.sh --tier=all
##   tools/test.sh --filter=traffic     # substring of script path or method name
##   tools/test.sh --list
##
## Equivalent raw call (after `godot --headless --import`):
##   godot --headless --script res://tests/run_all.gd -- [args]
## Exits non-zero if any test fails or any test script fails to load.
## Any engine error, push_error() or script runtime error logged while a test runs
## fails that test (a runtime error aborts the method silently otherwise). Tests
## that deliberately trigger an error call `expect_errors(n)` first.

const TEST_ROOT := "res://tests"
const SKIP_DIRS := ["lib", "out", "baselines", "fixtures"]
const SLOW_FAST_TEST_S := 5.0

## Captures errors logged through the engine (OS.add_logger) while tests run.
class ErrorCapture extends Logger:
	var _mutex := Mutex.new()
	var _messages := PackedStringArray()

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		var text := rationale if not rationale.is_empty() else code
		_mutex.lock()
		_messages.append("%s (%s:%d %s)" % [text, file.get_file(), line, function])
		_mutex.unlock()

	func take() -> PackedStringArray:
		_mutex.lock()
		var out := _messages
		_messages = PackedStringArray()
		_mutex.unlock()
		return out


var _errors := ErrorCapture.new()
var _tier := "fast"
var _filter := ""
var _list_only := false


func _initialize() -> void:
	_parse_args(OS.get_cmdline_user_args())
	_run.call_deferred()


func _parse_args(args: PackedStringArray) -> void:
	for a in args:
		if a.begins_with("--tier="):
			_tier = a.get_slice("=", 1)
		elif a.begins_with("--filter="):
			_filter = a.get_slice("=", 1)
		elif a == "--list":
			_list_only = true
		else:
			printerr("run_all: unknown argument %s" % a)
			quit(2)


func _prefixes() -> PackedStringArray:
	match _tier:
		"fast":
			return PackedStringArray(["test_"])
		"soak":
			return PackedStringArray(["soak_"])
		"all":
			return PackedStringArray(["test_", "soak_"])
	printerr("run_all: unknown tier %s (fast|soak|all)" % _tier)
	quit(2)
	return PackedStringArray()


func _run() -> void:
	OS.add_logger(_errors)
	var prefixes := _prefixes()
	var scripts := PackedStringArray()
	_discover(TEST_ROOT, scripts)
	scripts.sort()

	var passed := 0
	var failed := 0
	var failures := PackedStringArray()
	var t_start := Time.get_ticks_msec()

	for path in scripts:
		var script: Script = load(path)
		if script == null or not script.can_instantiate():
			failed += 1
			failures.append("%s: failed to load (parse error?)" % path)
			print("  LOAD ERROR  %s" % path)
			continue
		var methods := _test_methods(script, prefixes, path)
		if methods.is_empty():
			continue
		var suite: Object = script.new()
		if not suite is WBTest:
			failed += 1
			failures.append("%s: does not extend WBTest" % path)
			continue
		suite.tree = self
		print("%s" % path.trim_prefix(TEST_ROOT + "/"))
		if _list_only:
			for m in methods:
				print("    %s" % m)
			continue
		_errors.take()
		await suite.before_all()
		suite._take_failures()
		for e in _errors.take():
			failed += 1
			failures.append("%s::before_all: engine error: %s" % [path, e])
			print("    ERROR in before_all: %s" % e)
		for m in methods:
			_errors.take()
			await suite.before_each()
			var t0 := Time.get_ticks_usec()
			await suite.call(m)
			var dt_s := (Time.get_ticks_usec() - t0) / 1_000_000.0
			await suite.after_each()
			var errs: PackedStringArray = suite._take_failures()
			var logged := _errors.take()
			var allowed: int = suite._take_expected_errors()
			if logged.size() > allowed:
				for e in logged:
					errs.append("engine error: %s" % e)
			elif logged.size() < allowed:
				errs.append("expected %d engine error(s), got %d" % [allowed, logged.size()])
			var timing := "%.2fs" % dt_s
			if m.begins_with("test_") and dt_s > SLOW_FAST_TEST_S:
				timing += " SLOW (fast tier budget %.0fs)" % SLOW_FAST_TEST_S
			if errs.is_empty():
				passed += 1
				print("    ok    %s  %s" % [m, timing])
			else:
				failed += 1
				print("    FAIL  %s  %s" % [m, timing])
				for e in errs:
					print("          - %s" % e)
					failures.append("%s::%s: %s" % [path, m, e])
		await suite.after_all()

	var total_s := (Time.get_ticks_msec() - t_start) / 1000.0
	print("")
	if _list_only:
		quit(0)
		return
	if failed == 0:
		print("ALL PASSED  %d tests  tier=%s  %.1fs" % [passed, _tier, total_s])
		quit(0)
	else:
		print("FAILED  %d failed, %d passed  tier=%s  %.1fs" % [failed, passed, _tier, total_s])
		for f in failures:
			print("  %s" % f)
		quit(1)


func _test_methods(script: Script, prefixes: PackedStringArray, path: String) -> PackedStringArray:
	var out := PackedStringArray()
	for info in script.get_script_method_list():
		var n: String = info["name"]
		var match_prefix := false
		for p in prefixes:
			if n.begins_with(p):
				match_prefix = true
		if not match_prefix or out.has(n):
			continue
		if _filter.is_empty() or path.contains(_filter) or n.contains(_filter):
			out.append(n)
	return out


func _discover(dir_path: String, out: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for sub in dir.get_directories():
		if not SKIP_DIRS.has(sub):
			_discover(dir_path.path_join(sub), out)
	for f in dir.get_files():
		if f.begins_with("test_") and f.ends_with(".gd"):
			out.append(dir_path.path_join(f))
