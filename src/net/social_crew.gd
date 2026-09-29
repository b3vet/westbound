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
