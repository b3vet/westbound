class_name NetParty
extends RefCounted
## What the client knows about its party and the invites waiting for it. Spec:
## WESTBOUND_MULTIPLAYER_HANDOFF.md → Rooms, parties and matchmaking → Parties ("Up to 8
## players, led by one player. The leader invites online friends, or shares a party code.
## The party moves between rooms together"); docs/PROTOCOL.md §4 (`lobby_event.party_state`,
## `party_left`, `party_invite`), §12 (an invite is accepted with `party_join` and its code;
## declining needs no message); docs/SERVER.md → Parties (N9.3). WP N9.3.
##
## `party_state` replaces everything (code, leader, members in join order); `party_left`
## clears it. Invites are kept until accepted, declined or `party_invite_show_s` old.

## One member, as `party_state` lists it (Identity).
class Member:
	var account_id: String = ""
	var display_name: String = ""
	var name_tag: int = 0

	func full_name() -> String:
		return "%s#%04d" % [display_name, name_tag]


## One invite waiting for an answer.
class Invite:
	var code: String = ""
	var from_account: String = ""
	var from_name: String = ""
	var at_s: float = 0.0


var code: String = ""
var leader: String = ""
var members: Array[Member] = []
## This client's account (from Welcome), "" before the first Welcome.
var me: String = ""
## Newest first.
var invites: Array[Invite] = []
## Bumped whenever the party or the invites change (screens redraw on a new value).
var version: int = 0


func in_party() -> bool:
	return not code.is_empty()


## More than one member: the party moves together (and a member's Quick Join follows the
## leader).
func is_group() -> bool:
	return members.size() > 1


func is_leader() -> bool:
	return in_party() and not me.is_empty() and leader == me


func member(account_id: String) -> Member:
	for m in members:
		if m.account_id == account_id:
			return m
	return null


func leader_name() -> String:
	var m := member(leader)
	return m.full_name() if m != null else ""


## `lobby_event.party_state` (vector JSON). Drops an invite to this party.
func apply_state(msg: Dictionary) -> void:
	code = String(msg.get("code", ""))
	leader = String(msg.get("leader", ""))
	members.clear()
	for m: Dictionary in msg.get("members", []):
		var r := Member.new()
		r.account_id = String(m.get("account_id", ""))
		r.display_name = String(m.get("display_name", ""))
		r.name_tag = int(m.get("name_tag", 0))
		members.append(r)
	drop_invite(code)
	version += 1


## Out of the party (`party_left`, or the connection gone for good).
func clear() -> void:
	if code.is_empty() and members.is_empty():
		return
	code = ""
	leader = ""
	members.clear()
	version += 1


## `lobby_event.party_invite`: kept newest first, one per code, at most `max_kept`.
func add_invite(msg: Dictionary, now_s: float, max_kept: int) -> Invite:
	var from: Dictionary = msg.get("from", {})
	var inv := Invite.new()
	inv.code = String(msg.get("code", ""))
	inv.from_account = String(from.get("account_id", ""))
	inv.from_name = "%s#%04d" % [String(from.get("display_name", "")), int(from.get("name_tag", 0))]
	inv.at_s = now_s
	drop_invite(inv.code)
	invites.push_front(inv)
	while invites.size() > maxi(max_kept, 1):
		invites.pop_back()
	version += 1
	return inv


func drop_invite(invite_code: String) -> void:
	for i in invites.size():
		if invites[i].code == invite_code:
			invites.remove_at(i)
			version += 1
			return


## Drops invites older than `max_age_s`.
func expire_invites(now_s: float, max_age_s: float) -> void:
	for i in range(invites.size() - 1, -1, -1):
		if now_s - invites[i].at_s > max_age_s:
			invites.remove_at(i)
			version += 1


func newest_invite() -> Invite:
	return invites[0] if not invites.is_empty() else null
