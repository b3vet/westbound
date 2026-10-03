extends Node
## Party review scene (WP N9.3): the online hub's PARTY (none, leader with members, a
## member's view, the leader arming a removal), a PARTY INVITE, an invite link being
## followed, the hub's party line, and the room menu's ROOM tab (the invite link, the
## host's TRAFFIC / TIME OF DAY / REMOVE A PLAYER, a player's locked view). Spec:
## multiplayer handoff → Rooms, parties and matchmaking (Parties, Private rooms: invite
## links, host rules), Client changes (Party panel; Room menu: invite, host settings).
## docs/SCREENS.md → Online hub → Party (N9.3).
##
## The real run (src/run/run.tscn) on the title with a server-less rooms service, or in
## the demo room (`--room=demo`, RunRoom.snap_room) for the room menu.
##
##   tools/snap.sh src/ui/screens/dev/party_preview.tscn --renderer=both --sweep=party:none,lead,member,kick,invite,link,hub,room_host,room_player
##   tools/snap.sh src/ui/screens/dev/party_preview.tscn --size=2496x1320 --text_scale=1.25 --party=lead
##
## Protocol 2 (room and crew invites, docs/ROOMS_CLIENT.md → Room invites):
##   tools/snap.sh src/ui/screens/dev/party_preview.tscn --renderer=both --sweep=party:card,toast,crew_line
##   tools/snap.sh src/ui/screens/dev/party_preview.tscn --renderer=both --seconds=2.5 --sweep=party:room_invites
##
## snap_setup options: --party=none|lead|member|kick|invite|link|hub|room_host|room_player|
## card|toast|crew_line|room_invites (default lead), --text_scale=1|1.25,
## --hand=right|left, --sky_t=<0..1>.

const RUN_SCENE := preload("res://src/run/run.tscn")
const SNAP_SEED := 20260929
const SKY_T := 0.3
const CODE := "K7QX2M"
const LINK := "https://westbound.sipsakrandevu.com/r/K7QX2M"
const MEMBERS: Array[Array] = [["Dusty", 1234], ["You", 1], ["Şahin 34", 42], ["LoneWolf", 7],
	["Mira", 2718], ["Kestrel", 31]]

var run: Run


func _ready() -> void:
	run = RUN_SCENE.instantiate() as Run
	run.run_seed = SNAP_SEED
	run.record_best = false
	add_child(run)


## tools/snap.sh hook.
func snap_setup(args: Dictionary) -> void:
	Settings.reset_to_defaults()
	Settings.set_value(&"left_handed", String(args.get("hand", "right")) == "left")
	Settings.set_value(&"text_scale", float(args.get("text_scale", 1.0)))
	var what := String(args.get("party", "lead"))
	if what.begins_with("room"):
		_room_menu(what, args)
		return
	run.snap_setup({"state": "menu", "sky_t": float(args.get("sky_t", SKY_T)), "title": "hub"})
	run.dev.controls.visible = false
	(run.get_node(^"DevHud") as CanvasLayer).visible = false
	var hub := run.title.online_hub
	var rooms := NetRooms.new()
	rooms.standalone = true
	var link := NetLoopbackLink.new(NetTimeSource.new(), Rng.new(1))
	rooms.set_meta(&"demo_link", link)   # the endpoints only hold weak references
	rooms.setup(null, link.client, NetTuning.load_default(), null, RunLoop.loop_road(run.tuning).length())
	rooms.set_process(false)
	add_child(rooms)
	hub.rooms = rooms
	hub._bind_session()
	var p := rooms.session.party
	p.me = "2"
	match what:
		"lead", "kick", "hub":
			_party(p, "2")
		"member":
			_party(p, "1")
		"invite":
			p.add_invite({"from": {"account_id": "1", "display_name": "Dusty", "name_tag": 1234}, "code": CODE},
				0.0, 4)
		"card", "toast":
			rooms.session.room_invites.add({"from": {"account_id": "1", "display_name": "Dusty", "name_tag": 1234},
				"code": CODE, "room_id": 12, "visibility": "private", "players": 3, "max_players": 8,
				"expires_in_s": 600}, 0.0, 4)
		"crew_line":
			var sc := _social()
			var inv := NetCrew.Invite.new()
			inv.invite_id = "9"
			inv.crew_name = "Night Riders"
			inv.crew_tag = "NR"
			inv.from_name = "Dusty#1234"
			sc.crew_invites.append(inv)
			hub.social_client = sc
			hub.open()
	hub.refresh()
	match what:
		"none", "lead", "member":
			hub.open_party()
		"kick":
			hub.open_party()
			hub.lobby._tap_member(0)
		"invite":
			hub.open_party()
		"link":
			hub._open_lobby()
			hub.lobby.follow_link(CODE)
		"card":
			hub._process(0.0)
		"toast":
			run.title.open_title()
			run.title.invite_toast.rooms = rooms
			run.title.invite_toast.advance(0.0)
	run.title.finish_animations()


## A social client with online friends and crewmates, no server (previews only).
func _social() -> NetSocialClient:
	var t := NetTuning.load_default()
	var sc := NetSocialClient.new(NetApi.new(NetFakeSocial.new(), t, "https://preview.invalid/api/v1"), t)
	var names: Array[Array] = [["Dusty", 1234], ["Şahin 34", 42], ["LoneWolf", 7], ["WWWWWWWWWWWWWWWW", 8888]]
	for i in names.size():
		var f := NetSocialPlayer.new()
		f.account_id = str(100 + i)
		f.display_name = String(names[i][0])
		f.tag = int(names[i][1])
		f.full_name = "%s#%04d" % [f.display_name, f.tag]
		f.status = NetSocialPlayer.ONLINE
		sc.friends.append(f)
	sc.friends_loaded = true
	var crew := NetCrew.new()
	crew.crew_id = "5"
	crew.name = "Night Riders"
	crew.tag = "NR"
	for pair: Array in [["Mira", 2718], ["Kestrel", 31]]:
		var m := NetSocialPlayer.new()
		m.account_id = "2%s" % pair[1]
		m.display_name = String(pair[0])
		m.tag = int(pair[1])
		m.full_name = "%s#%04d" % [m.display_name, m.tag]
		m.status = NetSocialPlayer.ONLINE
		crew.members.append(m)
	sc.crew = crew
	return sc


func _party(p: NetParty, leader: String) -> void:
	var members: Array[Dictionary] = []
	for i in MEMBERS.size():
		members.append({"account_id": str(i + 1), "display_name": MEMBERS[i][0], "name_tag": MEMBERS[i][1]})
	p.apply_state({"code": CODE, "leader": leader, "members": members})


## The demo room with the room menu on ROOM: as host, or as a player.
func _room_menu(what: String, args: Dictionary) -> void:
	run.snap_setup({"mode": "loop", "at": "desert", "room": "demo", "remotes": 3, "speed_kmh": 150.0,
		"sky_t": float(args.get("sky_t", SKY_T))})
	run.dev.controls.visible = false
	(run.get_node(^"DevHud") as CanvasLayer).visible = false
	var rs := run.room.session
	if what == "room_host":
		rs.room.host_id = rs.room.you
		for m in rs.room.members:
			m.host = m.player_id == rs.room.you
		rs.room.version += 1
	var menu := run.room.hud.menu
	menu.invite_url = LINK
	if what == "room_invites":
		menu.social = _social()
		menu.open(RoomMenu.Tab.INVITE)
		menu.refresh()
	else:
		menu.open(RoomMenu.Tab.ROOM)
	run.room.frame(0.0)
