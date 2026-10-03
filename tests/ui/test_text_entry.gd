extends WBTest
## The text entry overlay (SocialField + TextEntryOverlay; owner request 2026-10-03: the
## on-screen keyboard hides the text fields): the mode rule (forced by the -1/0/1
## override), a tap opening the bar at the top with the field's text, rules and prompt,
## DONE and the return key writing back (return also submits, as Enter does in place),
## every cancel path (CANCEL, the dim, Esc, the pad's B, Android back) leaving the field
## alone, key muting while open, nothing behind it tappable, PadNav inside it, the bar
## above a reported keyboard, in-place typing when off, the web prompt winning, a crew
## join typed through it, and its text fit at both text sizes on 667x375 and 844x390
## phones. Touches go through Input.parse_input_event with an iOS-style id.
## docs/SCREENS.md → Social → Text fields.

const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const IOS_ID := 1_893_457_201
const PH := "ROOM CODE"
const QUESTION := "Room code (6 characters)"
const ME := "41"
## The canvases of a 667x375 and an 844x390 phone (canvas_items, expand: 720 tall), the
## latter with its notch and home-bar insets.
const PHONES: Array[Vector2] = [Vector2(1280.0, 720.0), Vector2(1558.0, 720.0)]
const NOTCH := Vector4(87.0, 0.0, 87.0, 39.0)
const TOL := 0.5

var hud: HudTuning
var style: HudStyle
var probe := HudTextProbe.new()
var _nodes: Array[Node] = []
var _changed: PackedStringArray = PackedStringArray()
var _submitted: PackedStringArray = PackedStringArray()


class MockBridge:
	extends NetJsBridge
	var answer: Variant = null

	func available() -> bool:
		return true

	func eval(_code: String) -> Variant:
		return answer


func before_all() -> void:
	hud = Tuning.load_default().hud


func before_each() -> void:
	tree.paused = false
	Settings.reset_to_defaults()
	style = HudStyle.new()
	style.setup(UiTheme.load_theme(), hud, 1.0)
	_changed.clear()
	_submitted.clear()


func after_each() -> void:
	HudDraw.probe = null
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	Settings.reset_to_defaults()
	await tree.process_frame


func _root() -> Control:
	var root := Control.new()
	root.size = SCREEN.size
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tree.root.add_child(root)
	_nodes.append(root)
	return root


## A field low on the screen (where the keyboard would cover it), overlay forced.
func _field(mode: int = 1) -> SocialField:
	var f := SocialField.new()
	f.name = "CodeField"
	f.prompt_mode = 0
	f.entry_mode = mode
	f.placeholder_text = PH
	f.prompt_message = QUESTION
	f.max_length = 8
	_root().add_child(f)
	SocialUi.style_edit(f, style, hud)
	SocialUi.place(f, Vector2(400.0, 560.0), Vector2(420.0, hud.touch_target_px))
	f.text_changed.connect(func(t: String) -> void: _changed.append(t))
	f.text_submitted.connect(func(t: String) -> void: _submitted.append(t))
	return f


func _tap_at(p: Vector2) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = IOS_ID
	ev.position = tree.root.get_final_transform() * p
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()
	var up := ev.duplicate() as InputEventScreenTouch
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()


func _tap(c: Control) -> void:
	_tap_at(c.get_global_rect().get_center())


func _key(code: Key, unicode: int = 0) -> void:
	for down: bool in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.unicode = unicode
		ev.pressed = down
		Input.parse_input_event(ev)
		Input.flush_buffered_events()


## Taps the field and lets the deferred open run.
func _open(f: SocialField) -> TextEntryOverlay:
	_tap(f)
	await tree.process_frame
	return f.entry


# ---------------------------------------------------------------- Opening

func test_tap_opens_the_bar_at_the_top_with_the_field() -> void:
	var f := _field()
	f.text = "K7Q"
	check(f.uses_overlay(), "forced on")
	check(not f.virtual_keyboard_enabled, "the field never opens the keyboard itself")
	var e: TextEntryOverlay = await _open(f)
	check(e != null and e.is_open() and f.is_entry_open(), "a tap opens the overlay")
	eq(f.entries, 1)
	eq(e.layer, TextEntryOverlay.LAYER)
	eq(e.edit.text, "K7Q", "pre-filled")
	eq(e.edit.caret_column, 3, "caret at the end")
	check(e.edit.has_focus(), "its field has the focus: the OS keyboard types there")
	check(e.edit.virtual_keyboard_enabled)
	check(not f.has_focus())
	eq(e.edit.max_length, 8)
	eq(e.edit.placeholder_text, PH)
	eq(e.caption.text, QUESTION.to_upper(), "the field's prompt")
	var bar := e.panel.get_global_rect()
	le(bar.end.y, SCREEN.size.y * 0.5, "the bar sits in the top half")
	lt(bar.end.y, f.get_global_rect().position.y, "above the field it types for")
	eq(e.backdrop.get_global_rect(), Rect2(Vector2.ZERO, tree.root.get_visible_rect().size), "the dim covers the canvas")
	eq(_changed.size(), 0, "opening changes nothing")


func test_focus_from_keys_or_pad_opens_it_too() -> void:
	var f := _field()
	f.grab_focus()
	await tree.process_frame
	check(f.is_entry_open(), "any focus opens the overlay")
	f.entry.cancel()
	f.editable = false
	_tap(f)
	await tree.process_frame
	check(not f.is_entry_open(), "a read-only field never opens it")


func test_rules_come_from_the_field() -> void:
	var f := _field()
	f.max_length = 6
	f.secret = true
	f.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_EMAIL_ADDRESS
	var e: TextEntryOverlay = await _open(f)
	check(e.edit.secret, "secret")
	eq(e.edit.virtual_keyboard_type, LineEdit.KEYBOARD_TYPE_EMAIL_ADDRESS)
	e.edit.insert_text_at_caret("ABCDEFG")
	eq(e.edit.text, "ABCDEF", "max_length while typing")
	e.edit.text = " WXYZ "
	_tap(e.done_button)
	eq(f.text, "WXYZ", "trimmed like the prompt's answer")


# ---------------------------------------------------------------- Writing back

func test_done_writes_back_without_submitting() -> void:
	var f := _field()
	var e: TextEntryOverlay = await _open(f)
	e.edit.insert_text_at_caret("K7QX2M")
	_tap(e.done_button)
	check(not e.is_open() and not e.visible and not f.is_entry_open(), "DONE closes it")
	eq(f.text, "K7QX2M")
	eq(f.caret_column, 6)
	eq(_changed, PackedStringArray(["K7QX2M"]), "text_changed, as typing")
	eq(_submitted.size(), 0, "DONE fills the field; the player taps JOIN")
	check(not e.edit.has_focus())


func test_return_key_writes_back_and_submits() -> void:
	var f := _field()
	var e: TextEntryOverlay = await _open(f)
	for c in "k7qx":
		_key(OS.find_keycode_from_string(c.to_upper()), c.unicode_at(0))
	eq(e.edit.text, "k7qx", "the keys type into the overlay's field")
	_key(KEY_ENTER)
	check(not e.is_open())
	eq(f.text, "k7qx")
	eq(_changed, PackedStringArray(["k7qx"]))
	eq(_submitted, PackedStringArray(["k7qx"]), "return submits, as Enter in the field does")


func test_cancel_paths_leave_the_field_alone() -> void:
	PadNav.register_actions()
	var f := _field()
	f.text = "ORIG"
	var behind := ScreenButton.make("BEHIND", ScreenButton.Kind.NORMAL, 20)
	behind.setup(style)
	SocialUi.place(behind, Vector2(40.0, 600.0), Vector2(200.0, hud.touch_target_px))
	f.get_parent().add_child(behind)
	var presses: Array[int] = [0]
	behind.pressed.connect(func() -> void: presses[0] += 1)
	for how: String in ["cancel", "dim", "esc", "pad_b", "back"]:
		var e: TextEntryOverlay = await _open(f)
		check(e.is_open(), how)
		e.edit.text = "CHANGED"
		match how:
			"cancel":
				_tap(e.cancel_button)
			"dim":
				_tap(behind)
			"esc":
				_key(KEY_ESCAPE)
			"pad_b":
				for down: bool in [true, false]:
					var ev := InputEventJoypadButton.new()
					ev.button_index = JOY_BUTTON_B
					ev.pressed = down
					Input.parse_input_event(ev)
					Input.flush_buffered_events()
			"back":
				e.propagate_notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
		check(not e.is_open() and not f.is_entry_open(), "%s closes it" % how)
		eq(f.text, "ORIG", "%s leaves the field" % how)
		eq(_changed.size(), 0, how)
		eq(_submitted.size(), 0, how)
		eq(e.edit.text, "", "%s: nothing typed stays behind" % how)
	eq(presses[0], 0, "nothing behind the dim takes the tap")


# ---------------------------------------------------------------- Keys, pad, keyboard

func test_keys_stay_muted_while_open() -> void:
	var hub := PlayerInput.new()
	tree.root.add_child(hub)
	_nodes.append(hub)
	var f := _field()
	f.hub = hub
	var e: TextEntryOverlay = await _open(f)
	check(not f.has_focus(), "the focus moved to the overlay")
	check(not hub.is_processing_input(), "keys go to the overlay only")
	_tap(e.done_button)
	check(hub.is_processing_input(), "DONE gives them back")
	e = await _open(f)
	check(not hub.is_processing_input())
	f.visible = false
	check(not e.is_open(), "hiding the field cancels")
	check(hub.is_processing_input(), "and gives the keys back")


func test_pad_moves_inside_the_overlay_and_b_cancels() -> void:
	PadNav.register_actions()
	var nav := PadNav.new()
	tree.root.add_child(nav)
	_nodes.append(nav)
	var f := _field()
	var under := ScreenButton.make("UNDER", ScreenButton.Kind.NORMAL, 20)
	under.setup(style)
	SocialUi.place(under, Vector2(40.0, 600.0), Vector2(200.0, hud.touch_target_px))
	f.get_parent().add_child(under)
	var e: TextEntryOverlay = await _open(f)
	var scope := nav.scope_buttons()
	eq(scope.size(), 2, "only the overlay's buttons")
	check(scope.has(e.done_button) and scope.has(e.cancel_button))
	check(nav.navigable(scope), "a modal for the pad")
	check(nav.press_back(), "B with no handler: CANCEL")
	check(not e.is_open())


func test_bar_stays_above_a_reported_keyboard() -> void:
	var full := SCREEN
	var g := hud.spacing_grid_px * 2.0
	eq(TextEntryOverlay.bar_top(full, full, 150.0, 0.0, g), g, "no keyboard: under the safe top")
	eq(TextEntryOverlay.bar_top(full, Rect2(0.0, 30.0, 1280.0, 690.0), 150.0, 0.0, g), 30.0 + g)
	eq(TextEntryOverlay.bar_top(full, full, 150.0, 400.0, g), g, "a phone keyboard: room to spare")
	eq(TextEntryOverlay.bar_top(full, full, 150.0, 600.0, g), 0.0, "never above the canvas")
	near(TextEntryOverlay.bar_top(full, full, 150.0, 540.0, g), 720.0 - 540.0 - g - 150.0, 1e-6)
	var f := _field()
	var e: TextEntryOverlay = await _open(f)
	e.keyboard_override_px = 520.0
	e._process(0.0)
	le(e.panel.get_global_rect().end.y, SCREEN.size.y - 520.0 + TOL, "the bar moved above it")


# ---------------------------------------------------------------- Other modes

func test_off_types_in_place() -> void:
	var f := _field(0)
	check(not f.uses_overlay())
	check(f.virtual_keyboard_enabled, "the field opens the keyboard itself")
	_tap(f)
	await tree.process_frame
	check(f.has_focus(), "focused in place")
	check(f.entry == null and f.entries == 0, "no overlay")
	_key(KEY_A, "A".unicode_at(0))
	eq(f.text, "A", "typed in place")
	await tree.process_frame   # LineEdit emits text_changed deferred
	eq(_changed, PackedStringArray(["A"]))


func test_web_touch_keeps_the_prompt() -> void:
	var f := _field(1)
	var mb := MockBridge.new()
	mb.answer = " k7qx2m "
	f.bridge = mb
	f.prompt_mode = 1
	check(f.uses_prompt() and not f.uses_overlay(), "the prompt wins")
	_tap(f)
	await tree.process_frame
	eq(f.prompts, 1)
	eq(f.entries, 0, "no overlay on the web prompt path")
	eq(f.text, "k7qx2m")


func test_automatic_rule() -> void:
	var f := _field(-1)
	f.prompt_mode = -1
	var t := NetTuning.load_default().duplicate() as NetTuning
	f.net_tuning = t
	check(t.text_entry_overlay, "on by default")
	eq(f.uses_overlay(), DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD)
			and DisplayServer.is_touchscreen_available(), "an OS keyboard on a touch screen")
	check(not f.uses_overlay(), "headless: typed in place")
	t.text_entry_overlay = false
	f.net_tuning = t
	check(not f.uses_overlay(), "the tuning turns it off")


# ---------------------------------------------------------------- A real screen

func test_crew_join_typed_through_the_overlay() -> void:
	var fake := NetFakeSocial.new()
	var session := NetSession.new()
	session.auto_start = false
	session.configure(fake, NetSessionStore.new(), NetTuning.load_default(), NetVirtualTime.new(1_000_000),
			"https://social.test/api/v1", 4)
	session.unix_clock = func() -> float: return fake.now_s
	tree.root.add_child(session)
	_nodes.append(session)
	await session.start()
	var owner := fake.add_player("Owner", 1)
	var cid := fake.make_crew(owner, "Night Riders", "NR")
	var p := ProfilePanel.new()
	p.size = SCREEN.size
	_root().add_child(p)
	p.setup(style, hud)
	p.bind(session)
	p.layout(Rect2(46.0, 150.0, 1188.0, 524.0))
	p.open()
	p.show_view(ProfilePanel.View.CREW)
	var cp := p.crew
	await cp.load_crew()
	cp.code_field.entry_mode = 1
	var e: TextEntryOverlay = await _open(cp.code_field)
	check(e != null and e.is_open(), "the crew's code field opens it")
	eq(e.caption.text, CrewPanel.TEXT_CODE_PROMPT.to_upper())
	eq(e.edit.max_length, cp.code_field.max_length)
	e.edit.text = String((fake.crews[cid] as Dictionary)["code"])
	_key(KEY_ENTER)
	eq(cp.code_field.text, String((fake.crews[cid] as Dictionary)["code"]))
	eq(cp.members_text.text, "2/16 MEMBERS · YOU: MEMBER", "return joined, as Enter in the field")


# ---------------------------------------------------------------- Text fit

func test_text_fits_on_small_phones_at_both_text_sizes() -> void:
	HudDraw.probe = probe
	var n := 0
	for size in PHONES:
		var full := Rect2(Vector2.ZERO, size)
		var safe := full
		if size.x > PHONES[0].x:
			safe = ScreenInsets.safe_rect(full, NOTCH)
		for ts in hud.text_scales:
			style.setup(UiTheme.load_theme(), hud, ts)
			for q: String in [QUESTION, CrewPanel.TEXT_NAME_PROMPT, CrewPanel.TEXT_CODE_PROMPT,
					FriendsPanel.TEXT_PROMPT]:
				var what := "%dx%d text %d%% '%s'" % [size.x, size.y, roundi(ts * 100.0), q]
				var f := _field()
				f.prompt_message = q
				var e: TextEntryOverlay = await _open(f)
				e.set_screen(full, safe)
				_redraw(e)
				probe.clear()
				await tree.process_frame
				n += _check(e, full, safe, what)
				eq(e.caption.text, q.to_upper(), "%s: the prompt shows whole" % what)
				e.cancel()
	gt(n, 0)


func _redraw(n: Node) -> void:
	if n is CanvasItem:
		(n as CanvasItem).queue_redraw()
	for ch in n.get_children(true):
		_redraw(ch)


func _check(e: TextEntryOverlay, full: Rect2, safe: Rect2, what: String) -> int:
	var bar := e.panel.get_global_rect()
	check(safe.grow(TOL).encloses(bar), "%s: bar %s inside the safe area %s" % [what, bar, safe])
	le(bar.end.y, full.size.y * 0.5, "%s: the bar is in the top half" % what)
	var controls: Array[Control] = [e.edit, e.cancel_button, e.done_button]
	for c in controls:
		check(bar.grow(TOL).encloses(c.get_global_rect()), "%s: %s inside the bar" % [what, c.name])
		ge(c.size.y, hud.touch_target_px - TOL, "%s: %s touch target" % [what, c.name])
	for a in controls.size():
		for b in range(a + 1, controls.size()):
			check(not controls[a].get_global_rect().grow(-TOL).intersects(controls[b].get_global_rect().grow(-TOL)),
					"%s: %s overlaps %s" % [what, controls[a].name, controls[b].name])
	ge(e.edit.size.x, hud.touch_target_px * 2.0, "%s: room to type" % what)
	var k := 0
	for i in probe.size():
		var ci := probe.items[i]
		if not is_instance_valid(ci) or not e.is_ancestor_of(ci):
			continue
		k += 1
		var g := probe.global_rect(i)
		var box: Rect2 = (ci as Control).get_global_rect()
		check(box.grow(TOL).encloses(g), "%s: '%s' %s runs out of %s %s" % [what, probe.texts[i], g, ci.name, box])
		check(bar.grow(TOL).encloses(g), "%s: '%s' runs out of the bar" % [what, probe.texts[i]])
		for c in controls:
			if c != ci:
				check(not g.grow(-TOL).intersects(c.get_global_rect().grow(-TOL)),
						"%s: '%s' runs under %s" % [what, probe.texts[i], c.name])
	ge(k, 3, "%s: the prompt, CANCEL and DONE drawn" % what)
	return k
