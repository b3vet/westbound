extends WBTest
## The loop editor and its traffic preview (N3.1). Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md
## → The loop map (editor tool: generate from a seed, adjust by hand, preview traffic in
## the sandbox, export). docs/LOOP_MAP.md → Editor. Rule 10: the traffic sandbox keeps
## working (here on the loop, through its road injection hook).

const EDITOR := "res://src/road/loop/dev/loop_editor.tscn"
const SANDBOX := "res://src/traffic/dev/traffic_sandbox.tscn"

var _nodes: Array[Node] = []


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	await tree.process_frame


func _editor() -> Control:
	var ed: Control = (load(EDITOR) as PackedScene).instantiate()
	tree.root.add_child(ed)
	_nodes.append(ed)
	await tree.process_frame
	return ed


func test_editor_generates_edits_and_validates() -> void:
	var ed := await _editor()
	var road: LoopRoadPath = ed.road
	if not check(road != null, "the editor generated the loop"):
		return
	eq((ed.errors as PackedStringArray).size(), 0, "\n".join(ed.errors))
	var hash0: String = ed.export_hash
	eq(hash0, LoopExport.sha256_hex(LoopExport.to_json(LoopRoadPath.load_default())), "the committed loop")
	ed.set_edit("bend/4/0/radius_m", 2600.0)
	await tree.process_frame
	await tree.process_frame
	var r2: LoopRoadPath = ed.road
	eq(r2.layout.param_value[r2.layout.param_index("bend/4/0/radius_m")], 2600.0, "the edit regenerated the loop")
	ne(ed.export_hash, hash0, "and changed the export")
	ed.clear_edit("bend/4/0/radius_m")
	await tree.process_frame
	await tree.process_frame
	eq(ed.export_hash, hash0, "dropping the edit restores the loop")
	ed.set_group("tunnel")
	await tree.process_frame


func test_plot_handles_map_to_the_loop() -> void:
	var ed := await _editor()
	var plot: LoopPlot = ed.plot
	var o: LoopLayout = (ed.road as LoopRoadPath).layout
	var i := o.param_index("tunnel/1/portal_m")
	near(plot.param_location(i), o.tunnel_s0[1], 1e-3, "the handle sits on the portal")
	near(plot.value_for_s(i, plot.param_location(i)), o.param_value[i], 1e-3, "and maps back to its value")
	var k := o.param_index("sector/3/offset_m")
	near(plot.param_location(k), o.sector_s[3], 1e-3, "sector handle on its gantry")
	near(plot.value_for_s(k, o.sector_s[3] + 100.0), o.param_value[k] + 100.0, 1e-3)
	check(LoopPlot.is_handle_key("ramp/0/off_m"))
	check(not LoopPlot.is_handle_key("bend/0/0/radius_m"))
	# A drag moves the tunnel.
	plot.param_dragged.emit("tunnel/1/portal_m", o.param_value[i] + 50.0)
	await tree.process_frame
	await tree.process_frame
	near((ed.road as LoopRoadPath).layout.tunnel_s0[1], o.tunnel_s0[1] + 50.0, 1e-3, "dragged 50 m on")


func test_traffic_sandbox_runs_on_the_loop_across_the_seam() -> void:
	var road := LoopRoadPath.load_default()
	var sb: Node3D = (load(SANDBOX) as PackedScene).instantiate()
	sb.road_override = road
	sb.biome_plan_override = road.biome_plan(3)
	sb.start_s = road.length() - 250.0
	tree.root.add_child(sb)
	_nodes.append(sb)
	sb.set_physics_process(false)
	await tree.process_frame
	check(sb.road == road, "the sandbox uses the injected road")
	gt(sb.sim.state.count, 5, "the director filled the loop")
	var s0: float = sb.car.state.s
	sb.advance_ticks(1200)   # 10 s
	gt(sb.car.state.s, road.length() + 50.0, "the bot drove across the seam (unwrapped s)")
	gt(sb.car.state.s - s0, 200.0)
	gt(sb.sim.state.count, 5, "traffic stays alive")
	for n in 3:
		await tree.process_frame


func test_preview_button_opens_the_sandbox() -> void:
	var ed := await _editor()
	var sb: Node = ed.preview_traffic()
	_nodes.append(sb)
	sb.set_physics_process(false)
	await tree.process_frame
	check(sb.get(&"road") is LoopRoadPath, "the sandbox drives the edited loop")
