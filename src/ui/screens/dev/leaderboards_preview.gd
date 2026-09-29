extends Node
## Leaderboards and results-placements review scene (WP N7.2). Spec: multiplayer handoff →
## Leaderboards, Client changes → Leaderboards screen. docs/SCREENS.md → Leaderboards.
##
## The real run (src/run/run.tscn) with a NetSession and NetRunsClient of its own over
## the in-memory boards server (NetFakeBoards, seeded with a few hundred drivers): no
## network. `--server=http://127.0.0.1:18480` (a local dev server; see docs/NET_CLIENT.md
## → Runs client → Live check) uses the game's own wiring instead: the `Net` autoload
## signs in to that server and NetRunsClient.ensure() attaches to it, as in a release.
##
##   tools/snap.sh src/ui/screens/dev/leaderboards_preview.tscn --renderer=both --sweep=view:global,around_me
##   tools/snap.sh src/ui/screens/dev/leaderboards_preview.tscn --state=empty
##   tools/snap.sh src/ui/screens/dev/leaderboards_preview.tscn --screen=results --result=done
##
## snap_setup options: --screen=boards|results|pause (default boards; pause: the menu
## with its LEADERBOARDS button), --from=pause|results
## (boards; default pause), --board=loop|loop_crew|journey|daily|distance (default
## journey), --view=global|around_me|friends, --period=0|1, --days_back=N (daily),
## --state=normal|empty|offline|signin|loading, --select=N (row N selected: the report /
## block bar), --scroll=px, --pull=px, --result=done|pending|offline|update|sending
## (results), --hand, --text_scale, --units, --sky_t.

const RUN_SCENE := preload("res://src/run/run.tscn")
const SNAP_SEED := 20260929
const SKY_T := 0.3
## 2026-09-29 12:00 UTC (a Tuesday: ISO week 2026-W40).
const NOW_S := 1790683200.0
const DRIVERS := 240
const TOP_SCORE := 2_412_300
const STEP := 9_100
const MY_RANK := 57
const FRIENDS: Array[int] = [3, 21, 56, 90]
const CREWS: Array[String] = ["NR", "RDX", "DUSK", "W7"]
const FAKE_SCORE := 1_284_500
## A score a live server's plausibility checks take for the payload below.
const LIVE_SCORE := 356_400
const LIVE_TIMEOUT_MS := 10000
## The device's own best before the run (the results' comparison line).
const LOCAL_BEST := 2_010_000
const HALF_STEP := 4_550
const DAILY_TOP := 1_206_000
const DAILY_STEP := 3_000
const CREW_COUNT := 30
const CREW_TOP := 9_000_000
const CREW_STEP := 180_000

var run: Run
var fake := NetFakeBoards.new()
var session: NetSession
var runs: NetRunsClient
var me: String = ""
## `--server=` given: the game's own session and runs client on that server.
var live: bool = false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		live = live or a.begins_with(NetSession.SERVER_ARG)
	if not live:
		fake.now_s = NOW_S
		session = NetSession.new()
		session.auto_start = false
		session.configure(fake, NetSessionStore.new(), NetTuning.load_default(), null,
				"https://preview.invalid/api/v1", SNAP_SEED)
		session.unix_clock = func() -> float: return fake.now_s
		add_child(session)
		runs = NetRunsClient.new()
		runs.configure(session, NetSessionStore.new(), session.tuning)
		runs.local_bests = func() -> Dictionary: return {}
		runs.car_of = func(_r: Dictionary) -> String: return "falcon_gt"
		runs.unix_clock = func() -> float: return fake.now_s
		session.add_child(runs)
	run = RUN_SCENE.instantiate() as Run
	run.run_seed = SNAP_SEED
	run.record_best = false
	add_child(run)


## tools/snap.sh hook.
func snap_setup(args: Dictionary) -> void:
	Settings.reset_to_defaults()
	Settings.set_value(&"left_handed", String(args.get("hand", "right")) == "left")
	Settings.set_value(&"text_scale", float(args.get("text_scale", 1.0)))
	Settings.set_value(&"units", StringName(String(args.get("units", "kmh"))))
	var st := String(args.get("state", "normal"))
	var screen := String(args.get("screen", "boards"))
	var from := String(args.get("from", "pause"))
	if live:
		session = NetSession.current
		var deadline := Time.get_ticks_msec() + LIVE_TIMEOUT_MS
		while session != null and not session.is_online() and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
		runs = NetRunsClient.ensure()
		if runs == null:
			push_warning("leaderboards_preview: no online session for --server")
			return
	else:
		await session.start()
		me = session.account_id()
		_seed(st)
	me = session.account_id()
	run.screens.results_screen.bind_runs(runs)
	run.screens.pause_screen.runs = runs
	var paused := (screen == "boards" and from == "pause") or screen == "pause"
	run.snap_setup({"state": "paused" if paused else "results", "sky_t": float(args.get("sky_t", SKY_T)),
			"s": 900.0, "speed_kmh": 180.0})
	run.dev.controls.visible = false
	(run.get_node(^"DevHud") as CanvasLayer).visible = false
	var screens := run.screens
	if screen == "results" or from == "results":
		await _results(String(args.get("result", "done")))
	if screen == "boards":
		LeaderboardsScreen.last_board = String(args.get("board", NetBoards.JOURNEY))
		LeaderboardsScreen.last_view = String(args.get("view", NetBoards.VIEW_GLOBAL))
		if st == "offline":
			fake.offline = true
		elif st == "signin":
			await session.logout()
		elif st == "loading":
			fake.hold = true
		if paused:
			screens.pause_screen.open_leaderboards()
		else:
			screens.results_screen.accept_input_now()
			screens.results_screen.open_leaderboards()
		var ls: LeaderboardsScreen = screens.pause_screen.leaderboards if paused else screens.results_screen.leaderboards
		if args.has("period"):
			ls._on_period(int(args["period"]))
		if args.has("days_back"):
			ls.step_day(int(args["days_back"]))
		ls.finish_animations()
		if args.has("scroll"):
			ls.list.scroll = float(args["scroll"])
			ls.list.set_page(ls.page, me, true)
		if args.has("pull"):
			ls.list.pull = float(args["pull"])
			ls.list._set_pull_state()
			ls.list._layout()
		if live:
			await _until(func() -> bool: return not runs.boards.is_loading(ls.board, ls.period(), ls.view))
		if args.has("select"):
			ls._on_row_tapped(int(args["select"]))
		screens.finish_animations()
		await get_tree().process_frame
		print("snap: boards board=%s view=%s state=%s rows=%d shown=%d status='%s' title='%s'" % [ls.board, ls.view, st,
				ls.list.count(), ls.list.rows.size(), ls.status.text, ls.state_title.text])
		if st == "loading":
			fake.release()
		return
	screens.finish_animations()
	await get_tree().process_frame
	if screen == "pause":
		print("snap: pause leaderboards_button=%s" % screens.pause_screen.boards_button.visible)
		return
	var o := screens.results_screen.online
	print("snap: results online='%s' note='%s' pb=%s verifying=%s" % [o.line.text, o.note.text,
			o.pb_chip.visible, o.verifying_chip.visible])


## A few hundred drivers on every board, the preview player among them.
func _seed(st: String) -> void:
	if st == "empty":
		return
	var week := fake.current_period(NetBoards.JOURNEY)
	var ids := fake.seed_board(NetBoards.JOURNEY, week, DRIVERS, TOP_SCORE, STEP)
	for i in ids.size():
		var id := ids[i]
		if i % 5 == 1:
			fake.set_crew(id, "c%d" % (i % CREWS.size()), CREWS[i % CREWS.size()], "Crew")
		fake.put_entry(NetBoards.JOURNEY, NetBoards.PERIOD_ALL, id, TOP_SCORE * 2 - i * STEP, "legacy" if i % 7 == 3 else "unverified")
		fake.put_entry(NetBoards.DAILY, fake.today(), id, DAILY_TOP - i * DAILY_STEP, "pending" if i % 9 == 4 else "unverified")
		fake.put_entry(NetBoards.DISTANCE, NetBoards.PERIOD_ALL, id, 180_000 - i * 600)
		fake.put_entry(NetBoards.LOOP, fake.current_period(NetBoards.LOOP), id, TOP_SCORE - i * STEP)
	# Names that stress the row: Turkish letters, the longest names.
	(fake.accounts[ids[0]] as Dictionary)["name"] = "Şahin 34"
	(fake.accounts[ids[1]] as Dictionary)["name"] = "WWWWWWWWWWWWWWWW"
	(fake.accounts[ids[4]] as Dictionary)["name"] = "Işıl Güneş"
	var entries: Array = fake.entries_of(NetBoards.JOURNEY, week)
	(entries[4] as Dictionary)["verification"] = "pending"
	fake.set_crew(me, "c0", CREWS[0], "Night Riders")
	fake.put_entry(NetBoards.JOURNEY, week, me, TOP_SCORE - (MY_RANK - 1) * STEP - HALF_STEP)
	fake.put_entry(NetBoards.JOURNEY, NetBoards.PERIOD_ALL, me, TOP_SCORE)
	for f in FRIENDS:
		fake.befriend(me, ids[f])
	var crews := fake.seed_board(NetBoards.LOOP_CREW, fake.current_period(NetBoards.LOOP_CREW), CREW_COUNT,
			CREW_TOP, CREW_STEP)
	print("snap: seeded %d drivers, %d crews" % [ids.size(), crews.size()])


## A finished Journey run through the client, then the results.
func _results(result: String) -> void:
	match result:
		"offline":
			fake.offline = true
		"update":
			fake.min_build = session.tuning.client_build + 1
		"sending":
			fake.hold = true
	var score := LIVE_SCORE if live else (FAKE_SCORE if result != "pending" else TOP_SCORE * 3)
	var payload := {
		RunStats.SCORE: score,
		RunStats.DISTANCE_M: 14_380.0,
		RunStats.LEGS_COMPLETED: 4,
		RunStats.COAST_REACHED: false,
		RunStats.BEST_CHAIN: 186_400,
		RunStats.BEST_MULTIPLIER: 24.6,
		RunStats.THREADS: 7,
		RunStats.CLOSE_PASSES: 58,
		RunStats.TOP_SPEED_KMH: 287.4,
		RunStats.NIGHT_TIME_S: 96.0,
		RunStats.HITS: 2,
		RunStats.SEED: SNAP_SEED if not live else Rng.random_seed(),
		RunStats.MODE: RunContext.MODE_JOURNEY,
		RunStats.PASSES: 212,
		RunStats.CUTS: 34,
		RunStats.DURATION_S: 512.3,
		RunStats.JOURNEY_COMPLETE: false,
		RunStats.JOURNEY_TIME_S: 0.0,
		RunStats.JOURNEY_DISTANCE_M: 0.0,
		&"personal_best": maxi(score, LOCAL_BEST),
		&"new_best": score > LOCAL_BEST,
		&"previous_best": LOCAL_BEST,
	}
	Events.run_over.emit(payload)   # "sending": held until the snap is taken
	await get_tree().process_frame
	if live and runs.last != null:
		var sub := runs.last
		await _until(func() -> bool: return sub.state != NetRunSubmission.State.SENDING)


func _until(cond: Callable) -> void:
	var deadline := Time.get_ticks_msec() + LIVE_TIMEOUT_MS
	while not bool(cond.call()) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
