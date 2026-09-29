extends Node
## Snap wrapper (dev, plan D14 review): the real run with a scripted controls setup,
## so the HUD's bottom-centre cluster can be reviewed over the real car in every camera,
## hand and control layout, optionally with the thumb zones drawn and a steering thumb
## down. Spec: UI, HUD and design system; Controls. docs/HUD.md → Thumb zones.
##
##   tools/snap.sh src/ui/hud/dev/hud_run_snap.tscn --renderer=both --cam=chase --hand=left
##   tools/snap.sh src/ui/hud/dev/hud_run_snap.tscn --cam=cockpit --throttle=manual --zones=true
##
## Args: --hand=right|left, --throttle=auto|manual, --steering=drag|gyro,
## --controls_scale=<f>, --text_scale=1|1.25, --units=kmh|mph, --zones=true (the
## thumb-zone overlay), --thumb=true (a steering thumb resting in its zone: the drag
## anchor ring shows where it landed). The run's own args (--cam, --sky_t, --seed, --s,
## --speed_kmh, --car, --state, --ghost, --high_beam) are passed on to it.

const HudPreview := preload("res://src/ui/hud/dev/hud_preview.gd")
const RUN_KEYS: Array[String] = ["cam", "sky_t", "seed", "s", "speed_kmh", "car", "state", "ghost",
		"high_beam", "damaged"]
## iOS-style touch id (CLAUDE.md: never index by the raw id).
const THUMB_ID := 1_893_457_201
## The demo thumb lands at this share of its zone (from the outer edge, from the top).
const THUMB_AT := Vector2(0.55, 0.55)

@onready var _run: Run = $Run


func snap_setup(args: Dictionary) -> void:
	Settings.set_value(&"left_handed", str(args.get("hand", "right")) == "left")
	Settings.set_value(&"throttle_mode", StringName(str(args.get("throttle", "auto"))))
	Settings.set_value(&"steering_mode", StringName(str(args.get("steering", "drag"))))
	Settings.set_value(&"controls_scale", float(args.get("controls_scale", 1.0)))
	Settings.set_value(&"text_scale", float(args.get("text_scale", 1.0)))
	Settings.set_value(&"units", StringName(str(args.get("units", "kmh"))))
	var run_args := {}
	for key in RUN_KEYS:
		if args.has(key):
			run_args[key] = args[key]
	_run.snap_setup(run_args)
	await get_tree().process_frame
	var hud := _run.hud as Hud
	if hud == null:
		return
	if bool(args.get("zones", false)):
		HudPreview.add_zone_overlay(self, hud)
	if bool(args.get("thumb", false)):
		_thumb_down(hud)


## A steering thumb resting in the steering side's zone (left for a right-handed
## player, whose pedals and gas thumb are on the right).
func _thumb_down(hud: Hud) -> void:
	var zones := hud.layout.thumb_zones
	if zones.size() < 2:
		return
	var left_handed := bool(Settings.get_value(&"left_handed"))
	var z := zones[1] if left_handed else zones[0]
	var fx := THUMB_AT.x if not left_handed else 1.0 - THUMB_AT.x
	var ev := InputEventScreenTouch.new()
	ev.index = THUMB_ID
	ev.position = z.position + z.size * Vector2(fx, THUMB_AT.y)
	ev.pressed = true
	_run.hub.handle_pointer(ev, float(Time.get_ticks_usec()) * PlayerInput.S_PER_USEC)
