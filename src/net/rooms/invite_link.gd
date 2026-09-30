class_name NetInviteLink
extends RefCounted
## Invite links (N9.3). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Rooms, parties and
## matchmaking → Private rooms ("The creator gets a code and an invite link
## `https://<domain>/r/<code>`. The link opens the app through Universal Links (iOS) and
## App Links (Android), or the web build directly"). docs/SERVER.md → Invite links and deep
## links; docs/ROOMS_CLIENT.md → Parties → Invite links.
##
## The server's `/r/<code>` page opens the web build with `?room=<code>`; a native build
## takes `--room=<code>` (and, once the owner sets up Universal Links / App Links, the OS
## hands the app the link: `from_url()` reads it). The code is a room's or a party's: the
## hub joins the room and, when no room has that code, the party (RoomLobbyPanel.follow_link).
##
##   var code := NetInviteLink.take()      # "" when there is none (or it was taken)
##
## `--room=demo` (the snap tools' demo room) is not a code and is ignored.

const PARAM := "room"
const ARG := "--room="

## The pending code, read once from the page URL or the command line.
static var _pending: String = ""
static var _read: bool = false


## The code the game was opened with, once ("" afterwards, and when there is none).
static func take() -> String:
	var c := peek()
	_pending = ""
	return c


## The pending code without taking it.
static func peek() -> String:
	if not _read:
		_read = true
		_pending = from_boot(NetJsBridge.new(), OS.get_cmdline_user_args(), OS.get_cmdline_args())
	return _pending


## Tests and the native link handler: `code` becomes the pending one ("" clears it).
static func set_pending(code: String) -> void:
	_read = true
	var c := NetRoomSession.normalize_code(code)
	_pending = c if NetRoomSession.is_valid_code(c) else ""


## `?room=` on the web, else a `--room=` argument; a valid code or "".
static func from_boot(bridge: NetJsBridge, user_args: PackedStringArray, args: PackedStringArray) -> String:
	var raw := ""
	if bridge != null and bridge.available():
		raw = bridge.query_param(PARAM)
	if raw.is_empty():
		for list: PackedStringArray in [user_args, args]:
			for a in list:
				if a.begins_with(ARG):
					raw = a.substr(ARG.length())
			if not raw.is_empty():
				break
	var c := NetRoomSession.normalize_code(raw)
	return c if NetRoomSession.is_valid_code(c) else ""


## The code in an invite link (`https://<domain>/r/<code>`, `<scheme>://r/<code>`, with or
## without a trailing slash or query), or "".
static func from_url(url: String, path: String = "/r/") -> String:
	var u := url.strip_edges()
	var q := u.find("?")
	if q >= 0:
		u = u.left(q)
	u = u.trim_suffix("/")
	var at := u.rfind(path)
	if at < 0:
		var bare := path.trim_prefix("/")
		if u.contains("://" + bare):
			at = u.find("://" + bare) + 2
		else:
			return ""
	var c := NetRoomSession.normalize_code(u.substr(at + path.length()))
	return c if NetRoomSession.is_valid_code(c) else ""
