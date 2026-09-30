extends WBTest
## The HUD in the loop test mode (N3.2). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Time of
## day in multiplayer ("HUD: the sun bar is replaced by a small clock showing time until
## night or dawn"), Scoring in multiplayer ("Sectors replace checkpoints").

const HUD_SCENE := "res://src/ui/hud/hud.tscn"
const SCREEN := Rect2(0.0, 0.0, 1280.0, 720.0)
const DT := 1.0 / 60.0

var hud: Hud
var feed: HudFeed
var loop_feed: HudLoopFeed


func before_each() -> void:
	Settings.reset_to_defaults()
	hud = (load(HUD_SCENE) as PackedScene).instantiate() as Hud
	hud.auto_process = false
	hud.set_screen(SCREEN, SCREEN)
	tree.root.add_child(hud)
	feed = HudFeed.new()
	feed.top_speed_mps = 70.0
	feed.checkpoint_distance_m = 2000.0
	hud.bind(feed)
	loop_feed = HudLoopFeed.new()
	hud.advance(DT)


func after_each() -> void:
	if hud != null:
		hud.free()
		hud = null
	Settings.reset_to_defaults()


func _loop_values(night: bool, flip_in_s: float, sector_m: float) -> void:
	loop_feed.active = true
	loop_feed.cycle_frac = 0.5
	loop_feed.day_frac = 22.0 / 32.0
	loop_feed.night = night
	loop_feed.flip_in_s = flip_in_s
	loop_feed.sector_distance_m = sector_m


func test_clock_replaces_the_sun_bar() -> void:
	check(not hud.clock_shown(), "the journey: the sun bar")
	eq(hud.checkpoint_text(), "2.0")
	_loop_values(false, 754.2, 3100.0)
	hud.bind_loop(loop_feed)
	hud.advance(DT)
	check(hud.clock_shown(), "loop mode: the room clock")
	eq(hud.clock_text(), "12:35", "time until night")
	eq(hud.checkpoint_text(), "3.1", "the next sector gantry")
	loop_feed.flip_in_s = 754.0
	hud.advance(DT)
	eq(hud.clock_text(), "12:34")
	var changes := hud.change_count()
	loop_feed.flip_in_s = 753.95
	hud.advance(DT)
	eq(hud.change_count(), changes, "nothing redraws within the same second")
	_loop_values(true, 59.0, 800.0)
	hud.advance(DT)
	eq(hud.clock_text(), "0:59", "time until the day")
	hud.bind_loop(null)
	hud.advance(DT)
	check(not hud.clock_shown(), "unbound: the sun bar again")
	eq(hud.checkpoint_text(), "2.0")


func test_toast_names_sectors_and_laps() -> void:
	_loop_values(false, 600.0, 3000.0)
	loop_feed.sectors = 6
	hud.bind_loop(loop_feed)
	hud.advance(DT)
	# Lap 1, gantry 1: leg index 1 x 6 + 1 + 1 = 8; the next sector starts there.
	Events.checkpoint_crossed.emit(8, {RunEvents.SUMMARY_CLEAN: true})
	Events.leg_started.emit(9, &"desert", &"")
	hud.advance(DT)
	var lines := hud.toast_lines()
	eq(lines[0], "SECTOR 1 COMPLETE")
	check(_has_prefix(lines, "SECTOR 2 — DESERT"), "the next sector: %s" % lines)
	_run(3.0)
	# Lap 2's gantry 0 (2 x 6 + 1 = 13) ends lap 1.
	Events.checkpoint_crossed.emit(13, {RunEvents.SUMMARY_CLEAN: true})
	Events.leg_started.emit(14, &"desert", &"")
	hud.advance(DT)
	lines = hud.toast_lines()
	eq(lines[0], "LAP 1 COMPLETE")
	check(_has_prefix(lines, "SECTOR 1 — DESERT"), "%s" % lines)
	_run(3.0)
	# Gantry 5 of lap 1 (6 + 5 + 1 = 12).
	Events.checkpoint_crossed.emit(12, {RunEvents.SUMMARY_CLEAN: true})
	Events.leg_started.emit(13, &"farmland", &"")
	hud.advance(DT)
	lines = hud.toast_lines()
	eq(lines[0], "SECTOR 5 COMPLETE")
	check(_has_prefix(lines, "SECTOR 6 — FARMLAND"), "%s" % lines)


func _run(seconds: float) -> void:
	for i in ceili(seconds / DT):
		hud.advance(DT)


func _has_prefix(lines: PackedStringArray, prefix: String) -> bool:
	for l in lines:
		if l.begins_with(prefix):
			return true
	return false
