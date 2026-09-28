extends Node
## Snap wrapper (dev): the real M2 drive scene with a scripted controls setup, for
## phone-size screenshots of the controls overlay in play (plan D9/D10 review).
## Spec: Controls; UI → HUD elements (controls overlay).
##
##   tools/snap.sh src/input/dev/controls_snap.tscn --size=1688x780 \
##       --steering=drag --throttle=manual --pedal=boost --drag_visual=wheel
##
## Args: --steering=drag|gyro --throttle=auto|manual --left_handed=true|false, and the
## input preview's demo args (--drag_visual, --controls_scale, --pedal, --drag_x,
## --tilt_deg). The drive scene's own args (--sky_t, --car, --cam, --speed_kmh, --s)
## are passed on to it.

const InputPreview := preload("res://src/input/dev/input_preview.gd")
const DRIVE_KEYS: Array[String] = ["sky_t", "car", "cam", "speed_kmh", "s"]

@onready var _drive: Node = $CarDrive


func snap_setup(args: Dictionary) -> void:
	var hub: PlayerInput = _drive.get_node("PlayerInput")
	var sim: InputPreview.SimulatedGravity = null
	if not hub.is_gyro_supported():
		sim = InputPreview.SimulatedGravity.new()
		hub.set_gravity_source(sim)
	Settings.set_value(&"steering_mode", StringName(str(args.get("steering", "drag"))))
	Settings.set_value(&"throttle_mode", StringName(str(args.get("throttle", "auto"))))
	Settings.set_value(&"left_handed", bool(args.get("left_handed", false)))
	InputPreview.apply_look_args(args)
	var drive_args := {}
	for key in DRIVE_KEYS:
		if args.has(key):
			drive_args[key] = args[key]
	if not drive_args.is_empty():
		await _drive.call("snap_setup", drive_args)
	InputPreview.demo_fingers(hub, sim, args)
