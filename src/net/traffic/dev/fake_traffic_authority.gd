class_name FakeTrafficAuthority
extends RefCounted
## A stand-in for the server's room traffic (N4.2 is not built yet) for the network traffic
## harness: the real GDScript TrafficSim + TrafficDirector at the server's 20 Hz with the
## multiplayer rules as close as the client model allows, and the room's traffic stream for
## one client encoded with the real codec. Spec: multiplayer handoff → Traffic:
## server-authoritative with intents (Server simulation, What the server sends, Area of
## interest, Correction schedule), Networking protocol; docs/PROTOCOL.md §4; plan MP-D5,
## MP-D6; docs/SERVER.md → Traffic simulation (N4.1). docs/NET_TRAFFIC.md → The fake
## authority, and its checklist for N4.2. WP N4.3. Dev and test fixture only.
##
## What it runs (the MP rules of SERVER.md "The server's rules", where the GDScript sim has
## them): every car's model every tick (near_radius_m = INF), the 1.0 s signal floor for
## every profile, no lane splitting, no set pieces, the move time decided when the blinker
## comes on (it announces a duration drawn from the profile's range, whole milliseconds, and
## makes the sim use exactly that once the move starts), the move starting at the tick
## TrafficSim's own float accumulation gives (checked: `move_tick_mismatches` stays 0). On
## the loop (LoopRoadPath) the population is RunLoop's: the loop's director leg, the
## section's density and lane flow speeds. Not here: the Rust server's ring population and
## ramps, the MP-D5 safety extensions, remote players. The director keeps traffic
## `test_authority_margin_m` beyond both edges of the area of interest, so cars enter and
## leave the area by driving.
##
## The stream, per tick, one frame (docs/NET_TRAFFIC.md → Checklist for N4.2):
## `traffic_despawn` (left the area, or the sim), `traffic_spawn` (entered the area; every
## spawned car is also in this tick's correction batch, which dates the spawn),
## `traffic_intent` (lane changes when the blinker comes on, cancels, hazards and hard
## brakes of a hit), `traffic_correction` (this tick's due cars: within
## traffic_correction_near_m at the near rate, else at the far rate, staggered by car id).
## Wire conventions: NetTrafficWire (s wrapped, d left-positive, lanes from the right, 7 =
## ramp). Car ids: MP-D6 (a free list; an id is reused only traffic_car_id_reuse_s after its
## despawn; 0 is never used).

const S2C := NetCodec.Direction.SERVER_TO_CLIENT
const C2S := NetCodec.Direction.CLIENT_TO_SERVER
const NO_ID := 0
## `color` is a u8 palette index.
const COLOR_COUNT := 256

var tuning: Tuning
var net: NetTuning
var road: RoadPath
var ctx: RunContext
var registry: TrafficRegistry
var sim: TrafficSim
var director: TrafficDirector
var loop: RunLoop
var events: ScoreEventBuffer
var codec := NetCodec.new()
## Server tick of the state in `sim` (the state at time tick x dt since the room start).
var tick: int = 0
var dt: float
## The client's player as the server knows it: its latest report, extrapolated to `tick`.
var player := VehicleState.new()
## The client has joined: traffic is streamed (before that, pings only).
var joined: bool = false
## Stream everything (spawns, intents, corrections) for every car in the area; tests may
## switch parts off to exercise the client's recovery.
var send_intents: bool = true

# Counters.
var frames_sent: int = 0
var bytes_sent: int = 0
var spawns_sent: int = 0
var despawns_sent: int = 0
var intents_sent: int = 0
var cancels_sent: int = 0
var corrections_sent: int = 0
var move_tick_mismatches: int = 0
var signals_seen: int = 0

var _cap: int
var _vid := PackedInt32Array()      # per slot: the vehicle this slot's bookkeeping belongs to
var _car := PackedInt32Array()      # per slot: its car id
var _known := PackedByteArray()     # per slot: in the client's area (spawned to it)
var _prev_lc := PackedInt32Array()
var _ann_move := PackedInt64Array() # announced move-start tick
var _ann_dur := PackedFloat64Array()# announced move time (s, whole ms)
var _move_tick := PackedInt64Array()# the tick the move started
var _prev_flags := PackedInt32Array()
var _cancel_sent := PackedByteArray() # a Hesitant's cancel went out with its signal
var _rng: Rng
# Car ids (MP-D6).
var _free_ids := PackedInt32Array()     # FIFO of released ids
var _free_at := PackedInt64Array()      # the tick each was released
var _free_head: int = 0
var _next_id: int = 1
var _reuse_ticks: int
# Player reports.
var _has_report := false
var _rep_tick: int = 0
var _rep_s: float = 0.0
var _rep_d: float = 0.0
var _rep_sdot: float = 0.0
var _rep_ddot: float = 0.0
var _extrap_ticks: int
var _synced_to: float = -INF
# The frame being built.
var _despawns: Array = []
var _spawns: Array = []
var _intents: Array = []
var _corr: Array = []


## `base`: the game tuning (copied); `road`: the room's road (LoopRoadPath for the loop);
## `start_s`: where the client's player starts.
func _init(base: Tuning, road_path: RoadPath, seed_value: int, start_s: float, player_length_m: float,
		player_width_m: float) -> void:
	road = road_path
	net = base.net
	dt = 1.0 / net.tick_rate_hz
	if road.period_m() > 0.0 and road is LoopRoadPath:
		loop = RunLoop.new()
		tuning = loop.run_tuning(base)
	else:
		tuning = base.duplicate() as Tuning
		tuning.traffic = base.traffic.duplicate() as TrafficTuning
		tuning.director = base.director.duplicate() as DirectorTuning
	var t := tuning.traffic
	t.near_radius_m = INF
	t.signal_time_floor_s = net.traffic_signal_floor_s
	t.despawn_behind_m = net.traffic_aoi_behind_m + net.test_authority_margin_m
	t.spawn_ahead_m = net.traffic_aoi_ahead_m + net.test_authority_margin_m
	t.max_active_vehicles = net.test_authority_capacity
	tuning.director.set_piece_unlock_order = []
	ctx = RunContext.new(seed_value, RunContext.MODE_JOURNEY, tuning)
	registry = TrafficRegistry.load_default(t)
	for p in registry.profile_count():
		registry.lane_split[p] = 0
	events = ScoreEventBuffer.new(tuning.scoring.event_buffer_capacity)
	sim = TrafficSim.new(ctx, road, registry)
	sim.set_player_body(player_length_m, player_width_m)
	director = TrafficDirector.new(ctx, road, sim, registry.profiles, registry.types, player_length_m,
		player_width_m)
	director.set_pieces_enabled = false
	director.set_fog_end(net.traffic_aoi_ahead_m)
	_rng = ctx.rng_traffic.derive(&"fake_authority_move_time")
	_cap = sim.state.capacity
	_vid.resize(_cap)
	_car.resize(_cap)
	_known.resize(_cap)
	_prev_lc.resize(_cap)
	_ann_move.resize(_cap)
	_ann_dur.resize(_cap)
	_move_tick.resize(_cap)
	_prev_flags.resize(_cap)
	_cancel_sent.resize(_cap)
	_reuse_ticks = ceili(net.traffic_car_id_reuse_s / dt)
	_extrap_ticks = maxi(roundi(net.test_authority_extrapolation_s / dt), 0)
	player.reset()
	player.s = start_s
	player.d = road.lane_center_d(mini(1, road.lane_count(start_s) - 1), start_s)
	if loop != null:
		loop.setup(tuning)
		loop.bind_director(director, start_s)
	road.ensure_generated_to(start_s + director.ahead_distance() + tuning.director.spawn_batch_length_m * 2.0)
	director.reset(player)
	_track(false)


## The leg's IDM headway scale the sim uses (the client model needs the same).
func headway_scale() -> float:
	return tuning.director.headway_scale(director.leg)


## The client's PlayerState report (from the uplink).
func receive_player_state(st: NetPlayerState) -> void:
	_has_report = true
	_rep_tick = st.tick
	_rep_s = NetTrafficWire.s_unwrap(road, st.s_m(), player.s)
	_rep_d = NetTrafficWire.d_from_wire(st.d_cm)
	# The wire's lateral quantities are left-positive like d (docs/NET_TRAFFIC.md).
	var h := -NetCodec.heading_from_wire(st.heading_e4)
	var v := st.speed_mps()
	var vl := -NetCodec.lat_vel_from_wire(st.lat_vel_cms)
	_rep_sdot = v * cos(h) - vl * sin(h)
	_rep_ddot = v * sin(h) + vl * cos(h)


## Server clock at `t_s` seconds since the room start (ticks, fractional).
func ticks_at(t_s: float) -> float:
	return t_s / dt


## A Pong frame answering `client_time_ms`, sent at `t_s` seconds since the room start.
func pong_frame(client_time_ms: int, t_s: float) -> PackedByteArray:
	var now := ticks_at(t_s)
	var whole := floori(now)
	var frac := clampi(floori((now - float(whole)) * NetCodec.TICK_FRACTION_SCALE), 0, NetCodec.U16_MAX)
	return codec.encode_frame([{"type": "pong", "client_time_ms": client_time_ms,
		"server_tick": whole, "tick_fraction": frac}], S2C)


## The client hit car `car_id` (its hit report): the sim's hit reaction, streamed as the
## hazard and hard-brake intents.
func notify_hit(car_id: int) -> void:
	for i in _cap:
		if sim.state.active[i] == 1 and _car[i] == car_id:
			sim.notify_hit(i)
			return


## One 20 Hz room tick: the player at this tick, the loop's sections, the sim, the
## director; then the client's stream. Returns the frame (empty when there is nothing).
func step() -> PackedByteArray:
	tick += 1
	_extrapolate_player()
	# The real server knows every lane drop on the ring; the director only syncs its own
	# window. Give the sim the drops the client's area can see (area + the drop zones'
	# view and merge distances), as the server would have them.
	var t := tuning.traffic
	var horizon := net.traffic_aoi_ahead_m + t.lane_drop_view_m + t.lane_drop_merge_zone_m
	if player.s + horizon > _synced_to:
		_synced_to = player.s + horizon + t.lane_drop_merge_zone_m
		sim.sync_road_closures(player.s - t.despawn_behind_m, _synced_to)
	if loop != null:
		loop.tick(dt, player.s, events)
	sim.step(dt, player, null, events)
	director.step(dt, player)
	events.clear()
	_track(joined)
	return _build_frame()


## The car of a slot in the sim, for tests (NO_ID when not tracked).
func car_id_of_slot(i: int) -> int:
	return _car[i] if sim.state.active[i] == 1 else NO_ID


func slot_of_car(car_id: int) -> int:
	for i in _cap:
		if sim.state.active[i] == 1 and _car[i] == car_id:
			return i
	return -1


## True when the client knows the car of slot i (it is in the area).
func client_knows(i: int) -> bool:
	return _known[i] == 1


func _extrapolate_player() -> void:
	if not _has_report:
		return
	var lag := clampi(tick - _rep_tick, 0, _extrap_ticks)
	var t := float(lag) * dt
	player.s = _rep_s + _rep_sdot * t
	player.d = _rep_d + _rep_ddot * t
	player.v = _rep_sdot
	player.v_lat = _rep_ddot
	player.yaw = 0.0


# ---------------------------------------------------------------- Bookkeeping and the stream

func _track(stream: bool) -> void:
	var st := sim.state
	var p_s := player.s
	var behind := net.traffic_aoi_behind_m
	var ahead := net.traffic_aoi_ahead_m
	var hyst := net.traffic_aoi_hysteresis_m
	var near_m := net.traffic_correction_near_m
	var near_period := maxi(roundi(net.tick_rate_hz / net.traffic_correction_near_hz), 1)
	var far_period := maxi(roundi(net.tick_rate_hz / net.traffic_correction_far_hz), 1)
	for i in _cap:
		var alive := st.active[i] == 1
		if _vid[i] != 0 and (not alive or st.vehicle_id[i] != _vid[i]):
			# The car in this slot left the sim.
			if _known[i] == 1 and stream:
				_despawns.append(_car[i])
			_release_id(_car[i])
			_vid[i] = 0
			_known[i] = 0
		if not alive:
			continue
		if _vid[i] == 0:
			_vid[i] = st.vehicle_id[i]
			_car[i] = _alloc_id()
			_known[i] = 0
			_prev_lc[i] = st.lc_state[i]
			_prev_flags[i] = st.flags[i]
			_ann_move[i] = -1
			_move_tick[i] = -1
		_track_lane_change(i, stream)
		_track_reactions(i, stream)
		var ds := st.s[i] - p_s
		if not stream:
			continue
		var inside := ds >= -behind and ds <= ahead
		if _known[i] == 0 and inside:
			_known[i] = 1
			_spawns.append(_spawn_entry(i))
			_corr.append(_corr_entry(i))
			spawns_sent += 1
		elif _known[i] == 1 and (ds < -behind - hyst or ds > ahead + hyst):
			_known[i] = 0
			_despawns.append(_car[i])
			despawns_sent += 1
		elif _known[i] == 1:
			var period := near_period if absf(ds) <= near_m else far_period
			if (tick + _car[i]) % period == 0:
				_corr.append(_corr_entry(i))


func _track_lane_change(i: int, stream: bool) -> void:
	var st := sim.state
	var lc := st.lc_state[i]
	var prev := _prev_lc[i]
	_prev_lc[i] = lc
	if lc == TrafficState.LaneChange.SIGNALING and prev != TrafficState.LaneChange.SIGNALING:
		# Blinker on at this tick: the move starts where _tick_signaling's accumulation
		# reaches the signal time; the move time is decided now (whole ms).
		signals_seen += 1
		var sig := st.lc_duration[i]
		var timer := 0.0
		var n := 0
		while timer < sig:
			timer += dt
			n += 1
		_ann_move[i] = tick + n
		var p := st.profile_id[i]
		var mn := registry.move_min_s[p]
		var mx := registry.move_max_s[p]
		var dur := mn if mx <= mn else _rng.float_range(mn, mx)
		_ann_dur[i] = NetTrafficWire.ms_to_s(NetTrafficWire.s_to_ms(dur))
		_cancel_sent[i] = 0
		if stream and _known[i] == 1 and send_intents:
			_intents.append(_intent_entry(i, "lane_change", tick, _ann_move[i],
				_wire_lane(st.target_lane[i], st.s[i]), NetTrafficWire.s_to_ms(_ann_dur[i])))
			intents_sent += 1
			# A Hesitant that will cancel decided so when its blinker came on (TrafficSim
			# rolls it in _start_signal): the cancel goes out now, dated at the signal's end.
			if sim._will_cancel[i] == 1:
				_intents.append(_intent_entry(i, "cancel", _ann_move[i], _ann_move[i], 0, 0))
				_cancel_sent[i] = 1
				cancels_sent += 1
	elif lc == TrafficState.LaneChange.MOVING and prev == TrafficState.LaneChange.SIGNALING:
		if tick != _ann_move[i]:
			move_tick_mismatches += 1
		_move_tick[i] = tick
		st.lc_duration[i] = _ann_dur[i]
	elif lc == TrafficState.LaneChange.NONE and prev == TrafficState.LaneChange.SIGNALING:
		if stream and _known[i] == 1 and send_intents and not (_cancel_sent[i] == 1 and tick == _ann_move[i]):
			_intents.append(_intent_entry(i, "cancel", tick, tick, 0, 0))
			cancels_sent += 1


func _track_reactions(i: int, stream: bool) -> void:
	var f := sim.state.flags[i]
	var was := _prev_flags[i]
	_prev_flags[i] = f
	if not stream or _known[i] == 0 or not send_intents:
		return
	if (f & TrafficState.FLAG_HIT) != 0 and (was & TrafficState.FLAG_HIT) == 0:
		var t := tuning.traffic
		_intents.append(_intent_entry(i, "hazard", tick, tick, 0, NetTrafficWire.s_to_ms(t.hit_recover_s)))
		_intents.append(_intent_entry(i, "hard_brake", tick, tick, 0, NetTrafficWire.s_to_ms(t.hit_brake_s)))
		intents_sent += 2


func _wire_lane(lane: int, s: float) -> int:
	return NetTrafficWire.lane_to_wire(lane, road.lane_count(s))


func _spawn_entry(i: int) -> Dictionary:
	var st := sim.state
	var lc := st.lc_state[i]
	var phase := "none"
	var move_tick := 0
	var dur_ms := 0
	var target := 0
	if lc == TrafficState.LaneChange.SIGNALING:
		phase = "signaling"
		move_tick = _ann_move[i]
	elif lc == TrafficState.LaneChange.MOVING:
		phase = "moving"
		move_tick = _move_tick[i]
	if lc != TrafficState.LaneChange.NONE:
		dur_ms = NetTrafficWire.s_to_ms(_ann_dur[i])
		target = _wire_lane(st.target_lane[i], st.s[i])
	return {
		"car_id": _car[i], "vehicle": st.type_id[i], "color": posmod(st.color_index[i], COLOR_COUNT),
		"profile": st.profile_id[i], "lane": _wire_lane(st.lane[i], st.s[i]),
		"s_mm": NetCodec.s_to_wire(NetTrafficWire.s_wrap(road, st.s[i])),
		"d_cm": NetTrafficWire.d_to_wire(st.d[i]), "speed_cms": NetCodec.speed_to_wire(st.v[i]),
		"lc_phase": phase, "lc_target_lane": target, "lc_move_start_tick": maxi(move_tick, 0),
		"lc_duration_ms": dur_ms,
		"flags": {"hazard": st.has_flag(i, TrafficState.FLAG_HAZARD),
			"braking": st.has_flag(i, TrafficState.FLAG_BRAKE)},
	}


func _corr_entry(i: int) -> Dictionary:
	var st := sim.state
	corrections_sent += 1
	return {"car_id": _car[i], "s_mm": NetCodec.s_to_wire(NetTrafficWire.s_wrap(road, st.s[i])),
		"d_cm": NetTrafficWire.d_to_wire(st.d[i]), "speed_cms": NetCodec.speed_to_wire(st.v[i])}


func _intent_entry(i: int, kind: String, start: int, move: int, target: int, dur_ms: int) -> Dictionary:
	return {"car_id": _car[i], "kind": kind, "start_tick": start, "move_start_tick": move,
		"target_lane": target, "duration_ms": dur_ms}


func _build_frame() -> PackedByteArray:
	var msgs: Array = []
	_batches(msgs, "traffic_despawn", "car_ids", _despawns, NetCodec.MAX_TRAFFIC_BATCH)
	_batches(msgs, "traffic_spawn", "cars", _spawns, NetCodec.MAX_TRAFFIC_BATCH)
	_batches(msgs, "traffic_intent", "intents", _intents, NetCodec.MAX_INTENT_BATCH)
	var k := 0
	while k < _corr.size():
		var n := mini(NetCodec.MAX_TRAFFIC_BATCH, _corr.size() - k)
		msgs.append({"type": "traffic_correction", "tick": tick, "cars": _corr.slice(k, k + n)})
		k += n
	_despawns.clear()
	_spawns.clear()
	_intents.clear()
	_corr.clear()
	if msgs.is_empty():
		return PackedByteArray()
	var bytes := codec.encode_frame(msgs, S2C)
	assert(codec.error == "", "FakeTrafficAuthority: cannot encode the frame: %s" % codec.error)
	frames_sent += 1
	bytes_sent += bytes.size()
	return bytes


static func _batches(msgs: Array, type_name: String, field: String, items: Array, cap: int) -> void:
	var k := 0
	while k < items.size():
		var n := mini(cap, items.size() - k)
		msgs.append({"type": type_name, field: items.slice(k, k + n)})
		k += n


func _alloc_id() -> int:
	if _free_head < _free_ids.size() and tick - _free_at[_free_head] >= _reuse_ticks:
		_free_head += 1
		return _free_ids[_free_head - 1]
	_next_id += 1
	assert(_next_id <= NetCodec.U16_MAX + 2, "FakeTrafficAuthority: car ids exhausted")
	return _next_id - 1


func _release_id(id: int) -> void:
	if id == NO_ID:
		return
	_free_ids.append(id)
	_free_at.append(tick)
