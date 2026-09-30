class_name NetSocialPlayer
extends RefCounted
## A player as the Social API shows them: a friend, a request, a blocked player or a crew
## member, with the presence fields for friends. Spec: multiplayer handoff → Rooms,
## parties and matchmaking → Friends and presence, Crews (persistent); docs/SERVER.md →
## Social API. WP N9.2; docs/NET_CLIENT.md → Social client.
##
## Account ids stay decimal Strings. Presence: `status` is OFFLINE, ONLINE or IN_ROOM;
## `room_id` is 0 outside a room (the WebSocket's 0 and the HTTP `null` both read as 0);
## `joinable` says the room has space (the Join button, N5).

const OFFLINE := "offline"
const ONLINE := "online"
const IN_ROOM := "in_room"
const STATUSES: Array[String] = [OFFLINE, ONLINE, IN_ROOM]
const TAG_FMT := "#%04d"

var account_id: String = ""
var display_name: String = ""
## The `#1234` number.
var tag: int = 0
## `display_name#0042`: the friend code.
var full_name: String = ""
## The player's crew tag ("" without a crew).
var crew_tag: String = ""
## Friends and requests: the request's id.
var request_id: String = ""
## Unix seconds: request sent / accepted (friends) / blocked / joined the crew.
var created_at: int = 0
var since: int = 0
var blocked_at: int = 0
var joined_at: int = 0
## Crew members: `owner`, `officer` or `member`.
var role: String = ""
var status: String = OFFLINE
var room_id: int = 0
var joinable: bool = false


## A player from a Social API object (null when it has no account id).
static func from_dict(v: Variant) -> NetSocialPlayer:
	if not (v is Dictionary):
		return null
	var d: Dictionary = v
	var p := NetSocialPlayer.new()
	p.account_id = NetApiResult.as_id(d.get("account_id"))
	if p.account_id.is_empty():
		return null
	p.display_name = _str(d.get("display_name"))
	p.tag = _int(d.get("tag", d.get("name_tag")))
	p.full_name = _str(d.get("full_name"))
	if p.full_name.is_empty() and not p.display_name.is_empty():
		p.full_name = p.display_name + TAG_FMT % p.tag
	p.crew_tag = _str(d.get("crew_tag"))
	p.request_id = NetApiResult.as_id(d.get("request_id"))
	p.created_at = _int(d.get("created_at"))
	p.since = _int(d.get("since"))
	p.blocked_at = _int(d.get("blocked_at"))
	p.joined_at = _int(d.get("joined_at"))
	p.role = _str(d.get("role"))
	p.set_presence(d.get("status"), d.get("room_id"), d.get("joinable"))
	return p


## Takes presence fields (JSON or decoded WebSocket values). True when anything changed.
func set_presence(new_status: Variant, new_room: Variant, new_joinable: Variant) -> bool:
	var s := _str(new_status)
	if not STATUSES.has(s):
		s = OFFLINE
	var room := maxi(_int(new_room), 0)
	var j := bool(new_joinable) if new_joinable is bool else false
	if s != IN_ROOM:
		room = 0
		j = false
	var changed := s != status or room != room_id or j != joinable
	status = s
	room_id = room
	joinable = j
	return changed


func tag_text() -> String:
	return TAG_FMT % tag


func is_online() -> bool:
	return status != OFFLINE


func in_room() -> bool:
	return status == IN_ROOM


## Friends list order: in a room, then online, then offline.
func presence_rank() -> int:
	return STATUSES.size() - 1 - STATUSES.find(status)


static func _str(v: Variant) -> String:
	return v if v is String else ""


static func _int(v: Variant) -> int:
	if v is int:
		return v
	if v is float and is_finite(v as float):
		return int(v)
	return 0
