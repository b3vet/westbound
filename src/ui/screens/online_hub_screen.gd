class_name OnlineHubScreen
extends RunScreen
## The online hub, a stub until rooms exist (WP8.5). Spec: multiplayer handoff → Client
## changes ("Online hub: Quick Join, room browser, create a private room, join by code";
## "Party panel and friends list"; "Crew page"; "Leaderboards"); plan: rooms are N5, not
## built yet. docs/SCREENS.md → Online hub.
##
## Over the title's attract drive, on the same slanted band:
##   - ONLINE (speed-tilted) top-left, the player and the online status under it; BACK
##     top-right (Esc too);
##   - a ROOMS panel: COMING SOON, and QUICK JOIN, ROOM BROWSER, PRIVATE ROOM and JOIN BY
##     CODE, disabled with SOON;
##   - LOOP PRACTICE (primary, bottom-left thumb): the run in loop mode (`?mode=loop`), solo
##     on the multiplayer loop, which works offline;
##   - FRIENDS, CREW and LEADERBOARDS up from the right thumb. FRIENDS and CREW open the
##     account view on that tab (they need a session: disabled, ONLINE OFF, without one);
##     LEADERBOARDS opens on the Loop season board.
## Emits intents only (loop_practice, social, back).

signal loop_practice()
signal social(view: int)
signal back()

const TILT_SHADER := preload("res://src/ui/theme/speed_tilt.gdshader")
const TEXT_TITLE := "ONLINE"
const TEXT_BACK := "BACK"
const TEXT_LOOP := "LOOP PRACTICE"
const TEXT_LOOP_NOTE := "SOLO ON THE LOOP · WORKS OFFLINE"
const TEXT_ROOMS := "ROOMS"
const TEXT_ROOMS_SOON := "COMING SOON"
const TEXT_ROOMS_NOTE := "Drive the loop with friends and crews."
const TEXT_QUICK_JOIN := "QUICK JOIN"
const TEXT_BROWSER := "ROOM BROWSER"
const TEXT_PRIVATE := "PRIVATE ROOM"
const TEXT_CODE := "JOIN BY CODE"
const TEXT_SOON := "SOON"
const TEXT_FRIENDS := "FRIENDS"
const TEXT_CREW := "CREW"
const TEXT_LEADERBOARDS := "LEADERBOARDS"
const TEXT_OFF := "ONLINE OFF"
const TEXT_STATUS := "%s  ·  %s"
const TEXT_NO_SESSION := "ONLINE IS OFF IN THIS BUILD  ·  LOOP PRACTICE STILL WORKS"
## Base sizes (canvas px at 100% text size).
const STATUS_PX := 16
const CAPTION_PX := 20
const NOTE_PX := 16

var band: TitleBand
var dim: ColorRect
var title: ScreenText
var status: ScreenText
var back_button: ScreenButton
var rooms_panel: ScreenPanel
var rooms_caption: ScreenText
var rooms_soon: ScreenText
var rooms_note: ScreenText
var room_buttons: Array[ScreenButton] = []
var loop_button: ScreenButton
var loop_caption: ScreenText
var friends_button: ScreenButton
var crew_button: ScreenButton
var boards_button: ScreenButton
var leaderboards: LeaderboardsScreen
var runs: NetRunsClient
## The session shown (null: NetSession.current).
var session: NetSession


func _init() -> void:
	super._init()
	name = "OnlineHub"
	dim = ColorRect.new()
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.visible = false
	add_child(dim)
	band = TitleBand.new()
	band.name = "Band"
	add_child(band)
	title = ScreenText.make(TEXT_TITLE, ScreenText.Face.DISPLAY, 60, ScreenText.Ink.TEXT)
	title.name = "Heading"
	add_child(title)
	status = ScreenText.make("", ScreenText.Face.LABEL, STATUS_PX, ScreenText.Ink.MUTED)
	status.name = "Status"
	add_child(status)
	back_button = _button(TEXT_BACK, ScreenButton.Kind.NORMAL, back.emit, self)
	rooms_panel = ScreenPanel.new()
	rooms_panel.name = "Rooms"
	add_child(rooms_panel)
	rooms_caption = ScreenText.make(TEXT_ROOMS, ScreenText.Face.LABEL, CAPTION_PX, ScreenText.Ink.TEXT)
	rooms_panel.add_child(rooms_caption)
	rooms_soon = ScreenText.make(TEXT_ROOMS_SOON, ScreenText.Face.LABEL, CAPTION_PX, ScreenText.Ink.GOLD)
	rooms_panel.add_child(rooms_soon)
	rooms_note = ScreenText.make(TEXT_ROOMS_NOTE, ScreenText.Face.BODY, NOTE_PX, ScreenText.Ink.MUTED)
	rooms_panel.add_child(rooms_note)
	for label: String in [TEXT_QUICK_JOIN, TEXT_BROWSER, TEXT_PRIVATE, TEXT_CODE]:
		var b := _button(label, ScreenButton.Kind.NORMAL, func() -> void: pass, rooms_panel)
		b.note = TEXT_SOON
		b.disabled = true
		room_buttons.append(b)
	loop_caption = ScreenText.make(TEXT_LOOP_NOTE, ScreenText.Face.LABEL, STATUS_PX, ScreenText.Ink.ACCENT)
	loop_caption.name = "LoopCaption"
	add_child(loop_caption)
	loop_button = _button(TEXT_LOOP, ScreenButton.Kind.PRIMARY, loop_practice.emit, self)
	boards_button = _button(TEXT_LEADERBOARDS, ScreenButton.Kind.NORMAL, open_leaderboards, self)
	crew_button = _button(TEXT_CREW, ScreenButton.Kind.NORMAL,
			func() -> void: social.emit(ProfilePanel.View.CREW), self)
	friends_button = _button(TEXT_FRIENDS, ScreenButton.Kind.NORMAL,
			func() -> void: social.emit(ProfilePanel.View.FRIENDS), self)


func _button(label: String, kind: ScreenButton.Kind, action: Callable, parent: Node) -> ScreenButton:
	var b := ScreenButton.make(label, kind, 24)
	b.name = label.capitalize().replace(" ", "")
	b.pressed.connect(action)
	parent.add_child(b)
	return b


func _restyled() -> void:
	band.setup(style)
	title.size_px = tuning.font_title_px
	title.use_tilt(TILT_SHADER, tuning.speed_tilt_rad())
	for b: ScreenButton in _buttons():
		b.size_px = tuning.font_screen_button_px
	if leaderboards != null:
		leaderboards.setup(style, tuning)
	dim.color = Color(style.ink, Units.pct_to_frac(tuning.screen_dim_pct))
	_layout()


func _buttons() -> Array[ScreenButton]:
	var out: Array[ScreenButton] = [back_button, loop_button, boards_button, crew_button, friends_button]
	out.append_array(room_buttons)
	return out


func open() -> void:
	if leaderboards != null:
		leaderboards.close(false)
	dim.visible = false
	refresh()
	super.open()
	var i := 0
	for c: Control in [title, status, rooms_panel, loop_caption, loop_button, friends_button, crew_button, boards_button]:
		slide_in(c, -tuning.screen_slide_px, tuning.screen_fade_in_s, float(i) * tuning.results_row_stagger_s)
		i += 1


## The status line and the buttons that need a session.
func refresh() -> void:
	var s := _session()
	if s == null:
		status.text = TEXT_NO_SESSION
		status.set_ink(ScreenText.Ink.MUTED)
	else:
		var n := s.profile.full_name if s.profile != null and not s.profile.full_name.is_empty() \
				else TitleProfileChip.TEXT_PLAYER
		status.text = TEXT_STATUS % [n, String(ProfilePanel.STATUS_LABEL.get(s.status, TEXT_OFF))]
		status.set_ink(ScreenText.Ink.ACCENT if s.is_online() else ScreenText.Ink.MUTED)
	for b: ScreenButton in [friends_button, crew_button]:
		b.disabled = s == null
		b.note = TEXT_OFF if s == null else ""
	_layout()


func _session() -> NetSession:
	if session != null and is_instance_valid(session):
		return session
	var c := NetSession.current
	return c if c != null and is_instance_valid(c) else null


## LEADERBOARDS: the boards over the hub, on the Loop season board.
func open_leaderboards() -> void:
	var first := leaderboards == null
	var c := runs if runs != null and is_instance_valid(runs) else NetRunsClient.ensure()
	leaderboards = LeaderboardsScreen.attach(self, leaderboards, c)
	if first:
		leaderboards.closed_by_player.connect(func() -> void:
			dim.visible = false
			_layout())
	dim.visible = true
	leaderboards.open_over(self, NetBoards.LOOP)


func leaderboards_open() -> bool:
	return leaderboards != null and leaderboards.is_open()


func _unhandled_input(event: InputEvent) -> void:
	if not visible or leaderboards_open():
		return
	if event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		back.emit()


func _layout() -> void:
	if style == null:
		return
	var m := margin()
	var g := tuning.spacing_grid_px
	var a := safe.grow(-m)
	var th := tuning.touch_target_px
	var bw := tuning.menu_button_width_px
	var ts := style.ts
	dim.position = Vector2.ZERO
	dim.size = full.size
	band.position = Vector2.ZERO
	band.size = full.size
	# Header: ONLINE and the status line; BACK top-right.
	var hs := title.get_combined_minimum_size()
	title.position = a.position
	title.size = hs
	var ss := status.get_combined_minimum_size()
	status.position = Vector2(a.position.x, a.position.y + hs.y)
	status.size = ss
	var bkw := SocialUi.button_width(back_button, tuning)
	back_button.size = Vector2(maxf(bkw, bw * BACK_WIDTH), th)
	back_button.position = Vector2(a.end.x - back_button.size.x, a.position.y)
	# LOOP PRACTICE: bottom-left.
	var pb := tuning.primary_button_size_px
	var lw := maxf(bw, SocialUi.button_width(loop_button, tuning))
	loop_button.size = Vector2(lw, pb.y)
	loop_button.position = Vector2(a.position.x, a.end.y - pb.y)
	var lcs := loop_caption.get_combined_minimum_size()
	loop_caption.position = Vector2(a.position.x, loop_button.position.y - g - lcs.y)
	loop_caption.size = lcs
	# The ROOMS panel between the header and LOOP PRACTICE: two rows of two buttons.
	var pad := tuning.panel_padding_px * ts
	var rw := bw * ROOM_WIDTH
	for b in room_buttons:
		rw = maxf(rw, SocialUi.button_width(b, tuning))
	var cs := rooms_caption.get_combined_minimum_size()
	var sn := rooms_soon.get_combined_minimum_size()
	var ns := rooms_note.get_combined_minimum_size()
	var pw := maxf(rw * 2.0 + g + pad * 2.0, ns.x + pad * 2.0)
	var head := cs.y + ns.y
	var ph := pad * 2.0 + head + g + th * 2.0 + g
	var top := status.position.y + ss.y + g * 2.0
	rooms_panel.position = Vector2(a.position.x, top)
	rooms_panel.size = Vector2(pw, ph)
	rooms_caption.position = Vector2(pad, pad)
	rooms_caption.size = cs
	rooms_soon.position = Vector2(pad + cs.x + g * 2.0, pad)
	rooms_soon.size = sn
	rooms_note.position = Vector2(pad, pad + cs.y)
	rooms_note.size = ns
	for i in room_buttons.size():
		@warning_ignore("integer_division")
		var row := i / 2
		var col := i % 2
		room_buttons[i].position = Vector2(pad + float(col) * (rw + g), pad + head + g + float(row) * (th + g))
		room_buttons[i].size = Vector2(rw, th)
	band.width = maxf(tuning.title_band_width_px, rooms_panel.position.x + pw + m)
	# FRIENDS, CREW, LEADERBOARDS: up from the right thumb.
	var sw := bw * SIDE_WIDTH
	for b: ScreenButton in [friends_button, crew_button, boards_button]:
		sw = maxf(sw, SocialUi.button_width(b, tuning))
	var y := a.end.y
	for b: ScreenButton in [boards_button, crew_button, friends_button]:
		y -= th
		b.position = Vector2(a.end.x - sw, y)
		b.size = Vector2(sw, th)
		y -= g


## Layout proportions of the menu width: BACK, a room button, the right column.
const BACK_WIDTH := 0.5   # lint: allow-number layout proportion
const ROOM_WIDTH := 0.75   # lint: allow-number layout proportion
const SIDE_WIDTH := 0.7   # lint: allow-number layout proportion
