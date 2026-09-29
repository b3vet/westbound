extends Node
## Audio settings review scene (WP7A). Spec: UI → Screens ("Settings: ... audio
## buses"); Audio ("Buses ... each with a volume setting"). docs/AUDIO.md → Settings.
##
## The real run (src/run/run.tscn) paused with SETTINGS open on a page.
##
##   tools/snap.sh src/audio/dev/audio_settings_preview.tscn --sweep=page:game,audio
##   tools/snap.sh src/audio/dev/audio_settings_preview.tscn --size=1560x720 --text_scale=1.25 --page=audio
##
## snap_setup options: --page=game|audio (default audio), --text_scale=1|1.25,
## --hand=right|left, --sky_t=<0..1>, --music=<0..1> (the music volume shown).

const RUN_SCENE := preload("res://src/run/run.tscn")
const SNAP_SEED := 20260929
const SKY_T := 0.3

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
	Settings.set_value(&"volume_music", float(args.get("music", 0.75)))
	run.snap_setup({"state": "paused", "sky_t": float(args.get("sky_t", SKY_T)), "s": 900.0, "speed_kmh": 180.0})
	run.dev.controls.visible = false
	(run.get_node(^"DevHud") as CanvasLayer).visible = false
	var pause := run.screens.pause_screen
	pause.open_settings()
	var page := SettingsPanel.PAGE_AUDIO if String(args.get("page", "audio")) == "audio" else SettingsPanel.PAGE_GAME
	pause.settings.show_page(page)
	run.screens.finish_animations()
	await get_tree().process_frame
