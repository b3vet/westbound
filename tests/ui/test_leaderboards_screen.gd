extends WBTest
## The leaderboards screen and the results' online line, on the in-memory boards server:
## opened from the pause menu and the results (built on first use, nothing drawn when
## hidden), every tab, period and view asking for the right URL, the player's row
## highlighted and centred in "around me" (pinned when out of view), pooled rows scrolled
## by touch, pull to refresh, the loading / empty / offline / signed-out / disabled
## states, report and block from a row, the results' placements arriving after the
## results opened (non-blocking), OFFLINE — WILL SUBMIT and UPDATE REQUIRED, and text fit
## at both text sizes, both hands and a notched canvas. Touches go through
## Input.parse_input_event with an iOS-style id. Spec: multiplayer handoff →
## Leaderboards, Client changes → Leaderboards screen, Rooms → Moderation; UI →
## Accessibility. WP N7.2.

const SCREENS_SCENE := preload("res://src/ui/screens/run_screens.tscn")
const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const IOS_ID := 1_893_457_201
const BASE := "https://lb.test/api/v1"
## 2026-09-29 12:00 UTC (ISO week 2026-W40).
const NOW_S := 1790683200.0
const WEEK := "2026-W40"
const DRIVERS := 150
const TOP := 2_000_000
const STEP := 10_000
const HALF_STEP := 5_000
const MY_RANK := 57
const CANVASES: Array[Vector2] = [Vector2(1280.0, 720.0), Vector2(1560.0, 720.0)]
const NOTCH := Vector4(44.0, 0.0, 44.0, 21.0)
const TOL := 0.5

var tuning: NetTuning
var hud: HudTuning
var fake: NetFakeBoards
var time: NetVirtualTime
var session: NetSession
var runs: NetRunsClient
var ids: PackedStringArray
var probe := HudTextProbe.new()
var _nodes: Array[Node] = []


func before_all() -> void:
	tuning = NetTuning.load_default().duplicate() as NetTuning
	tuning.api_backoff_jitter = 0.0
	hud = Tuning.load_default().hud


func before_each() -> void:
	Settings.reset_to_defaults()
	tree.paused = false
	fake = NetFakeBoards.new()
	fake.now_s = NOW_S
	time = NetVirtualTime.new(2_000_000)
	LeaderboardsScreen.last_board = NetBoards.JOURNEY
	LeaderboardsScreen.last_view = NetBoards.VIEW_GLOBAL


func after_each() -> void:
	HudDraw.probe = null
	fake.release()
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	runs = null
	session = null
	Settings.reset_to_defaults()
	await tree.process_frame


## A session (online unless `online` is false), its runs client, and a seeded board.
func _env(online: bool = true, seed_boards: bool = true) -> void:
	session = NetSession.new()
	session.auto_start = false
	session.configure(fake, NetSessionStore.new(), tuning, time, BASE, 8)
	session.unix_clock = func() -> float: return fake.now_s
	tree.root.add_child(session)
	_nodes.append(session)
	runs = NetRunsClient.new()
	runs.configure(session, NetSessionStore.new(), tuning, time)
	runs.unix_clock = func() -> float: return fake.now_s
	runs.local_bests = func() -> Dictionary: return {}
	runs.car_of = func(_r: Dictionary) -> String: return "falcon_gt"
	session.add_child(runs)
	if online:
		await session.start()
	if seed_boards:
		ids = fake.seed_board(NetBoards.JOURNEY, WEEK, DRIVERS, TOP, STEP)
		(fake.accounts[ids[1]] as Dictionary)["name"] = "WWWWWWWWWWWWWWWW"
		(fake.accounts[ids[0]] as Dictionary)["name"] = "Şahin 34"
		fake.set_crew(ids[1], "3", "DUSK", "Dusk")
		(fake.entries_of(NetBoards.JOURNEY, WEEK)[2] as Dictionary)["verification"] = "pending"
		(fake.entries_of(NetBoards.JOURNEY, WEEK)[3] as Dictionary)["verification"] = "legacy"
		if online:
			fake.put_entry(NetBoards.JOURNEY, WEEK, session.account_id(), TOP - (MY_RANK - 2) * STEP - HALF_STEP)
			fake.befriend(session.account_id(), ids[5])


func _screens(full: Rect2 = SCREEN, safe: Rect2 = SCREEN) -> RunScreens:
	var s := SCREENS_SCENE.instantiate() as RunScreens
	s.persist_settings = false
	tree.root.add_child(s)
	_nodes.append(s)
	s.bind(null, HudFeed.new())
	s.set_screen(full, safe)
	if runs != null:
		s.results_screen.bind_runs(runs)
		s.pause_screen.runs = runs
	return s


func _open(s: RunScreens) -> LeaderboardsScreen:
	s.show_state(Game.PAUSED, Game.RUNNING)
	s.pause_screen.finish_animations()
	_tap(s.pause_screen.boards_button)
	var ls := s.pause_screen.leaderboards
	if ls != null:
		ls.finish_animations()
	return ls


## A tap at the centre of `c` (or at `at`, global canvas px) with an iOS-style id.
func _tap(c: Control, at: Vector2 = Vector2(-1.0, -1.0)) -> void:
	var p := c.get_global_rect().get_center() if at.x < 0.0 else at
	_touch(p, true)
	_touch(p, false)


func _touch(p: Vector2, down: bool) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = IOS_ID
	ev.position = tree.root.get_final_transform() * p
	ev.pressed = down
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


## A drag from `from` by `by` (global canvas px) in `steps` moves, finger kept down
## unless `release`.
func _drag(from: Vector2, by: Vector2, steps: int, release: bool = true) -> void:
	_touch(from, true)
	var to_window := tree.root.get_final_transform()
	for i in steps:
		var ev := InputEventScreenDrag.new()
		ev.index = IOS_ID
		var p := from + by * float(i + 1) / float(steps)
		ev.position = to_window * p
		ev.relative = to_window.basis_xform(by / float(steps))
		Input.parse_input_event(ev)
		Input.flush_buffered_events()
	if release:
		_touch(from + by, false)


func _paths_since(n: int) -> PackedStringArray:
	var out := PackedStringArray()
	for i in range(n, fake.requests.size()):
		out.append(String(fake.requests[i]["path"]))
	return out


# ---------------------------------------------------------------- Opening

func test_pause_opens_it_and_back_restores_the_menu() -> void:
	await _env()
	var s := _screens()
	s.show_state(Game.PAUSED, Game.RUNNING)
	var p := s.pause_screen
	check(p.leaderboards == null, "not built before it is needed")
	check(p.boards_button.visible, "LEADERBOARDS in the menu")
	ge(p.boards_button.size.y, hud.touch_target_px)
	lt(p.boards_button.position.y, p.resume_button.position.y, "above RESUME...")
	gt(p.boards_button.position.y, p.quit_button.position.y, "...below QUIT")
	var ls := _open(s)
	if not check(ls != null and ls.visible, "open"):
		return
	check(not p.resume_button.visible and not p.title.visible, "the menu steps aside")
	check(p.dim.visible, "the dim stays")
	check(ls.get_parent() == p)
	eq(ls.board, NetBoards.JOURNEY)
	check(ls.list.count() > 0, "rows")
	_tap(ls.back_button)
	check(not ls.visible, "BACK closes it")
	eq(RunScreens._count_visible(ls), 0, "nothing under it draws")
	check(p.resume_button.visible and p.title.visible and p.boards_button.visible, "the menu is back")
	# Esc closes it too; resuming the run from under it leaves nothing drawn.
	ls = _open(s)
	var esc := InputEventAction.new()
	esc.action = &"ui_cancel"
	esc.pressed = true
	Input.parse_input_event(esc)
	Input.flush_buffered_events()
	check(not ls.visible, "Esc closes it")
	ls = _open(s)
	s.show_state(Game.RUNNING, Game.PAUSED)
	s.finish_animations()
	eq(s.visible_item_count(), 0, "gameplay: nothing drawn")
	s.show_state(Game.PAUSED, Game.RUNNING)
	check(not ls.visible and p.resume_button.visible, "a new pause starts at the menu")


func test_no_session_no_button_and_disabled_state() -> void:
	var s := _screens()
	s.show_state(Game.PAUSED, Game.RUNNING)
	check(not s.pause_screen.boards_button.visible, "no online session: no LEADERBOARDS")
	s.show_results(_results_payload())
	check(not s.results_screen.boards_button.visible)
	check(not s.results_screen.online.visible, "no online line")
	var ls := LeaderboardsScreen.attach(s.pause_screen, null, null)
	ls.open_over(s.pause_screen)
	eq(ls.state_title.text, LeaderboardsScreen.TEXT_DISABLED)
	eq(ls.state_note.text, LeaderboardsScreen.NOTE_DISABLED)


# ---------------------------------------------------------------- Requests

func test_tabs_periods_and_views_request_the_right_urls() -> void:
	await _env()
	var s := _screens()
	var n := fake.requests.size()
	var ls := _open(s)
	eq(_paths_since(n), PackedStringArray(["/boards/journey?period=current&view=global&limit=100"]), "opens on Journey")
	var expect := {
		NetBoards.LOOP: "/boards/loop?period=current&view=global&limit=100",
		NetBoards.LOOP_CREW: "/boards/loop_crew?period=current&view=global&limit=100",
		NetBoards.DAILY: "/boards/daily?period=current&view=global&limit=100",
		NetBoards.DISTANCE: "/boards/distance?period=current&view=global&limit=100",
	}
	for i in NetBoards.BOARDS.size():
		var b := NetBoards.BOARDS[i]
		if b == NetBoards.JOURNEY:
			continue
		n = fake.requests.size()
		_tap(ls.tabs[i])
		eq(_paths_since(n), PackedStringArray([expect[b]]), "tab %s" % b)
		check(ls.tabs[i].selected, "%s selected" % b)
	# Periods: Loop season / all time.
	_tap(ls.tabs[0])
	check(ls.periods[0].visible and ls.periods[1].visible)
	eq(ls.periods[0].text, LeaderboardsScreen.TEXT_SEASON)
	n = fake.requests.size()
	_tap(ls.periods[1])
	eq(_paths_since(n), PackedStringArray(["/boards/loop?period=all&view=global&limit=100"]), "Loop all time")
	# Journey: this week / all time, in every view.
	_tap(ls.tabs[2])
	eq(ls.periods[0].text, LeaderboardsScreen.TEXT_WEEK)
	_tap(ls.periods[1])
	for v: Array in [[1, "/boards/journey?period=all&view=around_me&limit=10"], [2, "/boards/journey?period=all&view=friends"],
			[0, "/boards/journey?period=all&view=global&limit=100"]]:
		runs.boards.invalidate()   # every view asks (none from memory)
		n = fake.requests.size()
		_tap(ls.views[int(v[0])])
		eq(_paths_since(n), PackedStringArray([v[1]]), "view %s" % NetBoards.VIEWS[int(v[0])])
	# Distance and the crew board have one period: no switcher.
	_tap(ls.tabs[4])
	check(not ls.periods[0].visible or ls.periods[0].text == LeaderboardsScreen.TEXT_ALL_TIME)
	check(not ls.periods[1].visible, "one period")
	# Daily Drive: today, then previous days by date.
	_tap(ls.tabs[3])
	check(ls.day_button.visible and ls.prev_button.visible and ls.next_button.visible, "the day stepper")
	eq(ls.day_button.text, LeaderboardsScreen.TEXT_TODAY)
	check(ls.next_button.disabled, "no future days")
	n = fake.requests.size()
	_tap(ls.prev_button)
	eq(ls.day_button.text, LeaderboardsScreen.TEXT_YESTERDAY)
	_tap(ls.prev_button)
	eq(ls.day_button.text, "SEP 27")
	eq(_paths_since(n), PackedStringArray(["/boards/daily?period=2026-09-28&view=global&limit=100",
			"/boards/daily?period=2026-09-27&view=global&limit=100"]))
	_tap(ls.day_button)
	eq(ls.day_button.text, LeaderboardsScreen.TEXT_TODAY, "the day button goes back to today")
	for i in tuning.boards_daily_days_back + 2:
		ls.step_day(1)
	eq(ls.days_back, tuning.boards_daily_days_back, "reaches back boards_daily_days_back days")
	check(ls.prev_button.disabled)


# ---------------------------------------------------------------- Rows

func test_around_me_highlights_and_centres_my_row() -> void:
	await _env()
	var s := _screens()
	var ls := _open(s)
	# Global: rank 57 is in the top 100 but out of view: pinned at the bottom.
	var mi := ls.list.my_index()
	eq(mi, MY_RANK - 1)
	check(ls.list.pinned.visible, "my row pinned while out of view")
	check(ls.list.pinned.mine, "and highlighted")
	eq(ls.list.pinned.entry.rank, MY_RANK)
	ls.list.center_on(mi)
	check(not ls.list.pinned.visible, "no pin once my row is in view")
	check(ls.list.row_of(mi) != null and ls.list.row_of(mi).mine)
	_tap(ls.views[1])
	eq(ls.view, NetBoards.VIEW_AROUND_ME)
	eq(ls.list.count(), tuning.boards_around_me_limit * 2 + 1, "ranks on each side")
	mi = ls.list.my_index()
	eq(mi, tuning.boards_around_me_limit, "me in the middle")
	var row := ls.list.row_of(mi)
	if not check(row != null, "my row is in view"):
		return
	check(row.mine, "highlighted")
	var mine_rows := 0
	for r in ls.list.rows:
		if r.visible and r.mine:
			mine_rows += 1
	eq(mine_rows, 1, "only mine")
	var centre := row.get_global_rect().get_center().y
	near(centre, ls.list.clip.get_global_rect().get_center().y, ls.list.row_h(), "centred in the list")
	check(not ls.list.pinned.visible)
	# Signed out: around me asks to sign in; global still reads.
	await session.logout()
	runs.boards.invalidate()
	_tap(ls.views[1])
	eq(ls.state_title.text, LeaderboardsScreen.TEXT_SIGN_IN)
	_tap(ls.views[0])
	check(ls.state_title.text.is_empty() and ls.list.count() > 0, "global works signed out")


func test_rows_are_pooled_and_scroll_by_touch() -> void:
	await _env()
	var s := _screens()
	var ls := _open(s)
	eq(ls.list.count(), tuning.boards_global_limit, "the top 100")
	var need := ceili(ls.list.size.y / ls.list.row_h()) + LeaderboardsList.SPARE_ROWS
	le(ls.list.rows.size(), need, "a small pool of rows, not 100 controls")
	lt(ls.list.rows.size(), 20)
	await tree.process_frame
	var redraws_before := ls.list.rows[0].redraws
	ls.list._layout()
	await tree.process_frame
	eq(ls.list.rows[0].redraws, redraws_before, "an unchanged row does not redraw")
	var clip := ls.list.clip.get_global_rect()
	_drag(clip.get_center(), Vector2(0.0, -ls.list.row_h() * 5.0), 10)
	near(ls.list.scroll, ls.list.row_h() * 5.0, 1.0, "dragged five rows up")
	ls.list.settle()
	var first := ls.list.index_at(Vector2(ls.list.size.x * 0.5, 1.0))
	ge(first, 4)
	check(ls.list.row_of(first) != null and ls.list.row_of(first).entry.rank == first + 1, "row reuse shows the right entry")
	eq(ls.list.selected, -1, "a drag selects nothing")
	# The wheel scrolls a row.
	var before := ls.list.scroll
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	wheel.position = ls.list.get_local_mouse_position()
	ls.list._gui_input(wheel)
	near(ls.list.scroll, before + ls.list.row_h(), 0.01)


func test_pull_to_refresh_asks_again() -> void:
	await _env()
	var s := _screens()
	var ls := _open(s)
	var n := fake.requests.size()
	var top := ls.list.clip.get_global_rect().position + Vector2(ls.list.size.x * 0.5, ls.list.row_h() * 0.5)
	_drag(top, Vector2(0.0, tuning.boards_pull_refresh_px * 3.0), 6, false)
	eq(ls.list.pull_state(), LeaderboardsList.PULL_READY)
	eq(ls.status.text, LeaderboardsScreen.TEXT_RELEASE, "RELEASE TO REFRESH")
	gt(ls.list.pull, 0.0)
	_touch(top + Vector2(0.0, tuning.boards_pull_refresh_px * 3.0), false)
	eq(_paths_since(n), PackedStringArray(["/boards/journey?period=current&view=global&limit=100"]),
			"a fresh page, asked again")
	ls.list.settle()
	# A small pull does nothing.
	n = fake.requests.size()
	_drag(top, Vector2(0.0, tuning.boards_pull_refresh_px * 0.5), 3)
	eq(fake.requests.size(), n)
	ls.list.settle()
	eq(ls.list.pull, 0.0)


# ---------------------------------------------------------------- States

func test_loading_empty_offline_and_signed_out_states() -> void:
	await _env(true, false)
	var s := _screens()
	fake.hold = true
	var ls := _open(s)
	eq(ls.state_title.text, LeaderboardsScreen.TEXT_LOADING, "loading")
	check(not ls.retry_button.visible)
	fake.release()
	await tree.process_frame
	eq(ls.state_title.text, LeaderboardsScreen.TEXT_EMPTY, "an empty board")
	_tap(ls.views[2])
	eq(ls.state_title.text, LeaderboardsScreen.TEXT_EMPTY_FRIENDS)
	_tap(ls.views[1])
	eq(ls.state_title.text, LeaderboardsScreen.TEXT_EMPTY_AROUND)
	_tap(ls.tabs[1])
	_tap(ls.views[2])
	eq(ls.state_title.text, LeaderboardsScreen.TEXT_CREW_FRIENDS, "the crew board has no friends view")
	# Offline with nothing cached: OFFLINE and RETRY; RETRY once back.
	_tap(ls.views[0])
	_tap(ls.tabs[4])
	fake.offline = true
	_tap(ls.tabs[3])
	eq(ls.state_title.text, LeaderboardsScreen.TEXT_OFFLINE)
	eq(ls.state_note.text, LeaderboardsScreen.NOTE_OFFLINE)
	check(ls.retry_button.visible, "RETRY")
	fake.offline = false
	fake.put_entry(NetBoards.DAILY, fake.today(), session.account_id(), 5000)
	_tap(ls.retry_button)
	check(ls.state_title.text.is_empty(), "rows after RETRY")
	eq(ls.list.count(), 1)
	# Offline with a cached page: the rows stay, the status says OFFLINE.
	fake.offline = true
	ls.fetch(true)
	eq(ls.list.count(), 1, "the cached rows stay")
	eq(ls.status.text, LeaderboardsScreen.TEXT_OFFLINE)


func test_report_and_block_from_a_row() -> void:
	await _env()
	var s := _screens()
	var ls := _open(s)
	var e := ls.page.entries[2]
	var row := ls.list.row_of(2)
	_tap(row)
	eq(ls.list.selected, 2, "a tap selects the row")
	check(row.selected, "drawn selected")
	for b: ScreenButton in [ls.report_cheat_button, ls.report_name_button, ls.block_button, ls.cancel_button]:
		check(b.visible, "%s shows" % b.text)
		ge(b.size.y, hud.touch_target_px)
	check(not ls.views[0].visible, "in place of the views")
	_tap(ls.report_cheat_button)
	if eq(fake.reports.size(), 1):
		eq(fake.reports[0]["target"], e.account_id)
		eq(fake.reports[0]["reason"], "cheating")
		eq(fake.reports[0]["context"], {"source": "leaderboard", "board": "journey", "period": WEEK, "run_id": e.run_id})
	eq(ls.status.text, LeaderboardsScreen.TEXT_REPORTED)
	check(ls.views[0].visible and ls.list.selected == -1, "back to the views")
	_tap(ls.list.row_of(3))
	_tap(ls.report_name_button)
	eq(fake.reports[-1]["reason"], "offensive_name")
	_tap(ls.list.row_of(4))
	_tap(ls.block_button)
	eq(ls.block_button.text, LeaderboardsScreen.TEXT_BLOCK_CONFIRM, "a second tap confirms")
	eq(fake.blocks_made.size(), 0)
	_tap(ls.block_button)
	if eq(fake.blocks_made.size(), 1):
		eq(fake.blocks_made[0]["target"], ls.page.entries[4].account_id)
	eq(ls.status.text, LeaderboardsScreen.TEXT_BLOCKED)
	_tap(ls.list.row_of(1))
	_tap(ls.cancel_button)
	check(ls.list.selected == -1 and ls.views[0].visible, "CANCEL")
	# My own row takes no actions.
	ls.list.center_on(ls.list.my_index())
	_tap(ls.list.row_of(ls.list.my_index()))
	eq(ls.list.selected, -1, "not on my own row")
	# A refused report says so.
	fake.script(HTTPClient.METHOD_POST, NetBoards.PATH_REPORTS, 429,
			{"error": "rate_limited", "message": "x", "retry_after_secs": 3600}, PackedStringArray(["Retry-After: 3600"]))
	ls.list.scroll = 0.0
	ls.list._layout()
	_tap(ls.list.row_of(2))
	_tap(ls.report_cheat_button)
	eq(ls.status.text, LeaderboardsScreen.TEXT_ACTION_LIMIT)


# ---------------------------------------------------------------- Results

func _results_payload(score: int = 1_284_500) -> Dictionary:
	var st := RunStats.new(0.0)
	st.distance_m = 14_380.0
	st.duration_s = 512.3
	st.legs_completed = 4
	st.best_chain = 186_400
	st.best_multiplier = 24.6
	st.passes = 212
	st.close_passes = 58
	st.threads = 7
	st.cuts = 34
	st.top_speed_mps = Units.kmh_to_mps(287.4)
	st.night_time_s = 96.0
	st.hits = 2
	var p := st.results(score, 20260929, RunContext.MODE_JOURNEY)
	p[&"personal_best"] = 2_010_000
	p[&"new_best"] = false
	p[&"previous_best"] = 2_010_000
	return p


func test_results_show_placements_when_they_arrive() -> void:
	await _env()
	var s := _screens()
	var rs := s.results_screen
	s.show_state(Game.RESULTS, Game.CRASH)
	fake.hold = true
	var payload := _results_payload()
	Events.run_over.emit(payload)
	check(rs.visible and rs.is_open(), "the results open at once")
	check(rs.online.visible, "the online line shows")
	eq(rs.online.line.text, ResultsOnline.TEXT_SENDING, "while the server works")
	fake.release()
	await tree.process_frame
	var sub := runs.submission_for(payload)
	check(sub != null and sub.is_done())
	var week_rank := NetRunSubmission.rank_of(sub.placement(NetBoards.JOURNEY, WEEK))
	var all_rank := NetRunSubmission.rank_of(sub.placement(NetBoards.JOURNEY, NetBoards.PERIOD_ALL))
	eq(rs.online.line.text, "#%s THIS WEEK  ·  #%s ALL TIME" % [HudFormat.thousands(week_rank), HudFormat.thousands(all_rank)])
	eq(rs.online.note.text, "#1 DISTANCE")
	check(rs.online.verifying_chip.visible, "VERIFYING (a personal best waits for its replay)")
	check(rs.online.pb_chip.visible, "NEW PB: the first all-time entry")
	lt(rs.online.modulate.a, 1.0, "it animates in")
	rs.finish_animations()
	eq(rs.online.modulate.a, 1.0)
	# LEADERBOARDS opens the run's board (after the tap guard).
	rs.accept_input_now()
	check(rs.boards_button.visible)
	_tap(rs.boards_button)
	if check(rs.leaderboards != null and rs.leaderboards.visible, "LEADERBOARDS from the results"):
		eq(rs.leaderboards.board, NetBoards.JOURNEY)
		check(not rs.retry_button.visible and not rs.online.visible, "the results step aside")
		_tap(rs.leaderboards.back_button)
		check(rs.retry_button.visible and rs.online.visible, "and come back")


func test_results_offline_and_update_required() -> void:
	await _env()
	var s := _screens()
	var rs := s.results_screen
	fake.offline = true
	var a := _results_payload()
	Events.run_over.emit(a)
	eq(rs.online.line.text, ResultsOnline.TEXT_OFFLINE, "OFFLINE — WILL SUBMIT")
	check(not rs.online.pb_chip.visible and not rs.online.verifying_chip.visible)
	fake.offline = false
	fake.min_build = tuning.client_build + 1
	runs.flush()
	await tree.process_frame
	eq(rs.online.line.text, ResultsOnline.TEXT_UPDATE, "UPDATE REQUIRED")
	eq(rs.online.note.text, ResultsOnline.NOTE_UPDATE)
	eq(rs.online.line.ink, ScreenText.Ink.HOT)
	# A new run replaces the line; a Loop practice run shows none.
	var loop := _results_payload()
	loop[RunStats.MODE] = &"loop"
	Events.run_over.emit(loop)
	check(not rs.online.visible, "no online line for Loop practice")


# ---------------------------------------------------------------- Text fit

func _configs() -> Array[Array]:
	var out: Array[Array] = []
	for size in CANVASES:
		var full := Rect2(Vector2.ZERO, size)
		var safe := full
		if size.x > CANVASES[0].x:
			safe = Rect2(Vector2(NOTCH.x, NOTCH.y), size - Vector2(NOTCH.x + NOTCH.z, NOTCH.y + NOTCH.w))
		for ts in hud.text_scales:
			for left: bool in [false, true]:
				out.append([full, safe, ts, left, "%dx%d text %d%% %s" % [size.x, size.y, roundi(ts * 100.0),
						"left" if left else "right"]])
	return out


func _capture(root: Node) -> void:
	_redraw(root)
	probe.clear()
	await tree.process_frame


func _redraw(n: Node) -> void:
	if n is CanvasItem:
		(n as CanvasItem).queue_redraw()
	for c in n.get_children():
		_redraw(c)


static func _inside(inner: Rect2, outer: Rect2) -> bool:
	return outer.grow(TOL).encloses(inner)


static func _overlap(a: Rect2, b: Rect2) -> bool:
	return a.grow(-TOL).intersects(b.grow(-TOL))


static func _container(ci: CanvasItem) -> Control:
	if ci is ScreenButton or ci is LeaderboardsRow:
		return ci as Control
	var n := ci.get_parent()
	while n != null and not (n is RunScreen):
		if n is ScreenButton or n is ScreenPanel:
			return n as Control
		n = n.get_parent()
	return null


static func _buttons(n: Node, out: Array[Control]) -> void:
	if n is ScreenButton and (n as ScreenButton).is_visible_in_tree():
		out.append(n as Control)
	for c in n.get_children():
		_buttons(c, out)


## Every visible text of `screen` fits: inside its own box, its panel, button or row,
## and the safe area; none overlap; none outside a button runs under one. Row texts are
## clipped to the list (partly scrolled rows are cut there).
func _check(screen: Control, safe: Rect2, what: String) -> int:
	var ids_: Array[int] = []
	var rects: Array[Rect2] = []
	for i in probe.size():
		var ci := probe.items[i]
		if not (is_instance_valid(ci) and ci.is_visible_in_tree() and screen.is_ancestor_of(ci)):
			continue
		var g := probe.global_rect(i)
		if ci is LeaderboardsRow:
			# Pooled rows are cut by the list's clip; the pinned row sits in the list.
			var parent := ci.get_parent() as Control
			var clip := parent.get_global_rect() if not (parent is LeaderboardsList) else (ci as Control).get_global_rect()
			if not clip.intersects(g):
				continue
			g = g.intersection(clip)
		ids_.append(i)
		rects.append(g)
	var buttons: Array[Control] = []
	_buttons(screen, buttons)
	for k in ids_.size():
		var i := ids_[k]
		var ci := probe.items[i] as Control
		var g := rects[k]
		if ci is ScreenText:
			check(_inside(probe.rects[i], Rect2(Vector2.ZERO, ci.size)),
					"%s: '%s' %s runs out of its box %s" % [what, probe.texts[i], probe.rects[i], ci.size])
		var box := _container(ci)
		if box != null:
			check(_inside(g, box.get_global_rect()),
					"%s: '%s' %s runs out of %s %s" % [what, probe.texts[i], g, box.name, box.get_global_rect()])
		else:
			for b in buttons:
				check(not _overlap(g, b.get_global_rect()), "%s: '%s' runs under %s" % [what, probe.texts[i], b.name])
		check(_inside(g, safe), "%s: '%s' %s outside the safe area" % [what, probe.texts[i], g])
	for a in ids_.size():
		for b in range(a + 1, ids_.size()):
			check(not _overlap(rects[a], rects[b]), "%s: '%s' overlaps '%s'" % [what, probe.texts[ids_[a]],
					probe.texts[ids_[b]]])
	# Buttons never overlap each other.
	for a in buttons.size():
		for b in range(a + 1, buttons.size()):
			check(not _overlap(buttons[a].get_global_rect(), buttons[b].get_global_rect()),
					"%s: %s overlaps %s" % [what, buttons[a].name, buttons[b].name])
	return ids_.size()


func test_text_fits_every_setting() -> void:
	await _env()
	fake.set_crew(session.account_id(), "3", "DUSK", "Dusk")
	for i in 3:
		fake.put_entry(NetBoards.DAILY, NetRunPayload.utc_date(NOW_S - 3.0 * 86400.0), ids[i], 88_888_888 - i)
	HudDraw.probe = probe
	var n := 0
	var k := 0
	for c in _configs():
		k += 1
		Settings.set_value(&"text_scale", float(c[2]))
		Settings.set_value(&"left_handed", bool(c[3]))
		var safe: Rect2 = c[1]
		LeaderboardsScreen.last_board = NetBoards.JOURNEY
		LeaderboardsScreen.last_view = NetBoards.VIEW_GLOBAL
		runs.boards.invalidate()
		var s := _screens(c[0], safe)
		var ls := _open(s)
		# The top 100 with the longest name, markers and the pinned row.
		await _capture(ls)
		n += _check(ls, safe, "%s global" % c[4])
		if k == 1:
			check(ls.list.pinned.visible, "%s: pinned row" % c[4])   # later runs put me at #1
		# A selected row with BLOCK asking for confirmation.
		_tap(ls.list.row_of(1))
		ls.block()
		await _capture(ls)
		n += _check(ls, safe, "%s actions" % c[4])
		check(ls.block_button.visible, "%s: the actions show" % c[4])
		ls.deselect()
		# Around me, pulled (the status line).
		ls.show_view(NetBoards.VIEW_AROUND_ME)
		ls.list.pull = tuning.boards_pull_refresh_px
		ls.list._set_pull_state()
		ls.list._layout()
		await _capture(ls)
		n += _check(ls, safe, "%s around me" % c[4])
		ls.list.settle()
		# Daily three days back (a date on the stepper), the widest scores.
		ls.show_view(NetBoards.VIEW_GLOBAL)
		ls.show_board(NetBoards.DAILY)
		for d in 3:
			ls.step_day(1)
		eq(ls.day_button.text, "SEP 26")
		await _capture(ls)
		n += _check(ls, safe, "%s daily" % c[4])
		# Offline (the state panel with RETRY).
		fake.offline = true
		ls.show_board(NetBoards.LOOP)
		await _capture(ls)
		n += _check(ls, safe, "%s offline" % c[4])
		eq(ls.state_title.text, LeaderboardsScreen.TEXT_OFFLINE)
		fake.offline = false
		ls.close_by_player()
		# Results with the online line (every chip) and LEADERBOARDS.
		s.show_state(Game.RESULTS, Game.CRASH)
		var big := _results_payload(88_888_000 + k)   # a new best every time: NEW PB shows
		big[RunStats.DISTANCE_M] = 888_800.0
		Events.run_over.emit(big)
		s.finish_animations()
		await _capture(s.results_screen)
		n += _check(s.results_screen, safe, "%s results" % c[4])
		check(s.results_screen.online.visible and s.results_screen.online.pb_chip.visible, "%s: placements" % c[4])
		fake.min_build = 99
		Events.run_over.emit(_results_payload())
		s.finish_animations()
		await _capture(s.results_screen)
		n += _check(s.results_screen, safe, "%s results update" % c[4])
		fake.min_build = 0
		_nodes.erase(s)
		s.free()
	gt(n, 0, "texts were recorded")
