class_name NetRoomSession
extends RefCounted
## The client side of a room: connect, join (Quick Join, create, code, id), the room
## state, placements, the 20 Hz state upload, remote players, run results, quick chat,
## and reconnecting within the seat hold. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Players
## (your car is yours: a PlayerState 20 times a second; spawning; crash-out; rejoin crew;
## reconnect: "your seat is held for 15 seconds"), Rooms, parties and matchmaking (private
## rooms, codes, Quick Join, room browser, quick chat), Networking protocol; Client changes
## (`room_client.gd`: joining, snapshots, respawn and rejoin, reconnect). docs/PROTOCOL.md
## §4, §12 (placement semantics); docs/SERVER.md → Rooms → For the client.
## docs/ROOMS_CLIENT.md. WP N5.2.
##
## Pure RefCounted driven by poll() (the NetRooms node polls it each frame); the transport
## and the clock are injected (tests run it on a NetLoopbackLink with NetVirtualTime).
##
##   IDLE --request--> CONNECTING --Welcome--> LOBBY --join sent--> JOINING --snapshot--> IN_ROOM
##   IN_ROOM --socket lost--> RECONNECTING --Welcome, join by code, snapshot--> IN_ROOM (seat kept)
##   RECONNECTING --room_reconnect_window_s over--> IDLE (`left`, timed_out)
##   IN_ROOM --leave() / room_left--> LOBBY (`left`) ; any fatal error --> FAILED
##
## Placements (PROTOCOL.md §12): the server puts this client's own id in player_states with
## run_state `protected`; each placement tick is taken once (has_placement / take_placement)
## and the client teleports there. Everyone else's states go to `remotes`.

signal state_changed(state: State)
## The first snapshot of a room (a join).
signal joined(room: NetRoomState)
## The snapshot after a reconnect (same seat, run intact).
signal rejoined(room: NetRoomState)
## A frame with traffic messages (spawn, despawn, intent, correction) while in the room,
## after joined / rejoined and the frame's placement (N4.3's NetworkTrafficSource applies
## it; the frame object is reused: consume it in the handler).
signal traffic_frame(frame: NetServerFrame)
## A join was refused or timed out: `code` (the protocol's error code or a REASON_*), text.
signal join_failed(code: String, message: String)
## Out of the room: `reason` = room_left's (left, kicked, closed, timed_out) or a
## connection failure's; `message` for the player ("" after the player's own leave).
signal left(reason: String, message: String)
signal room_list(rooms: Array[Dictionary])
## Members, host, settings or crews changed (NetRoomState.version moved).
signal room_changed()
signal run_result(result: Dictionary)
## A quick chat from a member who is not muted (their text; the member's chat fields too).
signal chat(player_id: int, text: String)
signal notice(text: String)
## The connection dropped in a room and the client is reconnecting (true) or back (false).
signal reconnecting(on: bool)
## N9.3: the party or its invites changed (`party.version` moved).
signal party_changed()
## N9.3: a friend invited this player to their party (`party.invites` holds it).
signal party_invited(invite: NetParty.Invite)
## N9.3: out of the party: `reason` = party_left's (left, kicked, disbanded) or `lost` (the
## connection stayed down longer than the server holds the place); `message` for the
## player ("" after the player's own leave).
signal party_left(reason: String, message: String)
## N9.3: a refused lobby command outside a join (party commands, a party move that could
## not follow): the protocol's error code and the player text.
signal lobby_error(code: String, message: String)

enum State { IDLE, CONNECTING, LOBBY, JOINING, IN_ROOM, RECONNECTING, FAILED }
enum Request { NONE, QUICK_JOIN, CREATE, CODE, ID, BROWSE }

const REASON_JOIN_TIMEOUT := "join_timeout"
const REASON_SEAT_LOST := "seat_lost"
const RUN_PROTECTED := 1
const RUN_DRIVING := 2
const RUN_CRASHED := 3
const USEC_PER_S := 1000000.0
const MS_PER_S := 1000.0   # lint: allow-number unit conversion
## Reconnecting never helps after these (the build, the account or another device).
const NO_RETRY: Array[String] = ["update_required", "server_outdated", "map_mismatch", "banned", "not_allowed"]
const _TEXT := {
	"room_not_found": "No room with that code.",
	"room_full": "That room is full.",
	"not_allowed": "You can't join that room.",
	"server_full": "The server is full right now. Please try again soon.",
	"join_timeout": "The server didn't answer. Please try again.",
	"kicked": "The host removed you from the room.",
	"closed": "The room closed.",
	"timed_out": "Lost the connection to the room.",
	"seat_lost": "Lost the connection to the room.",
	"rate_limited": "Too many requests. Please wait a moment and try again.",
	"party_not_found": "No party with that code.",
	"party_full": "That party is full.",
	"not_party_leader": "Your party leader picks the room.",
	"blocked": "You can't join this party.",
	"party_kicked": "The party leader removed you from the party.",
	"party_disbanded": "The party closed.",
	"party_lost": "Lost the connection to your party.",
}
## Error codes that answer party commands, never a join in progress.
const PARTY_ERRORS: Array[String] = ["party_not_found", "party_full", "blocked"]

var tuning: NetTuning
var client: NetClient
var time: NetTimeSource
var url: String = ""
var client_build: int = 0
var map_hash := PackedByteArray()
## () -> String: an access token for Hello (NetSession.access_token).
var token_provider: Callable
var room := NetRoomState.new()
var remotes: NetRemotePlayers
var loop_length: float = 0.0
var state: State = State.IDLE
## The last failure (code and player text), "" after a success.
var last_code: String = ""
var last_message: String = ""
## The newest room_list (browser rows as vector JSON).
var rooms_listed: Array[Dictionary] = []

## The pending placement (valid while has_placement()).
var placement_tick: int = -1
var placement_s: float = 0.0
var placement_d: float = 0.0
var placement_speed: float = 0.0
## States sent, and the room tick of the last one.
var states_sent: int = 0
var last_sent_tick: int = -1
## Frames handled in a room (dev HUD).
var frames_in: int = 0
## Dev (snaps, previews): the room clock stands at this tick instead of the server's
## (-1 = off). See enter_demo().
var demo_tick: float = -1.0
## The server streams traffic in this room (a traffic message arrived since the join).
var traffic_streamed: bool = false
## Bytes of the frame traffic_frame hands out.
var last_frame_bytes: int = 0
## N9.3: the party and the invites waiting for an answer.
var party := NetParty.new()
## N9.3: a room snapshot this client did not ask for while in the lobby is a party move
## (the leader took the party to a room): taken as a join when true (the hub sets it while
## it shows), else that seat is left again.
var accept_follows: bool = false

var _pending_lobby: Array[Dictionary] = []
## Party place held by the server: a dropped lobby connection retries until this time
## (0 = not retrying).
var _lobby_retry_until_us: int = 0
## A Welcome arrived: without a party_state in its frame the server no longer has us in a
## party.
var _party_check: bool = false

var _request: Request = Request.NONE
var _request_settings: Dictionary = {}
var _request_code: String = ""
var _request_id: int = 0
var _request_since_us: int = 0
var _left_for_retry: bool = false
var _placement_pending: bool = false
var _seen_placement_tick: int = -1
var _reconnect_deadline_us: int = 0
var _next_retry_us: int = 0
var _chat_next_us: int = 0
var _out := NetPlayerState.new()
## The last snapshot's room tick and its arrival (the room clock before the first Pong).
var _snap_tick: int = -1
var _snap_at_us: int = 0
## What the frame being handled brought: ARRIVED_* (signals go out after its placement).
var _arrived: int = 0
const ARRIVED_NONE := 0
const ARRIVED_JOINED := 1
const ARRIVED_REJOINED := 2


func _init(transport: NetTransport, net_tuning: NetTuning, loop_length_m: float,
		time_source: NetTimeSource = null) -> void:
	tuning = net_tuning
	time = time_source if time_source != null else NetTimeSource.new()
	client = NetClient.new(transport, tuning, time)
	loop_length = loop_length_m
	remotes = NetRemotePlayers.new(tuning.room_max_remotes, tuning.room_track_samples, loop_length_m,
		tuning.tick_rate_hz, tuning.room_snap_distance_m)
	room.tick_rate = tuning.tick_rate_hz
	client.frame_received.connect(_on_frame)
	client.server_error.connect(_on_server_error)
	client.welcomed.connect(_on_welcome)


## Where and how to connect (NetRooms fills these from the NetSession).
func configure(server_url: String, build: int, hash_bytes: PackedByteArray, tokens: Callable) -> void:
	url = server_url
	client_build = build
	map_hash = hash_bytes
	token_provider = tokens


# ---------------------------------------------------------------- Requests

func quick_join() -> void:
	_start_request(Request.QUICK_JOIN)


## A private room with these settings (visibility is always private: the server refuses
## public). `density`: NetCodec.DENSITY name; `time_mode`: NetCodec.TIME_MODE name.
func create_room(density: String, time_mode: String, fixed_cycle_ms: int = 0) -> void:
	_request_settings = {"visibility": "private", "max_players": tuning.room_max_remotes + 1,
		"density": density, "time_mode": time_mode, "fixed_cycle_ms": maxi(fixed_cycle_ms, 0)}
	_start_request(Request.CREATE)


func join_code(code: String) -> void:
	_request_code = normalize_code(code)
	_start_request(Request.CODE)


func join_id(room_id: int) -> void:
	_request_id = room_id
	_start_request(Request.ID)


## Asks for the public room list (answered by `room_list`).
func browse() -> void:
	_start_request(Request.BROWSE)


# ---------------------------------------------------------------- Party (N9.3)

## A new party led by this player (docs/SERVER.md → Parties). Connects first when needed.
func party_create() -> void:
	_party_cmd({"kind": "party_create"})


## Joins the party with `code` (also how an invite is accepted).
func party_join(code: String) -> void:
	var c := normalize_code(code)
	party.drop_invite(c)
	_party_cmd({"kind": "party_join", "code": c})


## Invites an online friend (a party is made for the leader-to-be when there is none).
func party_invite(account_id: String) -> void:
	_party_cmd({"kind": "party_invite", "account_id": account_id})


func party_leave() -> void:
	_party_cmd({"kind": "party_leave"})


## Leader only.
func party_kick(account_id: String) -> void:
	_party_cmd({"kind": "party_kick", "account_id": account_id})


## Declining an invite needs no message (PROTOCOL.md §12): it is forgotten here.
func decline_invite(code: String) -> void:
	var v := party.version
	party.drop_invite(code)
	if party.version != v:
		party_changed.emit()


## Opens the lobby connection without a request (the party panel, presence).
func connect_lobby() -> void:
	if client.is_ready() or state == State.CONNECTING:
		return
	if state == State.IDLE or state == State.FAILED:
		_set_state(State.CONNECTING)
		if _connect() != OK:
			_set_state(State.FAILED)


func _party_cmd(cmd: Dictionary) -> void:
	cmd["type"] = "lobby_command"
	if client.is_ready():
		var err := client.send_messages([cmd])
		if err != "":
			lobby_error.emit(err, text_for(err))
		return
	_pending_lobby.append(cmd)
	if state == State.IDLE or state == State.FAILED:
		_set_state(State.CONNECTING)
		if _connect() != OK:
			_pending_lobby.clear()
			_set_state(State.FAILED)
			lobby_error.emit(NetClient.REASON_CONNECT_FAILED, NetClient.user_message(NetClient.REASON_CONNECT_FAILED))


func _flush_lobby() -> void:
	if _pending_lobby.is_empty() or not client.is_ready():
		return
	var cmds := _pending_lobby.duplicate()
	_pending_lobby.clear()
	var err := client.send_messages(cmds)
	if err != "":
		lobby_error.emit(err, text_for(err))


## The invite link for `code` on the server `api_base` (`https://<domain>/r/<code>`, spec).
static func invite_url(api_base: String, code: String, path: String) -> String:
	var origin := api_base
	var scheme_end := origin.find("//")
	var slash := origin.find("/", scheme_end + 2) if scheme_end >= 0 else -1
	if slash >= 0:
		origin = origin.left(slash)
	return origin + path + code


## Leaves the room (or a join in progress); the connection stays up for the hub.
func leave() -> void:
	var was := state
	_request = Request.NONE
	if client.is_ready() and (was == State.IN_ROOM or was == State.JOINING):
		client.send_messages([{"type": "lobby_command", "kind": "room_leave"}])
	_clear_room()
	if was == State.RECONNECTING:
		client.close()
		_set_state(State.IDLE)
	elif client.is_ready():
		_set_state(State.LOBBY)
	elif was != State.FAILED:
		_set_state(State.IDLE)


## Leaves and closes the connection (back to the title). The party goes too (the server
## lets the place go after its hold).
func close() -> void:
	if state == State.IN_ROOM or state == State.JOINING:
		leave()
	client.close()
	_clear_room()
	_pending_lobby.clear()
	_lobby_retry_until_us = 0
	party.clear()
	_set_state(State.IDLE)


func is_in_room() -> bool:
	return state == State.IN_ROOM


## In a room or reconnecting to it (the run keeps driving).
func has_room() -> bool:
	return state == State.IN_ROOM or state == State.RECONNECTING


## Seconds of the seat hold left while reconnecting (0 otherwise).
func reconnect_left_s() -> float:
	if state != State.RECONNECTING:
		return 0.0
	return maxf(float(_reconnect_deadline_us - time.now_usec()) / USEC_PER_S, 0.0)


## The room clock (fractional room tick), or -1 before the first clock sample.
func server_tick() -> float:
	if demo_tick >= 0.0:
		return demo_tick
	if client.clock.has_sync():
		return client.clock.server_now()
	if _snap_tick >= 0 and state == State.IN_ROOM:
		# Before the first Pong of the room: the snapshot's tick plus the time since it
		# arrived (behind by the one-way delay; the clock then steps forward).
		return float(_snap_tick) + float(time.now_usec() - _snap_at_us) / USEC_PER_S * room.tick_rate
	return -1.0


## The one-way delay estimate in room ticks (half the best round trip; 0 before a sample).
func one_way_ticks() -> float:
	return client.clock.best_rtt_s * 0.5 * room.tick_rate


## Dev (snaps, previews): a room without a server: `snapshot` (vector JSON) applied as if
## joined, the clock standing at `tick`.
func enter_demo(snapshot: Dictionary, tick: float) -> void:
	demo_tick = tick
	room.apply_snapshot(snapshot)
	_set_state(State.IN_ROOM)


## Dev (snaps, previews): a placement as the server would send it.
func demo_place(tick: int, s_m: float, d_m: float, speed_mps: float) -> void:
	placement_tick = tick
	placement_s = s_m
	placement_d = d_m
	placement_speed = speed_mps
	_placement_pending = true


## Round trip to the server, ms (the room line's ping; 0 before a sample).
func ping_ms() -> float:
	return client.clock.last_rtt_s * MS_PER_S


# ---------------------------------------------------------------- Placement

func has_placement() -> bool:
	return _placement_pending


## Takes the pending placement (its fields stay readable). Returns false when none.
func take_placement() -> bool:
	if not _placement_pending:
		return false
	_placement_pending = false
	return true


# ---------------------------------------------------------------- Upload

## Sends this client's state for room tick `tick` (physical units; `s_m` any unwrapped s,
## wrapped here into [0, L)). One per tick: a tick not after the last one sent is skipped.
## Returns true when sent.
func send_state(tick: int, s_m: float, d_m: float, heading_rad: float, speed_mps: float,
		lat_vel_mps: float, yaw_rate_rad_s: float, steer: float, flag_bits: int, run_state: int) -> bool:
	if state != State.IN_ROOM or not client.is_ready() or tick <= last_sent_tick or tick < 0:
		return false
	var s := fposmod(s_m, loop_length) if loop_length > 0.0 else s_m
	if _out.set_physical(tick, s, d_m, heading_rad, speed_mps, lat_vel_mps, yaw_rate_rad_s, steer,
			flag_bits, run_state) != "":
		return false
	if client.send_player_state(_out) != "":
		return false
	last_sent_tick = tick
	states_sent += 1
	return true


## A counted hit (spec: "The client reports its own hits"). `target`: NetCodec.HIT_TARGET
## name; `car_id` 0 unless traffic. lives_left 0 = the crash-out.
func send_hit(tick: int, target: String, car_id: int, lives_left: int) -> bool:
	return _send_room({"type": "hit_report", "tick": maxi(tick, 0), "target": target,
		"car_id": clampi(car_id, 0, NetCodec.U16_MAX), "lives_left": clampi(lives_left, 0, 255)})   # lint: allow-number u8 range


## `kind`: start, end or rejoin (the REJOIN CREW button).
func send_run_event(kind: String, tick: int) -> bool:
	return _send_room({"type": "run_event", "kind": kind, "tick": maxi(tick, 0)})


## A quick chat item (NetRoomChat.*_item). Rate-limited on the device
## (room_chat_interval_s). Returns true when sent.
func send_chat(item: Dictionary) -> bool:
	var now := time.now_usec()
	if now < _chat_next_us:
		return false
	if not _send_room({"type": "quick_chat", "item": item}):
		return false
	_chat_next_us = now + roundi(tuning.room_chat_interval_s * USEC_PER_S)
	return true


func chat_ready() -> bool:
	return time.now_usec() >= _chat_next_us


## Host commands (private rooms): kick, set_density, set_time_mode.
func send_host(cmd: Dictionary) -> bool:
	var m := cmd.duplicate()
	m["type"] = "room_host_command"
	return _send_room(m)


func set_muted(player_id: int, on: bool) -> void:
	var m := room.member(player_id)
	if m != null and m.muted != on:
		m.muted = on
		room.version += 1
		room_changed.emit()


# ---------------------------------------------------------------- Poll

func poll() -> void:
	client.poll()
	var now := time.now_usec()
	if _party_check:
		# The Welcome's frame carried no party_state: the server has no party for us.
		_party_check = false
		if party.in_party():
			party.clear()
			party_changed.emit()
			party_left.emit("lost", text_for("party_lost"))
	var cs := client.get_state()
	match state:
		State.IDLE:
			if _lobby_retry_until_us > 0:
				if now >= _lobby_retry_until_us:
					_lobby_retry_until_us = 0
					_drop_party("lost")
				elif now >= _next_retry_us:
					_next_retry_us = now + roundi(tuning.party_reconnect_retry_s * USEC_PER_S)
					_set_state(State.CONNECTING)
					if _connect() != OK:
						_set_state(State.IDLE)
		State.CONNECTING:
			if cs == NetClient.State.FAILED:
				if _request != Request.NONE:
					_fail_request(client.failure_reason, client.failure_message)
				elif _lobby_retry_until_us > 0 and not NO_RETRY.has(client.failure_reason):
					_set_state(State.IDLE)
				else:
					_pending_lobby.clear()
					last_code = client.failure_reason
					last_message = client.failure_message
					_set_state(State.FAILED)
					lobby_error.emit(client.failure_reason, client.failure_message)
		State.LOBBY, State.IN_ROOM:
			if cs == NetClient.State.FAILED:
				_lost(now)
		State.JOINING:
			if cs == NetClient.State.FAILED:
				_fail_request(client.failure_reason, client.failure_message)
			elif now - _request_since_us > roundi(tuning.room_join_timeout_s * USEC_PER_S):
				_fail_request(REASON_JOIN_TIMEOUT, text_for(REASON_JOIN_TIMEOUT))
		State.RECONNECTING:
			if now >= _reconnect_deadline_us:
				client.close()
				_clear_room()
				_set_state(State.IDLE)
				reconnecting.emit(false)
				_left(REASON_SEAT_LOST)
				_drop_party("lost")
			elif cs == NetClient.State.FAILED or cs == NetClient.State.CLOSED or cs == NetClient.State.IDLE:
				if NO_RETRY.has(client.failure_reason):
					_clear_room()
					_set_state(State.FAILED)
					reconnecting.emit(false)
					last_code = client.failure_reason
					last_message = client.failure_message
					left.emit(client.failure_reason, client.failure_message)
				elif now >= _next_retry_us:
					_next_retry_us = now + roundi(tuning.room_reconnect_retry_s * USEC_PER_S)
					_connect()


# ---------------------------------------------------------------- Internals

func _start_request(kind: Request) -> void:
	if state == State.IN_ROOM or state == State.JOINING or state == State.RECONNECTING:
		return
	_request = kind
	_left_for_retry = false
	last_code = ""
	last_message = ""
	if client.is_ready():
		_send_request()
		return
	if state == State.CONNECTING:
		return   # the lobby connection is on its way (N9.3); Welcome sends the request
	_set_state(State.CONNECTING)
	if _connect() != OK:
		_fail_request(NetClient.REASON_CONNECT_FAILED, NetClient.user_message(NetClient.REASON_CONNECT_FAILED))


func _connect() -> Error:
	var token := String(token_provider.call()) if token_provider.is_valid() else ""
	return client.start(url, client_build, map_hash, token)


func _on_welcome(w: Dictionary) -> void:
	party.me = String(w.get("account_id", party.me))
	_party_check = true
	_lobby_retry_until_us = 0
	if state == State.CONNECTING:
		_set_state(State.LOBBY)
		_send_request()
	elif state == State.RECONNECTING:
		_request_since_us = time.now_usec()
		client.send_messages([{"type": "lobby_command", "kind": "room_join_code", "code": room.code}])
	_flush_lobby()


func _send_request() -> void:
	var cmd: Dictionary = {}
	match _request:
		Request.QUICK_JOIN:
			cmd = {"kind": "quick_join"}
		Request.CREATE:
			cmd = _request_settings.duplicate()
			cmd["kind"] = "room_create"
		Request.CODE:
			cmd = {"kind": "room_join_code", "code": _request_code}
		Request.ID:
			cmd = {"kind": "room_join_id", "room_id": _request_id}
		Request.BROWSE:
			cmd = {"kind": "room_browse"}
		_:
			_set_state(State.LOBBY)
			return
	cmd["type"] = "lobby_command"
	var err := client.send_messages([cmd])
	if err != "":
		_fail_request(err, text_for(err))
		return
	if _request == Request.BROWSE:
		_request = Request.NONE
		_set_state(State.LOBBY)
		return
	_request_since_us = time.now_usec()
	_set_state(State.JOINING)


func _fail_request(code: String, message: String) -> void:
	_request = Request.NONE
	last_code = code
	last_message = message
	_set_state(State.LOBBY if client.is_ready() else State.FAILED)
	join_failed.emit(code, message)


## The socket died while connected: in a room, hold on and reconnect.
func _lost(now: int) -> void:
	if state == State.IN_ROOM and not room.code.is_empty() and not NO_RETRY.has(client.failure_reason):
		_reconnect_deadline_us = now + roundi(tuning.room_reconnect_window_s * USEC_PER_S)
		_next_retry_us = now
		_set_state(State.RECONNECTING)
		reconnecting.emit(true)
		return
	var was_room := state == State.IN_ROOM
	last_code = client.failure_reason
	last_message = client.failure_message
	_clear_room()
	if party.in_party() and not NO_RETRY.has(client.failure_reason):
		# N9.3: the server holds the party place for a while; reconnect for it.
		_lobby_retry_until_us = now + roundi(tuning.party_reconnect_window_s * USEC_PER_S)
		_next_retry_us = now
		_set_state(State.IDLE)
	else:
		_set_state(State.FAILED)
		if party.in_party():
			_drop_party("lost")
	if was_room:
		left.emit(client.failure_reason, client.failure_message)


func _on_server_error(code: String, fatal: bool, _detail: String) -> void:
	if fatal:
		return   # NetClient fails; poll() sees it
	if PARTY_ERRORS.has(code) or (state != State.JOINING and state != State.RECONNECTING):
		# N9.3: a party command's refusal, or a party move that could not follow.
		lobby_error.emit(code, text_for(code))
		return
	if state == State.JOINING:
		if code == "already_in_room" and not _left_for_retry:
			# A seat the server still holds (a replaced login): leave it and try once more.
			_left_for_retry = true
			client.send_messages([{"type": "lobby_command", "kind": "room_leave"}])
			_send_request()
			return
		_fail_request(code, text_for(code))
	elif state == State.RECONNECTING:
		# The room is gone or full again: the seat is lost.
		client.send_messages([{"type": "lobby_command", "kind": "room_leave"}])
		_clear_room()
		_set_state(State.LOBBY)
		reconnecting.emit(false)
		_left(REASON_SEAT_LOST)


func _on_frame(frame: NetServerFrame) -> void:
	if state == State.IN_ROOM:
		frames_in += 1
	last_frame_bytes = client.last_frame_bytes
	_arrived = ARRIVED_NONE
	for msg: Dictionary in frame.messages:
		_on_message(msg)
	if state != State.IN_ROOM:
		return
	var you := room.you
	for k in frame.ps_count:
		if frame.ps_player_id[k] != you:
			continue
		var t := frame.ps_tick[k]
		if frame.ps_run_state[k] == RUN_PROTECTED and t > _seen_placement_tick:
			# A placement (PROTOCOL.md §12): repeated every tick until answered; take each
			# placement tick once.
			_seen_placement_tick = t
			placement_tick = t
			placement_s = NetCodec.s_from_wire(frame.ps_s_mm[k])
			placement_d = NetCodec.d_from_wire(frame.ps_d_cm[k])
			placement_speed = NetCodec.speed_from_wire(frame.ps_speed_cms[k])
			_placement_pending = true
	remotes.ingest_into(frame, you)
	# The join's signals after its placement is known (the run starts at it).
	var arrived := _arrived
	_arrived = ARRIVED_NONE
	if arrived == ARRIVED_JOINED:
		joined.emit(room)
		room_changed.emit()
	elif arrived == ARRIVED_REJOINED:
		reconnecting.emit(false)
		rejoined.emit(room)
		room_changed.emit()
	if state != State.IN_ROOM:
		return
	if frame.sp_count + frame.ds_count + frame.in_count + frame.co_count > 0:
		traffic_streamed = true
		traffic_frame.emit(frame)


func _on_message(msg: Dictionary) -> void:
	match String(msg.get("type", "")):
		"room_snapshot":
			_on_snapshot(msg)
		"room_event":
			if state != State.IN_ROOM:
				return
			var kind := room.apply_event(msg)
			if kind == "leave" or kind == "kick":
				remotes.release(int(msg.get("player_id", -1)))
			room_changed.emit()
		"lobby_event":
			match String(msg.get("kind", "")):
				"room_list":
					rooms_listed.clear()
					for r: Dictionary in msg.get("rooms", []):
						rooms_listed.append(r)
					room_list.emit(rooms_listed)
				"room_left":
					if state == State.IN_ROOM or state == State.JOINING:
						_clear_room()
						_set_state(State.LOBBY)
						_left(String(msg.get("reason", "left")))
				"party_state":
					_party_check = false
					party.apply_state(msg)
					party_changed.emit()
				"party_left":
					var reason := String(msg.get("reason", "left"))
					party.clear()
					party_changed.emit()
					party_left.emit(reason, "" if reason == "left" else text_for("party_" + reason))
				"party_invite":
					var inv := party.add_invite(msg, float(time.now_usec()) / USEC_PER_S,
						tuning.party_invites_max)
					party_changed.emit()
					party_invited.emit(inv)
		"run_result":
			if state == State.IN_ROOM:
				run_result.emit(msg)
		"quick_chat":
			if state != State.IN_ROOM:
				return
			var pid := int(msg.get("player_id", -1))
			var m := room.member(pid)
			if m == null or m.muted:
				return
			var text := NetRoomChat.text_of(msg.get("item", {}))
			m.chat_text = text
			m.chat_at_s = float(time.now_usec()) / USEC_PER_S
			chat.emit(pid, text)
		"server_notice":
			notice.emit(String(msg.get("text", "")))


func _on_snapshot(msg: Dictionary) -> void:
	var follow := state == State.LOBBY and accept_follows and party.in_party()
	if state != State.JOINING and state != State.RECONNECTING and state != State.IN_ROOM and not follow:
		# The answer to a join the player gave up on: leave that seat again.
		client.send_messages([{"type": "lobby_command", "kind": "room_leave"}])
		return
	var back := state == State.RECONNECTING
	var same_room := back and int(msg.get("room_id", 0)) == room.room_id
	room.tick_rate = client.clock.tick_rate()
	room.apply_snapshot(msg)
	remotes.clear()
	# Pong now carries this room's tick (docs/SERVER.md → For the client).
	client.clock.reset()
	client.ping_now()
	last_sent_tick = -1
	_snap_tick = int(msg.get("tick", 0))
	_snap_at_us = time.now_usec()
	if not same_room:
		_seen_placement_tick = -1
		_placement_pending = false
		traffic_streamed = false
	_request = Request.NONE
	_set_state(State.IN_ROOM)
	_arrived = ARRIVED_REJOINED if back else ARRIVED_JOINED


func _send_room(msg: Dictionary) -> bool:
	if state != State.IN_ROOM or not client.is_ready():
		return false
	return client.send_messages([msg]) == ""


func _drop_party(reason: String) -> void:
	if not party.in_party():
		return
	party.clear()
	party_changed.emit()
	party_left.emit(reason, text_for("party_" + reason))


func _left(reason: String) -> void:
	var text := "" if reason == "left" else text_for(reason)
	last_code = reason
	last_message = text
	left.emit(reason, text)


func _clear_room() -> void:
	remotes.clear()
	_placement_pending = false
	_seen_placement_tick = -1
	last_sent_tick = -1
	_snap_tick = -1
	traffic_streamed = false


static func text_for(code: String) -> String:
	return String(_TEXT.get(code, NetClient.user_message(code)))


## Upper case, no spaces or dashes (a pasted "abc-234" joins ABC234).
static func normalize_code(code: String) -> String:
	return code.strip_edges().to_upper().replace(" ", "").replace("-", "")


## True for a code the protocol accepts (6 characters of NetCodec.CODE_ALPHABET).
static func is_valid_code(code: String) -> bool:
	if code.length() != NetCodec.CODE_LEN:
		return false
	for c in code:
		if not NetCodec.CODE_ALPHABET.contains(c):
			return false
	return true


func _set_state(s: State) -> void:
	if s == state:
		return
	state = s
	state_changed.emit(s)
