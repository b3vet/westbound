extends Node
## The traffic sandbox on the multiplayer loop (N3.1 dev tool, not shipped): what the loop
## editor's PREVIEW TRAFFIC opens, as a scene of its own for snaps and quick runs. Spec:
## WESTBOUND_MULTIPLAYER_HANDOFF.md → The loop map ("preview traffic in the sandbox").
## docs/LOOP_MAP.md → Editor.
##
##   tools/snap.sh src/road/loop/dev/loop_traffic_preview.tscn --at=city --warm_s=20 --sky_t=0.4
##
## --at picks the car's start (LoopPreview.place_s names, or --s=<m>); every other option
## goes to the sandbox's snap_setup (cam, warm_s, sky_t, driver, labels, ...).

const SANDBOX_SCENE := "res://src/traffic/dev/traffic_sandbox.tscn"
const PREVIEW_SCRIPT := preload("res://src/road/loop/dev/loop_preview.gd")
const LAPS := 40

var sandbox: Node3D
var road: LoopRoadPath


func _ready() -> void:
	_boot(0.0)


func _boot(start_s: float) -> void:
	if sandbox != null:
		sandbox.free()
	road = LoopRoadPath.load_default()
	sandbox = (load(SANDBOX_SCENE) as PackedScene).instantiate()
	sandbox.road_override = road
	sandbox.biome_plan_override = road.biome_plan(LAPS)
	sandbox.start_s = start_s
	add_child(sandbox)


func snap_setup(args: Dictionary) -> void:
	var s := 0.0
	if args.has("s"):
		s = float(args["s"])
	elif args.has("at"):
		var namer: Node3D = PREVIEW_SCRIPT.new()
		namer.set(&"road", road)
		s = float(namer.call(&"place_s", String(args["at"])))
		namer.free()
	_boot(s)
	await get_tree().process_frame
	await sandbox.call(&"snap_setup", args)
