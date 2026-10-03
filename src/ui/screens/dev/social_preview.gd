extends Node
## Social screens review scene (WP N9.2): the friends list, the crew page and the report
## dialog. Spec: multiplayer handoff → Friends and presence, Crews (persistent),
## Moderation → Report, Client changes. docs/SCREENS.md → Social.
##
## The real run (src/run/run.tscn) paused, SETTINGS → ACCOUNT → a social tab open, on a
## NetSession of its own backed by the in-memory Social API (NetFakeSocial): no network.
##
##   tools/snap.sh src/ui/screens/dev/social_preview.tscn --renderer=both
##   tools/snap.sh src/ui/screens/dev/social_preview.tscn --sweep=social:friends,sheet,blocked,crew,member,crew_none,report
##   tools/snap.sh src/ui/screens/dev/social_preview.tscn --size=2496x1320 --text_scale=1.25 --social=crew
##
## snap_setup options: --social=friends|sheet|confirm|error|blocked|crew|member|
## crew_confirm|crew_none|crew_error|report|report_confirm|report_sent|report_limited|
## crew_invite_friends|crew_invites|crew_pending (default friends), --text_scale=1|1.25,
## --hand=right|left, --sky_t=<0..1>, --text_entry=name|tag|code|friend (the text entry
## overlay open on that field, as on a phone with an OS keyboard; docs/SCREENS.md →
## Social → Text fields):
##   tools/snap.sh src/ui/screens/dev/social_preview.tscn --size=1688x780 --social=crew_none --text_entry=name
##
## Crew invites (protocol 2): --sweep=social:crew_invite_friends,crew_invites,crew_pending

const RUN_SCENE := preload("res://src/run/run.tscn")
const SNAP_SEED := 20260929
const SKY_T := 0.3
const ROOM_ID := 12
const SEASON_SCORE := 1_832_400
const RIVAL_SCORE := 2_410_000

var run: Run
var fake := NetFakeSocial.new()
var session: NetSession


func _ready() -> void:
	session = NetSession.new()
	session.auto_start = false
	session.configure(fake, PreviewStore.new(), NetTuning.load_default(), null,
			"https://preview.invalid/api/v1", SNAP_SEED)
	session.unix_clock = func() -> float: return fake.now_s
	add_child(session)
	run = RUN_SCENE.instantiate() as Run
	run.run_seed = SNAP_SEED
	run.record_best = false
	add_child(run)


## tools/snap.sh hook.
func snap_setup(args: Dictionary) -> void:
	Settings.reset_to_defaults()
	Settings.set_value(&"left_handed", String(args.get("hand", "right")) == "left")
	Settings.set_value(&"text_scale", float(args.get("text_scale", 1.0)))
	var what := String(args.get("social", "friends"))
	await session.start()
	var me := session.account_id()
	_seed_world(me, what)
	run.snap_setup({"state": "paused", "sky_t": float(args.get("sky_t", SKY_T)),
			"s": 900.0, "speed_kmh": 180.0})
	run.dev.controls.visible = false
	(run.get_node(^"DevHud") as CanvasLayer).visible = false
	var pause := run.screens.pause_screen
	pause.open_settings()
	pause.toggle_account()
	var p := pause.profile
	var crew_view := what.begins_with("crew") or what == "member"
	p.show_view(ProfilePanel.View.CREW if crew_view else ProfilePanel.View.FRIENDS)
	var fp := p.friends
	var cp := p.crew
	if crew_view:
		await cp.load_crew()
	match what:
		"sheet", "confirm":
			fp._select(_friend(fp, "Şahin 34"), FriendsPanel.K_FRIEND)
			if what == "confirm":
				fp.sheet.press(FriendsPanel.A_BLOCK)
		"error":
			fp.field.text = "Nobody#0001"
			await fp.send()
			fp.field.text = "Nobody#0001"
		"blocked":
			fp.toggle_mode()
		"member", "crew_confirm":
			if what == "member":
				cp.select(cp.client.crew.members[2])
			else:
				cp.crew_actions.press(CrewPanel.A_LEAVE)
		"crew_invite_friends":
			cp.toggle_inviting()
			await cp.invite_friend(cp.client.crew_invitable()[0])
		"crew_error":
			cp.name_field.text = "Rude Boys"
			cp.tag_field.text = "RB"
			await cp.create()
			cp.code_field.text = "K7QX2M9P"
			await cp.join()
		"report", "report_confirm", "report_sent", "report_limited":
			if what == "report_limited":
				fake.reports_per_day = 0
			fp._select(_friend(fp, "LoneWolf"), FriendsPanel.K_FRIEND)
			fp.sheet.press(FriendsPanel.A_REPORT)
			var rd := p.report
			rd.choose("harassment")
			if what != "report":
				rd.send()
			if what == "report_sent" or what == "report_limited":
				await rd.confirm()
	run.screens.finish_animations()
	_open_entry(String(args.get("text_entry", "")), fp, cp)
	await get_tree().process_frame
	print("snap: social=%s view=%d rows=%d crew=%s" % [what, p.view, fp.rows.size(),
			cp.client.crew.tag if cp.client != null and cp.client.crew != null else "-"])


## The text entry overlay open on one field, with a little typed.
func _open_entry(which: String, fp: FriendsPanel, cp: CrewPanel) -> void:
	var fields := {"name": cp.name_field, "tag": cp.tag_field, "code": cp.code_field, "friend": fp.field}
	var texts := {"name": "Night Riders", "tag": "NR", "code": "K7QX", "friend": "LoneWolf#0007"}
	if not fields.has(which):
		return
	var f: SocialField = fields[which]
	f.entry_mode = 1
	f.text = String(texts[which])
	f.open_entry()


func _friend(fp: FriendsPanel, display: String) -> NetSocialPlayer:
	for f in fp.client.friends:
		if f.display_name == display:
			return f
	return fp.client.friends[0]


## Friends in every presence state, a request each way, a block, and (for the crew views)
## a crew with every role on the Loop crew board.
func _seed_world(me: String, what: String) -> void:
	var names: Array[String] = ["Şahin 34", "LoneWolf", "Night_Owl.77", "Dusty", "Maximilian Rider", "Zoë"]
	var tags: Array[int] = [34, 7, 1990, 412, 8, 5]
	var ids: Array[String] = []
	for i in names.size():
		ids.append(fake.add_player(names[i], tags[i]))
	fake.befriend(me, ids[0])
	fake.befriend(me, ids[1])
	fake.befriend(me, ids[2])
	fake.befriend(me, ids[3])
	fake.set_presence(ids[0], "in_room", ROOM_ID, true)
	fake.set_presence(ids[1], "online")
	fake.set_presence(ids[2], "in_room", ROOM_ID, false)
	fake.add_request(ids[4], me)
	fake.add_request(me, ids[5])
	var rival := fake.add_player("Road Hog", 66)
	fake.block_pair(me, rival)
	var other := fake.make_crew(ids[1], "Sundowners", "SUN")
	fake.crew_scores[other] = RIVAL_SCORE
	if what == "crew_invites" or what == "crew_pending":
		var kings := fake.make_crew(ids[5], "Coastline Kings", "CK")
		fake.add_crew_invite(other, me, ids[1])
		fake.add_crew_invite(kings, me, ids[5])
	if what == "crew_invite_friends":
		for pair: Array in [["Kestrel", 31], ["Mira", 2718]]:
			var id := fake.add_player(String(pair[0]), int(pair[1]))
			fake.befriend(me, id)
			fake.set_presence(id, "online")
	if what == "crew_none" or what == "crew_error" or what == "crew_invites":
		return
	var cid := fake.make_crew(me, "Night Riders", "NR")
	fake.add_member(cid, ids[0], NetCrew.OFFICER)
	fake.add_member(cid, ids[2])
	fake.add_member(cid, ids[3])
	fake.crew_scores[cid] = SEASON_SCORE


## Memory storage that reads as saved.
class PreviewStore:
	extends NetSessionStore

	func is_persistent() -> bool:
		return true
