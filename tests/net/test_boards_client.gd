extends WBTest
## NetBoards against the in-memory boards server: the request paths for every board,
## period and view, auth only where a view needs it, the page parsed (entries, `me`,
## legacy and verifying markers, crew rows), the cache and forced refresh, and the
## report and block calls. Spec: multiplayer handoff → Leaderboards, Rooms → Moderation;
## docs/SERVER.md → GET /boards, POST /reports, POST /blocks. WP N7.2.

const BASE := "https://boards.test/api/v1"
const NOW_S := 1790683200.0

var tuning: NetTuning
var fake: NetFakeBoards
var time: NetVirtualTime
var session: NetSession
var boards: NetBoards
var pages: Array[NetBoardPage] = []
var actions: Array[Array] = []
var _nodes: Array[Node] = []


func before_all() -> void:
	tuning = NetTuning.load_default().duplicate() as NetTuning
	tuning.api_backoff_jitter = 0.0


func before_each() -> void:
	fake = NetFakeBoards.new()
	fake.now_s = NOW_S
	time = NetVirtualTime.new(1_000_000)
	pages.clear()
	actions.clear()


func after_each() -> void:
	boards = null   # its signals hold this test's lambdas
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	await tree.process_frame


func _setup(online: bool = true) -> void:
	session = NetSession.new()
	session.auto_start = false
	session.configure(fake, NetSessionStore.new(), tuning, time, BASE, 4)
	session.unix_clock = func() -> float: return fake.now_s
	tree.root.add_child(session)
	_nodes.append(session)
	if online:
		await session.start()
	boards = NetBoards.new(session, tuning, time)
	boards.page_ready.connect(func(p: NetBoardPage) -> void: pages.append(p))
	boards.action_done.connect(func(k: String, id: String, r: NetApiResult) -> void: actions.append([k, id, r]))


func _last_path() -> String:
	return String(fake.requests[-1]["path"])


func test_paths_for_every_board_period_and_view() -> void:
	eq(NetBoards.path("journey", "current", "global", 100), "/boards/journey?period=current&view=global&limit=100")
	eq(NetBoards.path("journey", "all", "around_me", 10), "/boards/journey?period=all&view=around_me&limit=10")
	eq(NetBoards.path("daily", "2026-09-27", "friends", 0), "/boards/daily?period=2026-09-27&view=friends")
	eq(NetBoards.path("loop", "all", "friends", 100), "/boards/loop?period=all&view=friends", "friends takes no limit")
	eq(NetBoards.periods_of(NetBoards.LOOP), [NetBoards.PERIOD_CURRENT, NetBoards.PERIOD_ALL] as Array[String])
	eq(NetBoards.periods_of(NetBoards.JOURNEY), [NetBoards.PERIOD_CURRENT, NetBoards.PERIOD_ALL] as Array[String])
	eq(NetBoards.periods_of(NetBoards.LOOP_CREW), [NetBoards.PERIOD_CURRENT] as Array[String], "season only")
	eq(NetBoards.periods_of(NetBoards.DAILY), [NetBoards.PERIOD_CURRENT] as Array[String], "today (dates by the stepper)")
	eq(NetBoards.periods_of(NetBoards.DISTANCE), [NetBoards.PERIOD_CURRENT] as Array[String], "all time only")
	await _setup()
	for b in NetBoards.BOARDS:
		for p in NetBoards.periods_of(b):
			for v in NetBoards.VIEWS:
				await boards.fetch(b, p, v)
				eq(_last_path(), NetBoards.path(b, p, v, boards.limit_for(v)), "%s %s %s" % [b, p, v])
				check(pages[-1].ok, "%s %s %s answered" % [b, p, v])
	eq(boards.limit_for(NetBoards.VIEW_GLOBAL), tuning.boards_global_limit)
	eq(boards.limit_for(NetBoards.VIEW_AROUND_ME), tuning.boards_around_me_limit)


func test_page_parsing_markers_and_me() -> void:
	await _setup()
	var week := fake.current_period(NetBoards.JOURNEY)
	eq(week, "2026-W40", "2026-09-29 is in ISO week 40")
	var ids := fake.seed_board(NetBoards.JOURNEY, week, 5, 5000, 1000)
	(fake.entries_of(NetBoards.JOURNEY, week)[1] as Dictionary)["verification"] = "pending"
	(fake.entries_of(NetBoards.JOURNEY, week)[2] as Dictionary)["verification"] = "legacy"
	fake.set_crew(ids[0], "7", "NR", "Night Riders")
	fake.put_entry(NetBoards.JOURNEY, week, session.account_id(), 3500)
	await boards.fetch(NetBoards.JOURNEY, NetBoards.PERIOD_CURRENT, NetBoards.VIEW_GLOBAL)
	var p := pages[-1]
	check(p.ok)
	eq(p.period_key, week)
	eq(p.period_kind, "week")
	eq(p.total, 6)
	eq(p.entries.size(), 6)
	eq(p.entries[0].rank, 1)
	eq(p.entries[0].crew_tag, "NR")
	eq(p.entries[0].tag_text(), "%s" % (NetProfile.TAG_FMT % p.entries[0].tag))
	check(p.entries[1].verifying and not p.entries[1].legacy, "pending: verifying")
	check(p.entries[3].legacy, "legacy marker (below my 3,500)")
	if check(p.me != null, "me with a token"):
		eq(p.me.rank, 3)
		eq(p.my_index(session.account_id()), 2)
	check(String(fake.requests[-1]["auth"]) != "", "the token adds me")
	# The crew board: crew rows.
	fake.seed_board(NetBoards.LOOP_CREW, fake.current_period(NetBoards.LOOP_CREW), 3, 900, 100)
	await boards.fetch(NetBoards.LOOP_CREW, NetBoards.PERIOD_CURRENT, NetBoards.VIEW_GLOBAL)
	var c := pages[-1]
	check(c.entries[0].is_crew(), "crew rows")
	eq(c.entries[0].name_text(), "Crew 1")
	eq(c.entries[0].tag_text(), "")


func test_signed_out_reads_global_only() -> void:
	await _setup(false)
	await boards.fetch(NetBoards.JOURNEY, NetBoards.PERIOD_CURRENT, NetBoards.VIEW_GLOBAL)
	check(pages[-1].ok, "global works signed out")
	eq(String(fake.requests[-1]["auth"]), "", "without a token")
	check(pages[-1].me == null)
	var sent := fake.requests.size()
	await boards.fetch(NetBoards.JOURNEY, NetBoards.PERIOD_CURRENT, NetBoards.VIEW_AROUND_ME)
	eq(pages[-1].error, NetBoards.ERR_NOT_SIGNED_IN)
	await boards.fetch(NetBoards.JOURNEY, NetBoards.PERIOD_CURRENT, NetBoards.VIEW_FRIENDS)
	eq(pages[-1].error, NetBoards.ERR_NOT_SIGNED_IN)
	eq(fake.requests.size(), sent, "no request without a session")
	fake.offline = true
	await boards.fetch(NetBoards.DISTANCE, NetBoards.PERIOD_CURRENT, NetBoards.VIEW_GLOBAL)
	eq(pages[-1].error, NetApiResult.NETWORK, "offline")
	check(boards.cached(NetBoards.DISTANCE, NetBoards.PERIOD_CURRENT, NetBoards.VIEW_GLOBAL) == null, "failures are not cached")


func test_cache_and_forced_refresh() -> void:
	await _setup()
	await boards.fetch(NetBoards.JOURNEY, NetBoards.PERIOD_ALL, NetBoards.VIEW_GLOBAL)
	var n := fake.requests.size()
	await boards.fetch(NetBoards.JOURNEY, NetBoards.PERIOD_ALL, NetBoards.VIEW_GLOBAL)
	eq(fake.requests.size(), n, "fresh: from memory")
	eq(pages.size(), 2, "still answered")
	await boards.fetch(NetBoards.JOURNEY, NetBoards.PERIOD_ALL, NetBoards.VIEW_GLOBAL, true)
	eq(fake.requests.size(), n + 1, "forced")
	time.advance_s(tuning.boards_cache_s)
	await boards.fetch(NetBoards.JOURNEY, NetBoards.PERIOD_ALL, NetBoards.VIEW_GLOBAL)
	eq(fake.requests.size(), n + 2, "stale: asked again")
	# One request at a time per page.
	fake.hold = true
	boards.fetch(NetBoards.DAILY, NetBoards.PERIOD_CURRENT, NetBoards.VIEW_GLOBAL, true)
	boards.fetch(NetBoards.DAILY, NetBoards.PERIOD_CURRENT, NetBoards.VIEW_GLOBAL, true)
	check(boards.is_loading(NetBoards.DAILY, NetBoards.PERIOD_CURRENT, NetBoards.VIEW_GLOBAL))
	fake.release()
	await tree.process_frame
	eq(fake.count("/boards/daily?period=current&view=global&limit=100"), 1, "single flight")


func test_report_and_block() -> void:
	await _setup()
	var ids := fake.seed_board(NetBoards.JOURNEY, NetBoards.PERIOD_ALL, 3, 900, 100)
	fake.befriend(session.account_id(), ids[1])
	await boards.fetch(NetBoards.JOURNEY, NetBoards.PERIOD_ALL, NetBoards.VIEW_FRIENDS)
	eq(pages[-1].entries.size(), 1, "one friend on the board")
	await boards.report(ids[0], NetBoards.REASON_CHEATING, NetBoards.JOURNEY, NetBoards.PERIOD_ALL, "901")
	var req := fake.requests[-1]
	eq(String(req["path"]), NetBoards.PATH_REPORTS)
	eq(JSON.parse_string(String(req["body"])), {"target_account_id": ids[0], "reason": "cheating",
			"context": {"source": "leaderboard", "board": "journey", "period": "all", "run_id": "901"}})
	eq(fake.reports.size(), 1)
	check(actions[-1][2].ok and actions[-1][0] == NetBoards.ACTION_REPORT, "reported")
	await boards.report(ids[2], NetBoards.REASON_NAME, NetBoards.JOURNEY, NetBoards.PERIOD_ALL, "")
	eq(String(fake.reports[-1]["reason"]), "offensive_name")
	check(not (fake.reports[-1]["context"] as Dictionary).has("run_id"), "no run id: left out")
	await boards.block(ids[1])
	eq(String(fake.requests[-1]["path"]), NetBoards.PATH_BLOCKS)
	eq(JSON.parse_string(String(fake.requests[-1]["body"])), {"account_id": ids[1]})
	check(actions[-1][2].ok and actions[-1][0] == NetBoards.ACTION_BLOCK, "blocked")
	check(boards.cached(NetBoards.JOURNEY, NetBoards.PERIOD_ALL, NetBoards.VIEW_FRIENDS) == null,
			"the friends view is read again after a block")
	await boards.fetch(NetBoards.JOURNEY, NetBoards.PERIOD_ALL, NetBoards.VIEW_FRIENDS)
	eq(pages[-1].entries.size(), 0, "the blocked friend is gone")
	# Errors come back as results.
	await boards.report(session.account_id(), NetBoards.REASON_CHEATING, NetBoards.JOURNEY, NetBoards.PERIOD_ALL, "")
	eq((actions[-1][2] as NetApiResult).error, "cannot_report_self")
