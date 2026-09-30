extends WBTest
## The traffic sandbox's PASS overlay (WP6.1). Spec: Traffic → Traffic sandbox (debug
## scene): "overlays for ... the passability paths the director found". The scene
## boots with passability on (the director checks its batches with the car's params);
## the overlay gets the director's batch paths and the player's own path, and draws
## them without errors.

const SCENE := "res://src/traffic/dev/traffic_sandbox.tscn"
const FRAME := 1.0 / 60.0

var _scene: Node3D


func after_each() -> void:
	if _scene != null:
		_scene.queue_free()
		await tree.process_frame
		_scene = null


func test_pass_overlay_shows_the_directors_and_the_players_paths() -> void:
	_scene = (load(SCENE) as PackedScene).instantiate()
	tree.root.add_child(_scene)
	_scene.set_physics_process(false)
	await tree.process_frame
	var sb := _scene
	var dir: TrafficDirector = sb.director
	check(dir.passability_active(), "the sandbox director checks its batches")
	gt(dir.pass_checks, 0, "the prefill was checked")
	sb.time_scale = 4.0
	for i in 120:   # 8 s of sim time
		sb.advance_frame(FRAME)
	gt(dir.pass_batches, 3, "batches checked while driving")
	var overlay: TrafficOverlay = sb.overlay
	overlay.show_passability = true
	sb.refresh_passability()
	gt(overlay.passability_paths.size(), 0, "the director's paths reach the overlay")
	gt(overlay.passability_paths[0].size(), 2, "a path is a polyline")
	check(overlay.player_path_ok, "the bot's own window has a path")
	eq(overlay.player_path.size(), dir.passability.steps() + 1, "the player's path covers the horizon")
	near(overlay.player_path[0].x, sb.car.state.s, 0.01, "it starts at the player")
	sb.cam.set_mode(SandboxCamera.Mode.TOP)
	for i in 3:
		await tree.process_frame
