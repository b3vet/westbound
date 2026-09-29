extends WBTest
## Codec hot-path cost: the 20 Hz PlayerState upload and the 20 Hz downstream frame.
## Spec: multiplayer handoff → Networking protocol (PlayerStates batched at 20 Hz;
## corrections batched), Client changes → Performance ("everything stays within the
## original performance budget"); docs/PROTOCOL.md §11 (typical tick). WP N2.2.
##
## Budgets are ~3x the local median (WBBench rule of thumb); the printed numbers go into
## docs/NET_CLIENT.md.

const ITER := 2000

var codec: NetCodec
var st: NetPlayerState
var sink: NetServerFrame
var typical: PackedByteArray
var busy: PackedByteArray


func before_all() -> void:
	codec = NetCodec.new()
	st = NetPlayerState.new()
	st.set_physical(123456, 12345.678, -1.75, 0.0873, 69.44, -0.42, 0.118, -0.125,
		NetCodec.PLAYER_FLAG_BOOST | NetCodec.PLAYER_FLAG_HEADLIGHTS, 2)
	sink = NetServerFrame.new()
	var s2c := NetCodec.Direction.SERVER_TO_CLIENT
	# Typical tick (PROTOCOL.md §11): 7 remote players + a correction batch of 4 cars.
	var players := []
	for i in 7:
		var p := st.to_dict(false)
		p["s_mm"] = 12345678 + i * 20000
		players.append({"player_id": i + 1, "state": p})
	var corr := []
	for i in 4:
		corr.append({"car_id": 400 + i, "s_mm": 13000250 + i * 30000, "d_cm": 175 * (i - 2),
			"speed_cms": 3056})
	var base := [
		{"type": "player_states", "players": players},
		{"type": "traffic_correction", "tick": 123456, "cars": corr},
	]
	typical = codec.encode_frame(base, s2c)
	# Busy tick: plus a spawn, a despawn, two intents and a score sync.
	var spawn := {"car_id": 412, "vehicle": 3, "color": 7, "profile": 1, "lane": 2,
		"s_mm": 13000250, "d_cm": 525, "speed_cms": 3056, "lc_phase": "none",
		"lc_target_lane": 0, "lc_move_start_tick": 0, "lc_duration_ms": 0,
		"flags": {"hazard": false, "braking": false}}
	var intent := {"car_id": 412, "kind": "lane_change", "start_tick": 123456,
		"move_start_tick": 123476, "target_lane": 1, "duration_ms": 2500}
	var extra := base.duplicate()
	extra.append_array([
		{"type": "traffic_spawn", "cars": [spawn]},
		{"type": "traffic_despawn", "car_ids": [97]},
		{"type": "traffic_intent", "intents": [intent, intent]},
		{"type": "score_sync", "tick": 123460, "run_seq": 3, "banked": 125000, "chain": 4200,
			"multiplier_milli": 12500, "lives": 2, "crew_in_range": 2,
			"flags": {"banking": false, "night": true, "unverified": false}},
	])
	busy = codec.encode_frame(extra, s2c)


func _encode_player_state() -> void:
	codec.push_player_state(st)
	codec.finish_frame()


func _encode_player_state_dict() -> void:
	codec.encode_frame([st.to_dict()], NetCodec.Direction.CLIENT_TO_SERVER)


func _quantize_player_state() -> void:
	st.set_physical(123456, 12345.678, -1.75, 0.0873, 69.44, -0.42, 0.118, -0.125, 0, 2)


func _decode_typical() -> void:
	codec.decode_server_frame_into(typical, sink)


func _decode_busy() -> void:
	codec.decode_server_frame_into(busy, sink)


func _decode_typical_dicts() -> void:
	codec.decode_frame(typical, NetCodec.Direction.SERVER_TO_CLIENT)


func test_frames_are_what_the_budget_assumes() -> void:
	eq(typical.size(), 3 + 1 + 7 * 24 + 3 + 5 + 4 * 10, "typical frame bytes")
	eq(codec.decode_server_frame_into(typical, sink), "")
	eq(sink.ps_count, 7)
	eq(sink.co_count, 4)
	eq(codec.decode_server_frame_into(busy, sink), "")
	eq(sink.messages.size(), 1, "only score_sync takes the Dictionary path")


func test_player_state_encode_cost() -> void:
	var usec := WBBench.usec_per_call(_encode_player_state, ITER)
	WBBench.report("PlayerState encode + frame (typed)", usec, 30.0)
	le(usec, WBBench.budget(30.0), "PlayerState encode usec")
	var q := WBBench.usec_per_call(_quantize_player_state, ITER)
	WBBench.report("PlayerState quantize", q, 30.0)
	le(q, WBBench.budget(30.0), "quantize usec")
	var d := WBBench.usec_per_call(_encode_player_state_dict, ITER)
	WBBench.report("PlayerState encode via Dictionary (reference)", d, 300.0)


func test_downstream_frame_decode_cost() -> void:
	var usec := WBBench.usec_per_call(_decode_typical, ITER)
	WBBench.report("typical 20 Hz frame decode (7 players + 4 corrections)", usec, 150.0)
	le(usec, WBBench.budget(150.0), "typical frame decode usec")
	var b := WBBench.usec_per_call(_decode_busy, ITER)
	WBBench.report("busy 20 Hz frame decode (+spawn, despawn, 2 intents, score sync)", b, 300.0)
	le(b, WBBench.budget(300.0), "busy frame decode usec")
	var d := WBBench.usec_per_call(_decode_typical_dicts, ITER)
	WBBench.report("typical frame via Dictionaries (reference)", d, 1500.0)
