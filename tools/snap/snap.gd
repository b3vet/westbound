extends SceneTree
## Screenshot driver for tools/snap.sh (review tooling, plan §3). Use snap.sh;
## the raw call is
##   godot --path . --rendering-method gl_compatibility --rendering-driver opengl3 \
##         --fixed-fps 60 --script res://tools/snap/snap.gd -- <scene> [--key=value ...]
##
## For each planned capture: instance the scene, add it under root, call
## `snap_setup(args: Dictionary)` on the scene root if it has one (after _ready),
## wait the requested frames, save the viewport to PNG and free the instance.
## Prints "SNAP <absolute png path>" per image. Exit codes: 0 ok, 1 load or
## capture failure, 2 bad arguments.


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var opts := WBSnap.parse_args(OS.get_cmdline_user_args())
	var errors: PackedStringArray = opts["errors"]
	if not errors.is_empty():
		for e in errors:
			printerr("snap: %s" % e)
		quit(2)
		return

	var path := WBSnap.scene_path(opts["scene"])
	if not ResourceLoader.exists(path):
		printerr("snap: scene not found: %s" % path)
		quit(1)
		return
	var packed := load(path) as PackedScene
	if packed == null:
		printerr("snap: not a loadable PackedScene: %s" % path)
		quit(1)
		return

	var out_dir := ProjectSettings.globalize_path(String(opts["out"]))
	if DirAccess.make_dir_recursive_absolute(out_dir) != OK:
		printerr("snap: cannot create output directory %s" % out_dir)
		quit(1)
		return
	opts["out"] = out_dir

	var frames := WBSnap.wait_frames(opts)
	for capture in WBSnap.plan(opts):
		var scene := packed.instantiate()
		if scene == null:
			printerr("snap: failed to instantiate %s" % path)
			quit(1)
			return
		root.add_child(scene)
		if scene.has_method("snap_setup"):
			await scene.call("snap_setup", capture["params"])
		elif not capture["params"].is_empty():
			print("snap: note: %s has no snap_setup(args); options %s ignored" % [
				path, capture["params"]])
		for i in frames:
			await process_frame
		await RenderingServer.frame_post_draw

		var image := root.get_texture().get_image()
		if image == null or image.is_empty():
			printerr("snap: capture failed (no image; is a rendering driver available?)")
			quit(1)
			return
		var file: String = capture["file"]
		if image.save_png(file) != OK:
			printerr("snap: failed to write %s" % file)
			quit(1)
			return
		print("SNAP %s" % file)
		root.remove_child(scene)
		scene.free()
		await process_frame
	quit(0)
