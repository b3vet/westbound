class_name NetCrew
extends RefCounted
## A persistent crew as `GET /crews/mine` returns it, and the role rules the crew screen
## follows. Spec: multiplayer handoff → Crews (persistent) (a named crew with a 2–4
## character tag, up to 16 members, joined by an invite code; an owner and officers can
## kick); docs/SERVER.md → Social API → Crews (the role table). WP N9.2;
## docs/NET_CLIENT.md → Social client.
##
## The server enforces every rule; `allowed_actions()` only decides which buttons show:
##
##   | Action                  | Owner | Officer | Member |
##   | Kick a member           | yes   | yes     | no     |
##   | Kick an officer         | yes   | no      | no     |
##   | Promote or demote       | yes   | no      | no     |
##   | Transfer ownership      | yes   | no      | no     |
##   | Rotate the invite code  | yes   | yes     | no     |
##   | Disband                 | yes   | no      | no     |
##
## Nobody kicks themselves or changes their own role.

## A crew invite waiting for this player (`GET /crews/invites`, or the live
## `lobby_event.crew_invite`): accepted with `POST /crews/invites/{id}/accept` (the
## join-by-code checks), declined with `/decline`. docs/SERVER.md → Crew invites.
class Invite:
	var invite_id: String = ""
	var crew_id: String = ""
	var crew_name: String = ""
	var crew_tag: String = ""
	## 0 when unknown (a live event carries no size).
	var member_count: int = 0
	var max_members: int = 0
	var from_account: String = ""
	## `name#1234` of the member who sent it ("" when unknown).
	var from_name: String = ""
	## Unix seconds (0 when unknown).
	var expires_at: int = 0

	## "Night Riders [NR]".
	func crew_text() -> String:
		return "%s [%s]" % [crew_name, crew_tag] if not crew_tag.is_empty() else crew_name

	## From the API's JSON (null without an invite id).
	static func from_dict(v: Variant) -> Invite:
		if not (v is Dictionary):
			return null
		var d: Dictionary = v
		var inv := Invite.new()
		inv.invite_id = NetApiResult.as_id(d.get("invite_id"))
		if inv.invite_id.is_empty():
			return null
		inv.crew_id = NetApiResult.as_id(d.get("crew_id"))
		inv.crew_name = NetSocialPlayer._str(d.get("crew_name"))
		inv.crew_tag = NetSocialPlayer._str(d.get("crew_tag"))
		inv.member_count = NetSocialPlayer._int(d.get("member_count"))
		inv.max_members = NetSocialPlayer._int(d.get("max_members"))
		inv.expires_at = NetSocialPlayer._int(d.get("expires_at"))
		var from := NetSocialPlayer.from_dict(d.get("from"))
		if from != null:
			inv.from_account = from.account_id
			inv.from_name = from.full_name
		return inv

	## From `lobby_event.crew_invite` (vector JSON; `now_unix` + `expires_in_s`).
	static func from_event(msg: Dictionary, now_unix: int) -> Invite:
		var inv := Invite.new()
		inv.invite_id = String(msg.get("invite_id", ""))
		inv.crew_name = String(msg.get("crew_name", ""))
		inv.crew_tag = String(msg.get("crew_tag", ""))
		var from: Dictionary = msg.get("from", {})
		inv.from_account = String(from.get("account_id", ""))
		inv.from_name = "%s#%04d" % [String(from.get("display_name", "")), int(from.get("name_tag", 0))]
		inv.expires_at = now_unix + int(msg.get("expires_in_s", 0))
		return inv


const OWNER := "owner"
const OFFICER := "officer"
const MEMBER := "member"

const KICK := &"kick"
const PROMOTE := &"promote"
const DEMOTE := &"demote"
const TRANSFER := &"transfer"

var crew_id: String = ""
var name: String = ""
## Upper case, 2–4 characters.
var tag: String = ""
var owner_id: String = ""
var created_at: int = 0
var member_count: int = 0
var max_members: int = 0
## "" for non-members.
var invite_code: String = ""
## `owner`, `officer`, `member`; "" for non-members.
var your_role: String = ""
## Owner first, then officers, then members, each by join time (the server's order).
var members: Array[NetSocialPlayer] = []


## A crew from the API's JSON (null without a crew id).
static func from_dict(v: Variant) -> NetCrew:
	if not (v is Dictionary):
		return null
	var d: Dictionary = v
	var c := NetCrew.new()
	c.crew_id = NetApiResult.as_id(d.get("crew_id"))
	if c.crew_id.is_empty():
		return null
	c.name = NetSocialPlayer._str(d.get("name"))
	c.tag = NetSocialPlayer._str(d.get("tag"))
	c.owner_id = NetApiResult.as_id(d.get("owner_id"))
	c.created_at = NetSocialPlayer._int(d.get("created_at"))
	c.max_members = NetSocialPlayer._int(d.get("max_members"))
	c.invite_code = NetSocialPlayer._str(d.get("invite_code"))
	c.your_role = NetSocialPlayer._str(d.get("your_role"))
	var list: Variant = d.get("members")
	if list is Array:
		for m: Variant in list as Array:
			var p := NetSocialPlayer.from_dict(m)
			if p != null:
				c.members.append(p)
	c.member_count = NetSocialPlayer._int(d.get("member_count", c.members.size()))
	return c


func member(account_id: String) -> NetSocialPlayer:
	for m in members:
		if m.account_id == account_id:
			return m
	return null


func is_member() -> bool:
	return not your_role.is_empty()


## The actions someone with `your_role` may take on a member with `target_role`, in the
## order the crew screen shows them.
static func allowed_actions(your: String, target_role: String, is_self: bool) -> Array[StringName]:
	var out: Array[StringName] = []
	if is_self:
		return out
	if your == OWNER:
		if target_role == MEMBER:
			out.append(PROMOTE)
		elif target_role == OFFICER:
			out.append(DEMOTE)
		if target_role == MEMBER or target_role == OFFICER:
			out.append(TRANSFER)
			out.append(KICK)
	elif your == OFFICER and target_role == MEMBER:
		out.append(KICK)
	return out


static func can_rotate_code(your: String) -> bool:
	return your == OWNER or your == OFFICER


static func can_disband(your: String) -> bool:
	return your == OWNER
