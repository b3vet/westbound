extends Node
## Achievements review scene (WP8.3). Spec: Garage and progression (Achievements); UI →
## Screens. docs/ACHIEVEMENTS.md → Preview.
##
## The real run (src/run/run.tscn) with its achievement service (the title attaches it),
## the save in memory (nothing is written), either on the title with the achievements
## screen open, or driving with an unlock toast on show.
##
##   tools/snap.sh src/ui/screens/dev/achievements_preview.tscn --renderer=both --view=screen
##   tools/snap.sh src/ui/screens/dev/achievements_preview.tscn --view=screen --tab=1 --text_scale=1.25
##   tools/snap.sh src/ui/screens/dev/achievements_preview.tscn --renderer=both --view=toast --id=top_speed_300
##   tools/snap.sh src/ui/screens/dev/achievements_preview.tscn --size=2496x1320 --view=toast   # iPhone
##
## snap_setup options: --view=screen|toast (default screen), --tab=0|1|2, --save=mixed|
## locked|unlocked (default mixed: some unlocked, some in progress, hidden ones),
## --id=<achievement id> (the toast; default top_speed_300), --text_scale=1|1.25,
## --units=kmh|mph, --hand=right|left, --sky_t=<0..1>. Prints "snap: ...".

const RUN_SCENE := preload("res://src/run/run.tscn")
const SNAP_SEED := 20260929
const SKY_T := 0.3
## The mixed save: unlocked ids and progress (metric: value in tracker units).
const MIXED_UNLOCKED: Array[String] = ["first_thread", "threads_run", "first_leg", "halfway", "night_thread",
		"new_wheels", "daily_driver", "multiplier_50"]
const MIXED_PROGRESS := {"threads_run": 14.0, "close_passes_run": 17.0, "multiplier_run": 62.4,
		"top_speed_run": 80.2, "leg_run": 5.0, "clean_legs_run": 2.0, "threads_total": 64.0,
		"set_pieces_total": 6.0, "objectives_total": 7.0, "chain_run": 31_250.0, "score_run": 284_600.0}

var run: Run


func _ready() -> void:
	AchievementService.attach_under_tools = true
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
	_fill_save(String(args.get("save", "mixed")))
	var svc := AchievementService.current
	if svc != null:
		svc.haptic_tick = false
		svc.bind_save()
	var view := String(args.get("view", "screen"))
	if view == "toast":
		run.snap_setup({"state": "running", "sky_t": float(args.get("sky_t", SKY_T)), "s": 900.0, "speed_kmh": 180.0})
		run.dev.controls.visible = false
		(run.get_node(^"DevHud") as CanvasLayer).visible = false
		if svc != null:
			svc.preview_toast(StringName(String(args.get("id", "top_speed_300"))))
			svc.toast.advance(svc.tuning.toast_in_s)   # settled, fully in
		print("snap: view=toast showing=%s rect=%s" % [svc != null and svc.toast.showing(),
				svc.toast.toast_rect if svc != null else Rect2()])
		return
	run.snap_setup({"state": "menu", "sky_t": float(args.get("sky_t", SKY_T))})
	(run.get_node(^"DevHud") as CanvasLayer).visible = false
	run.title.open_achievements()
	run.title.achievements.snap_setup(args)
	await get_tree().process_frame
	print("snap: view=screen tab=%d items=%d" % [run.title.achievements.tab, run.title.visible_item_count()])


## The save's achievements section (in memory) for a preview state.
func _fill_save(state: String) -> void:
	var sec := Save.section(AchievementService.SECTION)
	sec.clear()
	var cat := AchievementCatalog.load_path(AchievementTuning.load_default().catalog_path)
	var u := {}
	var p := {}
	match state:
		"unlocked":
			for a in cat.achievements:
				u[String(a.id)] = 0
		"mixed":
			for id in MIXED_UNLOCKED:
				u[id] = 0
			p = MIXED_PROGRESS.duplicate()
	sec[AchievementTracker.KEY_UNLOCKED] = u
	sec[AchievementTracker.KEY_PROGRESS] = p
