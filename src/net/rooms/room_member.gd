class_name NetRoomMember
extends RefCounted
## One seat in the room: a player, their crew and the client-side extras (mute, the last
## quick chat). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Players ("Every remote car shows a
## nametag in its crew color"), Rooms, parties and matchmaking (Quick chat: "muted per
## player from the room menu"); docs/PROTOCOL.md §4 Member. WP N5.2.

var player_id: int = -1
## Decimal string (PROTOCOL.md §8: account ids never go through a float).
var account_id: String = ""
var display_name: String = ""
var name_tag: int = 0
## The persistent crew's tag (0–4 characters; "" = none).
var crew_tag: String = ""
## The room's scoring crew (0–15) and its color index (RoomCrew.color).
var crew_slot: int = 0
var crew_color: int = 0
var host: bool = false
## The seat is held (the connection dropped): the car fades.
var disconnected: bool = false
## Client-only: this player's quick chat is not shown.
var muted: bool = false
## Client-only: the latest quick chat (NetRoomChat text) and when it arrived (seconds).
var chat_text: String = ""
var chat_at_s: float = -INF


## From a vector-JSON Member (room_snapshot.members[i], room_event.join).
static func from_dict(m: Dictionary) -> NetRoomMember:
	var r := NetRoomMember.new()
	r.player_id = int(m.get("player_id", -1))
	var id: Dictionary = m.get("identity", {})
	r.account_id = String(id.get("account_id", ""))
	r.display_name = String(id.get("display_name", ""))
	r.name_tag = int(id.get("name_tag", 0))
	r.crew_tag = String(m.get("crew_tag", ""))
	r.crew_slot = int(m.get("crew_slot", 0))
	var f: Dictionary = m.get("flags", {})
	r.host = bool(f.get("host", false))
	r.disconnected = bool(f.get("disconnected", false))
	return r


## "name#1234" (the name tag is always four digits).
func full_name() -> String:
	return "%s#%04d" % [display_name, name_tag]


## The nametag: "name#1234 [TAG]" (no brackets without a crew).
func nametag() -> String:
	return full_name() if crew_tag.is_empty() else "%s [%s]" % [full_name(), crew_tag]
