class_name NetBoardPage
extends RefCounted
## One leaderboard read (`GET /api/v1/boards/{board}?period=&view=&limit=`) as typed
## data, or the reason it failed. Spec: multiplayer handoff → Leaderboards (boards,
## periods, views: global top 100, around me, friends; the legacy marker; "verifying");
## docs/SERVER.md → GET /boards. WP N7.2; docs/NET_CLIENT.md → Leaderboards.

## Where the page came from (the request), and what the server said it is.
var board: String = ""
## The period asked for ("current", "all", "2026-09-28", ...).
var period: String = ""
var view: String = ""
var ok: bool = false
## NetApiResult.error when not ok (network, offline, not_signed_in, invalid_period...).
var error: String = ""
## The period key the server resolved ("2026-W40", "all", ...), its kind and dates.
var period_key: String = ""
var period_kind: String = ""
var period_start: String = ""
var period_end: String = ""
var total: int = 0
var friends_available: bool = false
var generated_at: int = 0
var entries: Array[Entry] = []
## The caller's own entry (global rank), null when none or not signed in.
var me: Entry
## When it arrived (NetTimeSource microseconds).
var fetched_usec: int = 0


## One ranked row. On `loop_crew` the account fields are empty and the crew's are set.
class Entry:
	extends RefCounted
	var rank: int = 0
	var account_id: String = ""
	var crew_id: String = ""
	var display_name: String = ""
	var tag: int = 0
	var full_name: String = ""
	var crew_tag: String = ""
	var crew_name: String = ""
	var score: int = 0
	var verification: String = ""
	var verifying: bool = false
	var legacy: bool = false
	var run_id: String = ""
	var run_date: String = ""

	## A crew row (the Loop crew board).
	func is_crew() -> bool:
		return account_id.is_empty() and not crew_id.is_empty()

	## The row's name without the tag (a crew's name on the crew board).
	func name_text() -> String:
		if is_crew():
			return crew_name if not crew_name.is_empty() else crew_tag
		if not display_name.is_empty():
			return display_name
		var hash_at := full_name.rfind("#")
		return full_name.left(hash_at) if hash_at > 0 else full_name

	## "#0042" (players only).
	func tag_text() -> String:
		if is_crew():
			return ""
		if not display_name.is_empty():
			return NetProfile.TAG_FMT % tag
		var hash_at := full_name.rfind("#")
		return full_name.substr(hash_at) if hash_at > 0 else ""

	static func from_dict(d: Dictionary) -> Entry:
		var e := Entry.new()
		e.rank = NetBoardPage._int(d.get("rank", 0))
		e.account_id = NetApiResult.as_id(d.get("account_id"))
		e.crew_id = NetApiResult.as_id(d.get("crew_id"))
		e.display_name = NetBoardPage._str(d.get("display_name"))
		e.tag = NetBoardPage._int(d.get("tag", 0))
		e.full_name = NetBoardPage._str(d.get("full_name"))
		e.crew_tag = NetBoardPage._str(d.get("crew_tag"))
		e.crew_name = NetBoardPage._str(d.get("crew_name"))
		e.score = NetBoardPage._int(d.get("score", 0))
		e.verification = NetBoardPage._str(d.get("verification"))
		e.verifying = bool(d.get("verifying", false)) or e.verification == NetRunSubmission.VERIFICATION_PENDING
		e.legacy = bool(d.get("legacy", false)) or e.verification == "legacy"
		e.run_id = NetApiResult.as_id(d.get("run_id"))
		e.run_date = NetBoardPage._str(d.get("run_date"))
		return e


static func failed(board_id: String, period_id: String, view_id: String, code: String) -> NetBoardPage:
	var p := NetBoardPage.new()
	p.board = board_id
	p.period = period_id
	p.view = view_id
	p.error = code
	return p


static func from_body(board_id: String, period_id: String, view_id: String, body: Dictionary) -> NetBoardPage:
	var p := NetBoardPage.new()
	p.board = board_id
	p.period = period_id
	p.view = view_id
	p.ok = true
	p.period_key = _str(body.get("period"))
	p.period_kind = _str(body.get("period_kind"))
	p.period_start = _str(body.get("period_start"))
	p.period_end = _str(body.get("period_end"))
	p.total = _int(body.get("total", 0))
	p.friends_available = bool(body.get("friends_available", false))
	p.generated_at = _int(body.get("generated_at", 0))
	var list: Variant = body.get("entries", [])
	if list is Array:
		for d: Variant in list:
			if d is Dictionary:
				p.entries.append(Entry.from_dict(d as Dictionary))
	var me_d: Variant = body.get("me")
	if me_d is Dictionary:
		p.me = Entry.from_dict(me_d as Dictionary)
	return p


## The cache key of a request.
static func key_of(board_id: String, period_id: String, view_id: String) -> String:
	return "%s|%s|%s" % [board_id, period_id, view_id]


func key() -> String:
	return key_of(board, period, view)


## The index of the caller's row in `entries` (-1 when not listed). Players match by
## account id; on the crew board the caller's crew matches by crew id.
func my_index(my_account_id: String) -> int:
	for i in entries.size():
		if is_mine(entries[i], my_account_id):
			return i
	return -1


func is_mine(e: Entry, my_account_id: String) -> bool:
	if e.is_crew():
		return me != null and not me.crew_id.is_empty() and e.crew_id == me.crew_id
	if not my_account_id.is_empty() and e.account_id == my_account_id:
		return true
	return me != null and not me.account_id.is_empty() and e.account_id == me.account_id


static func _int(v: Variant) -> int:
	if v is int or v is float:
		return int(v)
	return 0


static func _str(v: Variant) -> String:
	return v if v is String else ""
