extends "res://tests/net/fake_room_server.gd"
## The scripted room server plus parties (N9.3 tests): party_create / party_join / party_invite /
## party_leave / party_kick answered as docs/SERVER.md → Parties says (party_state to the
## client, party_left, refusals as non-fatal errors), room_host_command recorded, and helpers
## to push an invite, move the party (an unrequested snapshot: the leader took the party to a
## room) or drop the party. The client is account `account_id` (fake_server.gd). Not a test
## file.

const PARTY_CODE := "PQ7K2M"
const LEADER_ID := "42"

## A non-fatal error answering the next party command ("" = accept).
var refuse_party: String = ""
## The party the client is in (members as Identity dictionaries), empty = none.
var party_members: Array[Dictionary] = []
var party_leader: String = ""
var party_code: String = ""
## Send the party state right after a Welcome (the server holds the place).
var state_on_welcome: bool = true
var party_commands: Array[Dictionary] = []
var host_commands: Array[Dictionary] = []


func _handle(m: Dictionary) -> void:
	if String(m["type"]) == "room_host_command" and established:
		host_commands.append(m)
		return
	super._handle(m)


## A Welcome carries the party's state in its frame while the server holds the place.
func send(msgs: Array) -> void:
	if state_on_welcome and not party_code.is_empty() and msgs.size() == 1 \
			and String((msgs[0] as Dictionary).get("type", "")) == "welcome":
		super.send(msgs + [state()])
		return
	super.send(msgs)


func _lobby(m: Dictionary) -> void:
	var kind := String(m["kind"])
	if not kind.begins_with("party_"):
		super._lobby(m)
		return
	party_commands.append(m)
	if not refuse_party.is_empty():
		var code := refuse_party
		refuse_party = ""
		send([{"type": "error", "code": code, "fatal": false, "detail": code}])
		return
	match kind:
		"party_create":
			party_code = PARTY_CODE
			party_leader = account_id
			party_members = [me()]
			send([state()])
		"party_join":
			party_code = String(m["code"])
			party_leader = LEADER_ID
			party_members = [identity(LEADER_ID, "Dusty", 1234), me()]
			send([state()])
		"party_invite":
			if party_code.is_empty():
				party_code = PARTY_CODE
				party_leader = account_id
				party_members = [me()]
				send([state()])
		"party_leave":
			if party_code.is_empty():
				send([{"type": "error", "code": "party_not_found", "fatal": false, "detail": "no party"}])
				return
			_clear()
			send([{"type": "lobby_event", "kind": "party_left", "reason": "left"}])
		"party_kick":
			for i in party_members.size():
				if String(party_members[i]["account_id"]) == String(m["account_id"]):
					party_members.remove_at(i)
					break
			send([state()])


func me() -> Dictionary:
	return identity(account_id, "Zoe", 7)


static func identity(id: String, player: String, tag: int) -> Dictionary:
	return {"account_id": id, "display_name": player, "name_tag": tag}


func state() -> Dictionary:
	return {"type": "lobby_event", "kind": "party_state", "code": party_code, "leader": party_leader,
		"members": party_members}


## The client joins a party of `n` led by LEADER_ID (as if it had accepted an invite).
func put_in_party(n: int, leader_is_me: bool = false) -> void:
	party_code = PARTY_CODE
	party_leader = account_id if leader_is_me else LEADER_ID
	party_members = [identity(LEADER_ID, "Dusty", 1234), me()]
	for i in n - 2:
		party_members.append(identity(str(100 + i), "Rider%d" % i, 10 + i))
	send([state()])


func push_invite(from_id: String, player: String, tag: int, code: String) -> void:
	send([{"type": "lobby_event", "kind": "party_invite", "from": identity(from_id, player, tag), "code": code}])


## The leader took the party to a room: the snapshot and placement the client did not ask
## for (docs/SERVER.md → Parties: the member's connection follows).
func move_party() -> void:
	in_seat = true
	var tick := floori(server_ticks())
	placement_tick = tick
	send([snapshot(tick), placement(tick)])


func kick_from_party() -> void:
	_clear()
	send([{"type": "lobby_event", "kind": "party_left", "reason": "kicked"}])


func _clear() -> void:
	party_code = ""
	party_leader = ""
	party_members = []
