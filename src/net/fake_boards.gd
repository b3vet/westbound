class_name NetFakeBoards
extends NetFakeAccounts
## The in-memory Accounts API plus the leaderboard, runs and moderation routes, behind
## the NetHttpBackend interface: headless tests and the leaderboards preview, with no
## network. Mirrors docs/SERVER.md → Leaderboards & runs API (boards, periods, views,
## POST /runs with idempotency and `build_unsupported`, POST /runs/legacy once per
## board) and Social API (POST /reports, POST /blocks). Spec: multiplayer handoff →
## Leaderboards; Testing → Client. WP N7.2.
##
## It is a model, not the server: ranking (value, then the earlier run), one entry per
## player and period, a run needs a value above 0; the plausibility checks are only the
## build check. The body of POST /runs is checked field by field against the contract:
## an unknown or missing field, a wrong type, or an integer field written as `12.0` is a
## 400 `invalid_body`, as the server's serde would answer.
##
## Test hooks (besides NetFakeAccounts'): min_build, add_player(), seed_board(),
## befriend(), set_crew(), entries_of(), reports, blocks_made, runs_received.

const RUN_FIELDS_INT: Array[String] = ["score", "legs_completed", "best_chain", "passes", "close_passes",
		"threads", "cuts", "hits", "client_build"]
const RUN_FIELDS_FLOAT: Array[String] = ["distance_m", "duration_s", "best_multiplier", "top_speed_kmh",
		"night_time_s"]
const RUN_FIELDS_OPTIONAL: Array[String] = ["journey_time_s", "journey_distance_m"]
const RUN_FIELDS_BOOL: Array[String] = ["coast_reached"]
const RUN_FIELDS_OPTIONAL_BOOL: Array[String] = ["journey_complete"]
const RUN_FIELDS_STRING: Array[String] = ["idempotency_key", "mode", "seed", "date", "car"]
const REPORT_REASONS: Array[String] = ["cheating", "offensive_name", "offensive_crew", "harassment",
		"griefing", "other"]
const KEY_MIN := 8
const KEY_MAX := 64
const REPLAY_TOP_N := 100
const AROUND_ME_DEFAULT := 10
const AROUND_ME_MAX := 50
const GLOBAL_MAX := 100
const DAY_S := 86400
const ISO_THURSDAY := 4
const DAYS_PER_WEEK := 7

## Oldest accepted client build (`build_unsupported` below it).
var min_build: int = 0
## (board|period) -> Array of entry Dictionaries {subject, account_id, crew_id, score,
## achieved_at, run_id, verification, run_date}.
var boards: Dictionary = {}
## account -> PackedStringArray of accepted friends.
var friends: Dictionary = {}
## account -> {crew_id, tag, name}.
var crews: Dictionary = {}
var reports: Array[Dictionary] = []
var blocks_made: Array[Dictionary] = []
## Every POST /runs body that passed validation (parsed).
var runs_received: Array[Dictionary] = []
## Every raw POST /runs body text (valid or not).
var run_texts: PackedStringArray = PackedStringArray()

## account|idempotency key -> the stored receipt.
var _receipts: Dictionary = {}
## account|board -> true (legacy uploads).
var _legacy: Dictionary = {}
var _next_run: int = 900
var _next_report: int = 1


# ---------------------------------------------------------------- Test hooks

## A player with no device credentials (a board entry's owner). Returns its id.
func add_player(display_name: String, tag: int) -> String:
	var id := str(_next_id)
	_next_id += 1
	accounts[id] = {"secret": "", "name": display_name, "tag": tag, "created_at": int(now_s),
			"name_changed_at": int(now_s), "renamed": false, "banned_until": 0, "ver": 0}
	return id


## Puts an entry on `board` / `period_key` for `account` (replaced only by a higher score).
func put_entry(board: String, period_key: String, account: String, score: int, verification: String = "unverified") -> Dictionary:
	var list := entries_of(board, period_key)
	var subject := account
	var crew_id := ""
	if board == NetBoards.LOOP_CREW:
		crew_id = account
	for e: Dictionary in list:
		if e["subject"] == subject:
			if score > int(e["score"]):
				e["score"] = score
				e["achieved_at"] = int(now_s)
				e["verification"] = verification
				_sort(list)
			return e
	_next_run += 1
	var e := {"subject": subject, "account_id": "" if board == NetBoards.LOOP_CREW else account,
			"crew_id": crew_id, "score": score, "achieved_at": int(now_s) + list.size(),
			"run_id": str(_next_run), "verification": verification, "run_date": today()}
	list.append(e)
	_sort(list)
	return e


## `count` generated players on a board, scores from `top` down by `step`.
func seed_board(board: String, period_key: String, players: int, top: int, step: int) -> PackedStringArray:
	var ids := PackedStringArray()
	for i in players:
		var n := GENERATED_NAMES[i % GENERATED_NAMES.size()]
		var id := add_player("%s %d" % [n, i + 1], (i * 131 + 7) % TAGS)
		if board == NetBoards.LOOP_CREW:
			set_crew(id, id, "C%d" % (i + 1), "Crew %d" % (i + 1))
		put_entry(board, period_key, id, maxi(1, top - i * step))
		ids.append(id)
	return ids


func befriend(a: String, b: String) -> void:
	for pair: Array in [[a, b], [b, a]]:
		var l: PackedStringArray = friends.get(pair[0], PackedStringArray())
		if not l.has(pair[1]):
			l.append(pair[1])
		friends[pair[0]] = l


func set_crew(account: String, crew_id: String, tag: String, crew_name: String) -> void:
	crews[account] = {"crew_id": crew_id, "tag": tag, "name": crew_name}


func entries_of(board: String, period_key: String) -> Array:
	var k := "%s|%s" % [board, period_key]
	if not boards.has(k):
		boards[k] = []
	return boards[k] as Array


## Today's UTC date on the fake's clock.
func today() -> String:
	return NetRunPayload.utc_date(now_s)


## The board's current period key on the fake's clock.
func current_period(board: String) -> String:
	match board:
		NetBoards.LOOP, NetBoards.LOOP_CREW:
			return today().left(7)
		NetBoards.JOURNEY:
			return iso_week(now_s)
		NetBoards.DAILY:
			return today()
	return NetBoards.PERIOD_ALL


## ISO 8601 week key (`2026-W40`) of unix seconds.
static func iso_week(unix_s: float) -> String:
	var d := Time.get_datetime_dict_from_unix_time(int(unix_s))
	var iso_wd := (int(d["weekday"]) + 6) % DAYS_PER_WEEK + 1
	var thursday := int(unix_s) + (ISO_THURSDAY - iso_wd) * DAY_S
	var td := Time.get_datetime_dict_from_unix_time(thursday)
	var jan1 := Time.get_unix_time_from_datetime_dict({"year": td["year"], "month": 1, "day": 1,
			"hour": 0, "minute": 0, "second": 0})
	@warning_ignore("integer_division")
	var week := (thursday - jan1) / DAY_S / DAYS_PER_WEEK + 1
	return "%04d-W%02d" % [td["year"], week]


# ---------------------------------------------------------------- Routes

func _route(method: int, path: String, auth: String, body: String) -> NetHttpResponse:
	var bare := path
	var query := ""
	var qi := path.find("?")
	if qi >= 0:
		bare = path.left(qi)
		query = path.substr(qi + 1)
	var post := method == HTTPClient.METHOD_POST
	if bare.begins_with(NetBoards.PATH_BOARDS) and method == HTTPClient.METHOD_GET:
		return _board(bare.substr(NetBoards.PATH_BOARDS.length()), query, auth)
	if post and bare == NetRunsClient.PATH_RUNS:
		run_texts.append(body)
		return _with_account(auth, _run.bind(body))
	if post and bare == NetRunsClient.PATH_LEGACY:
		return _with_account(auth, _legacy_upload.bind(body))
	if post and bare == NetBoards.PATH_REPORTS:
		return _with_account(auth, _report.bind(body))
	if post and bare == NetBoards.PATH_BLOCKS:
		return _with_account(auth, _block.bind(body))
	return super._route(method, path, auth, body)


func _with_account(auth: String, handler: Callable) -> NetHttpResponse:
	var who: Variant = _authed(auth, false)
	if who is NetHttpResponse:
		return who as NetHttpResponse
	return handler.call(String(who)) as NetHttpResponse


# ---------------------------------------------------------------- POST /runs

func _run(who: String, text: String) -> NetHttpResponse:
	var b := _json(text)
	if not _valid_run(b, text):
		return _err(400, "invalid_body")
	var key := String(b["idempotency_key"])
	var rk := "%s|%s" % [who, key]
	if _receipts.has(rk):
		var dup := (_receipts[rk] as Dictionary).duplicate(true)
		dup["duplicate"] = true
		return _ok(200, dup)
	runs_received.append(b)
	_next_run += 1
	var run_id := str(_next_run)
	var receipt := {"run_id": run_id, "verification": "unverified", "verifying": false, "reason": null,
			"replay_required": false, "duplicate": false, "placements": []}
	if int(b["client_build"]) < min_build:
		receipt["verification"] = "rejected"
		receipt["reason"] = "build_unsupported"
		_receipts[rk] = receipt
		return _ok(201, receipt)
	var mode := String(b["mode"])
	var score := int(b["score"])
	var metres := int(float(b["distance_m"]))
	var targets: Array[Array] = []
	if mode == NetBoards.JOURNEY:
		targets = [[NetBoards.JOURNEY, iso_week(now_s)], [NetBoards.JOURNEY, NetBoards.PERIOD_ALL],
				[NetBoards.DISTANCE, NetBoards.PERIOD_ALL]]
	else:
		targets = [[NetBoards.DAILY, String(b["date"])], [NetBoards.DISTANCE, NetBoards.PERIOD_ALL]]
	var replay := false
	var placements: Array[Dictionary] = []
	for t in targets:
		var board: String = t[0]
		var period: String = t[1]
		var value := metres if board == NetBoards.DISTANCE else score
		var list := entries_of(board, period)
		var prev: Variant = null
		for e: Dictionary in list:
			if e["subject"] == who:
				prev = int(e["score"])
		var improved := value > 0 and (prev == null or value > int(prev))
		if improved:
			var e := put_entry(board, period, who, value, "pending")
			e["run_id"] = run_id
		var rank := _rank_of(list, who)
		var pb := period == NetBoards.PERIOD_ALL or board == NetBoards.DAILY
		if improved and (rank <= REPLAY_TOP_N or pb):
			replay = true
		placements.append({"board": board, "period": period, "score": value, "rank": _opt(rank, rank > 0),
				"improved": improved, "previous_best": prev, "on_board": rank > 0})
	receipt["placements"] = placements
	receipt["replay_required"] = replay
	receipt["verification"] = "pending" if replay else "unverified"
	receipt["verifying"] = replay
	if not replay:
		for t in targets:
			for e: Dictionary in entries_of(t[0], t[1]):
				if e["run_id"] == run_id:
					e["verification"] = "unverified"
	_receipts[rk] = receipt
	return _ok(201, receipt)


## The contract's fields, exactly: no unknown or missing ones, right types, integers
## written as integers.
func _valid_run(b: Dictionary, text: String) -> bool:
	var known: Array[String] = []
	for group: Array[String] in [RUN_FIELDS_INT, RUN_FIELDS_FLOAT, RUN_FIELDS_OPTIONAL, RUN_FIELDS_BOOL,
			RUN_FIELDS_OPTIONAL_BOOL, RUN_FIELDS_STRING]:
		known.append_array(group)
	for k: Variant in b:
		if not known.has(String(k)):
			return false
	for k in RUN_FIELDS_STRING:
		if not (b.get(k) is String):
			return false
	var key := String(b["idempotency_key"])
	if key.length() < KEY_MIN or key.length() > KEY_MAX:
		return false
	if not (String(b["mode"]) in [NetBoards.JOURNEY, NetBoards.DAILY]) or not String(b["seed"]).is_valid_int():
		return false
	for k in RUN_FIELDS_INT:
		if not (b.get(k) is float) or float(b[k]) < 0.0 or not _int_literal(text, k):
			return false
	for k in RUN_FIELDS_FLOAT:
		if not (b.get(k) is float) or float(b[k]) < 0.0:
			return false
	for k in RUN_FIELDS_OPTIONAL:
		if b.has(k) and (not (b[k] is float) or float(b[k]) < 0.0):
			return false
	for k in RUN_FIELDS_BOOL:
		if not (b.get(k) is bool):
			return false
	for k in RUN_FIELDS_OPTIONAL_BOOL:
		if b.has(k) and not (b[k] is bool):
			return false
	return true


## `"key": 123` (not 123.0 or 1.2e2) in the raw JSON.
static func _int_literal(text: String, key: String) -> bool:
	var re := RegEx.create_from_string("\"%s\"\\s*:\\s*(-?[0-9]+)\\s*[,}]" % key)
	return re.search(text) != null


static func _rank_of(list: Array, subject: String) -> int:
	for i in list.size():
		if (list[i] as Dictionary)["subject"] == subject:
			return i + 1
	return 0


static func _sort(list: Array) -> void:
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["score"]) != int(b["score"]):
			return int(a["score"]) > int(b["score"])
		return int(a["achieved_at"]) < int(b["achieved_at"]))


# ---------------------------------------------------------------- POST /runs/legacy

func _legacy_upload(who: String, text: String) -> NetHttpResponse:
	var b := _json(text)
	var items: Variant = b.get("entries")
	if not (items is Array) or b.size() != 1:
		return _err(400, "invalid_body")
	var results: Array[Dictionary] = []
	var seen: Array[String] = []
	for it: Variant in items:
		if not (it is Dictionary):
			return _err(400, "invalid_body")
		var board := String((it as Dictionary).get("board", ""))
		var score: Variant = (it as Dictionary).get("score")
		if not (board in [NetBoards.JOURNEY, NetBoards.DISTANCE]) or seen.has(board) \
				or not (score is float) or float(score) < 1.0:
			return _err(400, "invalid_body")
		seen.append(board)
		var lk := "%s|%s" % [who, board]
		if _legacy.has(lk):
			results.append({"board": board, "status": "already_uploaded", "run_id": null, "placement": null})
			continue
		_legacy[lk] = true
		var e := put_entry(board, NetBoards.PERIOD_ALL, who, int(score), "legacy")
		var rank := _rank_of(entries_of(board, NetBoards.PERIOD_ALL), who)
		results.append({"board": board, "status": "accepted", "run_id": e["run_id"],
				"placement": {"board": board, "period": NetBoards.PERIOD_ALL, "score": int(score), "rank": rank,
				"improved": true, "previous_best": null, "on_board": true}})
	return _ok(200, {"results": results})


# ---------------------------------------------------------------- GET /boards

func _board(board: String, query: String, auth: String) -> NetHttpResponse:
	if not NetBoards.BOARDS.has(board):
		return _err(404, "unknown_board")
	var q := {}
	for part in query.split("&", false):
		var eq_at := part.find("=")
		var k := part.left(eq_at) if eq_at >= 0 else part
		if q.has(k) or not (k in ["period", "view", "limit"]):
			return _err(400, "invalid_query")
		q[k] = part.substr(eq_at + 1).uri_decode() if eq_at >= 0 else ""
	var view := String(q.get("view", NetBoards.VIEW_GLOBAL))
	if not NetBoards.VIEWS.has(view):
		return _err(400, "invalid_view")
	var period := String(q.get("period", NetBoards.PERIOD_CURRENT))
	if period == NetBoards.PERIOD_CURRENT:
		period = current_period(board)
	if not _period_ok(board, period):
		return _err(400, "invalid_period")
	var who := ""
	if not auth.is_empty() or view != NetBoards.VIEW_GLOBAL:
		var w: Variant = _authed(auth, false)
		if w is NetHttpResponse:
			return w as NetHttpResponse
		who = String(w)
	var list := entries_of(board, period)
	var subject := who
	if board == NetBoards.LOOP_CREW and crews.has(who):
		subject = String((crews[who] as Dictionary)["crew_id"])
	var limit := int(String(q.get("limit", "0"))) if q.has("limit") else 0
	var out: Array[Dictionary] = []
	var friends_ok := false
	match view:
		NetBoards.VIEW_GLOBAL:
			var n := mini(list.size(), limit if limit > 0 else GLOBAL_MAX)
			for i in n:
				out.append(_entry_json(board, list[i] as Dictionary, i + 1))
		NetBoards.VIEW_AROUND_ME:
			var side := clampi(limit if limit > 0 else AROUND_ME_DEFAULT, 1, AROUND_ME_MAX)
			var at := _rank_of(list, subject) - 1
			if at >= 0:
				var from := clampi(at - side, 0, maxi(0, list.size() - (2 * side + 1)))
				var to := mini(list.size(), from + 2 * side + 1)
				for i in range(from, to):
					out.append(_entry_json(board, list[i] as Dictionary, i + 1))
		NetBoards.VIEW_FRIENDS:
			if board != NetBoards.LOOP_CREW:
				friends_ok = true
				var mine: PackedStringArray = friends.get(who, PackedStringArray())
				var r := 0
				for e: Dictionary in list:
					if e["subject"] == who or mine.has(String(e["subject"])):
						r += 1
						out.append(_entry_json(board, e, r))
	var me: Variant = null
	var my_rank := _rank_of(list, subject)
	if not who.is_empty() and my_rank > 0:
		me = _entry_json(board, list[my_rank - 1] as Dictionary, my_rank)
	var kind := "all"
	var start: Variant = null
	var end: Variant = null
	if period != NetBoards.PERIOD_ALL:
		match board:
			NetBoards.JOURNEY:
				kind = "week"
			NetBoards.DAILY:
				kind = "day"
				start = period
				end = period
			_:
				kind = "season"
	return _ok(200, {"board": board, "period": period, "period_kind": kind, "period_start": start,
			"period_end": end, "view": view, "total": list.size(), "friends_available": friends_ok,
			"generated_at": int(now_s), "entries": out, "me": me})


func _period_ok(board: String, period: String) -> bool:
	match board:
		NetBoards.LOOP:
			return period == NetBoards.PERIOD_ALL or period.length() == "YYYY-MM".length()
		NetBoards.LOOP_CREW:
			return period.length() == "YYYY-MM".length()
		NetBoards.JOURNEY:
			return period == NetBoards.PERIOD_ALL or period.contains("-W")
		NetBoards.DAILY:
			return NetRunPayload.date_start(period) >= 0
	return period == NetBoards.PERIOD_ALL


func _entry_json(board: String, e: Dictionary, rank: int) -> Dictionary:
	var crew_board := board == NetBoards.LOOP_CREW
	var acc_id := String(e["account_id"])
	var acc: Dictionary = accounts.get(acc_id, {}) if not crew_board else {}
	var crew: Dictionary = {}
	if crew_board:
		for a: String in crews:
			if String((crews[a] as Dictionary)["crew_id"]) == String(e["crew_id"]):
				crew = crews[a]
	elif crews.has(acc_id):
		crew = crews[acc_id]
	var nm: Variant = acc.get("name") if not crew_board else null
	var tg: Variant = acc.get("tag") if not crew_board else null
	var verification := String(e["verification"])
	return {
		"rank": rank,
		"account_id": _opt(acc_id, not crew_board),
		"crew_id": _opt(String(e["crew_id"]), crew_board),
		"display_name": nm,
		"tag": tg,
		"full_name": _opt("%s#%04d" % [nm, int(tg)] if nm != null else "", nm != null),
		"crew_tag": crew.get("tag"),
		"crew_name": crew.get("name") if crew_board else null,
		"score": int(e["score"]),
		"verification": verification,
		"verifying": verification == "pending",
		"legacy": verification == "legacy",
		"run_id": e["run_id"],
		"run_date": e["run_date"],
		"achieved_at": e["achieved_at"],
	}


static func _opt(v: Variant, keep: bool) -> Variant:
	return v if keep else null


# ---------------------------------------------------------------- Social

func _report(who: String, text: String) -> NetHttpResponse:
	var b := _json(text)
	var target := String(b.get("target_account_id", ""))
	var reason := String(b.get("reason", ""))
	if not REPORT_REASONS.has(reason):
		return _err(400, "invalid_reason")
	if target == who:
		return _err(400, "cannot_report_self")
	if not accounts.has(target):
		return _err(404, "player_not_found")
	var id := str(_next_report)
	_next_report += 1
	reports.append({"reporter": who, "target": target, "reason": reason, "context": b.get("context")})
	return _ok(201, {"report_id": id})


func _block(who: String, text: String) -> NetHttpResponse:
	var b := _json(text)
	var target := String(b.get("account_id", ""))
	if target == who:
		return _err(400, "cannot_block_self")
	if not accounts.has(target):
		return _err(404, "player_not_found")
	blocks_made.append({"blocker": who, "target": target})
	for pair: Array in [[who, target], [target, who]]:
		var l: PackedStringArray = friends.get(pair[0], PackedStringArray())
		var i := l.find(String(pair[1]))
		if i >= 0:
			l.remove_at(i)
			friends[pair[0]] = l
	var acc: Dictionary = accounts[target]
	return _ok(201, {"account_id": target, "display_name": acc["name"], "tag": acc["tag"],
			"full_name": "%s#%04d" % [acc["name"], int(acc["tag"])], "crew_tag": null, "blocked_at": int(now_s)})
