class_name LeaderboardsScreen
extends RunScreen
## The leaderboards: Loop season, Loop crew, Journey, Daily Drive and Distance, each with
## its periods, in three views (global top 100, around me, friends). Spec: multiplayer
## handoff → Leaderboards (boards, periods, views, legacy marker, "verifying"), Client
## changes → Leaderboards screen ("replaces the Game Center / Play Games boards"), Rooms →
## Moderation (report, block); UI, HUD and design system → Design system, Accessibility
## (text size, left-handed); docs/SERVER.md → GET /boards, Reports, Blocks. WP N7.2;
## docs/SCREENS.md → Leaderboards.
##
## Opened over the pause menu or the results (open_over(host)): the host's own widgets
## hide while it shows (its dim stays), and come back when it closes (BACK, Esc).
##
## Layout (left-anchored, inside the safe area): the title, the period control and BACK
## on the top row; the board tabs in a column on the left; the list (LeaderboardsList:
## pooled rows) on the right with, under it, the status line and the view switch on the
## thumb side. Tapping another player's row puts REPORT CHEATING, REPORT NAME and BLOCK
## where the views were. Loading, empty, offline, signed-out and error states show in the
## list's panel, with RETRY where it helps. Pull down to refresh. Hidden = `visible =
## false`: nothing draws, and it is only built the first time it opens.

signal closed_by_player()

const TILT_SHADER := preload("res://src/ui/theme/speed_tilt.gdshader")
const TEXT_TITLE := "LEADERBOARDS"
const TEXT_BACK := "BACK"
const TEXT_RETRY := "RETRY"
const TAB_TEXT := {
	NetBoards.LOOP: "LOOP SEASON",
	NetBoards.LOOP_CREW: "LOOP CREW",
	NetBoards.JOURNEY: "JOURNEY",
	NetBoards.DAILY: "DAILY DRIVE",
	NetBoards.DISTANCE: "DISTANCE",
}
const VIEW_TEXT := {
	NetBoards.VIEW_GLOBAL: "TOP 100",
	NetBoards.VIEW_AROUND_ME: "AROUND ME",
	NetBoards.VIEW_FRIENDS: "FRIENDS",
}
const TEXT_SEASON := "SEASON"
const TEXT_WEEK := "THIS WEEK"
const TEXT_ALL_TIME := "ALL TIME"
const TEXT_TODAY := "TODAY"
const TEXT_YESTERDAY := "YESTERDAY"
const TEXT_PREV := "<"
const TEXT_NEXT := ">"
const MONTHS: Array[String] = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

const TEXT_LOADING := "LOADING..."
const TEXT_EMPTY := "NO RUNS HERE YET"
const NOTE_EMPTY := "Be the first on this board."
const TEXT_EMPTY_FRIENDS := "NO FRIENDS HERE YET"
const NOTE_EMPTY_FRIENDS := "Friends' runs show here."
const TEXT_EMPTY_AROUND := "YOU'RE NOT ON THIS BOARD YET"
const NOTE_EMPTY_AROUND := "Finish a run to get a rank."
const TEXT_CREW_FRIENDS := "CREWS RANK HERE"
const NOTE_CREW_FRIENDS := "The crew board has no friends view."
const TEXT_OFFLINE := "OFFLINE"
const NOTE_OFFLINE := "Can't reach the server. Pull down to try again."
const TEXT_SIGN_IN := "NOT SIGNED IN"
const NOTE_SIGN_IN := "This view needs your online account."
const TEXT_DISABLED := "ONLINE IS OFF"
const NOTE_DISABLED := "Online features are off in this build."
const TEXT_ERROR := "COULDN'T LOAD"

const TEXT_TOTAL := "%s ON THIS BOARD"
const TEXT_TOTAL_ONE := "1 ON THIS BOARD"
const TEXT_UPDATING := "UPDATING..."
const TEXT_PULL := "PULL TO REFRESH"
const TEXT_RELEASE := "RELEASE TO REFRESH"
const TEXT_REPORT_CHEAT := "REPORT CHEATING"
const TEXT_REPORT_NAME := "REPORT NAME"
const TEXT_BLOCK := "BLOCK"
const TEXT_BLOCK_CONFIRM := "CONFIRM BLOCK"
const TEXT_CANCEL := "CANCEL"
const TEXT_REPORTED := "REPORTED. THANKS."
const TEXT_BLOCKED := "BLOCKED"
const TEXT_ACTION_FAILED := "DIDN'T GO THROUGH"
const TEXT_ACTION_LIMIT := "TOO MANY REPORTS TODAY"
const TEXT_SENDING := "SENDING..."

## Font sizes, canvas px at 100% text size.
const TAB_PX := 20
const OPTION_PX := 18
const STATUS_PX := 14
const STATE_PX := 22
const NOTE_PX := 16
const ACTION_PX := 18

## The tab the screen opens on next time (the last one shown).
static var last_board: String = NetBoards.JOURNEY
static var last_view: String = NetBoards.VIEW_GLOBAL

var runs: NetRunsClient
var net: NetTuning
var board: String = NetBoards.JOURNEY
var view: String = NetBoards.VIEW_GLOBAL
## Index into NetBoards.periods_of(board); Daily Drive uses `days_back` instead.
var period_index: int = 0
var days_back: int = 0
var miles: bool = false
## The page on show (null before the first answer).
var page: NetBoardPage
## A state message instead of rows ("" = the rows show).
var state_text: String = ""
var busy: bool = false
var confirming_block: bool = false
## The screen hosting this one (pause or results) and what it hid.
var host: RunScreen

var title: ScreenText
var back_button: ScreenButton
var tabs: Array[ScreenButton] = []
var periods: Array[ScreenButton] = []
var prev_button: ScreenButton
var day_button: ScreenButton
var next_button: ScreenButton
var views: Array[ScreenButton] = []
var list_panel: ScreenPanel
var list: LeaderboardsList
var state_title: ScreenText
var state_note: ScreenText
var retry_button: ScreenButton
var status: ScreenText
var report_cheat_button: ScreenButton
var report_name_button: ScreenButton
var block_button: ScreenButton
var cancel_button: ScreenButton

var _hidden: Array[CanvasItem] = []
var _note: String = ""
## The last failed answer while nothing was cached for the choice (its state shows).
var _failed: NetBoardPage
var _last_force_usec: int = -1


func _init() -> void:
	super._init()
	name = "LeaderboardsScreen"
	modal = true
	title = ScreenText.make(TEXT_TITLE, ScreenText.Face.DISPLAY, 40, ScreenText.Ink.TEXT)
	add_child(title)
	back_button = _button(TEXT_BACK, ScreenButton.Kind.NORMAL, close_by_player, OPTION_PX)
	for b in NetBoards.BOARDS:
		var t := _button(String(TAB_TEXT[b]), ScreenButton.Kind.OPTION, show_board.bind(b), TAB_PX)
		t.align = HORIZONTAL_ALIGNMENT_LEFT
		tabs.append(t)
	for i in 2:
		periods.append(_button("", ScreenButton.Kind.OPTION, _on_period.bind(i), OPTION_PX))
	prev_button = _button(TEXT_PREV, ScreenButton.Kind.NORMAL, step_day.bind(1), OPTION_PX)
	prev_button.align = HORIZONTAL_ALIGNMENT_CENTER
	day_button = _button(TEXT_TODAY, ScreenButton.Kind.OPTION, _on_today, OPTION_PX)
	day_button.selected = true
	next_button = _button(TEXT_NEXT, ScreenButton.Kind.NORMAL, step_day.bind(-1), OPTION_PX)
	next_button.align = HORIZONTAL_ALIGNMENT_CENTER
	list_panel = ScreenPanel.new()
	list_panel.name = "ListPanel"
	add_child(list_panel)
	list = LeaderboardsList.new()
	list.name = "List"
	list.row_tapped.connect(_on_row_tapped)
	list.refresh_requested.connect(refresh)
	list.pull_changed.connect(func(_s: int) -> void: _update_status())
	list_panel.add_child(list)
	state_title = ScreenText.make("", ScreenText.Face.LABEL, STATE_PX, ScreenText.Ink.TEXT)
	list_panel.add_child(state_title)
	state_note = ScreenText.make("", ScreenText.Face.BODY, NOTE_PX, ScreenText.Ink.MUTED)
	list_panel.add_child(state_note)
	retry_button = ScreenButton.make(TEXT_RETRY, ScreenButton.Kind.NORMAL, OPTION_PX)
	retry_button.name = "Retry"
	retry_button.pressed.connect(refresh)
	list_panel.add_child(retry_button)
	status = ScreenText.make("", ScreenText.Face.LABEL, STATUS_PX, ScreenText.Ink.MUTED)
	add_child(status)
	for v in NetBoards.VIEWS:
		views.append(_button(String(VIEW_TEXT[v]), ScreenButton.Kind.OPTION, show_view.bind(v), OPTION_PX))
	report_cheat_button = _button(TEXT_REPORT_CHEAT, ScreenButton.Kind.NORMAL, report.bind(NetBoards.REASON_CHEATING), ACTION_PX)
	report_name_button = _button(TEXT_REPORT_NAME, ScreenButton.Kind.NORMAL, report.bind(NetBoards.REASON_NAME), ACTION_PX)
	block_button = _button(TEXT_BLOCK, ScreenButton.Kind.DANGER, block, ACTION_PX)
	cancel_button = _button(TEXT_CANCEL, ScreenButton.Kind.NORMAL, deselect, ACTION_PX)


func _button(label: String, kind: ScreenButton.Kind, action: Callable, px: int) -> ScreenButton:
	var b := ScreenButton.make(label, kind, px)
	b.name = label.capitalize().replace(" ", "") if not label.is_empty() else "Option"
	b.pressed.connect(action)
	add_child(b)
	return b


## The runs client (its NetBoards and session). Null: the game's (NetRunsClient.ensure()).
func bind(client: NetRunsClient) -> void:
	if runs != null and is_instance_valid(runs) and runs.boards.page_ready.is_connected(_on_page):
		runs.boards.page_ready.disconnect(_on_page)
		runs.boards.action_done.disconnect(_on_action)
	runs = client
	if runs != null:
		net = runs.tuning
		runs.boards.page_ready.connect(_on_page)
		runs.boards.action_done.connect(_on_action)


func _exit_tree() -> void:
	bind(null)


func _restyled() -> void:
	if net == null:
		net = runs.tuning if runs != null else NetTuning.load_default()
	title.size_px = net.boards_title_px
	title.use_tilt(TILT_SHADER, tuning.speed_tilt_rad())
	list.setup(style, net)
	_layout()


# ---------------------------------------------------------------- Opening

## The leaderboards screen of `over` (pause or results): `existing`, or a new one added
## to it and styled like it. Built on first use only.
static func attach(over: RunScreen, existing: LeaderboardsScreen, client: NetRunsClient) -> LeaderboardsScreen:
	var ls := existing
	if ls == null or not is_instance_valid(ls):
		ls = LeaderboardsScreen.new()
		ls.bind(client)
		over.add_child(ls)
		if over.style != null:
			ls.setup(over.style, over.tuning)
	return ls


## Shows the leaderboards over `over` (pause or results): its widgets hide, its dim
## stays. `start_board` "" = the last board shown.
func open_over(over: RunScreen, start_board: String = "") -> void:
	host = over
	if runs == null:
		bind(NetRunsClient.ensure())
	over.finish_animations()
	_hidden.clear()
	for c in over.get_children():
		var ci := c as CanvasItem
		if ci != null and ci != self and ci.visible and not (ci is ColorRect):
			ci.visible = false
			_hidden.append(ci)
	over.move_child(self, -1)
	mirrored = over.mirrored
	reduced_motion = over.reduced_motion
	place(Rect2(Vector2.ZERO, over.full.size), over.safe)
	board = start_board if NetBoards.BOARDS.has(start_board) else last_board
	view = last_view
	period_index = 0
	days_back = 0
	miles = StringName(str(Settings.get_value(&"units"))) == &"mph"
	deselect()
	_note = ""
	open()
	_apply()
	fetch()


## BACK / Esc: closes and gives the host its widgets back.
func close_by_player() -> void:
	close(false)
	closed_by_player.emit()


func _closed() -> void:
	for ci in _hidden:
		if is_instance_valid(ci):
			ci.visible = true
	_hidden.clear()
	list.settle()


func _entered() -> void:
	var tw := new_tween()
	modulate.a = 0.0
	tw.tween_property(self, ^"modulate:a", 1.0, tuning.screen_fade_in_s)
	slide_in(list_panel, -tuning.screen_slide_px, tuning.screen_fade_in_s, 0.0)


func _unhandled_input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		close_by_player()
	elif event.is_action_pressed(&"ui_accept"):
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------- Choices

func show_board(b: String) -> void:
	if not NetBoards.BOARDS.has(b):
		return
	board = b
	last_board = b
	period_index = 0
	days_back = 0
	_note = ""
	deselect()
	_apply()
	fetch()


func show_view(v: String) -> void:
	if not NetBoards.VIEWS.has(v):
		return
	view = v
	last_view = v
	_note = ""
	deselect()
	_apply()
	fetch()


func _on_period(i: int) -> void:
	if i >= NetBoards.periods_of(board).size():
		return
	period_index = i
	_note = ""
	deselect()
	_apply()
	fetch()


## Daily Drive: `back` more days into the past (negative: toward today).
func step_day(back: int) -> void:
	days_back = clampi(days_back + back, 0, net.boards_daily_days_back)
	_note = ""
	deselect()
	_apply()
	fetch()


func _on_today() -> void:
	step_day(-days_back)


## The period asked for: the board's list, or on Daily Drive today ("current") or a date.
func period() -> String:
	if board == NetBoards.DAILY:
		if days_back <= 0:
			return NetBoards.PERIOD_CURRENT
		return NetRunPayload.utc_date(_now_unix() - float(days_back) * NetRunsClient.S_PER_DAY)
	var ps := NetBoards.periods_of(board)
	return ps[clampi(period_index, 0, ps.size() - 1)]


# ---------------------------------------------------------------- Data

## Shows what is cached for the current choice at once, and asks the server when it is
## stale (or `force`). The answer arrives through NetBoards.page_ready (_on_page).
func fetch(force: bool = false) -> void:
	_failed = null
	list.distance = board == NetBoards.DISTANCE
	list.miles = miles
	if runs == null:
		page = null
		list.set_page(null, "")
		_refresh_state()
		return
	var p := period()
	var have := runs.boards.cached(board, p, view)
	var same := page != null and have != null and page.key() == have.key()
	page = have
	list.set_page(have, _my_id(), same)
	if have != null and not same and view == NetBoards.VIEW_AROUND_ME:
		list.center_on(list.my_index())
	_refresh_state()
	runs.boards.fetch(board, p, view, force)
	_refresh_state()


## Pull to refresh / RETRY: asks the server again (at most every boards_refresh_min_s).
func refresh() -> void:
	var now := Time.get_ticks_usec()
	if runs != null and _last_force_usec >= 0 \
			and now - _last_force_usec < roundi(net.boards_refresh_min_s * NetRunsClient.USEC_PER_S):
		fetch(false)
		return
	_last_force_usec = now
	fetch(true)


func _on_page(p: NetBoardPage) -> void:
	if p.board != board or p.period != period() or p.view != view:
		return   # an older choice's answer
	if not p.ok:
		# A cached page stays on show (the status line says why it is old); otherwise
		# the state panel says why there is nothing.
		if page != null:
			_note = _error_title(p.error)
		else:
			_failed = p
		_refresh_state()
		return
	var keep := page != null and page.key() == p.key()
	page = p
	_failed = null
	if _note == TEXT_OFFLINE or _note == TEXT_SIGN_IN or _note == TEXT_ERROR:
		_note = ""
	list.distance = board == NetBoards.DISTANCE
	list.miles = miles
	list.set_page(p, _my_id(), keep)
	if view == NetBoards.VIEW_AROUND_ME and not keep:
		list.center_on(list.my_index())
	_refresh_state()


func _my_id() -> String:
	if runs != null and runs.session != null:
		return runs.session.account_id()
	return ""


func _now_unix() -> float:
	return runs.now_unix() if runs != null else Time.get_unix_time_from_system()


## The state panel and the status line for what is shown now.
func _refresh_state() -> void:
	var failed := _failed
	var loading := runs != null and runs.boards.is_loading(board, period(), view)
	var note := ""
	var text := ""
	var can_retry := false
	if runs == null:
		text = TEXT_DISABLED
		note = NOTE_DISABLED
	elif page == null and loading:
		text = TEXT_LOADING
	elif page == null and failed != null:
		text = _error_title(failed.error)
		note = _error_note(failed.error)
		can_retry = failed.error != NetBoards.ERR_NO_SESSION
	elif page == null:
		text = TEXT_LOADING
	elif page.entries.is_empty():
		if view == NetBoards.VIEW_FRIENDS and board == NetBoards.LOOP_CREW:
			text = TEXT_CREW_FRIENDS
			note = NOTE_CREW_FRIENDS
		elif view == NetBoards.VIEW_FRIENDS:
			text = TEXT_EMPTY_FRIENDS
			note = NOTE_EMPTY_FRIENDS
		elif view == NetBoards.VIEW_AROUND_ME:
			text = TEXT_EMPTY_AROUND
			note = NOTE_EMPTY_AROUND
		else:
			text = TEXT_EMPTY
			note = NOTE_EMPTY
	state_text = text
	state_title.text = text
	state_title.set_ink(ScreenText.Ink.HOT if can_retry else ScreenText.Ink.TEXT)
	state_note.text = note
	state_title.visible = not text.is_empty()
	state_note.visible = not note.is_empty()
	retry_button.visible = can_retry
	list.visible = text.is_empty() or (page != null and not page.entries.is_empty())
	_update_status()
	_layout()


func _error_title(code: String) -> String:
	match code:
		NetBoards.ERR_NOT_SIGNED_IN:
			return TEXT_SIGN_IN
		NetBoards.ERR_NO_SESSION:
			return TEXT_DISABLED
		NetApiResult.NETWORK, NetApiResult.SERVER, NetApiResult.BAD_RESPONSE:
			return TEXT_OFFLINE
	return TEXT_ERROR


func _error_note(code: String) -> String:
	match code:
		NetBoards.ERR_NOT_SIGNED_IN:
			return NOTE_SIGN_IN
		NetBoards.ERR_NO_SESSION:
			return NOTE_DISABLED
		NetApiResult.NETWORK, NetApiResult.SERVER, NetApiResult.BAD_RESPONSE:
			return NOTE_OFFLINE
	return NetSession.error_text(NetApiResult.failure(0, code), _now_unix())


func _update_status() -> void:
	var t := ""
	var ink := ScreenText.Ink.MUTED
	match list.pull_state():
		LeaderboardsList.PULL_MORE:
			t = TEXT_PULL
		LeaderboardsList.PULL_READY:
			t = TEXT_RELEASE
			ink = ScreenText.Ink.ACCENT
	if t.is_empty() and not _note.is_empty():
		t = _note
		ink = ScreenText.Ink.ACCENT if _note == TEXT_REPORTED or _note == TEXT_BLOCKED else ScreenText.Ink.HOT
	if t.is_empty() and runs != null and runs.boards.is_loading(board, period(), view) and page != null:
		t = TEXT_UPDATING
	if t.is_empty() and page != null and page.ok and page.total > 0:
		t = TEXT_TOTAL_ONE if page.total == 1 else TEXT_TOTAL % HudFormat.thousands(page.total)
	status.text = t
	status.set_ink(ink)
	_layout_bottom()


# ---------------------------------------------------------------- Rows and actions

## The selected entry (null: none).
func selected_entry() -> NetBoardPage.Entry:
	if page == null or list.selected < 0 or list.selected >= page.entries.size():
		return null
	return page.entries[list.selected]


func _on_row_tapped(index: int) -> void:
	if page == null or index < 0 or index >= page.entries.size():
		return
	var e := page.entries[index]
	if list.selected == index or e.is_crew() or page.is_mine(e, _my_id()) or e.account_id.is_empty():
		deselect()
		return
	confirming_block = false
	list.select(index)
	_note = ""
	_apply()


func deselect() -> void:
	confirming_block = false
	if list != null:
		list.select(-1)
	_apply()


## REPORT CHEATING / REPORT NAME on the selected entry.
func report(reason: String) -> void:
	var e := selected_entry()
	if e == null or busy or runs == null:
		return
	busy = true
	_note = TEXT_SENDING
	_apply()
	runs.boards.report(e.account_id, reason, board, page.period_key if not page.period_key.is_empty() else period(), e.run_id)


## BLOCK asks for a second tap (CONFIRM BLOCK), then blocks.
func block() -> void:
	var e := selected_entry()
	if e == null or busy or runs == null:
		return
	if not confirming_block:
		confirming_block = true
		_apply()
		return
	busy = true
	_note = TEXT_SENDING
	_apply()
	runs.boards.block(e.account_id)


func _on_action(kind: String, _account_id: String, r: NetApiResult) -> void:
	busy = false
	confirming_block = false
	if r.ok:
		_note = TEXT_REPORTED if kind == NetBoards.ACTION_REPORT else TEXT_BLOCKED
		list.select(-1)
		if kind == NetBoards.ACTION_BLOCK and view == NetBoards.VIEW_FRIENDS:
			fetch(true)
	elif r.error == NetApiResult.RATE_LIMITED:
		_note = TEXT_ACTION_LIMIT
	else:
		_note = TEXT_ACTION_FAILED
	_apply()


# ---------------------------------------------------------------- View

## Buttons and texts for the current choices.
func _apply() -> void:
	if tabs.is_empty():
		return
	for i in tabs.size():
		tabs[i].selected = NetBoards.BOARDS[i] == board
	var daily := board == NetBoards.DAILY
	var ps := NetBoards.periods_of(board)
	for i in periods.size():
		var b := periods[i]
		b.visible = not daily and i < ps.size()
		if b.visible:
			b.text = _period_text(ps[i])
			b.selected = i == period_index
	prev_button.visible = daily
	day_button.visible = daily
	next_button.visible = daily
	if daily:
		day_button.text = _day_text(days_back) if days_back <= 1 else date_label(period())
		prev_button.disabled = days_back >= net.boards_daily_days_back
		next_button.disabled = days_back <= 0
	for i in views.size():
		views[i].selected = NetBoards.VIEWS[i] == view
	var acting := selected_entry() != null
	for v in views:
		v.visible = not acting
	for b: ScreenButton in [report_cheat_button, report_name_button, block_button, cancel_button]:
		b.visible = acting
		b.disabled = busy
	block_button.text = TEXT_BLOCK_CONFIRM if confirming_block else TEXT_BLOCK
	_update_status()
	_layout()


func _period_text(p: String) -> String:
	if p == NetBoards.PERIOD_ALL or board == NetBoards.DISTANCE:
		return TEXT_ALL_TIME
	if board == NetBoards.JOURNEY:
		return TEXT_WEEK
	return TEXT_SEASON


static func _day_text(back: int) -> String:
	if back <= 0:
		return TEXT_TODAY
	if back == 1:
		return TEXT_YESTERDAY
	return ""


func _layout() -> void:
	if style == null or net == null or tabs.is_empty():
		return
	var m := margin()
	var g := tuning.spacing_grid_px
	var a := safe.grow(-m)
	var th := tuning.touch_target_px
	var ts := style.ts
	# Top row: the title, the period control, BACK at the right end.
	var tsz := title.get_combined_minimum_size()
	title.position = Vector2(a.position.x, a.position.y + (th - tsz.y) * 0.5)
	title.size = tsz
	var bw := maxf(net.boards_back_width_px, _text_w(back_button) + g * 4.0)
	back_button.position = Vector2(a.end.x - bw, a.position.y)
	back_button.size = Vector2(bw, th)
	var x := a.position.x + tsz.x + g * 3.0
	for b: ScreenButton in [prev_button, day_button, next_button, periods[0], periods[1]]:
		if not b.visible:
			continue
		var w := maxf(net.boards_option_min_px * (0.5 if b == prev_button or b == next_button else 1.0),
				_text_w(b) + g * 4.0)
		b.position = Vector2(x, a.position.y)
		b.size = Vector2(w, th)
		x += w + g
	# Tabs: a column on the left.
	var top := a.position.y + th + g * 2.0
	var tw := maxf(net.boards_tab_width_px, _widest(tabs) + g * 4.0)
	var tab_h := minf(th, (a.end.y - top - g * float(tabs.size() - 1)) / float(tabs.size()))
	tab_h = maxf(tab_h, th)
	for i in tabs.size():
		tabs[i].position = Vector2(a.position.x, top + float(i) * (tab_h + g))
		tabs[i].size = Vector2(tw, tab_h)
	# The list's panel on the right, the bottom row under it.
	var lx := a.position.x + tw + g * 3.0
	var bottom_y := a.end.y - th
	list_panel.position = Vector2(lx, top)
	list_panel.size = Vector2(a.end.x - lx, bottom_y - g * 2.0 - top)
	var pad := tuning.panel_padding_px * ts
	list.position = Vector2(pad, pad)
	list.size = list_panel.size - Vector2(pad, pad) * 2.0
	_layout_state()
	_layout_bottom()


func _layout_state() -> void:
	var g := tuning.spacing_grid_px
	var th := tuning.touch_target_px
	var ps := list_panel.size
	var h := 0.0
	var parts: Array[Control] = []
	for c: Control in [state_title, state_note, retry_button]:
		if c.visible:
			parts.append(c)
	for c in parts:
		h += (th if c == retry_button else c.get_combined_minimum_size().y) + g
	var y := (ps.y - h) * 0.5
	for c in parts:
		if c == retry_button:
			var w := maxf(net.boards_back_width_px, _text_w(retry_button) + g * 4.0)
			c.position = Vector2((ps.x - w) * 0.5, y + g)
			c.size = Vector2(w, th)
			y += th + g
		else:
			var s := c.get_combined_minimum_size()
			c.size = Vector2(minf(s.x, ps.x), s.y)
			c.position = Vector2((ps.x - c.size.x) * 0.5, y)
			y += s.y + g


## The bottom row: the views (or the row actions) on the thumb side, the status line on
## the other.
func _layout_bottom() -> void:
	if style == null or net == null or tabs.is_empty():
		return
	var m := margin()
	var g := tuning.spacing_grid_px
	var a := safe.grow(-m)
	var th := tuning.touch_target_px
	var y := a.end.y - th
	var lx := list_panel.position.x
	var shown: Array[ScreenButton] = []
	for b: ScreenButton in views + [report_cheat_button, report_name_button, block_button, cancel_button]:
		if b.visible:
			shown.append(b)
	var total := 0.0
	for b in shown:
		b.size = Vector2(maxf(net.boards_option_min_px, _text_w(b) + g * 4.0), th)
		total += b.size.x + g
	total -= g
	var x := a.end.x - total if not mirrored else lx
	for b in shown:
		b.position = Vector2(x, y)
		x += b.size.x + g
	var ss := status.get_combined_minimum_size()
	status.size = ss
	var sy := y + (th - ss.y) * 0.5
	if mirrored:
		status.position = Vector2(a.end.x - ss.x, sy)
	else:
		status.position = Vector2(lx, sy)
	# The status line gives way when the row actions need the room (text size 125%).
	var room := (a.end.x - total - g - lx) if not mirrored else (a.end.x - (lx + total + g))
	status.visible = not status.text.is_empty() and ss.x <= room


## A date period as "SEP 27".
static func date_label(date: String) -> String:
	var p := date.split("-")
	if p.size() != 3:
		return date
	var mi := clampi(p[1].to_int() - 1, 0, MONTHS.size() - 1)
	return "%s %d" % [MONTHS[mi], p[2].to_int()]


func _text_w(b: ScreenButton) -> float:
	return HudDraw.text_width(style.label, b.text, b.font_px())


func _widest(bs: Array[ScreenButton]) -> float:
	var w := 0.0
	for b in bs:
		w = maxf(w, _text_w(b))
	return w
