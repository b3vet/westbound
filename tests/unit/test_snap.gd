extends WBTest
## tools/snap option parsing, capture planning and the snap_setup hook.
## Rendering itself needs a GPU context, so it is covered by running
## tools/snap.sh, not here (headless uses the dummy renderer).

const EXAMPLE := "res://tools/snap/example_snap_scene.tscn"

var _scene: Node


func after_each() -> void:
	if is_instance_valid(_scene):
		_scene.free()
	_scene = null


func test_defaults() -> void:
	var o := WBSnap.parse_args(PackedStringArray(["res://src/main.tscn"]))
	eq(o["errors"].size(), 0)
	eq(o["frames"], WBSnap.DEFAULT_FRAMES)
	eq(WBSnap.wait_frames(o), WBSnap.DEFAULT_FRAMES)
	var p := WBSnap.plan(o)
	eq(p.size(), 1)
	eq(p[0]["file"], "res://tests/out/snaps/main.png")
	eq(p[0]["params"], {})


func test_passthrough_params_are_coerced() -> void:
	var o := WBSnap.parse_args(PackedStringArray([
		"src/main.tscn", "--sky_t=0.62", "--cam=hood", "--speed_kmh=200", "--debug",
		"--frames=5", "--seconds=0.5", "--size=640x360"]))
	eq(o["errors"].size(), 0)
	eq(o["params"], {"sky_t": 0.62, "cam": "hood", "speed_kmh": 200, "debug": true})
	eq(WBSnap.wait_frames(o), 5 + 30)
	eq(WBSnap.scene_path(o["scene"]), "res://src/main.tscn")


func test_sweep_plans_one_capture_per_value() -> void:
	var o := WBSnap.parse_args(PackedStringArray([
		"src/sun/sky.tscn", "--sweep=sky_t:0,0.5,1", "--cam=hood", "--out=/tmp/x"]))
	var p := WBSnap.plan(o)
	eq(p.size(), 3)
	eq(p[1]["file"], "/tmp/x/sky_sky_t-0.5.png")
	eq(p[1]["params"], {"cam": "hood", "sky_t": 0.5})
	eq(p[2]["params"]["sky_t"], 1)


func test_two_sweeps_make_a_grid_and_tag_names() -> void:
	var o := WBSnap.parse_args(PackedStringArray([
		"a.tscn", "--sweep=cam:hood,chase", "--sweep=sky_t:0,1", "--tag=wip 2"]))
	var files := PackedStringArray()
	for c in WBSnap.plan(o):
		files.append(String(c["file"]).get_file())
	eq(files, PackedStringArray([
		"a_wip_2_cam-hood_sky_t-0.png", "a_wip_2_cam-hood_sky_t-1.png",
		"a_wip_2_cam-chase_sky_t-0.png", "a_wip_2_cam-chase_sky_t-1.png"]))


func test_bad_arguments_are_reported() -> void:
	eq(WBSnap.parse_args(PackedStringArray([]))["errors"].size(), 1, "no scene")
	eq(WBSnap.parse_args(PackedStringArray(["a.tscn", "--sweep=novalues"]))["errors"].size(), 1)
	eq(WBSnap.parse_args(PackedStringArray(["a.tscn", "--frames=0"]))["errors"].size(), 1)
	eq(WBSnap.parse_args(PackedStringArray(["a.tscn", "b.tscn"]))["errors"].size(), 1)


func test_example_scene_snap_setup_hook() -> void:
	var packed := load(EXAMPLE) as PackedScene
	if not check(packed != null, "example scene loads"):
		return
	_scene = packed.instantiate()
	tree.root.add_child(_scene)
	check(_scene.has_method("snap_setup"))
	_scene.call("snap_setup", {"sky_t": 1.0, "label": "x"})
	var label: Label = _scene.get_node("UI/Label")
	check(label.text.contains("label"), "snap_setup saw its args: %s" % label.text)
