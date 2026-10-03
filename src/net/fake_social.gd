class_name NetFakeSocial
extends NetFakeAccounts
## An in-memory Social API on top of NetFakeAccounts, for headless tests and the snap
## previews: friends and requests (caps, blocks answered as unknown players), blocks,
## GET /presence, crews with the role table, invite codes and succession, reports with a
## rolling daily limit, and the Loop crew board's "around me" entry. Mirrors
## docs/SERVER.md → Social API. Spec: multiplayer handoff → Friends and presence, Crews
## (persistent), Moderation → Report; Testing → Client. WP N9.2.
##
## Test hooks (besides NetFakeAccounts'):
##   add_player(name, tag) -> id       an account without a device (someone else)
##   befriend(a, b), add_request(from, to), block_pair(blocker, blocked)
##   set_presence(id, status, room_id, joinable)
##   make_crew(owner, name, tag) -> crew id, add_member(crew, id, role)
##   crew_scores[crew_id] = season score (the Loop crew board)
##   add_crew_invite(crew, to, from) -> invite id; crew_invites (each: id, crew, account,
##   inviter, created_at, expires_at); crew_invite_ttl_s, crew_max_pending_invites
##   reports (each: reporter, target, reason, context), caps (max_friends, ...)
## Profanity: NetFakeAccounts.blocked substrings also reject crew names and tags.

const CODE_ALPHABET := "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
const CODE_LEN := 8
const S_PER_DAY := 86400
const CREW_NAME_MIN := 3
const CREW_NAME_MAX := 24
const TAG_MIN := 2
const TAG_MAX := 4
const PERIOD := "2026-09"

var max_friends: int = 100
var max_outgoing_requests: int = 50
var max_incoming_requests: int = 100
var max_blocks: int = 500
var crew_max_members: int = 16
var reports_per_day: int = 10
var crew_invite_ttl_s: int = 7 * S_PER_DAY
var crew_max_pending_invites: int = 32

## {id, a, b, requester, status ("pending"/"accepted"), created_at, accepted_at}
var friendships: Array[Dictionary] = []
## "blocker>blocked" -> created_at
var block_rows: Dictionary = {}
## account id -> {status, room_id, joinable}
var presence: Dictionary = {}
## crew id -> {name, tag, owner, code, created_at}
var crews: Dictionary = {}
## account id -> {crew, role, joined_at}
var crew_members: Dictionary = {}
## crew id -> Loop crew season score (0 / absent: not on the board)
var crew_scores: Dictionary = {}
var reports: Array[Dictionary] = []
## Crew invites (docs/SERVER.md → Crew invites): {id, crew, account, inviter, created_at,
## expires_at}.
var crew_invites: Array[Dictionary] = []

var _next_request: int = 1
var _next_crew: int = 1
var _next_report: int = 1
var _next_invite: int = 1
var _code_serial: int = 0


# ---------------------------------------------------------------- Test hooks

## An account nobody signs in to (the other side of a friendship).
func add_player(display_name: String, tag: int) -> String:
	var id := str(_next_id)
	_next_id += 1
	accounts[id] = {"secret": "other-%s" % id, "name": display_name, "tag": tag,
			"created_at": int(now_s), "name_changed_at": int(now_s), "renamed": false,
			"banned_until": 0, "ver": 0}
	return id


func befriend(a: String, b: String) -> String:
	var row := _new_row(a, b, a)
	row["status"] = "accepted"
	row["accepted_at"] = int(now_s)
	return str(row["id"])


## A pending request from `from` to `to`; returns its id.
func add_request(from: String, to: String) -> String:
	return str(_new_row(from, to, from)["id"])


func block_pair(blocker: String, blocked_id: String) -> void:
	block_rows["%s>%s" % [blocker, blocked_id]] = int(now_s)
	var row := _row_between(blocker, blocked_id)
	if not row.is_empty():
		friendships.erase(row)


func set_presence(id: String, status: String, room_id: int = 0, joinable: bool = false) -> void:
	presence[id] = {"status": status, "room_id": room_id, "joinable": joinable}


func make_crew(owner: String, crew_name: String, crew_tag: String) -> String:
	var id := str(_next_crew)
	_next_crew += 1
	crews[id] = {"name": crew_name, "tag": crew_tag.to_upper(), "owner": owner,
			"code": _new_code(), "created_at": int(now_s)}
	crew_members[owner] = {"crew": id, "role": "owner", "joined_at": int(now_s)}
	return id


func add_member(crew_id: String, id: String, role: String = "member") -> void:
	now_s += 1.0
	crew_members[id] = {"crew": crew_id, "role": role, "joined_at": int(now_s)}


## A crew invite from `from` to `to` (no checks); its id.
func add_crew_invite(crew_id: String, to: String, from: String) -> String:
	var id := str(_next_invite)
	_next_invite += 1
	for row in crew_invites:
		if row["crew"] == crew_id and row["account"] == to:
			crew_invites.erase(row)
			break
	crew_invites.append({"id": id, "crew": crew_id, "account": to, "inviter": from,
			"created_at": int(now_s), "expires_at": int(now_s) + crew_invite_ttl_s})
	return id


func full_name_of(id: String) -> String:
	var acc: Dictionary = accounts[id]
	return "%s#%04d" % [acc["name"], acc["tag"]]


# ---------------------------------------------------------------- Routing

func _route(method: int, path: String, auth: String, body: String) -> NetHttpResponse:
	var q := path.find("?")
	var query := path.substr(q + 1) if q >= 0 else ""
	var p := path.left(q) if q >= 0 else path
	if not _social_path(p):
		return super._route(method, path, auth, body)
	var who: Variant = _authed(auth, false)
	if who is NetHttpResponse:
		return who as NetHttpResponse
	var me := String(who)
	var b := NetFakeAccounts._json(body)
	var parts := p.trim_prefix("/").split("/")
	var is_get := method == HTTPClient.METHOD_GET
	var post := method == HTTPClient.METHOD_POST
	var is_delete := method == HTTPClient.METHOD_DELETE
	match parts[0]:
		"friends":
			if parts.size() == 1 and is_get:
				return _ok(200, _friends_list(me))
			if parts.size() == 2 and parts[1] == "requests" and post:
				return _send_request(me, b)
			if parts.size() == 4 and parts[1] == "requests" and post and parts[3] == "accept":
				return _accept(me, parts[2])
			if parts.size() == 4 and parts[1] == "requests" and post and parts[3] == "decline":
				return _decline(me, parts[2])
			if parts.size() == 2 and is_delete:
				return _unfriend(me, parts[1])
		"presence":
			if is_get:
				return _ok(200, {"friends": _presence_list(me)})
		"blocks":
			if parts.size() == 1 and is_get:
				return _ok(200, {"blocks": _block_list(me), "max_blocks": max_blocks})
			if parts.size() == 1 and post:
				return _block(me, b)
			if parts.size() == 2 and is_delete:
				return _unblock(me, parts[1])
		"crews":
			return _crews(me, method, parts, b)
		"reports":
			if post:
				return _report(me, b)
		"boards":
			if is_get:
				return _crew_board(me, query)
	return _err(405 if parts.size() > 0 else 404, "method_not_allowed")


static func _social_path(p: String) -> bool:
	for prefix: String in ["/friends", "/presence", "/blocks", "/crews", "/reports", "/boards/loop_crew"]:
		if p == prefix or p.begins_with(prefix + "/"):
			return true
	return false


# ---------------------------------------------------------------- Friends

func _send_request(me: String, b: Dictionary) -> NetHttpResponse:
	var v: Variant = b.get("full_name")
	if not (v is String):
		return _err(400, "invalid_body")
	var code := (v as String).strip_edges()
	var hash_at := code.rfind("#")
	if hash_at <= 0 or not code.substr(hash_at + 1).is_valid_int() or code.substr(hash_at + 1).length() > 4:
		return _err(400, "invalid_full_name")
	var target := _find_account(code.left(hash_at).strip_edges(), code.substr(hash_at + 1).to_int())
	if target == me:
		return _err(400, "cannot_friend_self")
	if target.is_empty() or _blocked_either(me, target):
		return _err(404, "player_not_found")
	var row := _row_between(me, target)
	if not row.is_empty():
		if row["status"] == "accepted":
			return _err(409, "already_friends")
		if row["requester"] == me:
			return _err(409, "request_exists")
		return _accept(me, str(row["id"]))
	if _count(me, "accepted") >= max_friends:
		return _err(409, "friends_limit")
	if _count(target, "accepted") >= max_friends:
		return _err(409, "target_friends_limit")
	if _pending_from(me) >= max_outgoing_requests:
		return _err(409, "requests_limit")
	if _pending_to(target) >= max_incoming_requests:
		return _err(409, "target_requests_limit")
	var nr := _new_row(me, target, me)
	return _ok(201, {"request_id": str(nr["id"]), "status": "pending", "player": _player(target)})


func _accept(me: String, request_id: String) -> NetHttpResponse:
	var row := _row_by_id(request_id)
	if row.is_empty() or row["status"] != "pending" or row["requester"] == me \
			or (row["a"] != me and row["b"] != me):
		return _err(404, "request_not_found")
	var other := _other(row, me)
	if _count(me, "accepted") >= max_friends:
		return _err(409, "friends_limit")
	if _count(other, "accepted") >= max_friends:
		return _err(409, "target_friends_limit")
	row["status"] = "accepted"
	row["accepted_at"] = int(now_s)
	return _ok(200, {"request_id": str(row["id"]), "status": "accepted", "player": _player(other)})


func _decline(me: String, request_id: String) -> NetHttpResponse:
	var row := _row_by_id(request_id)
	if row.is_empty() or row["status"] != "pending" or (row["a"] != me and row["b"] != me):
		return _err(404, "request_not_found")
	friendships.erase(row)
	return NetHttpResponse.make(204)


func _unfriend(me: String, other: String) -> NetHttpResponse:
	var row := _row_between(me, other)
	if row.is_empty():
		return _err(404, "friend_not_found")
	friendships.erase(row)
	return NetHttpResponse.make(204)


func _friends_list(me: String) -> Dictionary:
	var fr: Array[Dictionary] = []
	var inc: Array[Dictionary] = []
	var out: Array[Dictionary] = []
	for row in friendships:
		if row["a"] != me and row["b"] != me:
			continue
		var other := _other(row, me)
		var e := _player(other)
		e["request_id"] = str(row["id"])
		e["created_at"] = row["created_at"]
		e["since"] = row["accepted_at"] if row["status"] == "accepted" else null
		var pr := _presence_of(other) if row["status"] == "accepted" else _presence_off()
		for k: String in pr:
			e[k] = pr[k]
		if row["status"] == "accepted":
			fr.append(e)
		elif row["requester"] == me:
			out.push_front(e)
		else:
			inc.push_front(e)
	fr.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		var rx := _status_rank(String(x["status"]))
		var ry := _status_rank(String(y["status"]))
		if rx != ry:
			return rx < ry
		return String(x["display_name"]).to_lower() < String(y["display_name"]).to_lower())
	return {"friends": fr, "incoming": inc, "outgoing": out, "max_friends": max_friends}


func _presence_list(me: String) -> Array[Dictionary]:
	var ids: Array[int] = []
	for row in friendships:
		if row["status"] == "accepted" and (row["a"] == me or row["b"] == me):
			ids.append(int(_other(row, me)))
	ids.sort()
	var out: Array[Dictionary] = []
	for id in ids:
		var e := _presence_of(str(id))
		e["account_id"] = str(id)
		out.append(e)
	return out


func _presence_of(id: String) -> Dictionary:
	if not presence.has(id):
		return _presence_off()
	var p: Dictionary = presence[id]
	var in_room := String(p["status"]) == "in_room"
	return {"status": p["status"], "room_id": p["room_id"] if in_room else null,
			"joinable": bool(p["joinable"]) and in_room}


static func _presence_off() -> Dictionary:
	return {"status": "offline", "room_id": null, "joinable": false}


static func _status_rank(s: String) -> int:
	match s:
		"in_room":
			return 0
		"online":
			return 1
	return 2


# ---------------------------------------------------------------- Blocks

func _block(me: String, b: Dictionary) -> NetHttpResponse:
	var v: Variant = b.get("account_id")
	if not (v is String):
		return _err(400, "invalid_body")
	var target := String(v)
	if target == me:
		return _err(400, "cannot_block_self")
	if not accounts.has(target):
		return _err(404, "player_not_found")
	var key := "%s>%s" % [me, target]
	if block_rows.has(key):
		return _ok(200, _block_entry(target, int(block_rows[key])))
	var mine := 0
	for k: String in block_rows:
		if k.begins_with(me + ">"):
			mine += 1
	if mine >= max_blocks:
		return _err(409, "blocks_limit")
	block_pair(me, target)
	return _ok(201, _block_entry(target, int(block_rows[key])))


func _unblock(me: String, target: String) -> NetHttpResponse:
	var key := "%s>%s" % [me, target]
	if not block_rows.has(key):
		return _err(404, "block_not_found")
	block_rows.erase(key)
	return NetHttpResponse.make(204)


func _block_list(me: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for k: String in block_rows:
		if k.begins_with(me + ">"):
			var target := k.substr(me.length() + 1)
			if accounts.has(target):
				out.push_front(_block_entry(target, int(block_rows[k])))
	return out


func _block_entry(target: String, at: int) -> Dictionary:
	var e := _player(target)
	e["blocked_at"] = at
	return e


func _blocked_either(a: String, b: String) -> bool:
	return block_rows.has("%s>%s" % [a, b]) or block_rows.has("%s>%s" % [b, a])


# ---------------------------------------------------------------- Crews

func _crews(me: String, method: int, parts: PackedStringArray, b: Dictionary) -> NetHttpResponse:
	var post := method == HTTPClient.METHOD_POST
	if parts.size() == 1 and post:
		return _create_crew(me, b)
	if parts.size() == 2 and parts[1] == "mine" and method == HTTPClient.METHOD_GET:
		if not crew_members.has(me):
			return _err(404, "not_in_crew")
		return _ok(200, _crew_view(String((crew_members[me] as Dictionary)["crew"]), me))
	if parts.size() == 2 and parts[1] == "join" and post:
		return _join_crew(me, b)
	if parts.size() >= 2 and parts[1] == "invites":
		return _my_invites(me, method, parts)
	if parts.size() < 2:
		return _err(404, "not_found")
	var crew_id := parts[1]
	if parts.size() == 2 and method == HTTPClient.METHOD_GET:
		if not crews.has(crew_id):
			return _err(404, "crew_not_found")
		return _ok(200, _crew_view(crew_id, me))
	var mem: Dictionary = crew_members.get(me, {})
	if mem.is_empty() or mem["crew"] != crew_id:
		return _err(404, "not_in_crew")
	var role := String(mem["role"])
	if parts.size() == 2 and method == HTTPClient.METHOD_DELETE:
		if role != "owner":
			return _err(403, "not_permitted")
		_disband(crew_id)
		return NetHttpResponse.make(204)
	if parts.size() == 3 and parts[2] == "invites":
		if method == HTTPClient.METHOD_GET:
			return _ok(200, {"invites": _sent_invites(crew_id)})
		if post:
			return _invite(me, crew_id, b)
	if parts.size() != 3 or not post:
		return _err(404, "not_found")
	match parts[2]:
		"leave":
			return _ok(200, _leave(me, crew_id))
		"invite-code":
			if role != "owner" and role != "officer":
				return _err(403, "not_permitted")
			(crews[crew_id] as Dictionary)["code"] = _new_code()
			return _ok(200, _crew_view(crew_id, me))
		"kick", "promote", "demote", "transfer":
			return _member_action(me, role, crew_id, parts[2], b)
	return _err(404, "not_found")


func _create_crew(me: String, b: Dictionary) -> NetHttpResponse:
	var n: Variant = b.get("name")
	var t: Variant = b.get("tag")
	if not (n is String) or not (t is String):
		return _err(400, "invalid_body")
	var crew_name := (n as String).strip_edges()
	var tag := (t as String).strip_edges().to_upper()
	if not _valid_crew_name(crew_name):
		return _err(400, "invalid_crew_name")
	if _profane(crew_name):
		return _err(400, "crew_name_not_allowed")
	if tag.length() < TAG_MIN or tag.length() > TAG_MAX or not _alnum(tag):
		return _err(400, "invalid_crew_tag")
	if _profane(tag):
		return _err(400, "crew_tag_not_allowed")
	for c: String in crews:
		var cr: Dictionary = crews[c]
		if String(cr["name"]).to_lower() == crew_name.to_lower():
			return _err(409, "crew_name_taken")
		if String(cr["tag"]) == tag:
			return _err(409, "crew_tag_taken")
	if crew_members.has(me):
		return _err(409, "already_in_crew")
	var id := make_crew(me, crew_name, tag)
	return _ok(201, _crew_view(id, me))


func _join_crew(me: String, b: Dictionary) -> NetHttpResponse:
	var v: Variant = b.get("invite_code")
	if not (v is String):
		return _err(400, "invalid_body")
	var code := (v as String).strip_edges().to_upper()
	var found := ""
	for c: String in crews:
		if (crews[c] as Dictionary)["code"] == code:
			found = c
	if found.is_empty():
		return _err(404, "invalid_invite_code")
	if crew_members.has(me):
		return _err(409, "already_in_crew")
	if _members_of(found).size() >= crew_max_members:
		return _err(409, "crew_full")
	add_member(found, me)
	_drop_invites(found, me)
	return _ok(200, _crew_view(found, me))


# ---------------------------------------------------------------- Crew invites

func _live_invite(row: Dictionary) -> bool:
	return int(row["expires_at"]) > int(now_s) and not _blocked_either(String(row["account"]),
			String(row["inviter"]))


func _invite(me: String, crew_id: String, b: Dictionary) -> NetHttpResponse:
	var v: Variant = b.get("account_id")
	if not (v is String):
		return _err(400, "invalid_body")
	var target := String(v)
	if target == me:
		return _err(400, "cannot_invite_self")
	if not accounts.has(target):
		return _err(404, "player_not_found")
	var row := _row_between(me, target)
	if row.is_empty() or row["status"] != "accepted" or _blocked_either(me, target):
		return _err(403, "not_friends")
	var tm: Dictionary = crew_members.get(target, {})
	if not tm.is_empty() and tm["crew"] == crew_id:
		return _err(409, "already_member")
	if _members_of(crew_id).size() >= crew_max_members:
		return _err(409, "crew_full")
	var renewed := false
	var pending := 0
	for r in crew_invites:
		if r["crew"] != crew_id or int(r["expires_at"]) <= int(now_s):
			continue
		if r["account"] == target:
			renewed = true
		else:
			pending += 1
	if pending >= crew_max_pending_invites:
		return _err(409, "crew_invites_limit")
	var id := add_crew_invite(crew_id, target, me)
	var inv := crew_invites[crew_invites.size() - 1]
	return _ok(200 if renewed else 201, {"invite_id": id, "player": _player(target), "from": _player(me),
			"created_at": inv["created_at"], "expires_at": inv["expires_at"]})


func _sent_invites(crew_id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for r in crew_invites:
		if r["crew"] == crew_id and int(r["expires_at"]) > int(now_s) and accounts.has(r["account"]):
			out.append({"invite_id": r["id"], "player": _player(String(r["account"])),
					"from": _player_or_null(String(r["inviter"])),
					"created_at": r["created_at"], "expires_at": r["expires_at"]})
	return out


func _my_invites(me: String, method: int, parts: PackedStringArray) -> NetHttpResponse:
	if parts.size() == 2 and method == HTTPClient.METHOD_GET:
		var out: Array[Dictionary] = []
		for i in range(crew_invites.size() - 1, -1, -1):
			var r := crew_invites[i]
			if r["account"] != me or not _live_invite(r) or not crews.has(r["crew"]):
				continue
			var cr: Dictionary = crews[r["crew"]]
			out.append({"invite_id": r["id"], "crew_id": r["crew"], "crew_name": cr["name"],
					"crew_tag": cr["tag"], "member_count": _members_of(String(r["crew"])).size(),
					"max_members": crew_max_members,
					"from": _player_or_null(String(r["inviter"])),
					"created_at": r["created_at"], "expires_at": r["expires_at"]})
		return _ok(200, {"invites": out})
	if parts.size() != 4 or method != HTTPClient.METHOD_POST:
		return _err(404, "not_found")
	var row := {}
	for r in crew_invites:
		if r["id"] == parts[2] and r["account"] == me:
			row = r
	match parts[3]:
		"decline":
			if row.is_empty():
				return _err(404, "invite_not_found")
			crew_invites.erase(row)
			return NetHttpResponse.make(204)
		"accept":
			if row.is_empty() or not _live_invite(row) or not crews.has(row["crew"]):
				return _err(404, "invite_not_found")
			var crew_id := String(row["crew"])
			if crew_members.has(me):
				if (crew_members[me] as Dictionary)["crew"] == crew_id:
					crew_invites.erase(row)
					return _ok(200, _crew_view(crew_id, me))
				return _err(409, "already_in_crew")
			if _members_of(crew_id).size() >= crew_max_members:
				return _err(409, "crew_full")
			add_member(crew_id, me)
			_drop_invites(crew_id, me)
			return _ok(200, _crew_view(crew_id, me))
	return _err(404, "not_found")


func _drop_invites(crew_id: String, account: String) -> void:
	for i in range(crew_invites.size() - 1, -1, -1):
		var r := crew_invites[i]
		if r["crew"] == crew_id and (account.is_empty() or r["account"] == account):
			crew_invites.remove_at(i)


func _leave(me: String, crew_id: String) -> Dictionary:
	var was_owner := String((crew_members[me] as Dictionary)["role"]) == "owner"
	crew_members.erase(me)
	var left := _members_of(crew_id)
	if left.is_empty():
		_disband(crew_id)
		return {"disbanded": true, "new_owner_id": null}
	if not was_owner:
		return {"disbanded": false, "new_owner_id": null}
	var heir := left[0]
	for id in left:
		if String((crew_members[id] as Dictionary)["role"]) == "officer":
			heir = id
			break
	(crew_members[heir] as Dictionary)["role"] = "owner"
	(crews[crew_id] as Dictionary)["owner"] = heir
	return {"disbanded": false, "new_owner_id": heir}


func _member_action(me: String, role: String, crew_id: String, action: String,
		b: Dictionary) -> NetHttpResponse:
	var v: Variant = b.get("account_id")
	if not (v is String):
		return _err(400, "invalid_body")
	var target := String(v)
	if target == me:
		match action:
			"kick":
				return _err(400, "cannot_kick_self")
			"transfer":
				return _err(400, "cannot_transfer_to_self")
		return _err(400, "cannot_change_own_role")
	var tm: Dictionary = crew_members.get(target, {})
	if tm.is_empty() or tm["crew"] != crew_id:
		return _err(404, "member_not_found")
	var allowed := NetCrew.allowed_actions(role, String(tm["role"]), false)
	if not allowed.has(StringName(action)):
		return _err(403, "not_permitted")
	match action:
		"kick":
			crew_members.erase(target)
		"promote":
			tm["role"] = "officer"
		"demote":
			tm["role"] = "member"
		"transfer":
			tm["role"] = "owner"
			(crew_members[me] as Dictionary)["role"] = "officer"
			(crews[crew_id] as Dictionary)["owner"] = target
	return _ok(200, _crew_view(crew_id, me))


func _disband(crew_id: String) -> void:
	_drop_invites(crew_id, "")
	for id in _members_of(crew_id):
		crew_members.erase(id)
	crews.erase(crew_id)
	crew_scores.erase(crew_id)


## Members by role (owner, officers, members), each by join time.
func _members_of(crew_id: String) -> Array[String]:
	var out: Array[String] = []
	for id: String in crew_members:
		if (crew_members[id] as Dictionary)["crew"] == crew_id:
			out.append(id)
	out.sort_custom(func(x: String, y: String) -> bool:
		var mx: Dictionary = crew_members[x]
		var my: Dictionary = crew_members[y]
		var rx := ["owner", "officer", "member"].find(mx["role"])
		var ry := ["owner", "officer", "member"].find(my["role"])
		if rx != ry:
			return rx < ry
		return int(mx["joined_at"]) < int(my["joined_at"]))
	return out


func _crew_view(crew_id: String, me: String) -> Dictionary:
	var cr: Dictionary = crews[crew_id]
	var ids := _members_of(crew_id)
	var members: Array[Dictionary] = []
	for id in ids:
		var m := _player(id)
		m.erase("crew_tag")
		m["role"] = (crew_members[id] as Dictionary)["role"]
		m["joined_at"] = (crew_members[id] as Dictionary)["joined_at"]
		members.append(m)
	var mine: Dictionary = crew_members.get(me, {})
	var member: bool = not mine.is_empty() and mine["crew"] == crew_id
	for m in members:
		# Presence for the viewer's own crew (room invites list online crewmates).
		m["status"] = _presence_of(String(m["account_id"]))["status"] if member else null
	return {"crew_id": crew_id, "name": cr["name"], "tag": cr["tag"], "owner_id": cr["owner"],
			"created_at": cr["created_at"], "member_count": ids.size(), "max_members": crew_max_members,
			"invite_code": cr["code"] if member else null, "your_role": mine["role"] if member else null,
			"members": members}


func _crew_board(me: String, query: String) -> NetHttpResponse:
	var out := {"board": "loop_crew", "period": PERIOD, "period_kind": "season", "view": "global",
			"total": crew_scores.size(), "friends_available": false, "generated_at": int(now_s),
			"entries": [], "me": null}
	if query.contains("view=around_me"):
		out["view"] = "around_me"
		var mine: Dictionary = crew_members.get(me, {})
		if not mine.is_empty() and int(crew_scores.get(mine["crew"], 0)) > 0:
			var crew_id := String(mine["crew"])
			var score := int(crew_scores[crew_id])
			var rank := 1
			for c: String in crew_scores:
				if int(crew_scores[c]) > score:
					rank += 1
			var cr: Dictionary = crews[crew_id]
			var e := {"rank": rank, "account_id": null, "crew_id": crew_id, "crew_tag": cr["tag"],
					"crew_name": cr["name"], "score": score}
			out["entries"] = [e]
			out["me"] = e
	return _ok(200, out)


# ---------------------------------------------------------------- Reports

func _report(me: String, b: Dictionary) -> NetHttpResponse:
	var target: Variant = b.get("target_account_id")
	var reason: Variant = b.get("reason")
	if not (target is String) or not (reason is String):
		return _err(400, "invalid_body")
	if not NetSocialClient.REPORT_REASONS.has(reason):
		return _err(400, "invalid_reason")
	var ctx: Variant = b.get("context")
	if ctx != null and not (ctx is Dictionary):
		return _err(400, "invalid_context")
	if target == me:
		return _err(400, "cannot_report_self")
	if not accounts.has(target):
		return _err(404, "player_not_found")
	var recent: Array[int] = []
	for r in reports:
		if r["reporter"] == me and int(r["at"]) > int(now_s) - S_PER_DAY:
			recent.append(int(r["at"]))
	if recent.size() >= reports_per_day:
		var e := _err_body("rate_limited")
		var oldest: int = int(recent.min()) if not recent.is_empty() else int(now_s)
		var retry_s: int = oldest + S_PER_DAY - int(now_s)
		e["retry_after_secs"] = retry_s
		return NetHttpResponse.make(429, JSON.stringify(e),
				PackedStringArray(["Content-Type: application/json", "Retry-After: %d" % retry_s]))
	reports.append({"id": _next_report, "reporter": me, "target": target, "reason": reason,
			"context": ctx, "at": int(now_s)})
	_next_report += 1
	return _ok(201, {"report_id": str(_next_report - 1)})


# ---------------------------------------------------------------- Helpers

func _player_or_null(id: String) -> Variant:
	if accounts.has(id):
		return _player(id)
	return null


func _player(id: String) -> Dictionary:
	var acc: Dictionary = accounts[id]
	var mem: Dictionary = crew_members.get(id, {})
	var crew_tag: Variant = null
	if not mem.is_empty() and crews.has(mem["crew"]):
		crew_tag = (crews[mem["crew"]] as Dictionary)["tag"]
	return {"account_id": id, "display_name": acc["name"], "tag": acc["tag"],
			"full_name": "%s#%04d" % [acc["name"], acc["tag"]], "crew_tag": crew_tag}


func _find_account(display_name: String, tag: int) -> String:
	for id: String in accounts:
		var acc: Dictionary = accounts[id]
		if String(acc["name"]).to_lower() == display_name.to_lower() and int(acc["tag"]) == tag:
			return id
	return ""


func _new_row(from: String, to: String, requester: String) -> Dictionary:
	now_s += 1.0
	var row := {"id": _next_request, "a": from, "b": to, "requester": requester, "status": "pending",
			"created_at": int(now_s), "accepted_at": null}
	_next_request += 1
	friendships.append(row)
	return row


func _row_between(a: String, b: String) -> Dictionary:
	for row in friendships:
		if (row["a"] == a and row["b"] == b) or (row["a"] == b and row["b"] == a):
			return row
	return {}


func _row_by_id(id: String) -> Dictionary:
	for row in friendships:
		if str(row["id"]) == id:
			return row
	return {}


static func _other(row: Dictionary, me: String) -> String:
	return String(row["b"]) if row["a"] == me else String(row["a"])


func _count(id: String, status: String) -> int:
	var n := 0
	for row in friendships:
		if row["status"] == status and (row["a"] == id or row["b"] == id):
			n += 1
	return n


func _pending_from(id: String) -> int:
	var n := 0
	for row in friendships:
		if row["status"] == "pending" and row["requester"] == id:
			n += 1
	return n


func _pending_to(id: String) -> int:
	var n := 0
	for row in friendships:
		if row["status"] == "pending" and row["requester"] != id and (row["a"] == id or row["b"] == id):
			n += 1
	return n


func _profane(s: String) -> bool:
	var l := s.to_lower()
	for w in blocked:
		if l.contains(w):
			return true
	return false


## The display-name character rules with the crew name's 3–24 length.
static func _valid_crew_name(n: String) -> bool:
	if n.length() < CREW_NAME_MIN or n.length() > CREW_NAME_MAX:
		return false
	var letter := false
	var prev_sep := false
	for i in n.length():
		var c := n[i]
		var is_letter := (c >= "A" and c <= "Z") or (c >= "a" and c <= "z") or EXTRA_LETTERS.contains(c)
		var is_sep := SEPARATORS.contains(c)
		if not (is_letter or (c >= "0" and c <= "9") or is_sep):
			return false
		if is_sep and (i == 0 or i == n.length() - 1 or prev_sep):
			return false
		letter = letter or is_letter
		prev_sep = is_sep
	return letter


static func _alnum(s: String) -> bool:
	for ch in s:
		if not ((ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9")):
			return false
	return true


func _new_code() -> String:
	_code_serial += 1
	var out := ""
	var x := _code_serial * 7919 + 17
	for i in CODE_LEN:
		out += CODE_ALPHABET[(x + i * 13) % CODE_ALPHABET.length()]
		x = (x * 31 + 7) % 100003
	return out
