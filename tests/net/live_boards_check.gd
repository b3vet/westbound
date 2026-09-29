extends Node
## Manual live check of run submission, the offline queue, the legacy upload, the
## leaderboard reads and report / block against a running (local dev) server. Not part of
## the test tiers (no `test_` prefix). Spec: multiplayer handoff → Leaderboards;
## docs/SERVER.md → Leaderboards & runs API, Social API. WP N7.2; docs/NET_CLIENT.md →
## Runs client → Live check.
##
##   tools/godot.sh --headless --path . res://tests/net/live_boards_check.tscn -- \
##       http://127.0.0.1:18480 [--unsupported-build=N]
##
## A scene, not a `--script` main loop: it needs the autoloads (Events). No `--server=`:
## the game's own `Net` session stays off.
##
## Three throwaway device accounts (memory stores: nothing is written to user://), named
## so the boards read well. Each finishes a Journey run through Events.run_over; one also
## a Daily Drive run on today's seed. Then: a duplicate submission, a run queued while
## the network is down and sent later with the same key, the legacy upload (once), a
## friendship and a crew (crew tags on the entries), every view of the Journey board,
## report and block. `--unsupported-build=N` sends one run as build N (start the server
## with WB_RUNS__SUPPORTED_BUILDS set without it): UPDATE REQUIRED. Prints one line per
## step, never a token. Exit 0 when every step passes. Refuses the production server.

const PROD_HOST := "westbound.sipsakrandevu.com"
const DEAD_URL := "http://127.0.0.1:9/api/v1"
const NAMES: Array[String] = ["Road Runner", "Şahin 34", "Night Owl"]
const SCORES: Array[int] = [183_200, 240_600, 121_900]
const LEGACY_JOURNEY := 77_000
const DAILY_SCORE := 98_400
const TIMEOUT_MS := 10000

var _url := ""
var _unsupported := 0
var _fails := 0
var _t: NetTuning


class Driver:
	extends RefCounted
	var session: NetSession
	var runs: NetRunsClient
	var name_text: String = ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--unsupported-build="):
			_unsupported = a.substr("--unsupported-build=".length()).to_int()
		else:
			_url = a
	if _url.is_empty():
		printerr("usage: live_boards_check.gd -- http://127.0.0.1:18480 [--unsupported-build=N]")
		get_tree().quit(2)
		return
	if _url.contains(PROD_HOST):
		printerr("live_boards_check: refusing the production server (use a local one)")
		get_tree().quit(2)
		return
	_t = NetTuning.load_default()
	_run()


func _run() -> void:
	await get_tree().process_frame
	var base := NetSession.normalize_server(_url, "")
	print("server %s" % base)
	var drivers: Array[Driver] = []
	for i in NAMES.size():
		var d := await _driver(base, {"journey": LEGACY_JOURNEY} if i == 0 else {})
		var r := await d.session.rename(NAMES[i])
		d.name_text = d.session.profile.full_name if d.session.profile != null else "?"
		_step("account %d" % (i + 1), d.session.is_online(), "%s %s" % [d.name_text, "" if r.ok else "(rename: %s)" % r.error])
		drivers.append(d)
	var a := drivers[0]
	var b := drivers[1]
	var c := drivers[2]
	# The legacy upload ran when A came online.
	_step("legacy upload", a.runs.legacy_done(), "journey %d as a legacy entry" % LEGACY_JOURNEY)
	var again: NetApiResult = await a.session.api.request(HTTPClient.METHOD_POST, NetRunsClient.PATH_LEGACY,
			{"entries": [{"board": "journey", "score": LEGACY_JOURNEY}]}, NetApi.AUTH)
	var status := ""
	if again.ok and again.data.get("results") is Array and not (again.data["results"] as Array).is_empty():
		status = String(((again.data["results"] as Array)[0] as Dictionary).get("status", ""))
	_step("legacy once", status == "already_uploaded", "a second upload: %s" % status)
	# Friends (A <-> B) and a crew for A: the friends view and crew tags.
	var fr: NetApiResult = await a.session.api.request(HTTPClient.METHOD_POST, "/friends/requests",
			{"full_name": b.name_text}, NetApi.AUTH)
	var acc: NetApiResult = await b.session.api.request(HTTPClient.METHOD_POST,
			"/friends/requests/%s/accept" % fr.str_field("request_id"), null, NetApi.AUTH)
	_step("friends", fr.ok and acc.ok, "%s + %s" % [a.name_text, b.name_text])
	var crew: NetApiResult = await a.session.api.request(HTTPClient.METHOD_POST, "/crews",
			{"name": "Night Riders", "tag": "NR"}, NetApi.AUTH)
	_step("crew", crew.ok or crew.error == "crew_name_taken" or crew.error == "already_in_crew",
			"NR %s" % ("created" if crew.ok else crew.error))
	# Runs through Events.run_over, one driver at a time (the others' clients step aside).
	for i in drivers.size():
		var sub := await _finish_run(drivers, i, _payload(RunContext.MODE_JOURNEY, SCORES[i], Rng.random_seed()))
		_step("run %d" % (i + 1), sub != null and sub.state == NetRunSubmission.State.DONE,
				_describe(sub))
	var today := NetRunPayload.utc_date(Time.get_unix_time_from_system())
	var daily_seed := NetRunPayload.daily_seed_of(today)
	var ds := await _finish_run(drivers, 1, _payload(RunContext.MODE_DAILY, DAILY_SCORE, daily_seed))
	_step("daily run", ds != null and ds.state == NetRunSubmission.State.DONE, _describe(ds))
	# A duplicate: the same body again.
	var body := NetRunPayload.build(a.runs.last.results, a.runs.last.key, a.runs.last.date, "falcon_gt", _t.client_build)
	var dup: NetApiResult = await a.session.api.request(HTTPClient.METHOD_POST, NetRunsClient.PATH_RUNS, body, NetApi.AUTH)
	_step("duplicate", dup.status == 200 and bool(dup.data.get("duplicate", false)) and dup.str_field("run_id") == a.runs.last.run_id,
			"200 duplicate: true, run %s" % dup.str_field("run_id"))
	# Offline: C's network is down at run end; the run is queued, then sent with its key.
	c.session.api.base_url = DEAD_URL
	var queued := await _finish_run(drivers, 2, _payload(RunContext.MODE_JOURNEY, SCORES[2] + 1000, Rng.random_seed()))
	var key := queued.key if queued != null else ""
	_step("offline queued", queued != null and queued.state == NetRunSubmission.State.QUEUED and c.runs.queued_count() == 1,
			"%s, key %s..." % [ResultsOnline._waiting_text(queued.waiting) if queued != null else "?", key.left(8)])
	c.session.api.base_url = base
	c.runs.flush()
	await _until(func() -> bool: return queued.state != NetRunSubmission.State.QUEUED and queued.state != NetRunSubmission.State.SENDING)
	_step("offline sent", queued.state == NetRunSubmission.State.DONE and queued.key == key and c.runs.queued_count() == 0,
			"same key, %s" % _describe(queued))
	if _unsupported > 0:
		var old_build := _t.client_build
		_t.client_build = _unsupported
		var u := await _finish_run(drivers, 0, _payload(RunContext.MODE_JOURNEY, SCORES[0], Rng.random_seed()))
		_t.client_build = old_build
		_step("unsupported build", u != null and u.update_required(), "%s: %s" % [ResultsOnline.TEXT_UPDATE, u.reason if u else "?"])
	# Board reads (the screen's requests).
	var boards := a.runs.boards
	for view in NetBoards.VIEWS:
		await boards.fetch(NetBoards.JOURNEY, NetBoards.PERIOD_CURRENT, view, true)
		var p := boards.cached(NetBoards.JOURNEY, NetBoards.PERIOD_CURRENT, view)
		var rows := PackedStringArray()
		if p != null:
			for e in p.entries:
				rows.append("#%d %s%s%s %s%s%s" % [e.rank, e.name_text(), e.tag_text(), " [%s]" % e.crew_tag if not e.crew_tag.is_empty() else "",
						HudFormat.thousands(e.score), " LEGACY" if e.legacy else "", " VERIFYING" if e.verifying else ""])
		_step("journey %s" % view, p != null and p.ok and not p.entries.is_empty(),
				"%s: %s" % [p.period_key if p != null else "?", ", ".join(rows)])
	await boards.fetch(NetBoards.JOURNEY, NetBoards.PERIOD_ALL, NetBoards.VIEW_GLOBAL, true)
	var all := boards.cached(NetBoards.JOURNEY, NetBoards.PERIOD_ALL, NetBoards.VIEW_GLOBAL)
	var legacy_seen := false
	if all != null:
		for e in all.entries:
			legacy_seen = legacy_seen or e.legacy
	_step("journey all time", all != null and all.ok, "%d entries, legacy marker %s" % [all.entries.size() if all else 0,
			"shown" if legacy_seen else "replaced by a better run"])
	for bd: String in [NetBoards.DAILY, NetBoards.DISTANCE, NetBoards.LOOP, NetBoards.LOOP_CREW]:
		await boards.fetch(bd, NetBoards.PERIOD_CURRENT, NetBoards.VIEW_GLOBAL, true)
		var p := boards.cached(bd, NetBoards.PERIOD_CURRENT, NetBoards.VIEW_GLOBAL)
		_step("%s" % bd, p != null and p.ok, "%s: %d entries" % [p.period_key if p != null else "?", p.entries.size() if p else 0])
	# Report and block C from A's board.
	var got: Array[NetApiResult] = []
	var on_action := func(_k: String, _id: String, r: NetApiResult) -> void: got.append(r)
	boards.action_done.connect(on_action)
	await boards.report(c.session.account_id(), NetBoards.REASON_CHEATING, NetBoards.JOURNEY, "current", "")
	_step("report", not got.is_empty() and got[-1].ok, "201 report %s" % (got[-1].str_field("report_id") if not got.is_empty() else "?"))
	await boards.block(c.session.account_id())
	_step("block", got.size() == 2 and got[-1].ok, "%s blocked" % c.name_text)
	boards.action_done.disconnect(on_action)
	for d in drivers:
		d.session.queue_free()
	print("LIVE_BOARDS %s (%d failed)" % ["ok" if _fails == 0 else "FAILED", _fails])
	get_tree().quit(0 if _fails == 0 else 1)


func _driver(base: String, bests: Dictionary) -> Driver:
	var d := Driver.new()
	d.session = NetSession.new()
	d.session.auto_start = false
	d.session.configure(NetHttpNode.new(d.session), NetSessionStore.new(), _t, null, base)
	get_tree().root.add_child(d.session)
	d.runs = NetRunsClient.new()
	d.runs.configure(d.session, NetSessionStore.new(), _t)
	d.runs.local_bests = func() -> Dictionary: return bests
	d.runs.car_of = func(_r: Dictionary) -> String: return "falcon_gt"
	d.session.add_child(d.runs)
	await d.session.start()
	await _until(func() -> bool: return d.runs.legacy_done() or bests.is_empty())
	return d


## Emits run_over with only driver `i`'s client listening, and waits for its answer.
func _finish_run(drivers: Array[Driver], i: int, payload: Dictionary) -> NetRunSubmission:
	for k in drivers.size():
		if k != i and Events.run_over.is_connected(drivers[k].runs.on_run_over):
			Events.run_over.disconnect(drivers[k].runs.on_run_over)
	if not Events.run_over.is_connected(drivers[i].runs.on_run_over):
		Events.run_over.connect(drivers[i].runs.on_run_over)
	Events.run_over.emit(payload)
	var sub := drivers[i].runs.submission_for(payload)
	if sub != null:
		await _until(func() -> bool: return sub.state != NetRunSubmission.State.SENDING)
	return sub


static func _payload(mode: StringName, score: int, run_seed: int) -> Dictionary:
	var st := RunStats.new(0.0)
	st.distance_m = 24_018.4
	st.duration_s = 512.3
	st.legs_completed = 6
	st.best_chain = 41_200
	st.best_multiplier = 23.5
	st.passes = 212
	st.close_passes = 61
	st.threads = 9
	st.cuts = 34
	st.top_speed_mps = Units.kmh_to_mps(287.1)
	st.night_time_s = 94.0
	st.hits = 1
	var p := st.results(score, run_seed, mode)
	p[&"personal_best"] = score
	p[&"new_best"] = true
	p[&"previous_best"] = 0
	return p


static func _describe(sub: NetRunSubmission) -> String:
	if sub == null:
		return "no submission"
	if sub.state != NetRunSubmission.State.DONE:
		return "%s %s %s" % [NetRunSubmission.State.keys()[sub.state], sub.error, sub.reason]
	var line := ResultsOnline.placement_text(sub, NetRunPayload.utc_date(Time.get_unix_time_from_system()))
	return "run %s %s: %s%s%s" % [sub.run_id, sub.verification, line,
			"  " + ResultsOnline.distance_text(sub) if not ResultsOnline.distance_text(sub).is_empty() else "",
			" NEW PB" if sub.new_pb() else ""]


func _until(cond: Callable) -> void:
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while not bool(cond.call()) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _step(what: String, ok: bool, detail: String) -> void:
	if not ok:
		_fails += 1
	print("%-18s %s  %s" % [what, "ok  " if ok else "FAIL", detail])
