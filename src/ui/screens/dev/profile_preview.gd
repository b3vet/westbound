extends Node
## Profile panel review scene (WP N1.2). Spec: multiplayer handoff → Client changes
## (Profile and account); plan MP-D2. docs/NET_CLIENT.md → Profile panel.
##
## The real run (src/run/run.tscn) paused, SETTINGS → ACCOUNT open, on a NetSession of
## its own backed by the in-memory accounts server (NetFakeAccounts): no network.
##
##   tools/snap.sh src/ui/screens/dev/profile_preview.tscn --renderer=both
##   tools/snap.sh src/ui/screens/dev/profile_preview.tscn --sweep=net:online,error,confirm,offline,failed,banned
##   tools/snap.sh src/ui/screens/dev/profile_preview.tscn --size=2496x1320 --text_scale=1.25
##
## snap_setup options: --net=online|error|saved|confirm|deleted|offline|failed|banned
## (default online), --text_scale=1|1.25, --hand=right|left, --sky_t=<0..1>.

const RUN_SCENE := preload("res://src/run/run.tscn")
const SNAP_SEED := 20260929
const SKY_T := 0.3
const PREVIEW_NAME := "Road Runner"
const TAKEN_TRY := "Rude Rider"
const BAN_DAYS := 7
const S_PER_DAY := 86400

var run: Run
var fake := NetFakeAccounts.new()
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
	var net := String(args.get("net", "online"))
	await _prepare(net)
	run.snap_setup({"state": "paused", "sky_t": float(args.get("sky_t", SKY_T)),
			"s": 900.0, "speed_kmh": 180.0})
	run.dev.controls.visible = false
	(run.get_node(^"DevHud") as CanvasLayer).visible = false
	var pause := run.screens.pause_screen
	pause.open_settings()
	pause.toggle_account()
	var p := pause.profile
	match net:
		"error":
			p.name_edit.text = TAKEN_TRY
			await p.save()
			p.name_edit.text = TAKEN_TRY
		"saved":
			p.name_edit.text = PREVIEW_NAME
			await p.save()
		"confirm":
			p.ask_delete()
		"deleted":
			p.ask_delete()
			await p.confirm_delete()
	run.screens.finish_animations()
	await get_tree().process_frame
	print("snap: net=%s status=%s name=%s" % [net, NetSession.Status.keys()[session.status],
			p.name_text.text + p.tag_text.text])


func _prepare(net: String) -> void:
	match net:
		"offline":
			fake.offline = true
			await session.start()
		"failed":
			await session.start()
			(fake.accounts[session.account_id()] as Dictionary)["secret"] = "rotated"
			for t: String in fake.refresh_tokens:
				(fake.refresh_tokens[t] as Dictionary)["revoked"] = true
			await session.retry()
		"banned":
			await session.start()
			fake.ban(session.account_id(), int(fake.now_s) + BAN_DAYS * S_PER_DAY)
			await session.retry()
		_:
			await session.start()


## Memory storage that reads as saved (the panel's normal note).
class PreviewStore:
	extends NetSessionStore

	func is_persistent() -> bool:
		return true
