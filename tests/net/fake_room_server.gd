extends "res://tests/net/fake_server.gd"
## The scripted server plus rooms (N5.2 tests): answers joins with a room_snapshot and a
## placement (the client's own id in player_states, run_state protected) in one frame,
## room_browse with a room_list, room_leave with room_left; records every state, hit, run
## event and chat. Mirrors docs/SERVER.md → Rooms → For the client. Not a test file.

const ROOM_ID := 12
const ROOM_CODE := "ABC234"
const YOU := 1
const OTHER := 0

## A non-fatal error code answering the next join instead of a snapshot ("" = accept).
var refuse_join: String = ""
## Answer joins at all (false: a hung join).
var answer_joins: bool = true
## Where the first placement goes (wire units).
var place_s_mm: int = 1_000_000
var place_d_cm: int = 350
var place_speed_cms: int = 3000
var time_mode: String = "cycle"
var cycle_ms: int = 1_000_000

var joins: Array[Dictionary] = []
var states: Array[Dictionary] = []
var hits: Array[Dictionary] = []
var run_events: Array[Dictionary] = []
var chats: Array[Dictionary] = []
var leaves: int = 0
var in_seat: bool = false
var placement_tick: int = -1


func _handle(m: Dictionary) -> void:
	if String(m["type"]) == "hello":
		established = false   # a Hello only ever opens a new connection here (reconnects)
	if not established or String(m["type"]) in ["hello", "ping"]:
		super._handle(m)
		return
	match String(m["type"]):
		"lobby_command":
			lobby_commands.append(m)
			_lobby(m)
		"player_state":
			states.append(m)
		"hit_report":
			hits.append(m)
		"run_event":
			run_events.append(m)
		"quick_chat":
			chats.append(m)


func _lobby(m: Dictionary) -> void:
	match String(m["kind"]):
		"quick_join", "room_create", "room_join_code", "room_join_id":
			joins.append(m)
			if not answer_joins:
				return
			if not refuse_join.is_empty():
				var code := refuse_join
				refuse_join = ""
				send([{"type": "error", "code": code, "fatal": false, "detail": code}])
				return
			in_seat = true
			var tick := floori(server_ticks())
			placement_tick = tick
			send([snapshot(tick), placement(tick)])
		"room_leave":
			leaves += 1
			if in_seat:
				in_seat = false
				send([{"type": "lobby_event", "kind": "room_left", "reason": "left"}])
		"room_browse":
			send([{"type": "lobby_event", "kind": "room_list", "rooms": [
				{"room_id": 7, "players": 3, "max_players": 8, "density": "normal", "night": false},
				{"room_id": 9, "players": 7, "max_players": 8, "density": "rush", "night": true},
			]}])


func snapshot(tick: int) -> Dictionary:
	return {"type": "room_snapshot", "room_id": ROOM_ID, "code": ROOM_CODE,
		"settings": {"visibility": "private", "max_players": 8, "density": "normal",
			"time_mode": time_mode, "fixed_cycle_ms": 0},
		"tick": tick,
		"clock": {"cycle_ms": cycle_ms, "cycle_len_ms": 1_920_000, "day_len_ms": 1_320_000},
		"you": YOU,
		"members": [
			_member(OTHER, "42", "Dusty", 1234, "WB", true),
			_member(YOU, "77", "Zoe", 7, "", false),
		],
		"crews": [{"crew_slot": 0, "color": 3, "session_total": 0}]}


static func _member(pid: int, account: String, player: String, tag: int, crew: String, host: bool) -> Dictionary:
	return {"player_id": pid, "identity": {"account_id": account, "display_name": player, "name_tag": tag},
		"crew_tag": crew, "crew_slot": 0, "flags": {"host": host, "disconnected": false}}


## The client's placement at `tick` (player_states with its own id, protected).
func placement(tick: int, s_mm: int = -1) -> Dictionary:
	return {"type": "player_states", "players": [{"player_id": YOU, "state": _state(tick,
		place_s_mm if s_mm < 0 else s_mm, place_d_cm, place_speed_cms, "protected")}]}


## Another player's state.
func other_state(pid: int, tick: int, s_mm: int, d_cm: int, speed_cms: int) -> Dictionary:
	return {"type": "player_states", "players": [{"player_id": pid, "state": _state(tick, s_mm, d_cm,
		speed_cms, "driving")}]}


static func _state(tick: int, s_mm: int, d_cm: int, speed_cms: int, run_state: String) -> Dictionary:
	return {"tick": tick, "s_mm": s_mm, "d_cm": d_cm, "heading_e4": 0, "speed_cms": speed_cms,
		"lat_vel_cms": 0, "yaw_rate_mrad_s": 0, "steer_e4": 0,
		"flags": {"brake": false, "boost": false, "headlights": false, "ghost": false},
		"run_state": run_state}


## Drops the connection from the server side (a network switch).
func drop() -> void:
	established = false
	in_seat = false
	transport.close(1001, "gone")
