extends WBTest
## Thermal state sources (src/platform/thermal.gd). Spec: Tech stack → Platform services
## (iOS ProcessInfo.thermalState, Android PowerManager.getCurrentThermalStatus → the
## governor); M9 ("under a forced thermal state"). WP9.1, docs/QUALITY.md → Thermal.
##
## The native plugins cannot run here: a double with the documented plugin interface
## (get_raw_state / get_platform / is_supported / thermal_state_changed) stands in.


class FakePlugin extends Object:
	signal thermal_state_changed(raw_state: int)
	var raw: int = 0
	var platform_name: String = "ios"
	var supported: bool = true
	var reads: int = 0

	func get_raw_state() -> int:
		reads += 1
		return raw

	func get_platform() -> String:
		return platform_name

	func is_supported() -> bool:
		return supported

	func push(value: int) -> void:
		raw = value
		thermal_state_changed.emit(value)


var _plugins: Array[Object] = []
var _changes: Array[StringName] = []


func after_each() -> void:
	for p in _plugins:
		p.free()
	_plugins.clear()
	_changes.clear()


func _plugin(platform_name: String) -> FakePlugin:
	var p := FakePlugin.new()
	p.platform_name = platform_name
	_plugins.append(p)
	return p


func _on_changed(state: StringName) -> void:
	_changes.append(state)


func test_no_plugin_is_nominal_and_unavailable() -> void:
	var th := Thermal.new()
	check(not th.detect(), "no WestboundThermal singleton headless")
	eq(th.get_state(), Thermal.NOMINAL)
	eq(th.source(), Thermal.SOURCE_NONE)
	check(not th.available(), "web / desktop: frame time only")
	th.advance(10.0)
	eq(th.get_state(), Thermal.NOMINAL)


func test_ios_states_map_one_to_one() -> void:
	var th := Thermal.new()
	var p := _plugin("ios")
	check(th.attach_native(p))
	eq(th.platform(), Thermal.PLATFORM_IOS)
	eq(th.source(), Thermal.SOURCE_NATIVE)
	var want: Array[StringName] = [Thermal.NOMINAL, Thermal.FAIR, Thermal.SERIOUS, Thermal.CRITICAL]
	for raw in 4:
		p.push(raw)
		eq(th.get_state(), want[raw], "ProcessInfo.ThermalState %d" % raw)
		eq(th.raw_state(), raw)


func test_android_statuses_map_through_the_tuning() -> void:
	var t := Tuning.load_default().quality
	var th := Thermal.new()
	th.configure(t)
	var p := _plugin("android")
	check(th.attach_native(p))
	eq(t.thermal_android_levels.size(), 7, "THERMAL_STATUS_NONE .. SHUTDOWN")
	var names: Array[String] = ["none", "light", "moderate", "severe", "critical", "emergency", "shutdown"]
	for raw in 7:
		p.push(raw)
		eq(th.level(), t.thermal_android_levels[raw], "THERMAL_STATUS_%s" % names[raw].to_upper())
	p.push(0)
	eq(th.get_state(), Thermal.NOMINAL)
	p.push(2)
	ge(th.level(), 2, "moderate throttling already steps the governor down")
	p.push(99)
	eq(th.get_state(), Thermal.CRITICAL, "past the table: the last level")
	p.push(-1)
	eq(th.get_state(), Thermal.NOMINAL, "unknown reads nominal")


func test_polls_the_plugin_without_a_signal() -> void:
	var t := Tuning.load_default().quality
	var th := Thermal.new()
	th.configure(t)
	var p := _plugin("ios")
	th.attach_native(p)
	var reads := p.reads
	p.raw = 2   # changed without the signal
	th.advance(t.thermal_poll_s * 0.5)
	eq(th.get_state(), Thermal.NOMINAL, "not polled yet")
	th.advance(t.thermal_poll_s * 0.5)
	eq(th.get_state(), Thermal.SERIOUS, "polled every thermal_poll_s")
	eq(p.reads, reads + 1)


func test_unsupported_plugin_is_not_attached() -> void:
	var th := Thermal.new()
	var p := _plugin("android")
	p.supported = false
	check(not th.attach_native(p), "Android < 10: no thermal API")
	eq(th.source(), Thermal.SOURCE_NONE)


func test_changed_signal_fires_once_per_change() -> void:
	var th := Thermal.new()
	th.changed.connect(_on_changed)
	var p := _plugin("ios")
	th.attach_native(p)
	p.push(0)
	p.push(2)
	p.push(2)
	p.push(1)
	eq(_changes, [Thermal.SERIOUS, Thermal.FAIR] as Array[StringName])
	th.detach_native()
	eq(th.get_state(), Thermal.NOMINAL, "detached: nominal")
	p.push(3)
	eq(th.get_state(), Thermal.NOMINAL, "no longer listening")


func test_parse_script() -> void:
	var levels := PackedInt32Array()
	var secs := PackedFloat64Array()
	check(Thermal.parse_script("serious:45,nominal", levels, secs))
	eq(levels, PackedInt32Array([2, 0]))
	eq(secs, PackedFloat64Array([45.0, 0.0]))
	levels.clear()
	secs.clear()
	check(Thermal.parse_script(" critical:2.5 , fair:10,nominal ", levels, secs))
	eq(levels, PackedInt32Array([3, 1, 0]))
	for bad: String in ["", "hot", "serious:x", "serious:-1", "serious:1:2", "nominal,,warm"]:
		var l := PackedInt32Array()
		var s := PackedFloat64Array()
		check(not Thermal.parse_script(bad, l, s), "rejects '%s'" % bad)


func test_forced_script_runs_on_frame_time_and_wins_over_the_plugin() -> void:
	var th := Thermal.new()
	var p := _plugin("ios")
	th.attach_native(p)
	check(th.apply_override("serious:45,fair:5,nominal"))
	eq(th.source(), Thermal.SOURCE_FORCED)
	check(th.available())
	eq(th.get_state(), Thermal.SERIOUS)
	p.push(0)
	eq(th.get_state(), Thermal.SERIOUS, "forced wins over the plugin")
	for i in 44:
		th.advance(1.0)
	eq(th.get_state(), Thermal.SERIOUS)
	th.advance(1.0)
	eq(th.get_state(), Thermal.FAIR, "after 45 s")
	th.advance(5.0)
	eq(th.get_state(), Thermal.NOMINAL, "then the last state")
	th.advance(1000.0)
	eq(th.get_state(), Thermal.NOMINAL, "holds")
	p.raw = 3
	th.clear_force()
	eq(th.source(), Thermal.SOURCE_NATIVE)
	eq(th.get_state(), Thermal.CRITICAL, "back to the plugin")


func test_a_single_state_override_holds() -> void:
	var th := Thermal.new()
	check(th.apply_override("SERIOUS"))
	th.advance(3600.0)
	eq(th.get_state(), Thermal.SERIOUS)
	check(th.apply_override("off"))
	eq(th.source(), Thermal.SOURCE_NONE)
	eq(th.get_state(), Thermal.NOMINAL)


func test_a_bad_override_changes_nothing() -> void:
	var th := Thermal.new()
	check(not th.apply_override("toasty:10"))
	check(not th.is_forced())
	eq(th.get_state(), Thermal.NOMINAL)


func test_dev_cycle() -> void:
	var th := Thermal.new()
	var seen: Array[StringName] = []
	for i in 5:
		th.cycle_force()
		seen.append(th.get_state() if th.is_forced() else &"auto")
	eq(seen, [Thermal.NOMINAL, Thermal.FAIR, Thermal.SERIOUS, Thermal.CRITICAL, &"auto"] as Array[StringName])
