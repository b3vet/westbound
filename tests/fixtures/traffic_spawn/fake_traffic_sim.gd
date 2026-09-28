class_name FakeTrafficSim
extends RefCounted
## Stand-in for WP2.4's TrafficSim in the spawning tests (not a test suite: the runner
## skips tests/fixtures). Same members the director uses: `state`, `spawn(rec) -> int`,
## `despawn(slot)`; plus a trivial kinematic `step` (s += v dt, no IDM, no lane changes).
## Also logs every spawn so tests can check where vehicles appeared.

var state: TrafficState
var road: RoadPath
var types: Array[VehicleType]

## Spawn log (one entry per successful spawn).
var log_s := PackedFloat64Array()
var log_d := PackedFloat64Array()
var log_v := PackedFloat64Array()
var log_lane := PackedInt32Array()
var log_length := PackedFloat64Array()
var log_width := PackedFloat64Array()
var despawn_count := 0


func _init(capacity: int, road_path: RoadPath, vehicle_types: Array[VehicleType]) -> void:
	state = TrafficState.new(capacity)
	road = road_path
	types = vehicle_types


func spawn(rec: SpawnSource.Record) -> int:
	var i := state.allocate()
	if i < 0:
		return -1
	var t := types[rec.type_id]
	state.s[i] = rec.s
	state.d[i] = road.lane_center_d(rec.lane, rec.s) if is_nan(rec.d) else rec.d
	state.v[i] = rec.v
	state.v0[i] = rec.v0
	state.length[i] = t.length_m
	state.width[i] = t.width_m
	state.lane[i] = rec.lane
	state.target_lane[i] = rec.lane
	state.type_id[i] = rec.type_id
	state.profile_id[i] = rec.profile_id
	state.model_variant[i] = rec.model_variant
	state.color_index[i] = rec.color_index
	state.flags[i] = rec.flags
	log_s.append(state.s[i])
	log_d.append(state.d[i])
	log_v.append(state.v[i])
	log_lane.append(rec.lane)
	log_length.append(t.length_m)
	log_width.append(t.width_m)
	return i


func despawn(slot: int) -> void:
	state.free_slot(slot)
	despawn_count += 1


func step(dt: float) -> void:
	for i in state.capacity:
		if state.active[i] == 1:
			state.s[i] += state.v[i] * dt


func spawn_count() -> int:
	return log_s.size()
