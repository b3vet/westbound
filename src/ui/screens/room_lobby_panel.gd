class_name RoomLobbyPanel
extends Control
## The online hub's room flows: PRIVATE ROOM (host options), JOIN BY CODE, the ROOM
## BROWSER and the joining status (QUICK JOIN and every join). Spec:
## WESTBOUND_MULTIPLAYER_HANDOFF.md → Rooms, parties and matchmaking (Private rooms: "The
## creator gets a code ... can change density or time mode"; Time of day: "the host can
## pick the cycle, a fixed time of day, or permanent night"; Public rooms: Quick Join,
## "The room browser lists public rooms with player count, density, day or night, and
## your ping"); Client changes (Online hub). docs/SCREENS.md → Online hub → Rooms (N5.2).
## WP N5.2.
##
## A panel over the hub, one view at a time. It calls the rooms service and shows where the
## join is; when the room's snapshot arrives it emits `joined(session)` (the hub hands it
## to the run) and closes. Every button is a ScreenButton at least touch_target_px tall.

signal joined(session: NetRoomSession)
signal closed()

enum View { STATUS, CREATE, CODE, BROWSER }

const TEXT_QUICK := "QUICK JOIN"
const TEXT_PRIVATE := "PRIVATE ROOM"
const TEXT_CODE := "JOIN BY CODE"
const TEXT_BROWSER := "ROOM BROWSER"
const TEXT_BACK := "BACK"
const TEXT_CANCEL := "CANCEL"
const TEXT_RETRY := "TRY AGAIN"
const TEXT_CREATE := "CREATE ROOM"
const TEXT_JOIN := "JOIN"
const TEXT_REFRESH := "REFRESH"
const TEXT_DENSITY := "TRAFFIC"
const TEXT_TIME := "TIME OF DAY"
const DENSITY_LABELS: Array[String] = ["LIGHT", "NORMAL", "RUSH HOUR"]
const TIME_LABELS: Array[String] = ["CYCLE", "MORNING", "GOLDEN", "NIGHT"]
const TIME_CYCLE := 0
const TIME_MORNING := 1
const TIME_GOLDEN := 2
const TIME_NIGHT := 3
const TEXT_CONNECTING := "CONNECTING..."
const TEXT_FINDING := "FINDING A ROOM..."
const TEXT_CREATING := "CREATING YOUR ROOM..."
const TEXT_JOINING := "JOINING %s..."
const TEXT_JOINING_ROOM := "JOINING ROOM %d..."
const TEXT_CODE_PH := "ROOM CODE"
const TEXT_CODE_PROMPT := "Room code (6 characters)"
const TEXT_CODE_BAD := "A code is 6 letters and digits."
const TEXT_CODE_NOTE := "ASK THE HOST FOR THE 6-CHARACTER CODE"
const TEXT_EMPTY := "NO PUBLIC ROOMS YET  ·  QUICK JOIN STARTS ONE"
const TEXT_LOADING := "LOOKING FOR ROOMS..."
const TEXT_ROW := "%d/%d  ·  %s  ·  %s  ·  %d MS"
const TEXT_DAY := "DAY"
const TEXT_NIGHT := "NIGHT ×2"
const TEXT_CREATE_NOTE := "PRIVATE: ONLY PLAYERS WITH THE CODE CAN JOIN"
## Browser rows shown at most (the list is fullest first).
const BROWSER_ROWS := 4
const MS_PER_MIN := 60000.0   # lint: allow-number unit conversion
const MS_PER_S := 1000.0   # lint: allow-number unit conversion

var style: HudStyle
var tuning: HudTuning
var net: NetTuning
var rooms: NetRooms
var hub: PlayerInput
var view: View = View.STATUS
var density: int = 1
var time_choice: int = TIME_CYCLE
## The request the STATUS view shows (TRY AGAIN repeats it).
var request_title: String = TEXT_QUICK

## Dims the hub behind the panel (the whole canvas).
var backdrop: ColorRect
var panel: ScreenPanel
var title: ScreenText
var status: ScreenText
var note: ScreenText
var back_button: ScreenButton
var action_button: ScreenButton
var density_label: ScreenText
var time_label: ScreenText
var density_buttons: Array[ScreenButton] = []
var time_buttons: Array[ScreenButton] = []
var code_field: SocialField
var row_buttons: Array[ScreenButton] = []
var row_ids := PackedInt32Array()

var _retry: Callable
var _area: Rect2 = Rect2(0.0, 0.0, 1280.0, 720.0)
var _browse_left_s: float = 0.0
var _session: NetRoomSession


func _init() -> void:
	name = "RoomLobby"
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	visible = false
	backdrop = ColorRect.new()
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)
	panel = ScreenPanel.new()
	panel.edge = ScreenPanel.Edge.ACCENT
	add_child(panel)
	title = _text("", ScreenText.Face.DISPLAY, 36, ScreenText.Ink.TEXT)
	status = _text("", ScreenText.Face.LABEL, 20, ScreenText.Ink.ACCENT)
	note = _text("", ScreenText.Face.LABEL, 16, ScreenText.Ink.MUTED)
	density_label = _text(TEXT_DENSITY, ScreenText.Face.LABEL, 16, ScreenText.Ink.MUTED)
	time_label = _text(TEXT_TIME, ScreenText.Face.LABEL, 16, ScreenText.Ink.MUTED)
	for i in DENSITY_LABELS.size():
		var k := i
		density_buttons.append(_button(DENSITY_LABELS[i], ScreenButton.Kind.OPTION, func() -> void: _pick_density(k)))
	for i in TIME_LABELS.size():
		var k := i
		time_buttons.append(_button(TIME_LABELS[i], ScreenButton.Kind.OPTION, func() -> void: _pick_time(k)))
	code_field = SocialField.new()
	code_field.name = "CodeField"
	code_field.placeholder_text = TEXT_CODE_PH
	code_field.prompt_message = TEXT_CODE_PROMPT
	code_field.max_length = NetCodec.CODE_LEN + 2
	code_field.text_submitted.connect(func(_t: String) -> void: _join_code())
	panel.add_child(code_field)
	for i in BROWSER_ROWS:
		var k := i
		var b := _button("", ScreenButton.Kind.NORMAL, func() -> void: _join_row(k))
		row_buttons.append(b)
	row_ids.resize(BROWSER_ROWS)
	row_ids.fill(-1)
	action_button = _button(TEXT_JOIN, ScreenButton.Kind.PRIMARY, func() -> void: _action())
	back_button = _button(TEXT_BACK, ScreenButton.Kind.NORMAL, close)


func _text(t: String, face: ScreenText.Face, px: int, ink: ScreenText.Ink) -> ScreenText:
	var s := ScreenText.make(t, face, px, ink)
	panel.add_child(s)
	return s


func _button(label: String, kind: ScreenButton.Kind, action: Callable) -> ScreenButton:
	var b := ScreenButton.make(label, kind, 22)
	b.name = label.capitalize().replace(" ", "") if not label.is_empty() else "Row"
	if kind == ScreenButton.Kind.OPTION:
		b.align = HORIZONTAL_ALIGNMENT_CENTER
	b.pressed.connect(action)
	panel.add_child(b)
	return b


func setup(s: HudStyle, t: HudTuning, net_tuning: NetTuning) -> void:
	style = s
	tuning = t
	net = net_tuning
	panel.fill_alpha = 1.0 / maxf(s.panel_fill.a, 0.01)   # opaque: nothing reads through it
	panel.setup(s)
	backdrop.color = Color(s.ink, Units.pct_to_frac(t.screen_dim_pct))
	for c in panel.get_children():
		if c is ScreenButton:
			(c as ScreenButton).setup(s)
		elif c is ScreenText:
			(c as ScreenText).setup(s)
	SocialUi.style_edit(code_field, s, t)
	code_field.net_tuning = net
	code_field.hub = hub
	_layout()


## Canvas rect the panel centres in.
func place(area: Rect2) -> void:
	_area = area
	position = Vector2.ZERO
	size = area.end + area.position
	backdrop.position = Vector2.ZERO
	backdrop.size = size
	_layout()


# ---------------------------------------------------------------- Flows

func quick_join() -> void:
	_start(TEXT_QUICK, TEXT_FINDING, func() -> void: rooms.quick_join())


func open_create() -> void:
	_open(View.CREATE, TEXT_PRIVATE)


func open_code() -> void:
	code_field.text = ""
	_open(View.CODE, TEXT_CODE)


func open_browser() -> void:
	_open(View.BROWSER, TEXT_BROWSER)
	_browse()


func create() -> void:
	var tm := "cycle"
	var fixed := 0
	match time_choice:
		TIME_MORNING:
			tm = "fixed"
			fixed = roundi(net.room_fixed_morning_min * MS_PER_MIN)
		TIME_GOLDEN:
			tm = "fixed"
			fixed = roundi(net.room_fixed_golden_min * MS_PER_MIN)
		TIME_NIGHT:
			tm = "night"
	var d := String(NetCodec.DENSITY[clampi(density, 0, NetCodec.DENSITY.size() - 1)])
	_start(TEXT_PRIVATE, TEXT_CREATING, func() -> void: rooms.create_room(d, tm, fixed))


func close() -> void:
	if not visible:
		return
	_bind(false)
	if rooms != null and rooms.session != null:
		var st := rooms.session.state
		if st == NetRoomSession.State.JOINING or st == NetRoomSession.State.CONNECTING:
			rooms.session.leave()
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


func _open(v: View, heading: String) -> void:
	view = v
	title.text = heading
	status.text = ""
	visible = true
	_bind(true)
	_refresh()


func _start(heading: String, working: String, request: Callable) -> void:
	_open(View.STATUS, heading)
	request_title = heading
	_retry = request
	_working(working)
	request.call()


func _working(text: String) -> void:
	status.text = text if rooms.session.client.is_ready() else TEXT_CONNECTING
	status.set_ink(ScreenText.Ink.ACCENT)
	_refresh()


func _action() -> void:
	match view:
		View.CREATE:
			create()
		View.CODE:
			_join_code()
		View.BROWSER:
			_browse()
		View.STATUS:
			if _retry.is_valid():
				_start(request_title, status_for(request_title), _retry)


static func status_for(heading: String) -> String:
	return TEXT_CREATING if heading == TEXT_PRIVATE else TEXT_FINDING


func _join_code() -> void:
	var code := NetRoomSession.normalize_code(code_field.text)
	if not NetRoomSession.is_valid_code(code):
		status.text = TEXT_CODE_BAD
		status.set_ink(ScreenText.Ink.HOT)
		_layout()
		return
	_start(TEXT_CODE, TEXT_JOINING % code, func() -> void: rooms.join_code(code))


func _join_row(k: int) -> void:
	var id := row_ids[k]
	if id > 0:
		_start(TEXT_BROWSER, TEXT_JOINING_ROOM % id, func() -> void: rooms.join_id(id))


func _browse() -> void:
	_browse_left_s = net.room_browse_refresh_s
	if rooms.session.rooms_listed.is_empty():
		status.text = TEXT_LOADING
		status.set_ink(ScreenText.Ink.MUTED)
	rooms.browse()
	_refresh()


func _pick_density(k: int) -> void:
	density = k
	_refresh()


func _pick_time(k: int) -> void:
	time_choice = k
	_refresh()


func _process(delta: float) -> void:
	if not visible or view != View.BROWSER or rooms == null:
		return
	_browse_left_s -= delta
	if _browse_left_s <= 0.0:
		_browse()


# ---------------------------------------------------------------- Session

func _bind(on: bool) -> void:
	var s := rooms.session if rooms != null else null
	if _session != null and _session != s or not on:
		_connect(_session, false)
		_session = null
	if on and s != null and _session == null:
		_session = s
		_connect(s, true)


func _connect(s: NetRoomSession, on: bool) -> void:
	if s == null:
		return
	var pairs: Array = [[s.joined, _on_joined], [s.join_failed, _on_failed], [s.room_list, _on_list],
		[s.state_changed, _on_state]]
	for p: Array in pairs:
		var sig: Signal = p[0]
		var c: Callable = p[1]
		if on and not sig.is_connected(c):
			sig.connect(c)
		elif not on and sig.is_connected(c):
			sig.disconnect(c)


func _on_joined(_r: NetRoomState) -> void:
	var s := _session
	_bind(false)
	visible = false
	joined.emit(s)


## Shows a failure on the STATUS view (a refused join; previews).
func show_error(message: String) -> void:
	_on_failed("", message)


func _on_failed(_code: String, message: String) -> void:
	if view != View.STATUS:
		view = View.STATUS
	status.text = message
	status.set_ink(ScreenText.Ink.HOT)
	_refresh()


func _on_list(_list: Array[Dictionary]) -> void:
	if view == View.BROWSER:
		status.text = ""
		_refresh()


func _on_state(st: NetRoomSession.State) -> void:
	if view == View.STATUS and st == NetRoomSession.State.JOINING and status.text == TEXT_CONNECTING:
		status.text = status_for(request_title) if request_title != TEXT_CODE else status.text
		_layout()


# ---------------------------------------------------------------- Look

func _refresh() -> void:
	for i in density_buttons.size():
		density_buttons[i].selected = i == density
		density_buttons[i].visible = view == View.CREATE
	for i in time_buttons.size():
		time_buttons[i].selected = i == time_choice
		time_buttons[i].visible = view == View.CREATE
	density_label.visible = view == View.CREATE
	time_label.visible = view == View.CREATE
	code_field.visible = view == View.CODE
	note.visible = true
	match view:
		View.CREATE:
			note.text = TEXT_CREATE_NOTE
			action_button.text = TEXT_CREATE
		View.CODE:
			note.text = TEXT_CODE_NOTE
			action_button.text = TEXT_JOIN
		View.BROWSER:
			action_button.text = TEXT_REFRESH
			note.text = ""
		View.STATUS:
			note.text = ""
			action_button.text = TEXT_RETRY
	var failed := view == View.STATUS and status.ink == ScreenText.Ink.HOT
	action_button.visible = view != View.STATUS or failed
	back_button.text = TEXT_CANCEL if view == View.STATUS and not failed else TEXT_BACK
	_fill_rows()
	_layout()


func _fill_rows() -> void:
	row_ids.fill(-1)
	var list: Array[Dictionary] = rooms.session.rooms_listed if rooms != null and rooms.session != null else []
	var ping := roundi(rooms.session.ping_ms()) if rooms != null and rooms.session != null else 0
	for i in row_buttons.size():
		var b := row_buttons[i]
		b.visible = view == View.BROWSER and i < list.size()
		if i >= list.size():
			continue
		var r := list[i]
		row_ids[i] = int(r.get("room_id", 0))
		var full := int(r.get("players", 0)) >= int(r.get("max_players", 1))
		b.text = TEXT_ROW % [int(r.get("players", 0)), int(r.get("max_players", 0)),
			String(r.get("density", "")).to_upper(), TEXT_NIGHT if bool(r.get("night", false)) else TEXT_DAY, ping]
		b.disabled = full
	if view == View.BROWSER and list.is_empty() and status.text.is_empty():
		note.text = TEXT_EMPTY


func _layout() -> void:
	if style == null:
		return
	var ts := style.ts
	var g := tuning.spacing_grid_px
	var pad := tuning.panel_padding_px * ts
	var th := tuning.touch_target_px
	var w := minf(net.room_panel_width_px * ts * WIDTH_SCALE, _area.size.x)
	var inner := w - pad * 2.0
	var y := _put(title, pad, pad, g)
	status.visible = not status.text.is_empty()
	if status.visible:
		y = _put(status, pad, y, g)
	if view == View.CREATE:
		y = _put(density_label, pad, y, g)
		y = _row(density_buttons, pad, y, inner, th, g)
		y = _put(time_label, pad, y, g)
		y = _row(time_buttons, pad, y, inner, th, g)
	elif view == View.CODE:
		code_field.position = Vector2(pad, y)
		code_field.size = Vector2(inner, th)
		y += th + g
	elif view == View.BROWSER:
		for b in row_buttons:
			if b.visible:
				b.position = Vector2(pad, y)
				b.size = Vector2(inner, th)
				y += th + g
	if not note.text.is_empty():
		y = _put(note, pad, y, g)
	var bw := (inner - g) * 0.5
	back_button.size = Vector2(bw, th)
	back_button.position = Vector2(pad, y)
	action_button.size = Vector2(bw, th)
	action_button.position = Vector2(pad + bw + g, y)
	y += th + pad
	panel.size = Vector2(w, y)
	panel.position = _area.position + (_area.size - panel.size) * 0.5


## Places a text at (x, y) at its size; returns the y under it.
static func _put(t: ScreenText, x: float, y: float, g: float) -> float:
	t.size = t.get_combined_minimum_size()
	t.position = Vector2(x, y)
	return y + t.size.y + g


static func _row(buttons: Array[ScreenButton], x: float, y: float, inner: float, th: float, g: float) -> float:
	var n := buttons.size()
	var bw := (inner - g * float(n - 1)) / float(n)
	for i in n:
		buttons[i].position = Vector2(x + float(i) * (bw + g), y)
		buttons[i].size = Vector2(bw, th)
	return y + th + g


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		close()


## The panel's width against the room menu's (room_panel_width_px).
const WIDTH_SCALE := 1.15   # lint: allow-number layout proportion
