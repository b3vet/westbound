extends WBTest
## The traffic sandbox's network mode and the dev HUD's network rows (N4.3). Spec:
## multiplayer handoff → Implementation milestones, N4 ("network overlays in the traffic
## sandbox"), Client network traffic ("Dev HUD adds network metrics"); CLAUDE.md rule 10
## (the sandbox and the dev HUD keep working). docs/NET_TRAFFIC.md → Sandbox.

const SCENE := "res://src/traffic/dev/traffic_sandbox.tscn"
const HUD_SCENE := "res://src/ui/dev_hud.tscn"
const TICKS_PER_S := 120

var _scene: Node3D
var _hud: CanvasLayer


func after_each() -> void:
	for n: Node in [_scene, _hud]:
		if n != null:
			n.queue_free()
	await tree.process_frame
	_scene = null
	_hud = null
	DevStats.reset()


## The sandbox on the loop (as loop_traffic_preview boots it).
func _boot_on_loop() -> Node3D:
	var road := RunLoop.loop_road(Tuning.load_default())
	_scene = (load(SCENE) as PackedScene).instantiate()
	_scene.set(&"road_override", road)
	_scene.set(&"biome_plan_override", road.biome_plan(2))
	_scene.set(&"start_s", road.length() + 2000.0)
	tree.root.add_child(_scene)
	_scene.set_physics_process(false)
	await tree.process_frame
	return _scene


func test_network_mode_drives_the_sandbox_and_back() -> void:
	var sb := await _boot_on_loop()
	var net: NetTrafficControls = sb.get(&"net_controls")
	net.set_active(true)
	check(sb.call(&"is_network"), "network mode on")
	var sim: TrafficSim = sb.get(&"sim")
	var updates := sim.stat_model_updates
	sb.call(&"advance_ticks", TICKS_PER_S * 6)
	gt(sim.state.count, 10, "the server's cars are in the sandbox's TrafficState")
	eq(sim.stat_model_updates, updates, "the local sim is off")
	var s := net.harness.source.stats
	gt(s.corrections, 50)
	eq(s.teleports, 0)
	eq(int(sb.call(&"spawn_vehicle", 0, 0, 1, true)), -1, "no local spawns in network mode")
	# Overlays draw (engine errors fail the test).
	var cam: SandboxCamera = sb.get(&"cam")
	cam.set_mode(SandboxCamera.Mode.TOP)
	for i in 3:
		await tree.process_frame
	check(net.overlay.visible, "network overlay shown")
	sb.call(&"refresh_stats")
	check(DevStats.has_value(NetTrafficStats.DEV_CORR_PER_S), "net metrics in DevStats")
	check(DevStats.has_value(NetTrafficStats.DEV_RTT_MS))
	# Another link restarts on the same TrafficState.
	net.cycle_link()
	sb.call(&"advance_ticks", TICKS_PER_S * 2)
	gt(sim.state.count, 5)
	# Off: local traffic again.
	net.set_active(false)
	check(not sb.call(&"is_network"))
	sim = sb.get(&"sim")
	updates = sim.stat_model_updates
	sb.call(&"advance_ticks", TICKS_PER_S)
	gt(sim.stat_model_updates, updates, "the local sim runs again")
	gt(sim.state.count, 10)


func test_snap_hook_starts_network_mode() -> void:
	var sb := await _boot_on_loop()
	await sb.call(&"snap_setup", {"net": true, "link": "clean", "warm_s": 4.0, "cam": "follow"})
	var net: NetTrafficControls = sb.get(&"net_controls")
	check(net.active, "net=true")
	eq(net.link, NetTrafficControls.Link.CLEAN)
	gt(net.harness.source.stats.corrections, 20)


func test_dev_hud_network_rows() -> void:
	_hud = (load(HUD_SCENE) as PackedScene).instantiate()
	tree.root.add_child(_hud)
	await tree.process_frame
	_hud.call(&"refresh")
	var rows: Array = _hud.call(&"rows_snapshot")
	var names := PackedStringArray()
	for r: Array in rows:
		names.append(r[0])
	check(names.has("net corr") and names.has("net link"), "the rows exist")
	eq(_hud.call(&"get_row_text", 10), "-", "placeholder outside network mode")
	var stats := NetTrafficStats.new(10.0)
	stats.add_correction(0.02, 0.0, true)
	stats.add_correction(0.30, 0.0, false)
	stats.report_dev_stats()
	DevStats.report(NetTrafficStats.DEV_RTT_MS, 148.0)
	DevStats.report(NetTrafficStats.DEV_CLOCK_SLEW_MS, 1.5)
	_hud.call(&"refresh")
	var corr: String = _hud.call(&"get_row_text", 10)
	check(corr.contains("16.0/30 cm"), "mean / max in cm: %s" % corr)
	var link: String = _hud.call(&"get_row_text", 11)
	check(link.contains("rtt 148") and link.contains("clk +1.5 ms"), link)
