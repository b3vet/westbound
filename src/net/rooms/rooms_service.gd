class_name NetRooms
extends Node
## The rooms service: one NetRoomSession on the session's WebSocket, polled every frame
## (also while the game is paused). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Rooms,
## parties and matchmaking; Client changes (`lobby.gd`, `room_client.gd`). docs/ROOMS_CLIENT.md.
## WP N5.2.
##
##   var rooms := NetRooms.ensure()          # null: online is off (?server=off, dev runs)
##   if rooms == null or not rooms.available(): show NetRooms.unavailable_text()
##   rooms.session.joined.connect(...)       # then quick_join() / create_room() / ...
##   rooms.quick_join()
##
## A child of the NetSession (like NetRunsClient), so it lives as long as the account and
## processes always. Joins wait for a fresh access token first (NetSession.fresh_access_token);
## reconnects take the current one. The loop's length comes from the committed map.

const TEXT_OFF := "Rooms need the online server. Loop practice still works."
const TEXT_OFFLINE := "You're offline. Rooms need a connection."
const TEXT_SIGNING_IN := "Signing in..."

static var current: NetRooms

var net_session: NetSession
var session: NetRoomSession
## Created without a session (tests, previews): nothing gates on the account.
var standalone: bool = false


## The live service for NetSession.current (created on first use), or null when online
## features are off.
static func ensure() -> NetRooms:
	if current != null and is_instance_valid(current):
		return current
	var s := NetSession.current
	if s == null or not is_instance_valid(s) or not s.is_inside_tree() or s.tuning == null or s.base_url.is_empty():
		return null
	var r := NetRooms.new()
	r.setup(s, NetWsTransport.new(s.tuning), s.tuning)
	s.add_child(r)
	return r


## The text the hub shows when rooms can't be used ("" when they can).
static func unavailable_text() -> String:
	var r := ensure()
	if r == null:
		return TEXT_OFF
	return r.why_unavailable()


func _init() -> void:
	name = "NetRooms"
	process_mode = Node.PROCESS_MODE_ALWAYS


## `transport` carries the room connection; `loop_length_m` < 0 = the committed loop's.
func setup(s: NetSession, transport: NetTransport, net_tuning: NetTuning, time: NetTimeSource = null,
		loop_length_m: float = -1.0) -> void:
	net_session = s
	var l := loop_length_m if loop_length_m >= 0.0 else RunLoop.loop_road(Tuning.load_default()).length()
	session = NetRoomSession.new(transport, net_tuning, l, time)
	var url := s.ws_url() if s != null else net_tuning.server_url
	var tokens := s.access_token if s != null else func() -> String: return ""
	session.configure(url, net_tuning.client_build, MapInfo.loop_hash(), tokens)
	# N9.3: friends presence rides on this connection whenever it is up (N5.2 left
	# NetSocialClient.attach_lobby unwired; the friends list polls only without it).
	var social := NetSocialClient.of(s)
	if social != null:
		social.attach_lobby(session.client)


func _enter_tree() -> void:
	if current == null or not is_instance_valid(current):
		current = self


func _exit_tree() -> void:
	if current == self:
		current = null
	if session != null:
		session.close()


func _process(_delta: float) -> void:
	if session != null:
		session.poll()


## True when a join can start (signed in, or standalone).
func available() -> bool:
	return why_unavailable().is_empty()


func why_unavailable() -> String:
	if standalone or net_session == null:
		return "" if session != null else TEXT_OFF
	match net_session.status:
		NetSession.Status.ONLINE:
			return ""
		NetSession.Status.CONNECTING, NetSession.Status.IDLE:
			return TEXT_SIGNING_IN
		NetSession.Status.DISABLED:
			return TEXT_OFF
	return TEXT_OFFLINE


func quick_join() -> void:
	await _fresh_token()
	session.quick_join()


func create_room(density: String, time_mode: String, fixed_cycle_ms: int = 0) -> void:
	await _fresh_token()
	session.create_room(density, time_mode, fixed_cycle_ms)


func join_code(code: String) -> void:
	await _fresh_token()
	session.join_code(code)


func join_id(room_id: int) -> void:
	await _fresh_token()
	session.join_id(room_id)


func browse() -> void:
	await _fresh_token()
	session.browse()


## N9.3: the party (docs/ROOMS_CLIENT.md → Parties). Each connects first when needed.
func party_create() -> void:
	await _fresh_token()
	session.party_create()


func party_join(code: String) -> void:
	await _fresh_token()
	session.party_join(code)


func party_invite(account_id: String) -> void:
	await _fresh_token()
	session.party_invite(account_id)


func party_leave() -> void:
	session.party_leave()


func party_kick(account_id: String) -> void:
	session.party_kick(account_id)


## The lobby connection alone (presence and party events while the hub shows).
func connect_lobby() -> void:
	if not available():
		return
	await _fresh_token()
	session.connect_lobby()


## The invite link for a room or party code (`https://<domain>/r/<code>`), "" without a
## server.
func invite_url(code: String) -> String:
	var base := net_session.base_url if net_session != null else ""
	if base.is_empty() or code.is_empty():
		return ""
	return NetRoomSession.invite_url(base, code, session.tuning.invite_path)


## A token good for the next hour before a new connection (renews when near expiry).
func _fresh_token() -> void:
	if net_session != null and not session.client.is_ready():
		await net_session.fresh_access_token()
