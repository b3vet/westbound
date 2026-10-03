class_name PadNav
extends Node
## Gamepad (and keyboard) navigation of every menu. Owner request (2026-10-03): play the
## web build with an Xbox controller. Spec: Controls → Keyboard and gamepad; UI →
## Screens. docs/CONTROLS.md → Menus with a gamepad.
##
## One per run (Run adds it first among its children, so its _unhandled_input runs after
## every screen's). Generic: no screen needs code for it. It works on ScreenButtons (they
## join BUTTON_GROUP and draw a focus ring while they hold visible focus):
##   - the scope: the ScreenButtons a pointer could press now (visible, enabled, taking
##     touches, not under a later full-cover sibling that takes touches, such as a modal
##     panel or a dim), in the highest CanvasLayer that has any, and not in a screen that
##     is closing;
##   - D-pad, left stick and arrow keys move the focus to the nearest button in that
##     direction inside the scope (never to a covered one); the first press only shows the
##     focus on the screen's default button (RunScreen.pad_default_focus(), else its
##     PRIMARY button, else the top-left one);
##   - A / Enter press the focused button (BaseButton's own ui_accept); B / Esc are the
##     screens' own ui_cancel, and when no screen took it, the scope's BACK / CLOSE /
##     CANCEL / DONE / NOT NOW / NO button;
##   - LB / RB (PageUp / PageDown) switch the scope's top row of OPTION tabs;
##   - while the player uses the pad or keys (`active`), a screen that opens gets its
##     default focus, and focus left on a covered button moves into the new scope; a
##     touch or a click ends that (the focus goes, as before this existed);
##   - screens that steer with the arrows themselves (RunScreen.pad_focus false: the
##     garage, the achievements) keep them: no focus there;
##   - buttons on the gameplay HUD (the room HUD's ROOM, REJOIN CREW) never take the
##     focus: a scope counts only inside a RunScreen or a modal panel (a Control that
##     takes touches over most of the screen, like the room menu), so A stays boost while
##     driving. The room menu opens from the pad with View (RoomHud, wb_room_menu).
## The left stick and held D-pad directions repeat (pad_nav_repeat_delay_s, then every
## pad_nav_repeat_s) as synthesized ui_* InputEventActions, so a screen's own handler
## (the garage's ui_left) sees the stick exactly like the D-pad.
##
## Bindings (register_actions(), idempotent, every device: a browser numbers pads by its
## Gamepad.index): ui_accept += A, ui_cancel += B, ui_up/down/left/right keep the
## engine's D-pad and lose its left-stick axes (PadNav synthesizes those), wb_tab_prev /
## wb_tab_next = LB / RB and PageUp / PageDown, wb_room_menu = View / Back.

const GROUP := &"wb_pad_nav"
## Every ScreenButton in the tree (ScreenButton joins it).
const BUTTON_GROUP := &"wb_pad_buttons"
const TAB_PREV := &"wb_tab_prev"
const TAB_NEXT := &"wb_tab_next"
## Gamepad View / Back: the room HUD's menu (RoomHud).
const ROOM_MENU := &"wb_room_menu"
const ACCEPT := &"ui_accept"
const CANCEL := &"ui_cancel"
const DIRS: Array[StringName] = [&"ui_left", &"ui_right", &"ui_up", &"ui_down"]
const DIR_VECTORS: Array[Vector2] = [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]
const NO_DIR := -1
## Labels of the button B presses when no screen handled ui_cancel, in preference order.
const BACK_TEXTS: Array[String] = ["BACK", "CLOSE", "CANCEL", "NOT NOW", "NO", "DONE"]
## Neighbour score: the sideways gap weighs this much more than the distance ahead.
const SIDE_WEIGHT := 2.0
## How often (s) the scope is checked while `active` (a new screen, a covered focus).
const SCAN_S := 0.1   # lint: allow-number UI poll period, not gameplay
## Hold sources (repeat).
enum Source { NONE, DPAD, STICK }

var controls: ControlsTuning
## The player is driving the menus with a pad or keys: the focus shows and follows.
var active: bool = false
## Scope scans (tests: nothing scans while touch drives the menus).
var scans: int = 0

var _hold_dir: int = NO_DIR
var _hold_source: Source = Source.NONE
var _repeat_left: float = 0.0
var _stick := Vector2.ZERO
var _stick_dir: int = NO_DIR
var _scan_left: float = 0.0


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _enter_tree() -> void:
	add_to_group(GROUP)


func _ready() -> void:
	register_actions()
	if controls == null:
		controls = Tuning.load_default().controls
	Input.joy_connection_changed.connect(_on_joy_connection)


## One console line per pad (the web build's console shows what the browser reports;
## the --gamepad smoke waits for it).
func _on_joy_connection(device: int, connected: bool) -> void:
	if not _leads():
		return
	if connected:
		print("pad: connected %d %s (%s)" % [device, Input.get_joy_name(device),
				"mapped" if Input.is_joy_known(device) else "unknown mapping"])
	else:
		print("pad: disconnected %d" % device)


# ---------------------------------------------------------------- Bindings

static func register_actions() -> void:
	_ensure(ACCEPT, _joy(JOY_BUTTON_A))
	_ensure(CANCEL, _joy(JOY_BUTTON_B))
	var pads: Array[JoyButton] = [JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT, JOY_BUTTON_DPAD_UP,
			JOY_BUTTON_DPAD_DOWN]
	for i in DIRS.size():
		_ensure(DIRS[i], _joy(pads[i]))
		# The engine binds the left stick to ui_* too; PadNav turns the stick into
		# discrete ui_* presses itself (hysteresis, repeat, the scope), so a stick held
		# over never reads as a stream of presses in a screen's own handler.
		for ev in InputMap.action_get_events(DIRS[i]):
			if ev is InputEventJoypadMotion:
				InputMap.action_erase_event(DIRS[i], ev)
	_ensure(TAB_PREV, _joy(JOY_BUTTON_LEFT_SHOULDER))
	_ensure(TAB_PREV, _key(KEY_PAGEUP))
	_ensure(TAB_NEXT, _joy(JOY_BUTTON_RIGHT_SHOULDER))
	_ensure(TAB_NEXT, _key(KEY_PAGEDOWN))
	_ensure(ROOM_MENU, _joy(JOY_BUTTON_BACK))


static func _ensure(action: StringName, ev: InputEvent) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	if not InputMap.action_has_event(action, ev):
		InputMap.action_add_event(action, ev)


static func _joy(button: JoyButton) -> InputEventJoypadButton:
	var ev := InputEventJoypadButton.new()
	ev.button_index = button
	ev.device = KeysGamepad.ALL_DEVICES
	return ev


static func _key(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	return ev


# ---------------------------------------------------------------- Input

func _input(event: InputEvent) -> void:
	if not _leads():
		return
	if _is_pointer_press(event):
		active = false
		_hold_dir = NO_DIR
		_drop_button_focus()
		return
	if event is InputEventJoypadMotion:
		_stick_moved(event as InputEventJoypadMotion)
		return
	var typing := event is InputEventKey and _text_focused()
	if typing:
		return
	var dir := _dir_of(event)
	if dir != NO_DIR:
		if event.is_pressed():
			active = true
			if event is InputEventJoypadButton:
				_start_hold(dir, Source.DPAD)
			if navigate(dir):
				get_viewport().set_input_as_handled()
		elif event is InputEventJoypadButton and _hold_source == Source.DPAD and _hold_dir == dir:
			_hold_dir = NO_DIR
		return
	if event.is_action_pressed(TAB_PREV) or event.is_action_pressed(TAB_NEXT):
		active = true
		if switch_tab(-1 if event.is_action_pressed(TAB_PREV) else 1):
			get_viewport().set_input_as_handled()
		return
	if (event is InputEventJoypadButton or event is InputEventKey) and event.is_pressed():
		active = true


## B / Esc that no screen handled: the scope's back button.
func _unhandled_input(event: InputEvent) -> void:
	if not _leads() or not event.is_action_pressed(CANCEL):
		return
	if event is InputEventKey and _text_focused():
		return
	if press_back():
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not _leads():
		return
	if _hold_dir != NO_DIR and controls != null:
		_repeat_left -= delta
		if _repeat_left <= 0.0:
			_repeat_left = controls.pad_nav_repeat_s
			_emit_dir(_hold_dir, true)
	if not active:
		return
	_scan_left -= delta
	if _scan_left > 0.0:
		return
	_scan_left = SCAN_S
	refresh_focus()


# ---------------------------------------------------------------- API

## Moves the focus one step towards DIRS[dir] inside the scope. True when the scope is
## navigated here (the event is consumed even at an edge: the engine's own search could
## reach a covered button); false for a manual scope (its screen takes the arrows) or none.
func navigate(dir: int) -> bool:
	var scope := scope_buttons()
	if not navigable(scope):
		return false
	var cur := get_viewport().gui_get_focus_owner() as ScreenButton
	if cur == null or not scope.has(cur):
		_focus(default_focus(scope))
		return true
	var next := neighbor(cur, DIR_VECTORS[dir], scope)
	if next != null:
		_focus(next)
	return true


## Puts the focus on the scope's default button when it has none there (a screen opened,
## a panel covered the old focus). Called every SCAN_S while `active`.
func refresh_focus() -> void:
	var scope := scope_buttons()
	var f := get_viewport().gui_get_focus_owner()
	if not navigable(scope):
		if f is ScreenButton and not scope.has(f as ScreenButton):
			f.release_focus()
		return
	if f is ScreenButton and scope.has(f as ScreenButton):
		return
	if f != null and not f is ScreenButton and f.is_visible_in_tree():
		return   # a text field the player clicked into keeps its focus
	_focus(default_focus(scope))


## LB / RB: the next (step 1) or previous (-1) tab of the scope's top OPTION row (two or
## more OPTION buttons on one line with one selected), wrapping. True when switched.
func switch_tab(step: int) -> bool:
	var scope := scope_buttons()
	if not navigable(scope):
		return false
	var row := _tab_row(scope)
	if row.is_empty():
		return false
	var sel := 0
	for i in row.size():
		if row[i].selected:
			sel = i
	var to := row[posmod(sel + step, row.size())]
	var f := get_viewport().gui_get_focus_owner() as ScreenButton
	to.pressed.emit()
	if f != null and row.has(f) and to.is_visible_in_tree():
		_focus(to)
	return true


## B with nothing else handling it: presses the scope's back button. True when pressed.
func press_back() -> bool:
	var scope := scope_buttons()
	if not navigable(scope):
		return false
	for text in BACK_TEXTS:
		for b in scope:
			if b.text == text:
				b.pressed.emit()
				return true
	return false


## The ScreenButtons a pointer could press now, in tree order (see the class comment).
func scope_buttons() -> Array[ScreenButton]:
	scans += 1
	var out: Array[ScreenButton] = []
	var top := -(1 << 30)
	var view := get_viewport().get_visible_rect()
	for n in get_tree().get_nodes_in_group(BUTTON_GROUP):
		var b := n as ScreenButton
		if b == null or not _reachable(b, view) or _covered(b):
			continue
		var layer := _layer_of(b)
		if layer > top:
			top = layer
			out.clear()
		if layer == top:
			out.append(b)
	return out


## The button a screen starts on: its pad_default_focus(), else the first PRIMARY, else
## the top-left one.
func default_focus(scope: Array[ScreenButton]) -> ScreenButton:
	var screen := _screen_of(scope[0])
	if screen != null:
		var d := screen.pad_default_focus() as ScreenButton
		if d != null and scope.has(d):
			return d
	for b in scope:
		if b.kind == ScreenButton.Kind.PRIMARY:
			return b
	var best := scope[0]
	for b in scope:
		var p := b.get_global_rect().position
		var q := best.get_global_rect().position
		if p.y < q.y or (is_equal_approx(p.y, q.y) and p.x < q.x):
			best = b
	return best


## The nearest button from `from` towards `dir` (a unit axis): ahead of it, scored by the
## gap ahead plus SIDE_WEIGHT x the sideways gap (0 when they overlap sideways). Null at
## an edge.
static func neighbor(from: Control, dir: Vector2, scope: Array[ScreenButton]) -> ScreenButton:
	var a := from.get_global_rect()
	var ac := a.get_center()
	var best: ScreenButton = null
	var best_score := INF
	for b in scope:
		if b == from:
			continue
		var r := b.get_global_rect()
		var ahead := (r.get_center() - ac).dot(dir)
		if ahead <= 0.0:
			continue
		var gap := 0.0
		var side := 0.0
		if dir.x != 0.0:
			gap = maxf(r.position.x - a.end.x, a.position.x - r.end.x)
			side = maxf(maxf(r.position.y - a.end.y, a.position.y - r.end.y), 0.0)
		else:
			gap = maxf(r.position.y - a.end.y, a.position.y - r.end.y)
			side = maxf(maxf(r.position.x - a.end.x, a.position.x - r.end.x), 0.0)
		var score := maxf(gap, 0.0) + side * SIDE_WEIGHT + ahead * 0.001   # lint: allow-number tie-break
		if score < best_score:
			best_score = score
			best = b
	return best


# ---------------------------------------------------------------- Internals

## Several runs (tests) may each have one: the first in the group leads.
func _leads() -> bool:
	return is_inside_tree() and get_tree().get_first_node_in_group(GROUP) == self


func _focus(b: ScreenButton) -> void:
	if b != null and b.is_inside_tree():
		b.grab_focus()


## The pad moves a focus in `scope`: it is a menu (a RunScreen that wants the pad's
## focus, or a modal panel), not the gameplay HUD's buttons nor a screen that takes the
## arrows itself.
func navigable(scope: Array[ScreenButton]) -> bool:
	if scope.is_empty():
		return false
	var screen := _screen_of(scope[0])
	if screen != null:
		return screen.pad_focus
	return _in_modal(scope[0])


## Under a Control that takes touches over the screen's centre and at least half of it.
func _in_modal(b: Control) -> bool:
	var view := get_viewport().get_visible_rect()
	var p := b.get_parent()
	while p != null and not p is CanvasLayer:
		var c := p as Control
		if c != null and c.mouse_filter == Control.MOUSE_FILTER_STOP:
			var r := c.get_global_rect()
			if r.has_point(view.get_center()) and r.get_area() >= view.get_area() * 0.5:
				return true
		p = p.get_parent()
	return false


func _reachable(b: ScreenButton, view: Rect2) -> bool:
	if not b.is_visible_in_tree() or b.disabled or b.focus_mode == Control.FOCUS_NONE \
			or b.mouse_filter == Control.MOUSE_FILTER_IGNORE:
		return false
	if not view.intersects(b.get_global_rect()):
		return false
	var screen := _screen_of(b)
	return screen == null or screen.is_open()


## Under a later sibling (of the button or an ancestor, up to its CanvasLayer) that is
## visible, takes touches and covers the button's centre: a modal panel, a dim.
static func _covered(b: Control) -> bool:
	var c := b.get_global_rect().get_center()
	var n: Node = b
	while n != null and not n is CanvasLayer:
		var p := n.get_parent()
		if p == null:
			break
		var after := false
		for s in p.get_children():
			if s == n:
				after = true
				continue
			if not after:
				continue
			var sc := s as Control
			if sc != null and sc.is_visible_in_tree() and sc.mouse_filter == Control.MOUSE_FILTER_STOP \
					and not sc is ScreenButton and sc.get_global_rect().has_point(c):
				return true
		n = p
	return false


static func _layer_of(n: Node) -> int:
	var p := n.get_parent()
	while p != null:
		if p is CanvasLayer:
			return (p as CanvasLayer).layer
		p = p.get_parent()
	return 0


static func _screen_of(n: Node) -> RunScreen:
	var p := n.get_parent()
	while p != null:
		if p is RunScreen:
			return p as RunScreen
		p = p.get_parent()
	return null


## The scope's top row of OPTION buttons that reads as tabs (2+ on one line, one selected).
func _tab_row(scope: Array[ScreenButton]) -> Array[ScreenButton]:
	var best: Array[ScreenButton] = []
	var best_y := INF
	for b in scope:
		if b.kind != ScreenButton.Kind.OPTION:
			continue
		var y := b.get_global_rect().position.y
		if y >= best_y:
			continue
		var row: Array[ScreenButton] = []
		var selected := 0
		for o in scope:
			if o.kind == ScreenButton.Kind.OPTION and o.get_parent() == b.get_parent() \
					and is_equal_approx(o.get_global_rect().position.y, y):
				row.append(o)
				if o.selected:
					selected += 1
		if row.size() >= 2 and selected == 1:
			best = row
			best_y = y
	best.sort_custom(func(p: ScreenButton, q: ScreenButton) -> bool:
		return p.get_global_rect().position.x < q.get_global_rect().position.x)
	return best


func _dir_of(event: InputEvent) -> int:
	if not (event is InputEventKey or event is InputEventJoypadButton or event is InputEventAction):
		return NO_DIR
	for i in DIRS.size():
		if event.is_action(DIRS[i], true):
			return i
	return NO_DIR


func _start_hold(dir: int, source: Source) -> void:
	_hold_dir = dir
	_hold_source = source
	_repeat_left = controls.pad_nav_repeat_delay_s if controls != null else 0.0


## The left stick as four directions with hysteresis: a new direction presses its ui_*
## action (a synthesized InputEventAction), the centre releases it.
func _stick_moved(ev: InputEventJoypadMotion) -> void:
	if ev.axis == JOY_AXIS_LEFT_X:
		_stick.x = ev.axis_value
	elif ev.axis == JOY_AXIS_LEFT_Y:
		_stick.y = ev.axis_value
	else:
		return
	var on := controls.pad_nav_stick_frac() if controls != null else 0.5
	var off := controls.pad_nav_release_frac() if controls != null else 0.5
	var dir := _stick_dir
	if dir != NO_DIR and _stick.dot(DIR_VECTORS[dir]) < off:
		dir = NO_DIR
	if dir == NO_DIR and _stick.length() >= on:
		if absf(_stick.x) >= absf(_stick.y):
			dir = 1 if _stick.x > 0.0 else 0
		else:
			dir = 3 if _stick.y > 0.0 else 2
	if dir == _stick_dir:
		return
	if _stick_dir != NO_DIR:
		_emit_dir(_stick_dir, false)
		if _hold_source == Source.STICK:
			_hold_dir = NO_DIR
	_stick_dir = dir
	if dir != NO_DIR:
		active = true
		_start_hold(dir, Source.STICK)
		_emit_dir(dir, true)


func _emit_dir(dir: int, down: bool) -> void:
	var ev := InputEventAction.new()
	ev.action = DIRS[dir]
	ev.pressed = down
	ev.strength = 1.0 if down else 0.0
	Input.parse_input_event(ev)


func _is_pointer_press(event: InputEvent) -> bool:
	if event is InputEventScreenTouch:
		return (event as InputEventScreenTouch).pressed
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		return mb.pressed and mb.device != InputEvent.DEVICE_ID_EMULATION
	return false


func _drop_button_focus() -> void:
	var f := get_viewport().gui_get_focus_owner()
	if f is ScreenButton:
		f.release_focus()


func _text_focused() -> bool:
	var f := get_viewport().gui_get_focus_owner()
	return f is LineEdit or f is TextEdit
