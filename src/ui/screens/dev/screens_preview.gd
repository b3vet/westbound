extends Node
## Screens review scene (WP4.4). Spec: UI → Screens (countdown with gyro calibration,
## pause menu and settings, results with the personal-best comparison), Run end.
## docs/SCREENS.md → Preview.
##
## The real run (src/run/run.tscn: world, car, traffic, HUD and its RunScreens) put in
## a state, with the screen frozen at a step so the snap shows it settled.
##
##   tools/snap.sh src/ui/screens/dev/screens_preview.tscn --renderer=both --screen=results_best
##   tools/snap.sh src/ui/screens/dev/screens_preview.tscn --screen=countdown --step=3 --gyro
##   tools/snap.sh src/ui/screens/dev/screens_preview.tscn --size=2496x1320 --screen=pause   # iPhone
##
## snap_setup options: --screen=countdown|pause|settings|results|results_best|crash|hold|
## warmup (WP8.1: the first run's warm-up hint, --warmup_s= seconds into it)
## (default countdown), --step=3|2|1|0 (countdown; 0 = GO), --gyro (calibration card,
## RECALIBRATE), --hand=right|left, --text_scale=1|1.25, --units=kmh|mph, --sky_t=<0..1>,
## --reduced_motion, --dev (keep the dev rows and dev HUD), --page=game|controls|audio|
## chooser (settings: the page shown; WP8.1). Prints the screens' visible canvas items
## ("snap: ...").

const RUN_SCENE := preload("res://src/run/run.tscn")
const SNAP_SEED := 20260929
const SKY_T := 0.3
const FAKE_SCORE := 1_284_500
const FAKE_BEST := 2_010_000
const FAKE_NEW_SCORE := 2_346_900

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
	Settings.set_value(&"units", StringName(String(args.get("units", "kmh"))))
	Settings.set_value(&"reduced_motion", bool(args.get("reduced_motion", false)))
	var screen := String(args.get("screen", "countdown"))
	var run_state := "running"
	match screen:
		"countdown", "hold":
			run_state = "countdown"
		"pause", "settings":
			run_state = "paused"
		"results", "results_best", "crash":
			run_state = "results" if screen != "crash" else "running"
		"warmup":
			run_state = "running"
	run.snap_setup({"state": run_state, "sky_t": float(args.get("sky_t", SKY_T)),
			"s": float(args.get("s", 900.0)), "speed_kmh": 180.0})
	var screens := run.screens
	# The review is of the screens: the dev overlays (rows, dev HUD) step aside.
	if not bool(args.get("dev", false)):
		run.dev.controls.visible = false
		(run.get_node(^"DevHud") as CanvasLayer).visible = false
	var gyro := bool(args.get("gyro", false))
	match screen:
		"countdown", "hold":
			run.auto_countdown = false
			screens.countdown.set_gyro(gyro)
			if screen == "hold":
				screens.countdown.set_gyro(true)
				screens.countdown.set_hold(true)
			else:
				screens.countdown.show_step(int(args.get("step", 3)))
		"pause", "settings":
			screens.pause_screen.set_gyro(gyro)
			if screen == "settings":
				screens.pause_screen.open_settings()
				var sp := screens.pause_screen.settings
				match String(args.get("page", "game")):
					"controls":
						sp.show_page(SettingsPanel.PAGE_CONTROLS)
					"audio":
						sp.show_page(SettingsPanel.PAGE_AUDIO)
					"chooser":
						sp.toggle_chooser()
		"results":
			screens.show_results(_payload(FAKE_SCORE, FAKE_BEST, false))
		"results_best":
			screens.show_results(_payload(FAKE_NEW_SCORE, FAKE_BEST, true))
		"warmup":
			# A fresh save's first Journey from the title (in memory: nothing is written).
			Save.first_run_enabled = true
			Save.reset_fresh()
			Settings.set_value(&"text_scale", float(args.get("text_scale", 1.0)))
			Settings.set_value(&"left_handed", String(args.get("hand", "right")) == "left")
			run.start_mode(RunContext.MODE_JOURNEY)
			run.go()
			run.sky.sky_t = float(args.get("sky_t", SKY_T))
			for i in roundi(float(args.get("warmup_s", 3.0)) * float(run.tuning.vehicle.physics_tick_hz)):
				await get_tree().physics_frame
		"crash":
			run.lives.lives = 1
			run.force_hit(HitDetection.HIT_TRAFFIC, -1, 1)
			for i in 4:
				await get_tree().physics_frame
			screens.crash_screen.show_hint_now()
	if screen == "countdown" or screen == "hold":
		screens.countdown.freeze()   # settled on the step (GO would fade out)
	else:
		screens.finish_animations()
	await get_tree().process_frame
	print("snap: screen=%s visible_screens=%d items=%d" % [screen, screens.visible_screen_count(),
			screens.visible_item_count()])


func _payload(score: int, best_before: int, new_best: bool) -> Dictionary:
	return {
		RunStats.SCORE: score,
		RunStats.DISTANCE_M: 14_380.0,
		RunStats.LEGS_COMPLETED: 4,
		RunStats.COAST_REACHED: false,
		RunStats.BEST_CHAIN: 186_400,
		RunStats.BEST_MULTIPLIER: 24.6,
		RunStats.THREADS: 7,
		RunStats.CLOSE_PASSES: 58,
		RunStats.TOP_SPEED_KMH: 287.4,
		RunStats.NIGHT_TIME_S: 96.0,
		RunStats.HITS: 2,
		RunStats.SEED: SNAP_SEED,
		RunStats.MODE: RunContext.MODE_JOURNEY,
		&"personal_best": maxi(score, best_before),
		&"new_best": new_best,
		&"previous_best": best_before,
	}
