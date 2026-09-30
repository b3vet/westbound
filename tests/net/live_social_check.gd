extends SceneTree
## Manual live check of NetSocialClient against a running server (not part of the test
## tiers: no `test_` prefix). Spec: multiplayer handoff → Friends and presence, Crews
## (persistent), Moderation → Report; docs/SERVER.md → Social API. WP N9.2;
## docs/NET_CLIENT.md → Social client → Live check.
##
##   tools/godot.sh --headless --path . --script res://tests/net/live_social_check.gd -- \
##       http://127.0.0.1:8080 [--keep]
##
## Two throwaway device accounts (memory stores, never the game's): A sends B a friend
## request by code, B accepts; both open the realtime gateway and A watches B come online
## and go offline over WebSocket presence (and B sees A by GET /presence); A creates a
## crew, B joins it by the invite code, A promotes and demotes B and rotates the code; A's
## legacy Journey best shows the crew tag on the board; B reports A; B blocks A (A's
## request then reads as an unknown player) and unblocks; both accounts are deleted
## (unless --keep). One line per step, never a token. Exit 0 when every step passes.
## Refuses the production server.

const PROD_HOST := "westbound.sipsakrandevu.com"
const MAP_HASH_BYTES := 32
const CLIENT_BUILD := 1
const WAIT_MS := 5000
const LEGACY_SCORE := 4321

var _url := ""
var _keep := false
var _fails := 0
var _t: NetTuning
var _clients: Array[NetClient] = []


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--keep":
			_keep = true
		else:
			_url = a
	if _url.is_empty():
		printerr("usage: live_social_check.gd -- http://127.0.0.1:8080 [--keep]")
		quit(2)
		return
	if _url.contains(PROD_HOST):
		printerr("live_social_check: refusing the production server (use a local one)")
		quit(2)
		return
	_t = NetTuning.load_default()
	_run()


func _run() -> void:
	await process_frame   # the root enters the tree after _initialize
	var base := NetSession.normalize_server(_url, "")
	print("server %s" % base)
	var sa := await _account(base)
	var sb := await _account(base)
	_step("accounts", sa.is_online() and sb.is_online(), "A %s, B %s" % [_who(sa), _who(sb)])
	var a := _social(sa)
	var b := _social(sb)
	# Friends.
	var r := await a.send_request(sb.profile.full_name)
	_step("request", r.ok and r.str_field("status") == "pending" and a.outgoing.size() == 1,
			"A -> %s: %s" % [sb.profile.full_name, r.str_field("status") if r.ok else r.error])
	r = await b.refresh_friends()
	var inc := b.incoming[0] if r.ok and b.incoming.size() == 1 else null
	_step("incoming", inc != null and inc.account_id == sa.account_id(), "B sees %s" % (inc.full_name if inc != null else "-"))
	r = await b.accept(inc.request_id if inc != null else "0")
	await a.refresh_friends()
	_step("accept", r.ok and b.friend(sa.account_id()) != null and a.friend(sb.account_id()) != null,
			"friends both ways")
	r = await a.send_request("Nobody Here#0001")
	_step("unknown code", r.error == "player_not_found", NetSocialClient.error_text(r))
	# Presence over the realtime gateway.
	var ca := await _connect(sa)
	a.attach_lobby(ca)
	await _pump(func() -> bool: return a.ws_presence_events > 0)
	_step("ws subscribe", a.ws_live() and a.ws_presence_events > 0,
			"snapshot: B %s" % a.friend(sb.account_id()).status)
	var cb := await _connect(sb)
	await _pump(func() -> bool: return a.friend(sb.account_id()).status == NetSocialPlayer.ONLINE)
	_step("ws online", a.friend(sb.account_id()).status == NetSocialPlayer.ONLINE,
			"A saw B come online (%d presence events)" % a.ws_presence_events)
	r = await b.refresh_presence()
	_step("poll presence", r.ok and b.friend(sa.account_id()).status == NetSocialPlayer.ONLINE,
			"B's GET /presence: A %s" % b.friend(sa.account_id()).status)
	cb.close()
	_clients.erase(cb)
	await _pump(func() -> bool: return a.friend(sb.account_id()).status == NetSocialPlayer.OFFLINE)
	_step("ws offline", a.friend(sb.account_id()).status == NetSocialPlayer.OFFLINE, "A saw B go offline")
	# Crews.
	var suffix := str(Time.get_ticks_usec() % 100000)
	var crew_name := "Live Crew %s" % suffix
	var tag := "L%s" % suffix.right(2)
	r = await a.create_crew(crew_name, tag)
	_step("create crew", r.ok and a.crew != null and a.crew.your_role == NetCrew.OWNER,
			"%s [%s] code %s" % [crew_name, tag, a.crew.invite_code if a.crew != null else "-"] if r.ok else r.error)
	r = await a.create_crew("Second Crew", "SC")
	_step("second crew refused", r.error == "already_in_crew", NetSocialClient.error_text(r))
	r = await b.join_crew("zzzz-zzzz")
	_step("bad invite code", r.error == "invalid_invite_code", NetSocialClient.error_text(r))
	r = await b.join_crew(a.crew.invite_code.to_lower() if a.crew != null else "")
	_step("join crew", r.ok and b.crew != null and b.crew.your_role == NetCrew.MEMBER and b.crew.members.size() == 2,
			"B is a member of %s" % (b.crew.name if b.crew != null else "-"))
	r = await b.kick(sa.account_id())
	_step("member can't kick", r.error == "not_permitted", NetSocialClient.error_text(r))
	r = await a.promote(sb.account_id())
	var promoted := r.ok and a.crew.member(sb.account_id()).role == NetCrew.OFFICER
	r = await a.demote(sb.account_id())
	_step("promote + demote", promoted and r.ok and a.crew.member(sb.account_id()).role == NetCrew.MEMBER, "")
	var old_code := a.crew.invite_code if a.crew != null else ""
	r = await a.rotate_invite_code()
	_step("rotate code", r.ok and a.crew.invite_code != old_code, "%s -> %s" % [old_code, a.crew.invite_code if r.ok else r.error])
	# The crew tag on a board: A's legacy Journey best.
	r = await sa.api.request(HTTPClient.METHOD_POST, "/runs/legacy",
			{"entries": [{"board": "journey", "score": LEGACY_SCORE}]}, NetApi.AUTH)
	var board := await sa.api.request(HTTPClient.METHOD_GET, "/boards/journey?period=all&view=global", null, NetApi.AUTH)
	var shown := ""
	if board.ok and board.data.get("entries") is Array:
		for e: Variant in board.data["entries"] as Array:
			if e is Dictionary and NetApiResult.as_id((e as Dictionary).get("account_id")) == sa.account_id():
				shown = str((e as Dictionary).get("crew_tag"))
	_step("crew tag on a board", r.ok and shown == tag, "journey/all: %s [%s]" % [_who(sa), shown])
	r = await a.refresh_standing()
	_step("season standing", r.ok and a.standing_loaded,
			"loop_crew %s: %s" % [a.standing_period, "#%d" % a.standing_rank if a.standing_rank > 0 else "not on the board yet"])
	# Report and block.
	r = await b.report(sa.account_id(), "other", {"source": "live_check"})
	_step("report", r.ok and not r.str_field("report_id").is_empty(), "report %s" % r.str_field("report_id"))
	r = await b.block(sa.account_id())
	var blocked := r.ok and b.friend(sa.account_id()) == null and b.blocks.size() == 1
	var again := await a.send_request(sb.profile.full_name)
	_step("block", blocked and again.error == "player_not_found",
			"A's request now reads: %s" % NetSocialClient.error_text(again))
	r = await b.unblock(sa.account_id())
	_step("unblock", r.ok and b.blocks.is_empty(), "")
	r = await b.leave_crew()
	_step("leave crew", r.ok and b.crew == null, "")
	for c in _clients:
		c.close()
	a.detach_lobby()
	if not _keep:
		var da := await sa.delete_account()
		var db := await sb.delete_account()
		_step("delete", da.ok and db.ok, "both accounts deleted")
	print("LIVE_SOCIAL %s (%d failed)" % ["ok" if _fails == 0 else "FAILED", _fails])
	quit(0 if _fails == 0 else 1)


func _account(base: String) -> NetSession:
	var s := NetSession.new()
	s.auto_start = false
	s.configure(NetHttpNode.new(get_root()), NetSessionStore.new(), _t, null, base)
	get_root().add_child(s)
	await s.start()
	return s


func _social(s: NetSession) -> NetSocialClient:
	var c := NetSocialClient.new(s.api, _t, s.time)
	c.session = s
	return c


func _connect(s: NetSession) -> NetClient:
	var client := NetClient.new(NetWsTransport.new(_t), _t)
	var zero_map := PackedByteArray()
	zero_map.resize(MAP_HASH_BYTES)
	client.start(s.ws_url(), CLIENT_BUILD, zero_map, await s.fresh_access_token())
	_clients.append(client)
	await _pump(func() -> bool: return client.get_state() == NetClient.State.READY \
			or client.get_state() == NetClient.State.FAILED)
	if client.get_state() != NetClient.State.READY:
		_step("ws hello", false, "%s: %s" % [client.failure_reason, client.failure_message])
	return client


## Polls every open connection each frame until `done` or the timeout.
func _pump(done: Callable) -> void:
	var deadline := Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline and not bool(done.call()):
		await process_frame
		for c in _clients:
			c.poll()


func _who(s: NetSession) -> String:
	return s.profile.full_name if s.profile != null else "?"


func _step(what: String, ok: bool, detail: String) -> void:
	if not ok:
		_fails += 1
	print("%-20s %s  %s" % [what, "ok  " if ok else "FAIL", detail])
