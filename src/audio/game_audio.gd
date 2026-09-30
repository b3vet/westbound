class_name GameAudio
extends Node
## The game's audio: buses and volumes, engine and wind, pass and traffic sounds,
## stingers, music. Spec: Audio, haptics and game feel (Audio; "every scoring event
## gets sound ... within one frame"); Architecture rules 4 and 7 (audio only listens;
## pooled players). docs/AUDIO.md.
##
## It only listens to `Events` and reads state; it never drives gameplay. Attach it to
## a run with GameAudio.attach(run) (one line in run.gd), or register it as the `Audio`
## autoload and call attach(run) the same way: attach() reuses /root/Audio when it
## exists. Per frame it re-reads the run's car, traffic, road and origin (a retry
## rebuilds them), then updates the engine, wind, traffic, tunnel reverb, the
## banking count-up and the music. Event handlers start their sound on the spot, so a
## sound starts in the frame of its event (VoicePool records the frame).
##
## Scoring:  scored -> stinger (UI, pitched by the multiplier) + pass/close/thread:
##           whoosh at the passed car (SFX, level and pitch by clearance, doppler),
##           close pass: zip, thread: thump. chain_banked -> count-up ticks + chime.
##           hesitated, hit, crash -> their stings; barrier_scrape -> scrape.
## Traffic:  traffic_horn -> horn at the car (doppler; heavy vehicles lower);
##           traffic_brake_tap (heavy) and hard braking trucks -> air-brake hiss.
## Night:    night_started -> music low-pass + reverb in; dawn_started -> out.
## Settings: volume_* and audio_muted (Settings), the M key (PlayerInput.mute_toggled).
## Slow motion doesn't bend audio; smoothing runs on real time. Reduced motion doesn't
## affect audio.

const AUTOLOAD_PATH := ^"/root/Audio"

var tuning: AudioTuning
var bank: AudioBank
var pool: VoicePool
var engine: EngineAudio
var traffic_audio: TrafficAudio
var music: MusicPlayer

## Bound sources (read-only). A bound run refreshes them each frame; tests set them.
var run: Run
var player: VehicleState
var player_input: VehicleInput
var hub: PlayerInput
## The run state (Game.*) as last announced.
var game_state: StringName = Game.RUNNING
var paused: bool = false
## The mute setting as applied to the Master bus.
var muted: bool = false
## Tunnel factor 0..1 at the player (tests may set tunnel_override >= 0).
var tunnel: float = 0.0
var tunnel_override: float = -1.0
## Music starts on its own (off in tests that count voices).
var autoplay_music: bool = true
## WP9.2: the web audio unlock (music waits for the first gesture). Made in setup() on
## the web; tests set one (with a scripted bridge) before setup.
var web_audio: WebAudio

## Banking count-up in progress: ticks left, time to the next, tick index.
var chime_left: int = 0
var _chime_timer: float = 0.0
var _chime_index: int = 0
var _scrape_at: float = -INF
var _clock: float = 0.0
var _bus_db := PackedFloat64Array()
var _bus_target := PackedFloat64Array()
var _tunnel_light: TunnelLight
var _tunnel_road: RoadPath
var _types: Array[VehicleType] = []
var _bound_traffic: TrafficState


## Attaches the game audio to `r`: the /root/Audio autoload when it exists, else a new
## child of the run. Returns the node.
static func attach(r: Run) -> GameAudio:
	var tree := r.get_tree() if r.is_inside_tree() else null
	var existing: GameAudio = null
	if tree != null:
		existing = tree.root.get_node_or_null(AUTOLOAD_PATH) as GameAudio
	if existing != null:
		existing.bind_run(r)
		return existing
	var a := GameAudio.new()
	a.name = "GameAudio"
	a.run = r
	r.add_child(a)
	return a


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	setup()


## Builds everything once (idempotent): buses, bank, voices, loops, music.
func setup(t: AudioTuning = null) -> void:
	if tuning != null:
		return
	tuning = t if t != null else AudioTuning.resolve()
	AudioBuses.ensure_layout()
	bank = AudioBank.new(tuning)
	pool = VoicePool.new()
	pool.name = "Voices"
	add_child(pool)
	pool.setup(tuning)
	engine = EngineAudio.new()
	engine.name = "Engine"
	add_child(engine)
	engine.setup(tuning, bank)
	traffic_audio = TrafficAudio.new()
	traffic_audio.name = "Traffic"
	add_child(traffic_audio)
	traffic_audio.setup(tuning, bank)
	traffic_audio.air_brake.connect(_on_air_brake)
	music = MusicPlayer.new()
	music.name = "Music"
	add_child(music)
	music.setup(tuning)
	if web_audio == null and WebAudio.wanted():
		web_audio = WebAudio.new()
	if web_audio != null:
		if web_audio.get_parent() == null:
			add_child(web_audio)
		web_audio.bind_music(music)
	_bus_db.resize(AudioBuses.NAMES.size())
	_bus_target.resize(AudioBuses.NAMES.size())
	apply_volumes(true)
	if run != null:
		bind_run(run)
	if autoplay_music:
		music.start()


func bind_run(r: Run) -> void:
	run = r
	if r != null and r.hub != null:
		bind_hub(r.hub)


func bind_hub(h: PlayerInput) -> void:
	if hub == h:
		return
	if hub != null and hub.mute_toggled.is_connected(toggle_mute):
		hub.mute_toggled.disconnect(toggle_mute)
	hub = h
	if hub != null:
		hub.mute_toggled.connect(toggle_mute)


## Binds the traffic the sounds follow (a run does this itself each frame).
func bind_traffic(state: TrafficState, types: Array[VehicleType], road: RoadPath, origin: FloatingOrigin) -> void:
	_bound_traffic = state
	_types = types
	traffic_audio.bind(state, types, road, origin, player)
	if road != _tunnel_road:
		_tunnel_road = road
		_tunnel_light = TunnelLight.new(road) if road != null else null


func _enter_tree() -> void:
	_connect(Events.scored, _on_scored)
	_connect(Events.chain_banked, _on_chain_banked)
	_connect(Events.hesitated, _on_hesitated)
	_connect(Events.hit, _on_hit)
	_connect(Events.crash_started, _on_crash_started)
	_connect(Events.barrier_scrape, _on_barrier_scrape)
	_connect(Events.boost_started, _on_boost_started)
	_connect(Events.traffic_horn, _on_traffic_horn)
	_connect(Events.traffic_brake_tap, _on_traffic_brake_tap)
	_connect(Events.night_started, _on_night_started)
	_connect(Events.dawn_started, _on_dawn_started)
	_connect(Events.morning_reached, _on_morning_reached)
	_connect(Events.run_started, _on_run_started)
	_connect(Events.game_state_changed, _on_game_state_changed)
	_connect(Events.paused_changed, _on_paused_changed)
	_connect(Events.settings_changed, _on_settings_changed)
	_connect(Events.bonus_awarded, _on_bonus_awarded)


func _exit_tree() -> void:
	_disconnect(Events.scored, _on_scored)
	_disconnect(Events.chain_banked, _on_chain_banked)
	_disconnect(Events.hesitated, _on_hesitated)
	_disconnect(Events.hit, _on_hit)
	_disconnect(Events.crash_started, _on_crash_started)
	_disconnect(Events.barrier_scrape, _on_barrier_scrape)
	_disconnect(Events.boost_started, _on_boost_started)
	_disconnect(Events.traffic_horn, _on_traffic_horn)
	_disconnect(Events.traffic_brake_tap, _on_traffic_brake_tap)
	_disconnect(Events.night_started, _on_night_started)
	_disconnect(Events.dawn_started, _on_dawn_started)
	_disconnect(Events.morning_reached, _on_morning_reached)
	_disconnect(Events.run_started, _on_run_started)
	_disconnect(Events.game_state_changed, _on_game_state_changed)
	_disconnect(Events.paused_changed, _on_paused_changed)
	_disconnect(Events.settings_changed, _on_settings_changed)
	_disconnect(Events.bonus_awarded, _on_bonus_awarded)
	if hub != null and hub.mute_toggled.is_connected(toggle_mute):
		hub.mute_toggled.disconnect(toggle_mute)
	hub = null


static func _disconnect(sig: Signal, c: Callable) -> void:
	if sig.is_connected(c):
		sig.disconnect(c)


static func _connect(sig: Signal, c: Callable) -> void:
	if not sig.is_connected(c):
		sig.connect(c)


# ---------------------------------------------------------------- Per frame

func _process(delta: float) -> void:
	# Real time: slow motion (Engine.time_scale) must not slow the smoothing.
	var dt := delta / Engine.time_scale if Engine.time_scale > 0.0 else delta
	step(dt)


## One audio frame (tests call it directly). Allocation-free.
func step(dt: float) -> void:
	if tuning == null:
		return
	_clock += dt
	_sync_run()
	_glide_volumes(dt)
	var driving := not paused and (game_state == Game.RUNNING or game_state == Game.COUNTDOWN)
	if not paused:
		engine.update(dt, player, player_input, driving)
		traffic_audio.update(dt, pool, game_state == Game.RUNNING or game_state == Game.CRASH)
		_update_tunnel()
		_update_chime(dt)
	music.update(dt)


func _sync_run() -> void:
	if run == null or not is_instance_valid(run):
		return
	var car := run.car
	if car != null:
		player = car.state
		player_input = car.input
	if run.hub != null and run.hub != hub:
		bind_hub(run.hub)
	var st := run.sim.state if run.sim != null else null
	if st != _bound_traffic or traffic_audio.road != run.road:
		var types: Array[VehicleType] = run.registry.types if run.registry != null else _types
		bind_traffic(st, types, run.road, run.origin)
	traffic_audio.player = player
	if run.state != game_state and run.state != Game.PAUSED:
		game_state = run.state


func _update_tunnel() -> void:
	var f := 0.0
	if tunnel_override >= 0.0:
		f = tunnel_override
	elif _tunnel_light != null and player != null:
		f = _tunnel_light.factor_at(player.s)
	tunnel = f
	AudioBuses.set_tunnel(f, tuning)


func _update_chime(dt: float) -> void:
	if chime_left <= 0:
		return
	_chime_timer -= dt
	while chime_left > 0 and _chime_timer <= 0.0:
		_chime_tick()
		_chime_timer += tuning.chime_tick_s


func _chime_tick() -> void:
	chime_left -= 1
	if chime_left == 0:
		pool.play(AudioBank.CHIME_BANK, bank.chime_bank, AudioBuses.UI, tuning.chime_bank_db, 1.0,
			tuning.priority_chime)
		return
	var scale := tuning.stinger_scale_semitones
	var semi := scale[_chime_index % scale.size()] if not scale.is_empty() else 0.0
	_chime_index += 1
	pool.play(AudioBank.CHIME_TICK, bank.chime_tick, AudioBuses.UI, tuning.chime_tick_db,
		pow(2.0, semi / AudioMath.SEMITONES), tuning.priority_chime)


# ---------------------------------------------------------------- Volumes

## Reads the volume settings and mute into the bus targets (`snap`: no glide).
func apply_volumes(snap: bool = false) -> void:
	muted = AudioBuses.setting_muted()
	for i in AudioBuses.NAMES.size():
		var target := AudioBuses.target_db(AudioBuses.base_db(i, tuning), AudioBuses.setting_volume(i))
		_bus_target[i] = target
		if snap:
			_bus_db[i] = target
		_set_bus(i, _bus_db[i])


## The M key: flips the audio_muted setting.
func toggle_mute() -> void:
	if Settings.DEFAULTS.has(AudioBuses.MUTE_KEY):
		Settings.set_value(AudioBuses.MUTE_KEY, not AudioBuses.setting_muted())


## A bus's current level (dB; -INF = off) and where it is gliding to (tests).
func bus_db(i: int) -> float:
	return _bus_db[i]


func bus_target_db(i: int) -> float:
	return _bus_target[i]


func _glide_volumes(dt: float) -> void:
	var k := AudioMath.smooth(dt, tuning.volume_glide_s)
	for i in _bus_db.size():
		var target := _bus_target[i]
		var cur := _bus_db[i]
		if cur == target:
			continue
		if is_inf(target) or is_inf(cur) or absf(target - cur) < AudioMath.DB_SNAP:
			cur = target
		else:
			cur += (target - cur) * k
		_bus_db[i] = cur
		_set_bus(i, cur)


## Writes a bus level: -INF mutes the bus; Master is also muted by the mute setting.
func _set_bus(i: int, db: float) -> void:
	var b := AudioBuses.index(AudioBuses.NAMES[i])
	if b < 0:
		return
	var off := is_inf(db)
	AudioServer.set_bus_mute(b, off or (i == 0 and muted))
	if not off:
		AudioServer.set_bus_volume_db(b, db)


# ---------------------------------------------------------------- Event handlers

func _on_scored(kind: StringName, _points: int, multiplier: float, clearance_m: float) -> void:
	var t := tuning
	var pitch := AudioMath.stinger_pitch(multiplier, t)
	match kind:
		Events.PASS:
			pool.play(AudioBank.STING_PASS, bank.sting_pass, AudioBuses.UI, t.sting_pass_db, pitch, t.priority_stinger)
			_whoosh(clearance_m)
		Events.CLOSE_PASS:
			pool.play(AudioBank.STING_CLOSE, bank.sting_close, AudioBuses.UI, t.sting_close_db, pitch, t.priority_stinger)
			_whoosh(clearance_m)
			pool.play(AudioBank.ZIP, bank.zip, AudioBuses.SFX, t.zip_db, AudioMath.zip_pitch(clearance_m, t), t.priority_zip)
		Events.THREAD:
			pool.play(AudioBank.STING_THREAD, bank.sting_thread, AudioBuses.UI, t.sting_thread_db, pitch, t.priority_stinger)
			pool.play(AudioBank.THUMP, bank.thump, AudioBuses.SFX, t.thump_db, 1.0, t.priority_thump)
		Events.CUT:
			pool.play(AudioBank.STING_CUT, bank.sting_cut, AudioBuses.UI, t.sting_cut_db, pitch, t.priority_stinger)
		_:
			pool.play(AudioBank.STING_PASS, bank.sting_pass, AudioBuses.UI, t.sting_pass_db, pitch, t.priority_stinger)


## The pass whoosh at the passed car (level and pitch by clearance), following it.
func _whoosh(clearance_m: float) -> void:
	var t := tuning
	var db := AudioMath.whoosh_db(clearance_m, t)
	var pitch := AudioMath.whoosh_pitch(clearance_m, t)
	var slot := traffic_audio.passed_slot()
	if slot >= 0:
		pool.play_at(AudioBank.WHOOSH, bank.whoosh, AudioBuses.SFX, db, pitch, t.priority_whoosh,
			traffic_audio.slot_position(slot), slot, traffic_audio.traffic.vehicle_id[slot], traffic_audio.doppler(slot))
	else:
		pool.play_at(AudioBank.WHOOSH, bank.whoosh, AudioBuses.SFX, db, pitch, t.priority_whoosh,
			traffic_audio.fallback_position(1.0))


func _on_chain_banked(amount: int, reason: StringName, _banked_total: int) -> void:
	if amount <= 0 or reason == Events.REASON_RUN_END:
		return
	chime_left = AudioMath.chime_ticks(amount, tuning) + 1   # the ticks, then the chime
	_chime_index = 0
	_chime_timer = tuning.chime_tick_s
	_chime_tick()   # the first tick in this frame


func _on_bonus_awarded(_kind: StringName, points: int, _banked_total: int) -> void:
	if points > 0:
		pool.play(AudioBank.CHIME_BANK, bank.chime_bank, AudioBuses.UI, tuning.bonus_chime_db, 1.0,
			tuning.priority_chime)


func _on_hesitated() -> void:
	pool.play(AudioBank.STING_HESITATED, bank.sting_hesitated, AudioBuses.UI, tuning.sting_hesitated_db, 1.0,
		tuning.priority_hit)


func _on_hit(_source: StringName, _lives_left: int) -> void:
	pool.play(AudioBank.HIT_IMPACT, bank.hit_impact, AudioBuses.SFX, tuning.hit_impact_db, 1.0, tuning.priority_hit)
	pool.play(AudioBank.STING_HIT, bank.sting_hit, AudioBuses.UI, tuning.sting_hit_db, 1.0, tuning.priority_hit)


func _on_crash_started() -> void:
	chime_left = 0
	pool.play(AudioBank.CRASH_METAL, bank.crash_metal, AudioBuses.SFX, tuning.crash_db, 1.0, tuning.priority_hit)
	pool.play(AudioBank.CRASH_GLASS, bank.crash_glass, AudioBuses.SFX, tuning.crash_db, 1.0, tuning.priority_hit)
	game_state = Game.CRASH


func _on_barrier_scrape(world_pos: Vector3) -> void:
	if _clock - _scrape_at < tuning.scrape_min_interval_s:
		return
	_scrape_at = _clock
	pool.play_at(AudioBank.SCRAPE, bank.scrape, AudioBuses.SFX, tuning.scrape_db, 1.0, tuning.priority_scrape, world_pos)


func _on_boost_started() -> void:
	pool.play(AudioBank.BOOST, bank.boost_whoosh, AudioBuses.SFX, tuning.boost_whoosh_db, 1.0, tuning.priority_boost)


func _on_traffic_horn(slot: int, world_pos: Vector3) -> void:
	var t := tuning
	var ts := traffic_audio.traffic
	if ts == null or slot < 0 or slot >= ts.capacity:
		pool.play_at(AudioBank.HORN, bank.horn, AudioBuses.SFX, t.horn_db, 1.0, t.priority_horn, world_pos)
		return
	var vid := ts.vehicle_id[slot]
	var pitch := 1.0
	if t.horn_pitch_variants > 0:
		pitch += float(vid % t.horn_pitch_variants) * t.horn_pitch_step
	if traffic_audio.is_heavy(slot):
		pitch *= t.horn_heavy_pitch
	pool.play_at(AudioBank.HORN, bank.horn, AudioBuses.SFX, t.horn_db, pitch, t.priority_horn, world_pos,
		slot, vid, traffic_audio.doppler(slot))


func _on_traffic_brake_tap(slot: int) -> void:
	traffic_audio.try_air_brake(slot)


func _on_air_brake(slot: int, world_pos: Vector3) -> void:
	var ts := traffic_audio.traffic
	pool.play_at(AudioBank.AIR_BRAKE, bank.air_brake, AudioBuses.SFX, tuning.air_brake_db, 1.0,
		tuning.priority_hiss, world_pos, slot, ts.vehicle_id[slot] if ts != null else 0)


func _on_night_started() -> void:
	music.set_night(true)


func _on_dawn_started(duration_s: float) -> void:
	music.set_night(false, duration_s)


func _on_morning_reached() -> void:
	if music.night_target > 0.0:
		music.set_night(false, 0.0)


func _on_run_started(_mode: StringName, _seed: int) -> void:
	pool.stop_all()
	chime_left = 0
	engine.reset()
	music.set_night(false, 0.0)
	if autoplay_music:
		music.start()


func _on_game_state_changed(_from: StringName, to: StringName) -> void:
	if to == Game.PAUSED:
		return
	game_state = to
	if to == Game.RESULTS:
		chime_left = 0


func _on_paused_changed(p: bool) -> void:
	paused = p
	engine.set_paused(p)
	traffic_audio.set_paused(p)


func _on_settings_changed(key: StringName) -> void:
	if key == AudioBuses.MUTE_KEY or AudioBuses.VOLUME_KEYS.has(key):
		apply_volumes()
