extends Control
## HUD review scene (WP4.3). Spec: UI, HUD and design system (layout, elements,
## accessibility); Scoring → Score feedback. docs/HUD.md → Preview.
##
## The real Hud over a flat painted road-and-sky background (colors from the color
## script at sky_t), fed by a fake HudFeed, with the real PlayerInput and
## ControlsOverlay so the touch controls show where they really are. Left alone it
## cycles fake events (review mode); snap_setup freezes a named state.
##
##   tools/snap.sh src/ui/hud/dev/hud_preview.tscn --renderer=both --state=busy
##   tools/snap.sh src/ui/hud/dev/hud_preview.tscn --state=idle --hand=left --throttle=manual
##   tools/snap.sh src/ui/hud/dev/hud_preview.tscn --size=2496x1320 --state=busy   # iPhone
##
## snap_setup options: --state=idle|busy|too_slow|night|bank|dawn|leg_toast|objective|warning
## (default busy); leg_toast: --night=true|false (default true); objective: --done=true,
## --failed=true;
## --hand=right|left, --throttle=auto|manual, --steering=drag|gyro, --controls_scale=<f>,
## --text_scale=1|1.25, --units=kmh|mph, --sky_t=<0..1> (default per state),
## --high_beam=true (the high-beam button lit; it shows at dusk, night and dawn),
## --world=true (the 3D look preview behind instead of the flat background).
## Prints the frame's draw calls and the HUD's visible canvas items ("snap: ...").

const LOOK_PREVIEW := "res://src/sun/dev/look_preview.tscn"
const SKY_T_DAY := 0.3
const SKY_T_NIGHT := 0.74
const SKY_T_DAWN := 0.86
const HORIZON_FRAC := 0.42
const LANES := 4
const DASHES := 9
const MEASURE_FRAMES := 3

@export var cycle: bool = true

var feed := HudFeed.new()
var sky_t: float = SKY_T_DAY

var _cs: ColorScript
var _key := ColorKey.new()
var _clock: float = 0.0
var _next_event: float = 0.0
var _event_i: int = 0
var _world: Node

@onready var hud: Hud = $Hud
@onready var hub: PlayerInput = $PlayerInput


func _ready() -> void:
	var t := Tuning.load_default()
	_cs = ColorScript.load_default()
	if not _cs.is_bound():
		_cs.bind(t.sun)
	feed.top_speed_mps = Units.kmh_to_mps(t.vehicle.car_top_speed_min_kmh)
	feed.min_speed_mps = t.scoring.min_speed_mps()
	feed.best = 2_010_000
	feed.banked = 1_284_500
	feed.checkpoint_distance_m = 1200.0
	feed.sun_height = 0.62
	feed.speed_mps = Units.kmh_to_mps(176.0)
	feed.boost_fill = 0.35
	feed.leg_index = 2
	feed.objective = LegObjectives.CLOSE_PASSES
	feed.objective_target = t.legs.objective_close_passes_count
	feed.objective_progress = 1
	hud.bind(feed)
	hud.high_beam_pressed.connect(hub.toggle_high_beam)
	_set_sky(sky_t)


func _process(delta: float) -> void:
	if cycle:
		_cycle(delta)


## tools/snap.sh hook.
func snap_setup(args: Dictionary) -> void:
	cycle = false
	Settings.reset_to_defaults()
	Settings.set_value(&"left_handed", String(args.get("hand", "right")) == "left")
	Settings.set_value(&"throttle_mode", StringName(String(args.get("throttle", "auto"))))
	Settings.set_value(&"steering_mode", StringName(String(args.get("steering", "drag"))))
	Settings.set_value(&"controls_scale", float(args.get("controls_scale", 1.0)))
	Settings.set_value(&"text_scale", float(args.get("text_scale", 1.0)))
	Settings.set_value(&"units", StringName(String(args.get("units", "kmh"))))
	var state := String(args.get("state", "busy"))
	var default_sky := SKY_T_DAY
	if state == "night":
		default_sky = SKY_T_NIGHT
	elif state == "dawn":
		default_sky = SKY_T_DAWN
	_set_sky(float(args.get("sky_t", default_sky)))
	if bool(args.get("world", false)):
		_add_world()
	Events.run_started.emit(&"journey", 1)
	hub.set_high_beam(bool(args.get("high_beam", false)))
	await get_tree().process_frame
	_apply_state(state, args)
	hud.settle_high_beam()
	# The HUD's own draw calls: the frame with it minus the frame without it.
	await _frames(MEASURE_FRAMES)
	var with_hud := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	hud.visible = false
	await _frames(MEASURE_FRAMES)
	var without := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	hud.visible = true
	print("snap: state=%s hud_items=%d draw_calls=%d without_hud=%d hud=%d" % [state,
			hud.visible_item_count(), with_hud, without, with_hud - without])


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw


func _apply_state(state: String, args: Dictionary = {}) -> void:
	var f := feed
	f.lives = 2
	f.ghost = false
	f.night = false
	f.dawning = false
	f.too_slow = false
	f.boosting = false
	match state:
		"idle":
			f.speed_mps = Units.kmh_to_mps(176.0)
			f.chain = 0
			f.multiplier = 1.0
			f.boost_fill = 0.35
			f.sun_height = 0.62
			Events.gear_shifted.emit(5)
		"busy":
			f.speed_mps = Units.kmh_to_mps(243.0)
			f.chain = 48_200
			f.multiplier = 24.6
			f.boost_fill = 0.8
			f.boosting = true
			f.sun_height = 0.41
			f.checkpoint_distance_m = 740.0
			Events.gear_shifted.emit(6)
			_emit_scored(Events.PASS, 320, 20.0)
			_emit_scored(Events.PASS, 480, 22.0)
			_emit_scored(Events.CUT, 2100, 23.0)
			_emit_scored(Events.CLOSE_PASS, 1450, 24.0)
			f.lives = 1
			f.ghost = true
			Events.hit.emit(Events.HIT_TRAFFIC, 1)
			_emit_scored(Events.THREAD, 6800, 24.6)
		"too_slow":
			f.speed_mps = Units.kmh_to_mps(78.0)
			f.too_slow = true
			f.chain = 12_400
			f.multiplier = 3.2
			f.boost_fill = 0.1
			f.sun_height = 0.28
			Events.gear_shifted.emit(3)
			_emit_scored(Events.PASS, 320, 3.0)
			_emit_scored(Events.CLOSE_PASS, 900, 3.2)
		"night":
			f.night = true
			f.speed_mps = Units.kmh_to_mps(205.0)
			f.chain = 22_000
			f.multiplier = 8.4
			f.boost_fill = 1.0
			f.sun_height = 0.0
			f.checkpoint_distance_m = 2300.0
			Events.gear_shifted.emit(5)
			Events.night_started.emit()
			_emit_scored(Events.CLOSE_PASS, 2900, 8.0)
			_emit_scored(Events.PASS, 960, 8.4)
		"dawn":
			f.dawning = true
			f.speed_mps = Units.kmh_to_mps(221.0)
			f.sun_height = 0.95
			f.multiplier = 1.0
			f.chain = 0
			f.boost_fill = 0.5
		"bank":
			f.speed_mps = Units.kmh_to_mps(214.0)
			f.chain = 0
			f.multiplier = 1.0
			f.boost_fill = 0.6
			Events.chain_banked.emit(48_200, Events.REASON_CASH_OUT, f.banked + 48_200)
			f.banked += 48_200
		"leg_toast":
			_leg_toast(bool(args.get("night", true)))
		"objective":
			f.speed_mps = Units.kmh_to_mps(226.0)
			f.chain = 18_400
			f.multiplier = 6.2
			f.objective_progress = 3
			Events.gear_shifted.emit(6)
			_emit_scored(Events.CLOSE_PASS, 1200, 5.0)
			_emit_scored(Events.CLOSE_PASS, 1450, 6.0)
			if bool(args.get("done", false)):
				f.objective_progress = f.objective_target
				f.objective_done = true
				_emit_scored(Events.CLOSE_PASS, 1600, 6.2)
				Events.objective_completed.emit(f.objective, 2500)
				Events.bonus_awarded.emit(LegTracker.BONUS_OBJECTIVE, 2500, f.banked + 2500)
				f.banked += 2500
			elif bool(args.get("failed", false)):
				f.objective = LegObjectives.NO_BRAKING
				f.objective_target = 0
				f.objective_failed = true
		"warning":
			f.speed_mps = Units.kmh_to_mps(208.0)
			f.chain = 9_600
			f.multiplier = 4.1
			f.checkpoint_distance_m = 500.0
			Events.gear_shifted.emit(5)
			Events.checkpoint_warning.emit(1000.0)
			_emit_scored(Events.PASS, 410, 3.8)
			_emit_scored(Events.CUT, 760, 4.0)
			Events.checkpoint_warning.emit(500.0)


## A night crossing of leg 2 into leg 3, in the run's event order: crossed, leg started,
## banked, dawn, the leg bonuses (x2), the life.
func _leg_toast(night: bool) -> void:
	var f := feed
	var k := 2 if night else 1
	f.speed_mps = Units.kmh_to_mps(231.0)
	f.chain = 0
	f.multiplier = 5.2
	f.boost_fill = 0.55
	f.lives = 2
	f.dawning = night
	f.sun_height = 0.05 if night else 0.85
	f.checkpoint_distance_m = 3480.0
	f.leg_index = 3
	f.objective = LegObjectives.THREADS
	f.objective_target = 2
	f.objective_progress = 0
	f.objective_done = false
	f.objective_failed = false
	Events.gear_shifted.emit(6)
	var summary := {
		RunEvents.SUMMARY_LEG_INDEX: 2, RunEvents.SUMMARY_CLEAN: true, RunEvents.SUMMARY_PACE: true,
		RunEvents.SUMMARY_THREADS: 3, RunEvents.SUMMARY_HEAT: false, RunEvents.SUMMARY_AT_NIGHT: night,
		RunEvents.SUMMARY_OBJECTIVE: LegObjectives.CLOSE_PASSES, RunEvents.SUMMARY_OBJECTIVE_DONE: true,
		RunEvents.SUMMARY_OBJECTIVE_POINTS: 2500 * k,
	}
	Events.checkpoint_crossed.emit(2, summary)
	Events.leg_started.emit(3, &"farmland", LegObjectives.THREADS)
	f.banked += 48_200
	Events.chain_banked.emit(48_200, Events.REASON_CHECKPOINT, f.banked)
	if night:
		Events.dawn_started.emit(6.0)
	for b: Array in [[LegTracker.BONUS_CLEAN, 5000], [LegTracker.BONUS_PACE, 3000], [LegTracker.BONUS_THREADS, 3000]]:
		f.banked += int(b[1]) * k
		Events.bonus_awarded.emit(b[0], int(b[1]) * k, f.banked)
	Events.life_restored.emit(2)


func _emit_scored(kind: StringName, points: int, mult: float) -> void:
	Events.scored.emit(kind, points, mult, 0.4)


## Review mode: a fake run that exercises every element.
func _cycle(delta: float) -> void:
	_clock += delta
	var f := feed
	f.speed_mps = Units.kmh_to_mps(165.0 + 85.0 * sin(_clock * 0.35))
	f.too_slow = false
	f.boost_fill = fposmod(_clock * 0.08, 1.2)
	f.boosting = f.boost_fill > 1.0
	f.boost_fill = minf(f.boost_fill, 1.0)
	f.sun_height = 1.0 - fposmod(_clock * 0.01, 1.0)
	f.checkpoint_distance_m = 3500.0 - fposmod(_clock * 60.0, 3500.0)
	f.multiplier = 1.0 + fposmod(_clock * 1.7, 40.0)
	if _clock >= _next_event:
		_next_event = _clock + 0.7
		_event_i += 1
		var kinds: Array[StringName] = [Events.PASS, Events.CLOSE_PASS, Events.PASS, Events.CUT, Events.THREAD]
		var kind := kinds[_event_i % kinds.size()]
		var pts := int(300.0 * f.multiplier) + _event_i * 7
		f.chain += pts
		_emit_scored(kind, pts, f.multiplier)
		if _event_i % 12 == 0:
			Events.chain_banked.emit(f.chain, Events.REASON_CASH_OUT, f.banked + f.chain)
			f.banked += f.chain
			f.chain = 0
			f.multiplier = 1.0
		if _event_i % 17 == 0:
			f.lives = 1
			Events.hit.emit(Events.HIT_TRAFFIC, 1)
			Events.ghost_started.emit(2.0)
			f.ghost = true
		if _event_i % 17 == 4:
			f.ghost = false
			Events.ghost_ended.emit()
		if _event_i % 17 == 10:
			f.lives = 2
			Events.life_restored.emit(2)
		if _event_i % 23 == 0:
			f.leg_index += 1
			f.objective_progress = 0
			_leg_toast(_event_i % 2 == 0)
		elif _event_i % 23 == 12:
			Events.checkpoint_warning.emit(1000.0)
		elif _event_i % 23 == 18:
			Events.checkpoint_warning.emit(500.0)
		elif _event_i % 5 == 0 and f.objective_target > 0 and not f.objective_done:
			f.objective_progress += 1
			f.objective_done = f.objective_progress >= f.objective_target


func _set_sky(value: float) -> void:
	sky_t = value
	_cs.sample_into(sky_t, _key)
	hud.set_accent(_key.ui_accent)
	hud.set_headlight_ramp(_key.emissive_headlight)
	queue_redraw()


func _add_world() -> void:
	var packed := load(LOOK_PREVIEW) as PackedScene
	if packed == null:
		return
	_world = packed.instantiate()
	add_child(_world)
	move_child(_world, 0)
	if _world.has_method("snap_setup"):
		_world.call("snap_setup", {"sky_t": sky_t, "cam": "chase"})


## Flat stand-in world: sky gradient, sun, fields, a road in perspective, a few cars.
func _draw() -> void:
	if _world != null:
		return
	var r := get_viewport_rect()
	var w := r.size.x
	var h := r.size.y
	var hy := h * HORIZON_FRAC
	var k := _key
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(w, 0), Vector2(w, hy), Vector2(0, hy)]),
			PackedColorArray([k.sky_zenith, k.sky_zenith, k.sky_horizon, k.sky_horizon]))
	if k.sun_elevation_deg > -5.0:
		var sy := hy - k.sun_elevation_deg / 40.0 * hy
		draw_circle(Vector2(w * 0.36, sy), h * 0.05, k.sun_disc_color)
	draw_polygon(PackedVector2Array([Vector2(0, hy), Vector2(w, hy), Vector2(w, h), Vector2(0, h)]),
			PackedColorArray([k.fog_color, k.fog_color, k.horizon_tint_0, k.horizon_tint_0]))
	var cx := w * 0.5
	var road_top := w * 0.02
	var road_bottom := w * 0.9
	draw_polygon(PackedVector2Array([Vector2(cx - road_top, hy), Vector2(cx + road_top, hy),
			Vector2(cx + road_bottom, h), Vector2(cx - road_bottom, h)]),
			PackedColorArray([k.road_tone.lerp(k.fog_color, 0.7), k.road_tone.lerp(k.fog_color, 0.7),
			k.road_tone, k.road_tone]))
	for lane in range(1, LANES):
		var u := float(lane) / float(LANES) * 2.0 - 1.0
		for d in DASHES:
			var t0 := pow(float(d) / float(DASHES), 2.0)
			var t1 := pow((float(d) + 0.5) / float(DASHES), 2.0)
			var y0 := lerpf(hy, h, t0)
			var y1 := lerpf(hy, h, t1)
			var x0 := cx + u * lerpf(road_top, road_bottom, t0)
			var x1 := cx + u * lerpf(road_top, road_bottom, t1)
			draw_line(Vector2(x0, y0), Vector2(x1, y1), k.lane_line_tint, lerpf(1.0, 6.0, t1))
	# Traffic in the middle third.
	for c in 3:
		var t := 0.25 + 0.2 * float(c)
		var y := lerpf(hy, h, t)
		var u := -0.5 + 0.5 * float(c)
		var x := cx + u * lerpf(road_top, road_bottom, t)
		var s := lerpf(10.0, 150.0, t)
		draw_rect(Rect2(x - s * 0.5, y - s * 0.55, s, s * 0.55), Color("#2a2f3a"))
		draw_rect(Rect2(x - s * 0.45, y - s * 0.2, s * 0.15, s * 0.07), Color("#ff3b30"))
		draw_rect(Rect2(x + s * 0.3, y - s * 0.2, s * 0.15, s * 0.07), Color("#ff3b30"))
