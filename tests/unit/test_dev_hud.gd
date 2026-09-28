extends WBTest
## Dev HUD smoke test (src/ui/dev_hud.tscn). Spec: Tech stack → Testing.

const DevHudScene := preload("res://src/ui/dev_hud.tscn")

var _hud: Node


func before_each() -> void:
	DevStats.reset()
	_hud = DevHudScene.instantiate()
	tree.root.add_child(_hud)


func after_each() -> void:
	if _hud != null:
		_hud.free()
		_hud = null
	DevStats.reset()


func _key(pressed: bool, echo: bool = false) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = KEY_QUOTELEFT
	ev.physical_keycode = KEY_QUOTELEFT
	ev.pressed = pressed
	ev.echo = echo
	return ev


func _touch(index: int, pressed: bool) -> InputEventScreenTouch:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.pressed = pressed
	ev.position = Vector2(100.0 + 50.0 * index, 300.0)
	return ev


func test_starts_visible_in_debug() -> void:
	eq(_hud.is_hud_visible(), OS.is_debug_build())
	eq(_hud.is_processing(), OS.is_debug_build())


func test_backtick_toggles_and_hidden_stops_processing() -> void:
	_hud.set_hud_visible(true)
	tree.root.push_input(_key(true))
	check(not _hud.is_hud_visible(), "backtick hides")
	check(not _hud.is_processing(), "hidden HUD does not process")
	tree.root.push_input(_key(false))
	tree.root.push_input(_key(true, true))
	check(not _hud.is_hud_visible(), "release and echo do nothing")
	tree.root.push_input(_key(true))
	check(_hud.is_hud_visible(), "backtick shows again")
	check(_hud.is_processing())


func test_three_finger_tap_toggles() -> void:
	_hud.set_hud_visible(false)
	tree.root.push_input(_touch(0, true))
	tree.root.push_input(_touch(1, true))
	check(not _hud.is_hud_visible(), "two fingers are not enough")
	tree.root.push_input(_touch(2, true))
	check(_hud.is_hud_visible(), "third finger toggles")
	# A fourth finger in the same gesture does not toggle back.
	tree.root.push_input(_touch(3, true))
	check(_hud.is_hud_visible(), "one toggle per gesture")
	for i in 4:
		tree.root.push_input(_touch(i, false))
	for i in 3:
		tree.root.push_input(_touch(i, true))
	check(not _hud.is_hud_visible(), "next three-finger tap toggles again")
	for i in 3:
		tree.root.push_input(_touch(i, false))


func test_slow_touches_are_not_a_tap() -> void:
	# A finger held down (e.g. steering) plus two quick taps is not a gesture.
	check(not _hud.handle_touch(0, true, 1000))
	check(not _hud.handle_touch(1, true, 5000))
	check(not _hud.handle_touch(2, true, 5050))
	check(_hud.handle_touch(3, true, 5100), "three recent touches")


func test_refresh_shows_reported_values() -> void:
	_hud.set_hud_visible(true)
	for _i in 3:
		await tree.process_frame
	_hud.refresh()
	eq(_hud.get_row_text(_hud.Row.VEHICLES), "-", "no vehicles reported yet")
	eq(_hud.get_row_text(_hud.Row.SIM), "-")
	check(not _hud.get_row_text(_hud.Row.FPS).is_empty(), "fps shown")
	check(not _hud.get_row_text(_hud.Row.SCALE).is_empty(), "render scale shown")
	DevStats.report(DevStats.VEHICLES, 42)
	DevStats.report_sim_tick_usec(250)
	DevStats.report(DevStats.THERMAL, Thermal.NOMINAL)
	DevStats.report(DevStats.QUALITY_TIER, &"medium")
	DevStats.report(DevStats.GOVERNOR_RUNG, 2)
	_hud.refresh()
	eq(_hud.get_row_text(_hud.Row.VEHICLES), "42")
	eq(_hud.get_row_text(_hud.Row.SIM), "0.25 ms  max 0.25")
	eq(_hud.get_row_text(_hud.Row.THERMAL), "nominal")
	eq(_hud.get_row_text(_hud.Row.QUALITY), "medium  gov 2")
