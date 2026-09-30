class_name NetRoomState
extends RefCounted
## What the client knows about its room: settings, members, crews, host and the room
## clock, from `room_snapshot` and kept current by `room_event`. Spec:
## WESTBOUND_MULTIPLAYER_HANDOFF.md → Rooms (settings: code, private/public, up to 8
## players, density, time-of-day mode; the host), Time of day in multiplayer (the room
## clock: 32 min cycle, 22 min day, night ×2); docs/PROTOCOL.md §4 (room_snapshot,
## room_event, RoomSettings, RoomClock, Member, RoomCrew); docs/SERVER.md → Rooms → For the
## client. WP N5.2.
##
## The room clock follows the server: `clock_cycle_ms` holds at `clock_tick`, and in
## `cycle` mode it advances with server_now() (fractional room ticks); `fixed` and `night`
## hold it (the server gives the held position). cycle_ms_at(now_tick) is the phase.

const MS_PER_S := 1000.0   # lint: allow-number unit conversion

var room_id: int = 0
var code: String = ""
## The player id the server gave this client (`you`).
var you: int = -1
var host_id: int = -1
var visibility: String = "private"
var max_players: int = 8
var density: String = "normal"
var time_mode: String = "cycle"
var fixed_cycle_ms: int = 0
## The room clock: the cycle position `clock_cycle_ms` at room tick `clock_tick`.
var clock_tick: int = 0
var clock_cycle_ms: int = 0
var cycle_len_ms: int = 1
var day_len_ms: int = 1
var tick_rate: float = 20.0
## Members in join order (at most 16).
var members: Array[NetRoomMember] = []
## Crew slot → RoomCrew color index and session total.
var crew_colors: Dictionary[int, int] = {}
var crew_totals: Dictionary[int, int] = {}
## Bumped whenever members, host or settings change (the HUD redraws on a new value).
var version: int = 0


## A snapshot (on every join and rejoin) replaces everything. Members muted before a
## rejoin stay muted (by account).
func apply_snapshot(msg: Dictionary) -> void:
	var muted: Dictionary[String, bool] = {}
	for m in members:
		if m.muted:
			muted[m.account_id] = true
	room_id = int(msg.get("room_id", 0))
	code = String(msg.get("code", ""))
	you = int(msg.get("you", -1))
	_apply_settings(msg.get("settings", {}), msg.get("clock", {}), int(msg.get("tick", 0)))
	crew_colors.clear()
	crew_totals.clear()
	for c: Dictionary in msg.get("crews", []):
		crew_colors[int(c.get("crew_slot", 0))] = int(c.get("color", 0))
		crew_totals[int(c.get("crew_slot", 0))] = int(c.get("session_total", 0))
	members.clear()
	host_id = -1
	for m: Dictionary in msg.get("members", []):
		var r := NetRoomMember.from_dict(m)
		r.muted = muted.has(r.account_id)
		_add(r)
	_recolor()
	version += 1


## A room_event (join, leave, host_change, kick, settings, crew, connection). Returns the
## event's kind ("" when it was not a room_event).
func apply_event(msg: Dictionary) -> String:
	if String(msg.get("type", "")) != "room_event":
		return ""
	var kind := String(msg.get("kind", ""))
	match kind:
		"join":
			var r := NetRoomMember.from_dict(msg)
			remove(r.player_id)
			_add(r)
			_recolor()
		"leave", "kick":
			remove(int(msg.get("player_id", -1)))
		"host_change":
			host_id = int(msg.get("player_id", -1))
			for m in members:
				m.host = m.player_id == host_id
		"settings":
			_apply_settings(msg.get("settings", {}), msg.get("clock", {}), int(msg.get("tick", 0)))
		"crew":
			crew_colors[int(msg.get("crew_slot", 0))] = int(msg.get("color", 0))
			crew_totals[int(msg.get("crew_slot", 0))] = int(msg.get("session_total", 0))
			_recolor()
		"connection":
			var m := member(int(msg.get("player_id", -1)))
			if m != null:
				m.disconnected = not bool(msg.get("connected", true))
	version += 1
	return kind


func member(player_id: int) -> NetRoomMember:
	for m in members:
		if m.player_id == player_id:
			return m
	return null


func me() -> NetRoomMember:
	return member(you)


func is_host() -> bool:
	return you >= 0 and host_id == you


func is_public() -> bool:
	return visibility == "public"


func remove(player_id: int) -> void:
	for i in members.size():
		if members[i].player_id == player_id:
			members.remove_at(i)
			return


## The room clock's position (ms into the cycle) at fractional room tick `now_tick`:
## advanced with the room clock in `cycle` mode, held otherwise.
func cycle_ms_at(now_tick: float) -> float:
	if time_mode != "cycle":
		return float(clock_cycle_ms)
	var ms := float(clock_cycle_ms) + (now_tick - float(clock_tick)) / tick_rate * MS_PER_S
	return fposmod(ms, float(maxi(cycle_len_ms, 1)))


func is_night_at(now_tick: float) -> bool:
	return cycle_ms_at(now_tick) >= float(day_len_ms)


## "3/8" for the room line.
func players_text() -> String:
	return "%d/%d" % [members.size(), max_players]


func _add(r: NetRoomMember) -> void:
	members.append(r)
	if r.host:
		host_id = r.player_id


func _recolor() -> void:
	for m in members:
		m.crew_color = crew_colors.get(m.crew_slot, m.crew_slot)


func _apply_settings(s: Dictionary, c: Dictionary, tick: int) -> void:
	visibility = String(s.get("visibility", visibility))
	max_players = int(s.get("max_players", max_players))
	density = String(s.get("density", density))
	time_mode = String(s.get("time_mode", time_mode))
	fixed_cycle_ms = int(s.get("fixed_cycle_ms", fixed_cycle_ms))
	if not c.is_empty():
		clock_tick = tick
		clock_cycle_ms = int(c.get("cycle_ms", 0))
		cycle_len_ms = maxi(int(c.get("cycle_len_ms", 1)), 1)
		day_len_ms = int(c.get("day_len_ms", 0))
