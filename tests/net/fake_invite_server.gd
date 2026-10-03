extends "res://tests/net/fake_party_server.gd"
## The scripted room and party server plus room and crew invites (protocol 2 tests):
## `lobby_command.room_invite` recorded and answered as docs/SERVER.md → Room invites says
## (nothing on success; `refuse_invite` answers the next one with a non-fatal error and its
## detail), and helpers to push a `lobby_event.room_invite` or `crew_invite` to the client.
## Not a test file.

## A non-fatal error code answering the next room_invite ("" = accept), and its detail.
var refuse_invite: String = ""
var refuse_detail: String = ""
var room_invites: Array[Dictionary] = []


func _lobby(m: Dictionary) -> void:
	if String(m["kind"]) != "room_invite":
		super._lobby(m)
		return
	room_invites.append(m)
	if not refuse_invite.is_empty():
		var code := refuse_invite
		refuse_invite = ""
		send([{"type": "error", "code": code, "fatal": false, "detail": refuse_detail}])
		return
	if not in_seat:
		send([{"type": "error", "code": "not_in_room", "fatal": false,
			"detail": "Join a room before inviting players to it."}])


## `from` invites the client to room `code`.
func push_room_invite(from_id: String, player: String, tag: int, code: String,
		players: int = 3, expires_in_s: int = 120, visibility: String = "private") -> void:
	send([{"type": "lobby_event", "kind": "room_invite", "from": identity(from_id, player, tag),
		"room_id": 33, "code": code, "visibility": visibility, "players": players, "max_players": 8,
		"expires_in_s": expires_in_s}])


## A crew invites the client (the invite's id is the fake Social API's).
func push_crew_invite(invite_id: String, crew_tag: String, crew_name: String, from_id: String,
		player: String, tag: int) -> void:
	send([{"type": "lobby_event", "kind": "crew_invite", "invite_id": invite_id, "crew_tag": crew_tag,
		"crew_name": crew_name, "from": identity(from_id, player, tag), "expires_in_s": 604800}])
