extends WBTest
## Audio (WP7A): buses and volumes, the engine crossfade, pass whooshes, stingers,
## traffic sounds, night filter, tunnel reverb, the voice budget, the run hookup.
## Spec: Audio, haptics and game feel ("every scoring event gets sound ... within one
## frame"; the pass whoosh; engine; buses). docs/AUDIO.md. Headless runs use the Dummy
## audio driver: players really start (and finish in real time), and VoicePool records
## every sound it starts with the process frame (the test hook).

const RUN_SCENE := preload("res://src/run/run.tscn")
const DT := 1.0 / 60.0
const EPS := 1e-6
const IOS_ID := 1_893_457_201

var t: AudioTuning
var _nodes: Array[Node] = []
var _types: Array[VehicleType] = []
var _semi: int = -1
var _sedan: int = -1


func before_all() -> void:
	t = AudioTuning.resolve()
	var reg := TrafficRegistry.load_default(Tuning.load_default().traffic)
	_types = reg.types
	_semi = reg.type_index(&"semi")
	_sedan = reg.type_index(&"sedan")


func before_each() -> void:
	Settings.reset_to_defaults()


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	Settings.reset_to_defaults()
	AudioBuses.set_night(0.0, t)
	AudioBuses.set_tunnel(0.0, t)
	for i in AudioBuses.NAMES.size():
		var b := AudioBuses.index(AudioBuses.NAMES[i])
		if b >= 0:
			AudioServer.set_bus_mute(b, false)


func _audio() -> GameAudio:
	var a := GameAudio.new()
	a.autoplay_music = false
	a.game_state = Game.RUNNING
	tree.root.add_child(a)
	_nodes.append(a)
	a.player = VehicleState.new()
	a.player.s = 500.0
	a.player.v = Units.kmh_to_mps(150.0)
	a.player.rpm = 4000.0
	a.player.gear = 4
	a.player_input = VehicleInput.new()
	a.player_input.throttle = 1.0
	return a


## A traffic state with cars at (s, d, type) triples relative to the player.
func _traffic(a: GameAudio, cars: Array) -> TrafficState:
	var st := TrafficState.new(8)
	for c: Array in cars:
		var i := st.allocate()
		st.s[i] = a.player.s + float(c[0])
		st.d[i] = float(c[1])
		st.type_id[i] = int(c[2])
		st.length[i] = _types[int(c[2])].length_m
		st.width[i] = _types[int(c[2])].width_m
		st.v[i] = Units.kmh_to_mps(110.0)
	a.bind_traffic(st, _types, null, null)
	return st


# ---------------------------------------------------------------- Buses

func test_bus_layout_has_the_buses_and_effects() -> void:
	check(AudioBuses.ensure_layout(), "the layout is in place")
	var layout := load(AudioBuses.LAYOUT_PATH) as AudioBusLayout
	check(layout != null, "default_bus_layout.tres loads")
	for n in AudioBuses.NAMES:
		var b := AudioBuses.index(n)
		ge(b, 0, "bus %s" % n)
		if b > 0:
			eq(AudioServer.get_bus_send(b), AudioBuses.MASTER, "%s sends to Master" % n)
	var music := AudioBuses.index(AudioBuses.MUSIC)
	check(AudioServer.get_bus_effect(music, AudioBuses.MUSIC_LOWPASS) is AudioEffectLowPassFilter, "music low-pass")
	check(AudioServer.get_bus_effect(music, AudioBuses.MUSIC_REVERB) is AudioEffectReverb, "music reverb")
	check(AudioServer.get_bus_effect(AudioBuses.index(AudioBuses.SFX), AudioBuses.SFX_REVERB) is AudioEffectReverb,
		"SFX tunnel reverb")
	check(AudioServer.get_bus_effect(AudioBuses.index(AudioBuses.ENGINE), AudioBuses.ENGINE_REVERB) is AudioEffectReverb,
		"Engine tunnel reverb")
	check(not AudioBuses.night_enabled(), "night effects start off")
	check(not AudioBuses.tunnel_enabled(), "tunnel reverb starts off")


func test_volume_settings_apply() -> void:
	var a := _audio()
	await tree.process_frame
	var music := AudioBuses.index(AudioBuses.MUSIC)
	near(AudioServer.get_bus_volume_db(music), t.music_db, 1e-3, "default: the tuning's level")
	Settings.set_value(&"volume_music", 0.5)
	for i in 60:
		a.step(DT)
	near(AudioServer.get_bus_volume_db(music), t.music_db + linear_to_db(0.5), 0.1, "50% glides in")
	check(not AudioServer.is_bus_mute(music))
	Settings.set_value(&"volume_music", 0.0)
	a.step(DT)
	check(AudioServer.is_bus_mute(music), "0 mutes the bus")
	Settings.set_value(&"volume_sfx", 0.75)
	for i in 60:
		a.step(DT)
	near(AudioServer.get_bus_volume_db(AudioBuses.index(AudioBuses.SFX)), t.sfx_db + linear_to_db(0.75), 0.1)
	# Mute: the setting and the M key (PlayerInput.mute_toggled).
	var master := AudioBuses.index(AudioBuses.MASTER)
	check(not AudioServer.is_bus_mute(master))
	var hub := PlayerInput.new()
	_nodes.append(hub)
	a.bind_hub(hub)
	hub.mute_toggled.emit()
	eq(Settings.get_value(&"audio_muted"), true, "M mutes")
	check(AudioServer.is_bus_mute(master), "Master muted")
	hub.mute_toggled.emit()
	check(not AudioServer.is_bus_mute(master), "M again unmutes")


# ---------------------------------------------------------------- Engine

func test_engine_weights_by_rpm() -> void:
	var steps := t.engine_step_rpm
	var w := PackedFloat64Array()
	w.resize(steps.size())
	for i in steps.size():
		AudioMath.engine_step_weights(steps[i], steps, w)
		near(w[i], 1.0, EPS, "at step %d only that loop" % i)
	AudioMath.engine_step_weights(steps[0] * 0.5, steps, w)
	near(w[0], 1.0, EPS, "below the first step")
	AudioMath.engine_step_weights(steps[steps.size() - 1] * 2.0, steps, w)
	near(w[steps.size() - 1], 1.0, EPS, "above the last")
	# Between two steps: equal power, and the weight moves toward the higher one.
	var prev := -1.0
	for k in 11:
		var rpm := lerpf(steps[2], steps[3], float(k) / 10.0)
		AudioMath.engine_step_weights(rpm, steps, w)
		var power := 0.0
		var nonzero := 0
		for x in w:
			power += x * x
			if x > 0.0:
				nonzero += 1
		near(power, 1.0, 1e-9, "equal power at %d rpm" % rpm)
		le(nonzero, 2, "two loops at most")
		gt(w[3], prev - EPS, "the upper loop grows with rpm")
		prev = w[3]
	near(AudioMath.engine_pitch(3000.0, 2450.0, t.engine_pitch_min, t.engine_pitch_max), 3000.0 / 2450.0, EPS)
	near(AudioMath.on_throttle_weight(1.0), 1.0, EPS)
	near(AudioMath.on_throttle_weight(0.0), 0.0, EPS)


func test_engine_crossfades_pitches_and_dips() -> void:
	var a := _audio()
	await tree.process_frame
	var e := a.engine
	var st := a.player
	st.rpm = lerpf(t.engine_step_rpm[3], t.engine_step_rpm[4], 0.5)
	for i in 30:
		a.step(DT)
	gt(e.on_gain(3), 0.0, "step 3 heard")
	gt(e.on_gain(4), 0.0, "step 4 heard")
	eq(e.on_gain(0), 0.0, "far steps silent")
	le(e.audible_loops(), 4, "at most 4 engine loops mix")
	near(e.on_players[3].pitch_scale, st.rpm / t.engine_step_rpm[3], 0.01, "pitched by rpm")
	gt(e.on_gain(3), e.off_gain(3), "on throttle: the on loop leads")
	a.player_input.throttle = 0.0
	for i in 60:
		a.step(DT)
	gt(e.off_gain(3), e.on_gain(3), "off throttle: the off loop leads")
	# An upshift dips the level, then it recovers.
	a.player_input.throttle = 1.0
	for i in 60:
		a.step(DT)
	var before := e.on_gain(3) + e.on_gain(4)
	st.gear += 1
	a.step(DT)
	lt(e.on_gain(3) + e.on_gain(4), before * 0.9, "shift dip")
	eq(e.shifts, 1)
	for i in 30:
		a.step(DT)
	near(e.on_gain(3) + e.on_gain(4), before, before * 0.05, "recovered")
	# Crash / results: the engine fades out.
	a.game_state = Game.RESULTS
	for i in 120:
		a.step(DT)
	eq(e.audible_loops(), 0, "silent at the results")


func test_wind_rises_with_speed_and_boost_intake() -> void:
	gt(AudioMath.wind_db(Units.kmh_to_mps(250.0), t), AudioMath.wind_db(Units.kmh_to_mps(120.0), t), "louder faster")
	gt(AudioMath.wind_pitch(Units.kmh_to_mps(250.0), t), AudioMath.wind_pitch(Units.kmh_to_mps(120.0), t))
	var a := _audio()
	await tree.process_frame
	a.player.v = Units.kmh_to_mps(120.0)
	for i in 60:
		a.step(DT)
	var slow := a.engine.wind_gain
	a.player.v = Units.kmh_to_mps(250.0)
	for i in 60:
		a.step(DT)
	gt(a.engine.wind_gain, slow, "wind rises with speed")
	a.player.v = Units.kmh_to_mps(20.0)
	for i in 120:
		a.step(DT)
	lt(a.engine.wind_gain, t.silent_gain * 2.0, "no wind when slow")
	# Boost: the whoosh on boost_started (same frame) and the intake roar.
	var played := a.pool.played
	Events.boost_started.emit()
	eq(a.pool.played, played + 1)
	eq(a.pool.last_id(), AudioBank.BOOST)
	a.player.boost_active = true
	for i in 30:
		a.step(DT)
	check(a.engine.intake.playing and not a.engine.intake.stream_paused, "intake roar while boosting")
	a.player.boost_active = false
	for i in 60:
		a.step(DT)
	check(a.engine.intake.stream_paused or not a.engine.intake.playing, "intake gone after boost")


# ---------------------------------------------------------------- Scoring sounds

func test_every_scoring_event_sounds_in_the_same_frame() -> void:
	var a := _audio()
	await tree.process_frame
	var p := a.pool
	var cases := [
		[Events.PASS, AudioBank.STING_PASS],
		[Events.CLOSE_PASS, AudioBank.STING_CLOSE],
		[Events.CUT, AudioBank.STING_CUT],
		[Events.THREAD, AudioBank.STING_THREAD],
	]
	for c: Array in cases:
		var frame := Engine.get_process_frames()
		var before := p.played
		Events.scored.emit(c[0], 100, 2.0, 0.6)
		gt(p.played, before, "%s plays" % c[0])
		check(p.count_recent(c[1], p.played - before) == 1, "%s stinger" % c[0])
		eq(p.last_frame(), frame, "%s in the same frame" % c[0])
	# Banking, hesitation, hit and crash too.
	for ev: Array in [
			[func() -> void: Events.chain_banked.emit(4000, Events.REASON_CASH_OUT, 4000), AudioBank.CHIME_TICK],
			[func() -> void: Events.hesitated.emit(), AudioBank.STING_HESITATED],
			[func() -> void: Events.hit.emit(Events.HIT_TRAFFIC, 1), AudioBank.STING_HIT],
			[func() -> void: Events.crash_started.emit(), AudioBank.CRASH_GLASS]]:
		var frame := Engine.get_process_frames()
		var before := p.played
		(ev[0] as Callable).call()
		gt(p.played, before, "%s plays" % ev[1])
		eq(p.count_recent(ev[1], p.played - before), 1, "%s" % ev[1])
		eq(p.last_frame(), frame, "%s in the same frame" % ev[1])


func test_close_pass_zip_and_thread_thump() -> void:
	var a := _audio()
	await tree.process_frame
	var p := a.pool
	var n := p.played
	Events.scored.emit(Events.CLOSE_PASS, 30, 1.0, 0.4)
	eq(p.played - n, 3, "stinger, whoosh, zip")
	eq(p.count_recent(AudioBank.WHOOSH, 3), 1)
	eq(p.count_recent(AudioBank.ZIP, 3), 1)
	n = p.played
	Events.scored.emit(Events.PASS, 10, 1.0, 2.0)
	eq(p.played - n, 2, "stinger and whoosh, no zip")
	eq(p.count_recent(AudioBank.ZIP, 2), 0)
	n = p.played
	Events.scored.emit(Events.THREAD, 50, 1.0, 1.2)
	eq(p.played - n, 2, "stinger and thump (the passes had their whooshes)")
	eq(p.count_recent(AudioBank.THUMP, 2), 1)


func test_whoosh_scales_with_clearance() -> void:
	var prev_db := INF
	var prev_pitch := INF
	for k in 13:
		var c := float(k) * 0.25
		var db := AudioMath.whoosh_db(c, t)
		var pitch := AudioMath.whoosh_pitch(c, t)
		le(db, prev_db + EPS, "quieter as clearance grows (%.2f m)" % c)
		le(pitch, prev_pitch + EPS, "longer (lower pitch) as clearance grows")
		prev_db = db
		prev_pitch = pitch
	gt(AudioMath.whoosh_db(0.3, t), AudioMath.whoosh_db(2.5, t), "closer is louder")
	gt(AudioMath.whoosh_pitch(0.3, t), AudioMath.whoosh_pitch(2.5, t), "closer is shorter and sharper")
	near(AudioMath.whoosh_db(0.0, t), t.whoosh_near_db, EPS, "clamped near")
	near(AudioMath.whoosh_db(10.0, t), t.whoosh_far_db, EPS, "clamped far")
	gt(AudioMath.zip_pitch(0.2, t), AudioMath.zip_pitch(0.9, t), "sharper zip when closer")
	# The played voice carries it.
	var a := _audio()
	await tree.process_frame
	Events.scored.emit(Events.PASS, 10, 1.0, 0.3)
	var near_v := a.pool.positional[_last_positional(a)]
	var near_db := near_v.volume_db
	var near_pitch := a.pool.base_pitch[_last_positional(a)]
	Events.scored.emit(Events.PASS, 10, 1.0, 2.8)
	var far_v := a.pool.positional[_last_positional(a)]
	gt(near_db, far_v.volume_db, "voice: louder when closer")
	gt(near_pitch, a.pool.base_pitch[_last_positional(a)], "voice: higher pitch when closer")


func _last_positional(a: GameAudio) -> int:
	var best := -1
	var best_order := -1
	for k in a.pool.positional.size():
		var o: int = a.pool._order[a.pool.flat.size() + k]
		if o > best_order:
			best_order = o
			best = k
	return best


func test_whoosh_sits_on_the_passed_cars_side_with_doppler() -> void:
	var a := _audio()
	await tree.process_frame
	# A car just behind on the left (fully behind: centres 1 car length apart), one far behind on the right.
	var st := _traffic(a, [[-4.6, -3.5, _sedan], [-25.0, 3.5, _sedan]])
	eq(a.traffic_audio.passed_slot(), 0, "the nearest car behind the tail")
	Events.scored.emit(Events.PASS, 10, 1.0, 1.5)
	var k := _last_positional(a)
	eq(a.pool.track_slot[k], 0, "the whoosh follows the passed car")
	lt(a.pool.positional[k].position.x, 0.0, "on its side (left)")
	# The car falls behind (we are faster): doppler lowers the pitch.
	a.step(DT)
	lt(a.pool.positional[k].pitch_scale, a.pool.base_pitch[k], "receding: doppler down")
	st.v[0] = a.player.v + 20.0
	a.step(DT)
	gt(a.pool.positional[k].pitch_scale, a.pool.base_pitch[k], "approaching: doppler up")


func test_stinger_pitch_rises_with_the_multiplier() -> void:
	near(AudioMath.stinger_pitch(1.0, t), 1.0, EPS, "1x: the base note")
	near(AudioMath.stinger_pitch(0.5, t), 1.0, EPS, "never below the base")
	var prev := 0.0
	var m := 1.0
	while m <= 256.0:
		var p := AudioMath.stinger_pitch(m, t)
		ge(p, prev, "non-decreasing at %.1fx" % m)
		prev = p
		m *= 1.25
	gt(AudioMath.stinger_pitch(4.0, t), AudioMath.stinger_pitch(1.0, t), "4x above 1x")
	gt(AudioMath.stinger_pitch(16.0, t), AudioMath.stinger_pitch(4.0, t), "16x above 4x")
	var top := t.stinger_scale_semitones[t.stinger_scale_semitones.size() - 1]
	near(AudioMath.stinger_pitch(1e9, t), pow(2.0, top / 12.0), EPS, "capped at the scale's top")
	# The voice carries it.
	var a := _audio()
	await tree.process_frame
	Events.scored.emit(Events.CUT, 15, 1.0, -1.0)
	var low := _flat_pitch(a, AudioBank.STING_CUT)
	Events.scored.emit(Events.CUT, 15, 12.0, -1.0)
	gt(_flat_pitch(a, AudioBank.STING_CUT), low, "stinger voice pitched up at 12x")


## Pitch of the newest flat voice playing `id`.
func _flat_pitch(a: GameAudio, id: StringName) -> float:
	var best := -1
	for v in a.pool.flat.size():
		if a.pool._id[v] == id and (best < 0 or a.pool._order[v] > a.pool._order[best]):
			best = v
	return a.pool.flat[best].pitch_scale if best >= 0 else 0.0


func test_banking_counts_up_then_chimes() -> void:
	var a := _audio()
	await tree.process_frame
	var p := a.pool
	var n := p.played
	var amount := roundi(t.chime_points_per_tick * 6.0)
	Events.chain_banked.emit(amount, Events.REASON_CHECKPOINT, amount)
	eq(p.played - n, 1, "the first tick at once")
	var ticks := AudioMath.chime_ticks(amount, t)
	for i in ceili(float(ticks + 2) * t.chime_tick_s / DT) + 2:
		a.step(DT)
	eq(p.count_recent(AudioBank.CHIME_TICK, p.played - n), ticks, "one tick per step of the count-up")
	eq(p.count_recent(AudioBank.CHIME_BANK, p.played - n), 1, "then the chime")
	n = p.played
	Events.chain_banked.emit(5000, Events.REASON_RUN_END, 5000)
	eq(p.played, n, "no chime for the run-end bank")


# ---------------------------------------------------------------- Traffic

func test_horns_air_brakes_and_tire_hum() -> void:
	var a := _audio()
	await tree.process_frame
	var st := _traffic(a, [[10.0, 3.5, _semi], [-8.0, -3.5, _sedan], [30.0, 0.0, _sedan],
		[60.0, 3.5, _sedan], [120.0, 0.0, _sedan]])
	# Horn with doppler, lower on a truck.
	Events.traffic_horn.emit(1, Vector3(-3.5, 0.0, 8.0))
	eq(a.pool.last_id(), AudioBank.HORN)
	var car_pitch := a.pool.base_pitch[_last_positional(a)]
	Events.traffic_horn.emit(0, Vector3(3.5, 0.0, -10.0))
	lt(a.pool.base_pitch[_last_positional(a)], car_pitch, "truck horns are lower")
	# Air brake: a brake tap on the truck hisses, a car's doesn't, and there is a cooldown.
	var n := a.pool.played
	Events.traffic_brake_tap.emit(1)
	eq(a.pool.played, n, "cars have no air brakes")
	Events.traffic_brake_tap.emit(0)
	eq(a.pool.last_id(), AudioBank.AIR_BRAKE, "the truck hisses")
	n = a.pool.played
	Events.traffic_brake_tap.emit(0)
	eq(a.pool.played, n, "cooldown")
	# A truck that starts braking hard nearby hisses too (rising edge, after the cooldown).
	a.step(DT)
	for i in ceili(t.air_brake_cooldown_s / DT) + 1:
		a.step(DT)
	n = a.pool.played
	st.flags[0] |= TrafficState.FLAG_BRAKE_STRONG
	a.step(DT)
	eq(a.pool.played, n + 1, "hard braking truck: hiss")
	eq(a.pool.last_id(), AudioBank.AIR_BRAKE)
	a.step(DT)
	eq(a.pool.played, n + 1, "once per edge")
	# Tire hum: the nearest cars within the radius, stable voices.
	for i in 30:
		a.step(DT)
	eq(a.traffic_audio.hum_count(), mini(t.tire_hum_voices, 3), "the nearest within %.0f m" % t.tire_hum_radius_m)
	for v in a.traffic_audio.hum.size():
		var s := a.traffic_audio.hum_slot[v]
		if s >= 0:
			lt(absf(st.s[s] - a.player.s), t.tire_hum_radius_m, "hum only near")
			check(a.traffic_audio.hum[v].playing, "hum playing")


# ---------------------------------------------------------------- Night, tunnel, music

func test_night_filter_toggles_on_night_and_dawn() -> void:
	var a := _audio()
	await tree.process_frame
	check(not AudioBuses.night_enabled())
	Events.night_started.emit()
	for i in ceili(t.night_fade_s / DT) + 2:
		a.step(DT)
	check(AudioBuses.night_enabled(), "night: low-pass on")
	var lp := AudioServer.get_bus_effect(AudioBuses.index(AudioBuses.MUSIC), AudioBuses.MUSIC_LOWPASS) as AudioEffectLowPassFilter
	near(lp.cutoff_hz, t.night_lowpass_hz, 1.0, "at the night cutoff")
	var rv := AudioServer.get_bus_effect(AudioBuses.index(AudioBuses.MUSIC), AudioBuses.MUSIC_REVERB) as AudioEffectReverb
	near(rv.wet, t.night_reverb_wet, 1e-3, "night reverb")
	Events.dawn_started.emit(1.0)
	for i in ceili(1.0 / DT) + 2:
		a.step(DT)
	check(not AudioBuses.night_enabled(), "dawn: off again")


func test_tunnel_reverb_on_entry_and_exit() -> void:
	var a := _audio()
	await tree.process_frame
	var road := StraightRoadPath.new(3)
	road.add_feature(RoadFeature.make(RoadFeature.Kind.TUNNEL, 1000.0, 1400.0))
	a.bind_traffic(TrafficState.new(4), _types, road, null)
	a.player.s = 800.0
	a.step(DT)
	check(not AudioBuses.tunnel_enabled(), "outside: dry")
	a.player.s = 1200.0
	a.step(DT)
	check(AudioBuses.tunnel_enabled(), "inside: reverb")
	var rv := AudioServer.get_bus_effect(AudioBuses.index(AudioBuses.SFX), AudioBuses.SFX_REVERB) as AudioEffectReverb
	near(rv.wet, t.tunnel_reverb_wet, 1e-3)
	check(AudioServer.is_bus_effect_enabled(AudioBuses.index(AudioBuses.ENGINE), AudioBuses.ENGINE_REVERB), "engine too")
	a.player.s = 1600.0
	a.step(DT)
	check(not AudioBuses.tunnel_enabled(), "out again: dry")


func test_music_plays_and_the_clock_follows() -> void:
	var a := _audio()
	await tree.process_frame
	a.music.start()
	check(a.music.is_playing(), "a track plays")
	eq(a.music.tracks_started, 1)
	eq(a.music.player.bus, AudioBuses.MUSIC)
	for path in t.music_tracks:
		check(ResourceLoader.exists(path), "track %s exists" % path)
	a.step(DT)
	check(not a.music.clock.is_running(), "no tempo known: the clock stays stopped")
	var c := MusicClock.new()
	c.sync(1.25, 120.0, 4)
	near(c.beat_phase(), 0.5, EPS)
	eq(c.beat_in_bar(), 2)
	eq(c.bar(), 0)
	c.sync(2.0, 120.0, 4)
	eq(c.bar(), 1)
	c.sync(1.0, 0.0, 4)
	eq(c.bpm(), 0.0, "tempo 0 stops it")


func test_loops_are_imported_looping() -> void:
	var b := AudioBank.new(t)
	for s in b.engine_on + b.engine_off:
		check(s != null and (s as AudioStreamOggVorbis).loop, "engine loop %s" % (s.resource_path if s != null else "missing"))
	for s: AudioStream in [b.wind_loop, b.tire_hum_loop, b.intake_loop]:
		check((s as AudioStreamOggVorbis).loop, "%s loops" % s.resource_path)
	check((b.whoosh as AudioStreamWAV).loop_mode == AudioStreamWAV.LOOP_DISABLED, "one-shots don't loop")


## WP7.6: an OGG Vorbis one-shot sets up a Vorbis decoder on every play() (~0.6 ms on the
## main thread; a 20-event frame took ~20 ms). Every sound the bank holds is either a
## looping OGG (engine, wind, tire hum, intake) or a non-looping QOA WAV one-shot, which
## starts in microseconds (docs/AUDIO.md → Assets). The scan covers every AudioStream
## member, so a new one-shot is checked without editing this test.
func test_one_shots_are_wav() -> void:
	var b := AudioBank.new(t)
	var one_shots := 0
	for p: Dictionary in b.get_property_list():
		if not (p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE) or p.type != TYPE_OBJECT:
			continue
		var s := b.get(p.name) as AudioStream
		if s == null:
			continue
		var ogg := s as AudioStreamOggVorbis
		if ogg != null:
			check(ogg.loop, "%s is OGG, so it must be a loop (one-shots are WAV)" % s.resource_path)
			continue
		var wav := s as AudioStreamWAV
		check(wav != null, "%s: a one-shot is an AudioStreamWAV (%s)" % [s.resource_path, s.get_class()])
		if wav == null:
			continue
		one_shots += 1
		eq(wav.format, AudioStreamWAV.FORMAT_QOA, "%s imported with QOA (compress/mode=2)" % s.resource_path)
		eq(wav.loop_mode, AudioStreamWAV.LOOP_DISABLED, "%s doesn't loop" % s.resource_path)
		gt(wav.get_length(), 0.0, "%s has audio" % s.resource_path)
	eq(one_shots, 19, "every one-shot in the bank was scanned")


# ---------------------------------------------------------------- Budget

func test_voice_cap_holds_and_priorities_steal() -> void:
	var a := _audio()
	await tree.process_frame
	var p := a.pool
	for i in 100:
		Events.scored.emit(Events.CLOSE_PASS, 30, 1.0 + float(i), 0.3)
		Events.traffic_horn.emit(-1, Vector3.ZERO)
		le(p.active_count(), t.max_voices, "cap holds")
	eq(p.voice_count(), t.voices_flat + t.voices_positional, "the pool never grows")
	gt(p.dropped + p.stolen, 0, "over budget: steal or drop")
	# Fill every positional voice with low-priority horns, then a whoosh steals one.
	p.stop_all()
	for i in t.voices_positional:
		Events.traffic_horn.emit(-1, Vector3.ZERO)
	var st := p.stolen
	Events.scored.emit(Events.PASS, 10, 1.0, 1.0)
	eq(p.stolen, st + 1, "the whoosh outranks a horn")
	eq(p.count_recent(AudioBank.WHOOSH, 2), 1)
	# A horn can't steal from whooshes.
	p.stop_all()
	for i in t.voices_positional:
		Events.scored.emit(Events.PASS, 10, 1.0, 1.0)
	var dr := p.dropped
	Events.traffic_horn.emit(-1, Vector3.ZERO)
	eq(p.dropped, dr + 1, "lower priority drops")


func test_no_new_nodes_or_objects_per_event() -> void:
	var a := _audio()
	await tree.process_frame
	_traffic(a, [[-4.6, -3.5, _sedan], [10.0, 3.5, _semi]])
	# Warm up once. Each play() makes an engine-side stream playback (a RefCounted the
	# player drops when the sound ends or is stopped): compare with the voices stopped.
	for i in 20:
		_burst()
		a.step(DT)
	a.pool.stop_all()
	await tree.process_frame
	var nodes := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	for i in 200:
		_burst()
		a.step(DT)
		le(a.pool.active_count(), t.max_voices)
	eq(Performance.get_monitor(Performance.OBJECT_NODE_COUNT), nodes, "no new nodes per event")
	a.pool.stop_all()
	await tree.process_frame
	le(Performance.get_monitor(Performance.OBJECT_COUNT), objects, "no objects left behind per event")


func _burst() -> void:
	Events.scored.emit(Events.PASS, 10, 2.0, 1.1)
	Events.scored.emit(Events.CLOSE_PASS, 30, 3.0, 0.4)
	Events.scored.emit(Events.THREAD, 50, 4.0, 1.0)
	Events.scored.emit(Events.CUT, 15, 4.0, -1.0)
	Events.traffic_horn.emit(1, Vector3.ZERO)
	Events.hesitated.emit()


# ---------------------------------------------------------------- The run

func test_attached_to_the_run() -> void:
	var r := RUN_SCENE.instantiate() as Run
	r.manual_ticks = true
	r.auto_countdown = false
	r.record_best = false
	r.crash_cinematic = false
	r.run_seed = 4242
	tree.root.add_child(r)
	_nodes.append(r)
	await tree.process_frame
	var a := r.get_node_or_null(^"GameAudio") as GameAudio
	if not check(a != null, "the run attaches GameAudio"):
		return
	a.music.stop()
	r.go()
	for i in 30:
		r.tick()
		a.step(DT)
	check(a.player == r.car.state, "reads the run's car")
	check(a.traffic_audio.traffic == r.sim.state, "reads the run's traffic")
	gt(a.engine.audible_loops(), 0, "the engine runs")
	check(a.hub == r.hub, "mute key wired")
