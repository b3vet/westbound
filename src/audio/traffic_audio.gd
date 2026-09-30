class_name TrafficAudio
extends Node
## Traffic around the player: tire hum of the nearest cars, truck air-brake hiss, and
## placement plus doppler for the pool's positional voices (pass whooshes, horns).
## Spec: Audio ("Pass whoosh: a doppler whoosh per passed car"; "Traffic: horns with
## doppler, a truck air-brake hiss and tire hum"). docs/AUDIO.md → Traffic.
##
## Reads TrafficState (read-only) in road space: per frame one pass over the live slots
## finds the tire_hum_voices nearest cars within tire_hum_radius_m (insertion into
## fixed arrays) and the heavy vehicles that start braking hard within
## air_brake_radius_m (a rising FLAG_BRAKE_STRONG edge; per-slot memory keyed on
## vehicle_id, with a cooldown). A hum voice keeps its car while it stays among the
## nearest, so voices don't jump. Doppler comes from AudioMath.doppler_pitch on the
## road-space offset and relative velocity. Positions are render space (the road
## sample + the floating origin); the camera is the listener.
## Allocation-free per frame (arrays sized in bind()).

signal air_brake(slot: int, world_pos: Vector3)

var tuning: AudioTuning
var traffic: TrafficState
var road: RoadPath
var origin: FloatingOrigin
var player: VehicleState
## Per vehicle type: heavy (trucks, buses).
var heavy_type := PackedByteArray()

var hum: Array[AudioStreamPlayer3D] = []
var hum_slot := PackedInt32Array()
var hum_vehicle := PackedInt32Array()
var hum_gain := PackedFloat64Array()
## Air-brake memory per slot.
var _prev_flags := PackedInt32Array()
var _prev_vid := PackedInt32Array()
var _hiss_at := PackedFloat64Array()
var _near_slot := PackedInt32Array()
var _near_dist := PackedFloat64Array()
var _smp := RoadSample.new()
var _clock: float = 0.0


func setup(t: AudioTuning, bank: AudioBank) -> void:
	tuning = t
	if not hum.is_empty():
		return
	for i in t.tire_hum_voices:
		var p := AudioStreamPlayer3D.new()
		p.name = "Hum%d" % i
		p.stream = bank.tire_hum_loop
		p.bus = AudioBuses.SFX
		p.unit_size = t.positional_unit_size_m
		p.max_distance = t.positional_max_distance_m
		p.panning_strength = t.positional_panning
		p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		p.volume_db = linear_to_db(t.silent_gain)
		add_child(p)
		hum.append(p)
	hum_slot.resize(hum.size())
	hum_vehicle.resize(hum.size())
	hum_gain.resize(hum.size())
	_near_slot.resize(hum.size())
	_near_dist.resize(hum.size())
	for i in hum.size():
		hum_slot[i] = -1


## Binds the traffic and the heavy-vehicle table (run start; allocates once per run).
func bind(state: TrafficState, types: Array[VehicleType], road_path: RoadPath, floating_origin: FloatingOrigin,
		player_state: VehicleState) -> void:
	player = player_state
	road = road_path
	origin = floating_origin
	if state != traffic:
		traffic = state
		var cap := state.capacity if state != null else 0
		_prev_flags.resize(cap)
		_prev_vid.resize(cap)
		_hiss_at.resize(cap)
		for i in cap:
			_prev_flags[i] = 0
			_prev_vid[i] = 0
			_hiss_at[i] = -INF
	heavy_type.resize(types.size())
	for i in types.size():
		heavy_type[i] = 1 if types[i] != null and types[i].mass_kg >= tuning.heavy_mass_kg else 0
	for i in hum.size():
		hum_slot[i] = -1
		hum_gain[i] = 0.0


func is_heavy(slot: int) -> bool:
	if traffic == null or slot < 0 or slot >= traffic.capacity:
		return false
	var ty := traffic.type_id[slot]
	return ty >= 0 and ty < heavy_type.size() and heavy_type[ty] == 1


## Per frame: hum voices, air-brake edges, tracked pool voices. `dt` is real time.
func update(dt: float, pool: VoicePool, active: bool) -> void:
	_clock += dt
	if traffic == null or player == null or not active:
		for i in hum.size():
			hum_slot[i] = -1
		_fade_hum(dt)
		return
	_scan()
	_assign_hum()
	_fade_hum(dt)
	if pool != null:
		_track(pool)


## The live slot the player most likely just passed: nearest behind the player's tail
## (a pass is paid once the car is fully behind), within the search window. -1 if none.
func passed_slot() -> int:
	if traffic == null or player == null:
		return -1
	var best := -1
	var best_gap := INF
	for i in traffic.capacity:
		if traffic.active[i] == 0:
			continue
		var ds := traffic.s[i] - player.s
		if ds > tuning.pass_search_ahead_m or ds < -tuning.pass_search_behind_m:
			continue
		var gap := absf(ds + traffic.length[i] * 0.5)
		if gap < best_gap:
			best_gap = gap
			best = i
	return best


## Render-space position of a traffic slot (or of a road point), and fallbacks when no
## road is bound (tests): relative to the origin, x = d, z = -s.
func slot_position(slot: int) -> Vector3:
	return road_position(traffic.s[slot], traffic.d[slot])


func road_position(s: float, d: float) -> Vector3:
	if road != null:
		road.sample_into(s, _smp)
		if origin != null:
			return _smp.local_point(d, origin.origin_x, origin.origin_y, origin.origin_z)
		return _smp.local_point(d, 0.0, 0.0, 0.0)
	return Vector3(d, 0.0, -s)


## Where a pass whoosh goes when no car is found: beside and behind the player.
func fallback_position(side: float) -> Vector3:
	if player == null:
		return Vector3(side * tuning.pass_fallback_side_m, 0.0, tuning.pass_fallback_behind_m)
	return road_position(player.s - tuning.pass_fallback_behind_m, player.d + side * tuning.pass_fallback_side_m)


## Doppler pitch factor for a slot relative to the player.
func doppler(slot: int) -> float:
	if traffic == null or player == null:
		return 1.0
	return AudioMath.doppler_pitch(traffic.s[slot] - player.s, traffic.d[slot] - player.d,
		traffic.v[slot] - player.v, traffic.v_lat[slot] - player.v_lat, tuning)


func hum_count() -> int:
	var n := 0
	for i in hum.size():
		if hum_slot[i] >= 0:
			n += 1
	return n


func _scan() -> void:
	for k in _near_slot.size():
		_near_slot[k] = -1
		_near_dist[k] = INF
	var r2 := tuning.tire_hum_radius_m * tuning.tire_hum_radius_m
	var h2 := tuning.air_brake_radius_m * tuning.air_brake_radius_m
	for i in traffic.capacity:
		if traffic.active[i] == 0:
			continue
		var ds := traffic.s[i] - player.s
		var dd := traffic.d[i] - player.d
		var dist2 := ds * ds + dd * dd
		if dist2 < r2:
			_insert_near(i, dist2)
		var flags := traffic.flags[i]
		var vid := traffic.vehicle_id[i]
		if vid != _prev_vid[i]:
			_prev_vid[i] = vid
			_prev_flags[i] = flags
			continue
		var strong := (flags & TrafficState.FLAG_BRAKE_STRONG) != 0
		var was := (_prev_flags[i] & TrafficState.FLAG_BRAKE_STRONG) != 0
		_prev_flags[i] = flags
		if strong and not was and dist2 < h2 and is_heavy(i):
			try_air_brake(i)


## Air brake for `slot` unless it hissed within the cooldown. Returns true if it fires.
func try_air_brake(slot: int) -> bool:
	if slot < 0 or slot >= _hiss_at.size() or not is_heavy(slot):
		return false
	if _clock - _hiss_at[slot] < tuning.air_brake_cooldown_s:
		return false
	_hiss_at[slot] = _clock
	air_brake.emit(slot, slot_position(slot))
	return true


func _insert_near(slot: int, dist2: float) -> void:
	var n := _near_slot.size()
	if n == 0 or dist2 >= _near_dist[n - 1]:
		return
	var k := n - 1
	while k > 0 and _near_dist[k - 1] > dist2:
		_near_dist[k] = _near_dist[k - 1]
		_near_slot[k] = _near_slot[k - 1]
		k -= 1
	_near_dist[k] = dist2
	_near_slot[k] = slot


func _assign_hum() -> void:
	# Drop voices whose car left the nearest set (or whose slot was reused).
	for v in hum.size():
		var s := hum_slot[v]
		if s < 0:
			continue
		if traffic.active[s] == 0 or traffic.vehicle_id[s] != hum_vehicle[v] or not _is_near(s):
			hum_slot[v] = -1
	# Give unheard near cars a free voice.
	for k in _near_slot.size():
		var s := _near_slot[k]
		if s < 0 or _has_hum(s):
			continue
		for v in hum.size():
			if hum_slot[v] < 0 and hum_gain[v] <= tuning.silent_gain:
				hum_slot[v] = s
				hum_vehicle[v] = traffic.vehicle_id[s]
				break


func _is_near(slot: int) -> bool:
	for k in _near_slot.size():
		if _near_slot[k] == slot:
			return true
	return false


func _has_hum(slot: int) -> bool:
	for v in hum.size():
		if hum_slot[v] == slot:
			return true
	return false


func _fade_hum(dt: float) -> void:
	var t := tuning
	var step := dt / maxf(t.tire_hum_fade_s, dt)
	for v in hum.size():
		var p := hum[v]
		var s := hum_slot[v]
		var target := 0.0
		var pitch := 1.0
		if s >= 0:
			var heavy := is_heavy(s)
			var speed01 := AudioMath.ramp(absf(traffic.v[s]), 0.0, t.tire_hum_full_mps())
			target = db_to_linear(t.tire_hum_db + (t.tire_hum_heavy_db if heavy else 0.0))
			pitch = lerpf(t.tire_hum_pitch_min, t.tire_hum_pitch_max, speed01) \
				* (t.tire_hum_heavy_pitch if heavy else 1.0) * doppler(s)
			p.position = slot_position(s)
		hum_gain[v] = move_toward(hum_gain[v], target, step * maxf(target, db_to_linear(t.tire_hum_db)))
		if hum_gain[v] <= t.silent_gain:
			if p.playing and not p.stream_paused:
				p.stream_paused = true
			continue
		p.volume_db = linear_to_db(hum_gain[v])
		p.pitch_scale = pitch
		if not p.playing:
			p.play()
		if p.stream_paused:
			p.stream_paused = false


## Moves the pool's positional voices that follow a car and applies its doppler.
func _track(pool: VoicePool) -> void:
	for k in pool.positional.size():
		var s := pool.track_slot[k]
		if s < 0:
			continue
		var p := pool.positional[k]
		if not p.playing or s >= traffic.capacity or traffic.active[s] == 0 \
				or traffic.vehicle_id[s] != pool.track_vehicle[k]:
			pool.track_slot[k] = VoicePool.NO_SLOT
			continue
		p.position = slot_position(s)
		p.pitch_scale = pool.base_pitch[k] * doppler(s)


func set_paused(paused: bool) -> void:
	for p in hum:
		if paused:
			p.stream_paused = true
