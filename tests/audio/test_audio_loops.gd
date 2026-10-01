extends WBTest
## Long-lived audio loops (engine, intake, wind, tire hum) keep sounding for as long as
## the game runs. Spec: Audio, haptics and game feel (Audio: engine, wind). docs/AUDIO.md
## → Loops on the web.
##
## The owner's bug: on the web build the engine and wind stopped for good after a few
## minutes. Godot 4.7's web sample playback resumes a paused sample from a position it
## never wraps to the buffer (the time since the last full restart, pauses included);
## past the end WebKit (Safari, every iOS browser) neither plays nor ends the source, so
## the loop never restarts and Godot still reports it playing. The fix never pauses a
## loop on the web: a silent loop is stopped (after loop_stop_hold_s) and started again
## with play(). Headless runs mix in the engine (stream playback), so these tests force
## the web mode (`stop_silent`) and check the invariant that avoids the engine bug (no
## loop is ever paused), plus, in both modes, that every loop that should be heard is
## playing, through a real Run with every event type: throttle lifts, gear shifts,
## boosts, hits, the crash, the results, retries, pause, slow motion, night and dawn,
## checkpoints (leg changes).

const RUN_SCENE := preload("res://src/run/run.tscn")
const FRAME_S := 1.0 / 60.0
const TICKS_PER_FRAME := 2
const BOT_SEED := 23
const BOT_SPEED_MPS := 52.0
const RUN_SEED := 20260930
## Fast variant: simulated seconds per mode; soak: minutes.
const FAST_S := 13.0
const SOAK_MIN := 12.0
## Event schedules (simulated seconds, repeating): pause, slow motion, a hit, night/dawn,
## a jump to just before the next checkpoint (a leg change). The fast variant packs them
## (a crash, the results and a retry in FAST_S); the soak spaces them (longer runs,
## checkpoints, many retries).
const FAST_EVERY_S: Array[float] = [5.0, 3.0, 3.0, 6.0, 7.0]
const SOAK_EVERY_S: Array[float] = [17.0, 11.0, 25.0, 40.0, 30.0]
## The leg jump lands this far before the checkpoint (m).
const BEFORE_CHECKPOINT_M := 150.0
const PAUSE_FOR_S := 2.5
const RESULTS_FOR_S := 3.0
## The bot lifts off the throttle (brakes lightly) for LIFT_S every LIFT_EVERY_S.
const LIFT_EVERY_S := 5.0
const LIFT_S := 1.6
const LIFT_BRAKE := 0.3
## Wind is checked when the car is this many times faster than the wind start speed.
const WIND_CHECK_FACTOR := 1.5
## The rpm sweep toggles the throttle every this many frames.
const SWEEP_LIFT_FRAMES := 90
## The long runs yield a real engine frame every this many frames.
const YIELD_EVERY_FRAMES := 60

var t: AudioTuning
var _nodes: Array[Node] = []
var _failures_seen: int = 0
var _first_failure: String = ""


## SandboxBot's weaving, plus a throttle lift every LIFT_EVERY_S (the on/off crossfade,
## the rpm falling through the steps, downshifts) and a boost when the meter is full.
class LiftingBot:
	extends SandboxBot
	var ticks: int = 0
	var lift_every: int = 1
	var lift_for: int = 0

	func update(dt: float, state: VehicleState, out_input: VehicleInput) -> void:
		super.update(dt, state, out_input)
		ticks += 1
		if ticks % lift_every < lift_for:
			out_input.throttle = 0.0
			out_input.brake = LIFT_BRAKE
		out_input.boost = state.boost_meter >= 1.0 and not state.boost_active


func before_all() -> void:
	t = AudioTuning.resolve()


func before_each() -> void:
	_failures_seen = 0
	_first_failure = ""


func after_each() -> void:
	tree.paused = false
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	Engine.time_scale = 1.0
	AudioBuses.set_night(0.0, t)
	AudioBuses.set_tunnel(0.0, t)


func _audio(web: bool) -> GameAudio:
	var a := GameAudio.new()
	a.autoplay_music = false
	a.game_state = Game.RUNNING
	tree.root.add_child(a)
	_nodes.append(a)
	a.engine.stop_silent = web
	a.traffic_audio.stop_silent = web
	a.player = VehicleState.new()
	a.player.s = 500.0
	a.player.v = Units.kmh_to_mps(150.0)
	a.player.rpm = 4000.0
	a.player.gear = 4
	a.player_input = VehicleInput.new()
	a.player_input.throttle = 1.0
	return a


# ---------------------------------------------------------------- The web mode

## Web mode: loops are never paused (Godot's web sample pause breaks them); silent ones
## stop after the hold and start again when heard; the game pause stops them.
func test_web_loops_stop_instead_of_pausing() -> void:
	var a := _audio(true)
	await tree.process_frame
	var e := a.engine
	var st := a.player
	var hold_frames := ceili(t.loop_stop_hold_s / FRAME_S)
	# Sweep the rpm through every step and back, lifting the throttle now and then.
	var steps := t.engine_step_rpm
	for i in 600:
		var x := float(i) / 300.0
		st.rpm = lerpf(steps[0], steps[steps.size() - 1], x if x <= 1.0 else 2.0 - x)
		a.player_input.throttle = 0.0 if posmod(floori(float(i) / float(SWEEP_LIFT_FRAMES)), 2) == 1 else 1.0
		a.step(FRAME_S)
		_expect_loops(a, true, "sweep frame %d" % i)
	# A loop silent for the hold is stopped, not paused.
	st.rpm = steps[0]
	a.player_input.throttle = 1.0
	for i in hold_frames + 2:
		a.step(FRAME_S)
	var top := steps.size() - 1
	check(not e.on_players[top].playing, "the top step, silent for the hold, is stopped")
	check(not e.on_players[top].stream_paused, "stopped, never paused")
	check(e.sounding(0), "the idle step plays")
	# Back up: the stopped loop starts again the frame it is heard.
	st.rpm = steps[top]
	for i in 30:
		a.step(FRAME_S)
		_expect_loops(a, true, "back up frame %d" % i)
	check(e.on_players[top].playing, "restarted when heard")
	# The game pause stops every loop; the resume starts the heard ones again.
	Events.paused_changed.emit(true)
	a.step(FRAME_S)
	for p in e.loops:
		check(not p.playing and not p.stream_paused, "%s stopped by the pause" % p.name)
	Events.paused_changed.emit(false)
	a.step(FRAME_S)
	_expect_loops(a, true, "after the pause")
	check(e.sounding(top) and e.wants(top), "the engine is back after the pause")
	check(e.sounding(e.loops.find(e.wind)), "the wind is back after the pause")
	eq(_failures_seen, 0, "loop invariant broken %d times; first: %s" % [_failures_seen, _first_failure])


## A gain hovering at silence doesn't stop and restart the loop every frame (each play()
## on the web sets up a decoder): it keeps playing through silences shorter than the hold.
func test_web_loop_hold_rides_out_short_silences() -> void:
	var a := _audio(true)
	await tree.process_frame
	var w := a.engine.wind
	a.player.v = Units.kmh_to_mps(200.0)
	for i in 60:
		a.step(FRAME_S)
	check(w.playing, "wind plays at speed")
	var short := maxi(floori(t.loop_stop_hold_s / FRAME_S * 0.5), 1)
	var stops := 0
	for burst in 6:
		a.player.v = 0.0
		a.engine.wind_gain = 0.0
		for i in short:
			a.step(FRAME_S)
			if not w.playing:
				stops += 1
		a.player.v = Units.kmh_to_mps(200.0)
		for i in short:
			a.step(FRAME_S)
	eq(stops, 0, "short silences don't stop the wind")
	check(not w.stream_paused, "never paused on the web")


## The native mode is unchanged: silent loops are paused, and resume when heard.
func test_native_loops_pause_when_silent() -> void:
	var a := _audio(false)
	await tree.process_frame
	var e := a.engine
	a.player.rpm = t.engine_step_rpm[0]
	for i in 30:
		a.step(FRAME_S)
	var top := t.engine_step_rpm.size() - 1
	a.player.rpm = t.engine_step_rpm[top]
	for i in 30:
		a.step(FRAME_S)
	# (A paused native player reports playing = false; the pause is what counts.)
	check(e.on_players[0].stream_paused, "native: a silent loop is paused")
	_expect_loops(a, false, "native")
	eq(_failures_seen, 0, "loop invariant broken %d times; first: %s" % [_failures_seen, _first_failure])


# ---------------------------------------------------------------- The long run

## Every loop survives a run with every event type, in both modes (fast variant).
func test_loops_survive_a_run_with_every_event() -> void:
	for web: bool in [false, true]:
		await _drive_long(FAST_S, web, FAST_EVERY_S)
	eq(_failures_seen, 0, "loop invariant broken %d times; first: %s" % [_failures_seen, _first_failure])


## The same over SOAK_MIN simulated minutes per mode: legs, night, many retries.
func soak_loops_survive_minutes_with_every_event() -> void:
	for web: bool in [false, true]:
		await _drive_long(SOAK_MIN * 60.0, web, SOAK_EVERY_S)
	eq(_failures_seen, 0, "loop invariant broken %d times; first: %s" % [_failures_seen, _first_failure])


func _drive_long(seconds: float, web: bool, every_s: Array[float]) -> void:
	var r := RUN_SCENE.instantiate() as Run
	r.run_seed = RUN_SEED
	r.manual_ticks = true
	r.crash_cinematic = false
	r.record_best = false
	tree.root.add_child(r)
	_nodes.append(r)
	await tree.process_frame
	var a := r.get_node_or_null(^"GameAudio") as GameAudio
	if not check(a != null, "the run has its audio"):
		return
	a.music.stop()
	a.autoplay_music = false
	a.engine.stop_silent = web
	a.traffic_audio.stop_silent = web
	var mode := "web" if web else "native"
	_new_bot(r)
	r.go()
	var frames := roundi(seconds / FRAME_S)
	var pause_left := 0
	var results_left := 0
	var runs := 1
	var hits := 0
	var pauses := 0
	var nights := 0
	var legs_jumped := 0
	var crossed := [0]
	var on_cross := func(_leg: int, _summary: Dictionary) -> void: crossed[0] += 1
	Events.checkpoint_crossed.connect(on_cross)
	var heard_wind := 0
	for f in frames:
		var sec := float(f) * FRAME_S
		# Pause and resume (the tree pauses; audio keeps processing).
		if pause_left > 0:
			pause_left -= 1
			if pause_left == 0:
				r.resume()
		elif r.state == Game.RUNNING and _every(f, every_s[0]):
			r.pause()
			pauses += 1
			pause_left = roundi(PAUSE_FOR_S / FRAME_S)
		if _every(f, every_s[1]):
			Events.slowmo_requested.emit(0.3, 0.8, &"test")
		if _every(f, every_s[3]):
			nights += 1
			if nights % 2 == 1:
				Events.night_started.emit()
			else:
				Events.dawn_started.emit(2.0)
		if r.state == Game.RUNNING and _every(f, every_s[4]):
			var leg_m := r.tuning.legs.leg_length_m()
			var next := (floorf(r.car.state.s / leg_m) + 1.0) * leg_m
			r.dev_teleport(next - BEFORE_CHECKPOINT_M, r.car.state.v)
			legs_jumped += 1
		if r.state == Game.RUNNING and _every(f, every_s[2]):
			r.force_hit(HitDetection.HIT_BARRIER, -1, 1)
			hits += 1
		if r.state == Game.CRASH:
			r.skip()
		if r.state == Game.RESULTS:
			if results_left == 0:
				results_left = roundi(RESULTS_FOR_S / FRAME_S)
			results_left -= 1
			if results_left == 0:
				r.retry()
				_new_bot(r)
				r.go()
				runs += 1
		if r.state != Game.PAUSED:
			for k in TICKS_PER_FRAME:
				r.tick()
			r.frame(FRAME_S)
		a.step(FRAME_S)
		_expect_loops(a, web, "%s t=%.2f s state=%s" % [mode, sec, r.state])
		# Let the engine run a real frame now and then: its deferred work (message queue,
		# audio server) otherwise piles up over a long blocking loop and the next frame
		# takes minutes.
		if f % YIELD_EVERY_FRAMES == 0:
			await tree.process_frame
		# The wind and engine follow the car when it drives at speed with the engine up.
		if r.state == Game.RUNNING and not a.paused and a.engine.fade >= 1.0:
			if a.engine.audible_loops() == 0:
				_note("%s t=%.2f s: driving with no engine loop heard" % [mode, sec])
			if absf(r.car.state.v) > t.wind_min_mps() * WIND_CHECK_FACTOR:
				heard_wind += 1
				if not a.engine.sounding(a.engine.loops.find(a.engine.wind)):
					_note("%s t=%.2f s: at %.0f km/h the wind is silent" % [mode, sec, Units.mps_to_kmh(r.car.state.v)])
	gt(heard_wind, roundi(1.0 / FRAME_S), "%s: the wind was heard" % mode)
	gt(hits, 0, "%s: hits" % mode)
	gt(pauses, 0, "%s: pauses" % mode)
	Events.checkpoint_crossed.disconnect(on_cross)
	if legs_jumped > 1:
		gt(int(crossed[0]), 0, "%s: crossed a checkpoint" % mode)
	if seconds >= FAST_S:
		gt(runs, 1, "%s: at least one retry" % mode)
	tree.paused = false
	Engine.time_scale = 1.0
	_nodes.erase(r)
	r.free()


## True on the last frame of each `period` seconds.
func _every(f: int, period: float) -> bool:
	var n := roundi(period / FRAME_S)
	return f % n == n - 1


func _new_bot(r: Run) -> void:
	var bot := LiftingBot.new(r.road, r.sim.state, r.car.params, BOT_SEED)
	bot.mode = SandboxBot.Mode.WEAVE
	bot.v_target = BOT_SPEED_MPS
	bot.length_m = r.car.car.length_m
	bot.width_m = r.car.car.width_m
	var hz := float(TICKS_PER_FRAME) / FRAME_S
	bot.lift_every = roundi(LIFT_EVERY_S * hz)
	bot.lift_for = roundi(LIFT_S * hz)
	r.drive_controller = bot


# ---------------------------------------------------------------- The invariant

## Every loop that should be heard is playing and not paused; on the web no loop is
## ever paused (that path breaks Godot's web samples). Skipped while the game is paused
## (native loops are paused then).
func _expect_loops(a: GameAudio, web: bool, ctx: String) -> void:
	var e := a.engine
	for k in e.loops.size():
		var p := e.loops[k]
		if web and p.stream_paused:
			_note("%s: %s paused on the web" % [ctx, p.name])
		if not a.paused and e.wants(k) and not e.sounding(k):
			_note("%s: %s should be heard but is %s" % [ctx, p.name, "paused" if p.stream_paused else "stopped"])
	var h := a.traffic_audio
	for v in h.hum.size():
		var p := h.hum[v]
		if web and p.stream_paused:
			_note("%s: %s paused on the web" % [ctx, p.name])
		if not a.paused and h.hum_gain[v] > t.silent_gain and not (p.playing and not p.stream_paused):
			_note("%s: %s should be heard but is not" % [ctx, p.name])


func _note(what: String) -> void:
	if _failures_seen == 0:
		_first_failure = what
	_failures_seen += 1
