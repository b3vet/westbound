extends WBTest
## The room HUD with a gamepad (owner request, 2026-10-03): while driving the HUD's ROOM and
## REJOIN CREW never take the pad's focus (A stays boost); View opens the room menu, the
## focus moves into it, the D-pad walks it, LB / RB switch its tabs, B closes it, and View
## toggles it too. docs/CONTROLS.md → Menus with a gamepad.

const FakeRoomServer := preload("res://tests/net/fake_room_server.gd")
const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const PAD := 1

var t: Tuning
var net: NetTuning
var time: NetVirtualTime
var link: NetLoopbackLink
var server: RefCounted
var rs: NetRoomSession
var hud: RoomHud
var pad: PadNav


func before_all() -> void:
	t = Tuning.load_default()
	net = NetTuning.load_default()


func before_each() -> void:
	Settings.reset_to_defaults()
	pad = PadNav.new()
	pad.controls = t.controls
	tree.root.add_child(pad)
	time = NetVirtualTime.new(1_000_000)
	link = NetLoopbackLink.new(time, Rng.new(3))
	link.latency_s = 0.03
	link.ordered = true
	server = FakeRoomServer.new(link)
	rs = NetRoomSession.new(link.client, net, RunLoop.loop_road(t).length(), time)
	rs.configure("loop://rooms", 1, NetCodec.hex_to_bytes(
			"0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186"), func() -> String: return "token")
	rs.quick_join()
	for i in 50:
		time.advance_s(0.01)
		server.call("poll")
		rs.poll()
	hud = RoomHud.new()
	tree.root.add_child(hud)
	hud.setup(net, rs)
	hud.set_screen(SCREEN, SCREEN)
	hud.advance(0.0)


func after_each() -> void:
	var f := tree.root.gui_get_focus_owner()
	if f != null:
		f.release_focus()
	for n: Node in [hud, pad]:
		if n != null and is_instance_valid(n):
			n.free()
	hud = null
	pad = null
	rs = null
	server = null
	link = null
	Settings.reset_to_defaults()


func _press(b: JoyButton) -> void:
	for down: bool in [true, false]:
		var ev := InputEventJoypadButton.new()
		ev.button_index = b
		ev.pressed = down
		ev.device = PAD
		Input.parse_input_event(ev)
		Input.flush_buffered_events()


func test_hud_buttons_never_take_the_focus_while_driving() -> void:
	check(hud.room_button.is_visible_in_tree(), "ROOM shows")
	pad.active = true
	pad.refresh_focus()
	check(tree.root.gui_get_focus_owner() == null, "no focus on the HUD's buttons")
	_press(JOY_BUTTON_DPAD_DOWN)
	check(tree.root.gui_get_focus_owner() == null, "the D-pad does not reach them either")
	_press(JOY_BUTTON_A)
	check(not hud.menu.is_open(), "A (boost) does not press ROOM")


func test_view_opens_the_room_menu_and_b_closes_it() -> void:
	_press(JOY_BUTTON_BACK)
	check(hud.menu.is_open(), "View opens the room menu")
	pad.active = true
	pad.refresh_focus()
	var f := tree.root.gui_get_focus_owner()
	check(f != null and hud.menu.is_ancestor_of(f), "the focus moved into the menu")
	var tab := hud.menu.tab
	_press(JOY_BUTTON_RIGHT_SHOULDER)
	ne(hud.menu.tab, tab, "RB: the next tab")
	_press(JOY_BUTTON_DPAD_DOWN)
	f = tree.root.gui_get_focus_owner()
	check(f != null and hud.menu.is_ancestor_of(f), "the D-pad stays in the menu")
	_press(JOY_BUTTON_B)
	check(not hud.menu.is_open(), "B closes it")
	_press(JOY_BUTTON_BACK)
	check(hud.menu.is_open(), "View again")
	_press(JOY_BUTTON_BACK)
	check(not hud.menu.is_open(), "View toggles it shut")
