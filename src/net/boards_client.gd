class_name NetBoards
extends RefCounted
## Leaderboard reads and the two moderation actions on an entry. Spec: multiplayer
## handoff → Leaderboards (boards, periods, views: global top 100, around me, friends),
## Rooms → Moderation (report and block); docs/SERVER.md → GET /boards, Social API →
## Blocks, Reports. WP N7.2; docs/NET_CLIENT.md → Leaderboards.
##
##   boards.page_ready.connect(show)
##   boards.fetch("journey", "current", "around_me")     # coroutine; page_ready fires
##   var p := boards.cached("journey", "current", "around_me")   # any age, or null
##
## Pages are kept in memory for `boards_cache_s`, and one request per board, period and
## view is out at a time. `global` works signed out (the token only adds `me`);
## `around_me` and `friends` need the session online, and answer `not_signed_in`
## otherwise without a request. Report and block go through the same session.

signal page_ready(page: NetBoardPage)
## kind: ACTION_REPORT or ACTION_BLOCK.
signal action_done(kind: String, account_id: String, result: NetApiResult)

const LOOP := "loop"
const LOOP_CREW := "loop_crew"
const JOURNEY := "journey"
const DAILY := "daily"
const DISTANCE := "distance"
## Screen order (the tabs).
const BOARDS: Array[String] = [LOOP, LOOP_CREW, JOURNEY, DAILY, DISTANCE]

const VIEW_GLOBAL := "global"
const VIEW_AROUND_ME := "around_me"
const VIEW_FRIENDS := "friends"
const VIEWS: Array[String] = [VIEW_GLOBAL, VIEW_AROUND_ME, VIEW_FRIENDS]

## The board's current default period (season, week, today), and all time.
const PERIOD_CURRENT := "current"
const PERIOD_ALL := "all"

const PATH_BOARDS := "/boards/"
const PATH_REPORTS := "/reports"
const PATH_BLOCKS := "/blocks"
const REASON_CHEATING := "cheating"
const REASON_NAME := "offensive_name"
const ACTION_REPORT := "report"
const ACTION_BLOCK := "block"
const CONTEXT_SOURCE := "leaderboard"
## Client-side codes (NetBoardPage.error).
const ERR_NOT_SIGNED_IN := "not_signed_in"
const ERR_NO_SESSION := "offline"

var session: NetSession
var tuning: NetTuning
var time: NetTimeSource
## Requests sent (tests, dev stats).
var loads_sent: int = 0

var _cache: Dictionary[String, NetBoardPage] = {}
var _inflight: Dictionary[String, bool] = {}


func _init(s: NetSession, t: NetTuning, clock: NetTimeSource = null) -> void:
	session = s
	tuning = t
	time = clock if clock != null else NetTimeSource.new()


## The periods a board keeps, first = its default (docs/SERVER.md → Boards and periods).
## Daily Drive's previous days are dates (`YYYY-MM-DD`), see the screen's stepper.
static func periods_of(board: String) -> Array[String]:
	match board:
		LOOP, JOURNEY:
			return [PERIOD_CURRENT, PERIOD_ALL]
	return [PERIOD_CURRENT]


## The request path: `/boards/{board}?period=&view=&limit=` (limit only where the view
## takes one: `global` and `around_me`).
static func path(board: String, period: String, view: String, limit: int) -> String:
	var q := "%s%s?period=%s&view=%s" % [PATH_BOARDS, board, period.uri_encode(), view]
	if limit > 0 and view != VIEW_FRIENDS:
		q += "&limit=%d" % limit
	return q


func limit_for(view: String) -> int:
	match view:
		VIEW_GLOBAL:
			return tuning.boards_global_limit
		VIEW_AROUND_ME:
			return tuning.boards_around_me_limit
	return 0


## The last page of this request (any age; failed pages are not kept), or null.
func cached(board: String, period: String, view: String) -> NetBoardPage:
	return _cache.get(NetBoardPage.key_of(board, period, view)) as NetBoardPage


func is_fresh(p: NetBoardPage) -> bool:
	return p != null and p.ok and time.now_usec() - p.fetched_usec < roundi(tuning.boards_cache_s * USEC_PER_S)


func is_loading(board: String, period: String, view: String) -> bool:
	return _inflight.has(NetBoardPage.key_of(board, period, view))


## Seconds since `p` arrived.
func age_s(p: NetBoardPage) -> float:
	return float(time.now_usec() - p.fetched_usec) / USEC_PER_S


## Reads a page (unless a fresh one is cached and not `force`) and emits page_ready with
## it, or with the failure. A coroutine: await it, or listen to page_ready.
func fetch(board: String, period: String, view: String, force: bool = false) -> void:
	var k := NetBoardPage.key_of(board, period, view)
	var have := cached(board, period, view)
	if not force and is_fresh(have):
		page_ready.emit(have)
		return
	if _inflight.has(k):
		return
	var p: NetBoardPage
	var online := session != null and session.is_online()
	if session == null or session.api == null:
		p = NetBoardPage.failed(board, period, view, ERR_NO_SESSION)
	elif view != VIEW_GLOBAL and not online:
		p = NetBoardPage.failed(board, period, view, ERR_NOT_SIGNED_IN)
	else:
		_inflight[k] = true
		loads_sent += 1
		var r: NetApiResult = await session.api.request(HTTPClient.METHOD_GET,
				path(board, period, view, limit_for(view)), null, NetApi.AUTH if online else 0)
		_inflight.erase(k)
		if r.ok:
			p = NetBoardPage.from_body(board, period, view, r.data)
		else:
			p = NetBoardPage.failed(board, period, view, r.error)
	p.fetched_usec = time.now_usec()
	if p.ok:
		_cache[k] = p
	page_ready.emit(p)


## Forgets cached pages (all, or one view's) so the next load asks the server.
func invalidate(view: String = "") -> void:
	if view.is_empty():
		_cache.clear()
		return
	for k: String in _cache.keys():
		if (_cache[k] as NetBoardPage).view == view:
			_cache.erase(k)


## POST /reports: `reason` is REASON_CHEATING or REASON_NAME; the context says which
## board entry it came from.
func report(account_id: String, reason: String, board: String, period: String, run_id: String) -> void:
	var r := NetApiResult.failure(0, ERR_NOT_SIGNED_IN)
	if session != null and session.is_online():
		var ctx := {"source": CONTEXT_SOURCE, "board": board, "period": period}
		if not run_id.is_empty():
			ctx["run_id"] = run_id
		r = await session.api.request(HTTPClient.METHOD_POST, PATH_REPORTS,
				{"target_account_id": account_id, "reason": reason, "context": ctx}, NetApi.AUTH)
	action_done.emit(ACTION_REPORT, account_id, r)


## POST /blocks. The friends view changes with it (the friendship goes), so it is
## dropped from the cache.
func block(account_id: String) -> void:
	var r := NetApiResult.failure(0, ERR_NOT_SIGNED_IN)
	if session != null and session.is_online():
		r = await session.api.request(HTTPClient.METHOD_POST, PATH_BLOCKS, {"account_id": account_id}, NetApi.AUTH)
		if r.ok:
			invalidate(VIEW_FRIENDS)
	action_done.emit(ACTION_BLOCK, account_id, r)


const USEC_PER_S := 1000000.0
