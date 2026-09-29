class_name NetServerFrame
extends RefCounted
## One decoded server → client frame, for the 20 Hz downstream hot path. Spec: multiplayer
## handoff → Networking protocol (PlayerStates, TrafficSpawn/Despawn/Intent/Correction,
## batched); docs/PROTOCOL.md §4. WP N2.2. Filled by NetCodec.decode_server_frame_into().
##
## Structure of arrays, pre-sized at init to the most entries a 16 KB frame can hold, so
## decoding the hot messages allocates nothing: `player_states` entries go to `ps_*`,
## `traffic_spawn` to `sp_*`, `traffic_despawn` to `ds_*`, `traffic_intent` to `in_*`,
## `traffic_correction` to `co_*` (each entry carries its batch's tick). Values are wire
## units (mm, cm, cm/s, 1e-4 rad, ...; convert with NetCodec's `*_from_wire`); enums are
## indices into NetCodec's name tables and flags are bit sets. u32 fields use
## PackedInt64Array. Every other message is a vector-JSON Dictionary in `messages`.
##
## `order_*` keeps the frame's message order: message i has type `order_type[i]` and covers
## entries `order_first[i] ..< order_first[i] + order_count[i]` of that type's arrays (for
## other types, `messages[order_first[i]]`). A consumer that only cares about one kind reads
## its arrays directly. Reuse one instance; the next decode clears it.

const PLAYER_ENTRY_LEN := 24
const SPAWN_LEN := 23
const INTENT_LEN := 14
const CORRECTION_LEN := 10
const DESPAWN_LEN := 2

## Entry capacities: more than a 16,384-byte frame can carry (16384 / entry bytes, rounded
## up); test_codec_vectors checks them against NetCodec.MAX_FRAME_LEN.
const PS_CAP := 683
const SP_CAP := 713
const DS_CAP := 8193
const IN_CAP := 1171
const CO_CAP := 1639

var order_count_total: int = 0
var order_type := PackedInt32Array()
var order_first := PackedInt32Array()
var order_count := PackedInt32Array()

## Non-batch messages of this frame, in order (Welcome, Pong, Error, lobby, room, score...).
var messages: Array[Dictionary] = []

var ps_count: int = 0
var ps_player_id := PackedInt32Array()
var ps_tick := PackedInt64Array()
var ps_s_mm := PackedInt64Array()
var ps_d_cm := PackedInt32Array()
var ps_heading_e4 := PackedInt32Array()
var ps_speed_cms := PackedInt32Array()
var ps_lat_vel_cms := PackedInt32Array()
var ps_yaw_rate_mrad_s := PackedInt32Array()
var ps_steer_e4 := PackedInt32Array()
var ps_flags := PackedInt32Array()
var ps_run_state := PackedInt32Array()

var sp_count: int = 0
var sp_car_id := PackedInt32Array()
var sp_vehicle := PackedInt32Array()
var sp_color := PackedInt32Array()
var sp_profile := PackedInt32Array()
var sp_lane := PackedInt32Array()
var sp_s_mm := PackedInt64Array()
var sp_d_cm := PackedInt32Array()
var sp_speed_cms := PackedInt32Array()
var sp_lc_phase := PackedInt32Array()
var sp_lc_target_lane := PackedInt32Array()
var sp_lc_move_start_tick := PackedInt64Array()
var sp_lc_duration_ms := PackedInt32Array()
var sp_flags := PackedInt32Array()

var ds_count: int = 0
var ds_car_id := PackedInt32Array()

var in_count: int = 0
var in_car_id := PackedInt32Array()
var in_kind := PackedInt32Array()
var in_start_tick := PackedInt64Array()
var in_move_start_tick := PackedInt64Array()
var in_target_lane := PackedInt32Array()
var in_duration_ms := PackedInt32Array()

var co_count: int = 0
var co_tick := PackedInt64Array()
var co_car_id := PackedInt32Array()
var co_s_mm := PackedInt64Array()
var co_d_cm := PackedInt32Array()
var co_speed_cms := PackedInt32Array()


func _init() -> void:
	order_type.resize(NetCodec.MAX_MESSAGES_PER_FRAME)
	order_first.resize(NetCodec.MAX_MESSAGES_PER_FRAME)
	order_count.resize(NetCodec.MAX_MESSAGES_PER_FRAME)
	ps_player_id.resize(PS_CAP)
	ps_tick.resize(PS_CAP)
	ps_s_mm.resize(PS_CAP)
	ps_d_cm.resize(PS_CAP)
	ps_heading_e4.resize(PS_CAP)
	ps_speed_cms.resize(PS_CAP)
	ps_lat_vel_cms.resize(PS_CAP)
	ps_yaw_rate_mrad_s.resize(PS_CAP)
	ps_steer_e4.resize(PS_CAP)
	ps_flags.resize(PS_CAP)
	ps_run_state.resize(PS_CAP)
	sp_car_id.resize(SP_CAP)
	sp_vehicle.resize(SP_CAP)
	sp_color.resize(SP_CAP)
	sp_profile.resize(SP_CAP)
	sp_lane.resize(SP_CAP)
	sp_s_mm.resize(SP_CAP)
	sp_d_cm.resize(SP_CAP)
	sp_speed_cms.resize(SP_CAP)
	sp_lc_phase.resize(SP_CAP)
	sp_lc_target_lane.resize(SP_CAP)
	sp_lc_move_start_tick.resize(SP_CAP)
	sp_lc_duration_ms.resize(SP_CAP)
	sp_flags.resize(SP_CAP)
	ds_car_id.resize(DS_CAP)
	in_car_id.resize(IN_CAP)
	in_kind.resize(IN_CAP)
	in_start_tick.resize(IN_CAP)
	in_move_start_tick.resize(IN_CAP)
	in_target_lane.resize(IN_CAP)
	in_duration_ms.resize(IN_CAP)
	co_tick.resize(CO_CAP)
	co_car_id.resize(CO_CAP)
	co_s_mm.resize(CO_CAP)
	co_d_cm.resize(CO_CAP)
	co_speed_cms.resize(CO_CAP)


func clear() -> void:
	order_count_total = 0
	messages.clear()
	ps_count = 0
	sp_count = 0
	ds_count = 0
	in_count = 0
	co_count = 0


func push_order(type_id: int, first: int, n: int) -> void:
	order_type[order_count_total] = type_id
	order_first[order_count_total] = first
	order_count[order_count_total] = n
	order_count_total += 1


## The frame as vector-JSON Dictionaries, in message order (tests and debugging; allocates).
func to_dicts() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in order_count_total:
		var first := order_first[i]
		var n := order_count[i]
		match order_type[i]:
			NetCodec.MSG_PLAYER_STATES:
				var players := []
				for k in range(first, first + n):
					players.append({"player_id": ps_player_id[k], "state": _player_state_dict(k)})
				out.append({"type": "player_states", "players": players})
			NetCodec.MSG_TRAFFIC_SPAWN:
				var cars := []
				for k in range(first, first + n):
					cars.append({
						"car_id": sp_car_id[k], "vehicle": sp_vehicle[k], "color": sp_color[k],
						"profile": sp_profile[k], "lane": sp_lane[k], "s_mm": sp_s_mm[k],
						"d_cm": sp_d_cm[k], "speed_cms": sp_speed_cms[k],
						"lc_phase": NetCodec.LC_PHASE[sp_lc_phase[k]],
						"lc_target_lane": sp_lc_target_lane[k],
						"lc_move_start_tick": sp_lc_move_start_tick[k],
						"lc_duration_ms": sp_lc_duration_ms[k],
						"flags": NetCodec.bits_to_flags(sp_flags[k], NetCodec.TRAFFIC_FLAGS),
					})
				out.append({"type": "traffic_spawn", "cars": cars})
			NetCodec.MSG_TRAFFIC_DESPAWN:
				var ids := []
				for k in range(first, first + n):
					ids.append(ds_car_id[k])
				out.append({"type": "traffic_despawn", "car_ids": ids})
			NetCodec.MSG_TRAFFIC_INTENT:
				var intents := []
				for k in range(first, first + n):
					intents.append({
						"car_id": in_car_id[k], "kind": NetCodec.INTENT_KIND[in_kind[k]],
						"start_tick": in_start_tick[k], "move_start_tick": in_move_start_tick[k],
						"target_lane": in_target_lane[k], "duration_ms": in_duration_ms[k],
					})
				out.append({"type": "traffic_intent", "intents": intents})
			NetCodec.MSG_TRAFFIC_CORRECTION:
				var corr := []
				for k in range(first, first + n):
					corr.append({"car_id": co_car_id[k], "s_mm": co_s_mm[k], "d_cm": co_d_cm[k],
						"speed_cms": co_speed_cms[k]})
				out.append({"type": "traffic_correction",
					"tick": co_tick[first] if n > 0 else 0, "cars": corr})
			_:
				out.append(messages[first])
	return out


## Copies player_states entry `k` into `st` (no allocation).
func player_state_into(k: int, st: NetPlayerState) -> void:
	st.tick = ps_tick[k]
	st.s_mm = ps_s_mm[k]
	st.d_cm = ps_d_cm[k]
	st.heading_e4 = ps_heading_e4[k]
	st.speed_cms = ps_speed_cms[k]
	st.lat_vel_cms = ps_lat_vel_cms[k]
	st.yaw_rate_mrad_s = ps_yaw_rate_mrad_s[k]
	st.steer_e4 = ps_steer_e4[k]
	st.flags = ps_flags[k]
	st.run_state = ps_run_state[k]


func _player_state_dict(k: int) -> Dictionary:
	return {
		"tick": ps_tick[k], "s_mm": ps_s_mm[k], "d_cm": ps_d_cm[k],
		"heading_e4": ps_heading_e4[k], "speed_cms": ps_speed_cms[k],
		"lat_vel_cms": ps_lat_vel_cms[k], "yaw_rate_mrad_s": ps_yaw_rate_mrad_s[k],
		"steer_e4": ps_steer_e4[k],
		"flags": NetCodec.bits_to_flags(ps_flags[k], NetCodec.PLAYER_FLAGS),
		"run_state": NetCodec.RUN_STATE[ps_run_state[k]],
	}
