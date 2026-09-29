extends SceneTree
## Draw-call measurement driver for tools/drawcalls.sh (spec: Performance budget →
## draw calls, triangles; plan WP4.6). Use drawcalls.sh; the raw call is
##   godot --path . --rendering-method gl_compatibility --rendering-driver opengl3 \
##         --fixed-fps 60 --script res://tools/drawcalls/drawcalls.gd -- <scene> [--key=value ...]
##
## Instances the scene under root, sets `--set=prop:value` properties on the scene
## root (before snap_setup; e.g. `--set=_leg:8`), calls `snap_setup(args)` with the
## other `--key=value` pairs (like tools/snap.sh), waits `--frames` frames, then
## samples the engine monitors for `--sample` frames while the scene runs:
##   draw calls (3D + canvas; min / mean / max), the root viewport's 3D draws,
##   objects and primitives in frame,
## then pauses the tree (a frozen frame, so the rest is exact and repeatable) and
## repeats the sample with each visible CanvasLayer hidden in turn (its share),
## with every CanvasLayer hidden (3D only), and with each of the scene root's direct
## 3D children hidden in turn (the delta is that child's share).
## Prints machine-readable lines starting with "DRAWCALLS " and exits 0; 1 on a load
## failure, 2 on bad arguments.

const DEFAULT_WARMUP_FRAMES := 180
const DEFAULT_SAMPLE_FRAMES := 60
## Frames to let a visibility change reach the renderer before sampling again.
const SETTLE_FRAMES := 3
## Frames per measurement once the tree is paused (the frame no longer changes).
const FROZEN_SAMPLE_FRAMES := 4


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene_arg := ""
	var params := {}
	var sets: Array[PackedStringArray] = []
	var warmup := DEFAULT_WARMUP_FRAMES
	var sample := DEFAULT_SAMPLE_FRAMES
	var breakdown := true
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--"):
			scene_arg = a
			continue
		var kv := a.substr(2).split("=", true, 1)
		var key := kv[0]
		var value := kv[1] if kv.size() > 1 else "true"
		match key:
			"frames":
				warmup = int(value)
			"sample":
				sample = maxi(int(value), 1)
			"no-breakdown":
				breakdown = false
			"size":
				pass
			"set":
				var pv := value.split(":", true, 1)
				if pv.size() != 2:
					printerr("drawcalls: --set wants prop:value, got %s" % value)
					quit(2)
					return
				sets.append(pv)
			_:
				params[key] = WBSnap.coerce(value)
	if scene_arg.is_empty():
		printerr("drawcalls: no scene given")
		quit(2)
		return
	var path := WBSnap.scene_path(scene_arg)
	var packed := load(path) as PackedScene
	if packed == null:
		printerr("drawcalls: cannot load %s" % path)
		quit(1)
		return
	var scene := packed.instantiate()
	root.add_child(scene)
	for pv in sets:
		scene.set(pv[0], WBSnap.coerce(pv[1]))
	if scene.has_method("snap_setup"):
		await scene.call("snap_setup", params)
	for i in warmup:
		await process_frame

	var vp := root
	print("DRAWCALLS scene %s" % path)
	print("DRAWCALLS renderer %s  window %s  3d_scale %.2f  msaa %d" % [
		RenderingServer.get_current_rendering_method(), str(vp.get_visible_rect().size),
		vp.scaling_3d_scale, vp.msaa_3d])
	var moving := await _sample(sample)
	_print_row("total (moving)", moving)
	# What the scene reports to the dev HUD (vehicles on screen and so on), if anything.
	for key: StringName in [DevStats.VEHICLES, &"opposite", &"leg", &"camera", &"sky_t"]:
		if DevStats.has_value(key):
			print("DRAWCALLS stat %s %s" % [key, str(DevStats.get_value(key))])

	# The rest is measured on a frozen frame (tree paused), so every share is exact
	# and the numbers repeat from run to run.
	paused = true
	var all := await _sample(FROZEN_SAMPLE_FRAMES)
	_print_row("total (frozen)", all)
	var layers: Array[CanvasLayer] = []
	_collect_layers(root, layers)
	if breakdown:
		# Per CanvasLayer share (dev HUD, touch controls, dev buttons, ...).
		for l in layers:
			l.visible = false
			var without_layer := await _sample(FROZEN_SAMPLE_FRAMES)
			l.visible = true
			_print_share("  canvas:%s" % _layer_label(l), _delta(all, without_layer))
	for l in layers:
		l.visible = false
	var only_3d := await _sample(FROZEN_SAMPLE_FRAMES)
	_print_row("3d_only (frozen)", only_3d)
	_print_share("canvas (frozen)", _delta(all, only_3d))

	if breakdown:
		# Per child share, measured in the 3D-only state (overlays already hidden).
		var cam := root.get_camera_3d()
		for c in scene.get_children():
			var n3 := c as Node3D
			# Hiding the camera's branch would measure an empty frame: skip it.
			if n3 == null or not n3.visible or (cam != null and (n3 == cam or n3.is_ancestor_of(cam))):
				continue
			n3.visible = false
			var without := await _sample(FROZEN_SAMPLE_FRAMES)
			n3.visible = true
			_print_share("  3d:%s" % c.name, _delta(only_3d, without))
	for l in layers:
		l.visible = true
	root.remove_child(scene)
	scene.free()
	await process_frame
	quit(0)


## Samples the monitors over `frames` frames after a short settle.
## Returns [draws_min, draws_mean, draws_max, objects_mean, prims_mean, 3d_mean]:
## Performance's frame totals (3D + canvas) and the root viewport's 3D draws.
func _sample(frames: int) -> PackedFloat64Array:
	for i in SETTLE_FRAMES:
		await process_frame
	await RenderingServer.frame_post_draw
	var dmin := INF
	var dmax := -INF
	var dsum := 0.0
	var osum := 0.0
	var psum := 0.0
	var vsum := 0.0
	for i in frames:
		await RenderingServer.frame_post_draw
		var d := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		dmin = minf(dmin, d)
		dmax = maxf(dmax, d)
		dsum += d
		osum += Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
		psum += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		vsum += float(root.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME))
	var n := float(frames)
	return PackedFloat64Array([dmin, dsum / n, dmax, osum / n, psum / n, vsum / n])


static func _delta(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for i in a.size():
		out.append(a[i] - b[i])
	return out


static func _print_row(label: String, r: PackedFloat64Array) -> void:
	print("DRAWCALLS %-30s draws %6.1f (min %4.0f max %4.0f)  3d %6.1f  objects %6.1f  prims %8.0f" % [
		label, r[1], r[0], r[2], r[5], r[3], r[4]])


## A share (a difference of two samples): means only.
static func _print_share(label: String, r: PackedFloat64Array) -> void:
	print("DRAWCALLS %-30s draws %6.1f                       3d %6.1f  objects %6.1f  prims %8.0f" % [
		label, r[1], r[5], r[3], r[4]])


static func _layer_label(l: CanvasLayer) -> String:
	var owner_name := l.get_parent().name if l.get_parent() != null else &""
	return "%s/%s" % [owner_name, l.name]


static func _collect_layers(n: Node, out: Array[CanvasLayer]) -> void:
	var cl := n as CanvasLayer
	if cl != null and cl.visible:
		out.append(cl)
	for c in n.get_children():
		_collect_layers(c, out)
