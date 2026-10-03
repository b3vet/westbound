class_name NetRoomInvites
extends RefCounted
## Room invites waiting for an answer (protocol 2). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md →
## Rooms, parties and matchmaking (Private rooms: "The creator gets a code and an invite
## link"; Friends and presence); the owner's request "invite my friends or crew into a
## private room in online mode". docs/PROTOCOL.md §4 (`lobby_event.room_invite`: accepted
## with `room_join_code` and its code; declining needs no message); docs/SERVER.md → Room
## invites; docs/ROOMS_CLIENT.md → Room invites.
##
## Kept newest first, one per room code, at most `room_invites_max`, until accepted,
## declined or past the `expires_in_s` the server gave (client clock).

## One invite.
class Invite:
	var code: String = ""
	var room_id: int = 0
	var from_account: String = ""
	## `name#1234`.
	var from_name: String = ""
	## `private` or `public`.
	var visibility: String = ""
	var players: int = 0
	var max_players: int = 0
	## Arrival and expiry, client seconds.
	var at_s: float = 0.0
	var expires_s: float = 0.0
	## Shown once each: the online hub's card, the title toast (with JOIN), the run toast
	## (a note). An invite seen in a run still gets its title toast and its hub card.
	var hub_card: bool = false
	var toast_title: bool = false
	var toast_run: bool = false

	func is_public() -> bool:
		return visibility == "public"


## Newest first.
var invites: Array[Invite] = []
## Bumped whenever the list changes (screens redraw on a new value).
var version: int = 0


## `lobby_event.room_invite` (vector JSON) at `now_s`: kept newest first, one per code.
func add(msg: Dictionary, now_s: float, max_kept: int) -> Invite:
	var from: Dictionary = msg.get("from", {})
	var inv := Invite.new()
	inv.code = String(msg.get("code", ""))
	inv.room_id = int(msg.get("room_id", 0))
	inv.from_account = String(from.get("account_id", ""))
	inv.from_name = "%s#%04d" % [String(from.get("display_name", "")), int(from.get("name_tag", 0))]
	inv.visibility = String(msg.get("visibility", ""))
	inv.players = int(msg.get("players", 0))
	inv.max_players = int(msg.get("max_players", 0))
	inv.at_s = now_s
	inv.expires_s = now_s + float(msg.get("expires_in_s", 0))
	drop(inv.code)
	invites.push_front(inv)
	while invites.size() > maxi(max_kept, 1):
		invites.pop_back()
	version += 1
	return inv


## Forgets the invite to `code` (accepted or declined).
func drop(code: String) -> void:
	for i in invites.size():
		if invites[i].code == code:
			invites.remove_at(i)
			version += 1
			return


## Drops invites past their expiry; true when any went.
func expire(now_s: float) -> bool:
	var any := false
	for i in range(invites.size() - 1, -1, -1):
		if now_s >= invites[i].expires_s:
			invites.remove_at(i)
			any = true
	if any:
		version += 1
	return any


func newest() -> Invite:
	return invites[0] if not invites.is_empty() else null


## The newest invite the hub has not shown as a card yet (null: none).
func next_for_hub() -> Invite:
	for inv in invites:
		if not inv.hub_card:
			return inv
	return null


## The newest invite the title (`title` true) or a run has not toasted yet (null: none).
func next_for_toast(title: bool) -> Invite:
	for inv in invites:
		if not (inv.toast_title if title else inv.toast_run):
			return inv
	return null


func find(code: String) -> Invite:
	for inv in invites:
		if inv.code == code:
			return inv
	return null


func is_empty() -> bool:
	return invites.is_empty()
