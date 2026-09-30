class_name TrafficState
extends RefCounted
## Traffic on one carriageway as a structure of arrays with fixed capacity.
## Spec: Traffic → Road-space simulation (vehicle state list), tick budget (60 cap),
## Visuals (lights). See docs/CONTRACTS.md "TrafficState" for field ownership.
##
## Every array is allocated once in _init() with `capacity` entries and never
## resized. A slot is live when active[i] == 1; iterate `for i in capacity` and skip
## inactive slots. allocate()/free_slot() and every accessor are allocation-free.
##
## Slot vs vehicle_id: the slot index `i` is what Events carry (traffic_horn etc.) and
## what views index. vehicle_id[i] is unique per spawn within a run (slots are reused),
## so per-car memory (cut cooldowns, pass tracking) keys on vehicle_id.
##
## Units: SI, road space, right-positive (d > 0 = right of the reference line).
## s and d refer to the center of the vehicle's box; length/width are the visual body
## (collision inset is applied by consumers from LivesTuning.collision_inset_m).

enum LaneChange { NONE = 0, SIGNALING = 1, MOVING = 2 }

const FLAG_BRAKE := 1 << 0           ## decel > TrafficTuning.brake_light_decel_mps2
const FLAG_BRAKE_STRONG := 1 << 1    ## decel > brake_light_strong_decel_mps2 (brighter)
const FLAG_BLINKER_LEFT := 1 << 2
const FLAG_BLINKER_RIGHT := 1 << 3
const FLAG_HAZARD := 1 << 4
const FLAG_HEADLIGHTS := 1 << 5
const FLAG_HIGH_BEAM := 1 << 6
const FLAG_SCRIPTED := 1 << 7        ## driven by a set piece (may exceed the decel clamp if warned)
const FLAG_HIT := 1 << 8             ## recovering from a player hit (swerve, hazards)
const FLAG_FAR := 1 << 9             ## beyond near_radius_m: ticks at far_tick_hz

var capacity: int
## Live vehicles.
var count: int = 0
## Next vehicle_id to hand out (monotonic within a run).
var next_vehicle_id: int = 1

var active: PackedByteArray
var vehicle_id: PackedInt32Array
var s: PackedFloat64Array            ## m along the road (box center)
var d: PackedFloat64Array            ## m lateral, + right
var v: PackedFloat64Array            ## m/s along the road
var v0: PackedFloat64Array           ## m/s desired speed (IDM v0)
var v_lat: PackedFloat64Array        ## m/s lateral (d_dot); visual yaw = atan2(v_lat, v)
var accel: PackedFloat64Array        ## m/s^2 longitudinal, after clamps
var length: PackedFloat64Array       ## m
var width: PackedFloat64Array        ## m
var lane: PackedInt32Array           ## current lane (0 = next to the median)
var target_lane: PackedInt32Array    ## == lane unless a change is signaled or moving
var lc_state: PackedInt32Array       ## LaneChange
var lc_timer: PackedFloat64Array     ## s elapsed in the current lc_state
var lc_duration: PackedFloat64Array  ## s: signal time while SIGNALING, move time while MOVING
var lc_start_d: PackedFloat64Array   ## d when the lateral move started (smoothstep origin)
var react_timer: PackedFloat64Array  ## s: reaction/recovery timer (hit recovery, brake tap, horns)
var type_id: PackedInt32Array        ## index into the VehicleType registry
var profile_id: PackedInt32Array     ## index into the DriverProfile registry
var model_variant: PackedInt32Array  ## index into the type's model_scene_paths
var color_index: PackedInt32Array    ## index into the biome traffic palette
var flags: PackedInt32Array          ## FLAG_* bitfield

var _free: PackedInt32Array          ## stack of free slots; top at _free_top - 1
var _free_top: int = 0


func _init(slots: int) -> void:
	capacity = slots
	active = _bytes(slots)
	vehicle_id = _ints(slots)
	s = _floats(slots)
	d = _floats(slots)
	v = _floats(slots)
	v0 = _floats(slots)
	v_lat = _floats(slots)
	accel = _floats(slots)
	length = _floats(slots)
	width = _floats(slots)
	lane = _ints(slots)
	target_lane = _ints(slots)
	lc_state = _ints(slots)
	lc_timer = _floats(slots)
	lc_duration = _floats(slots)
	lc_start_d = _floats(slots)
	react_timer = _floats(slots)
	type_id = _ints(slots)
	profile_id = _ints(slots)
	model_variant = _ints(slots)
	color_index = _ints(slots)
	flags = _ints(slots)
	_free = _ints(slots)
	clear()


## Frees every slot and restarts vehicle ids.
func clear() -> void:
	count = 0
	next_vehicle_id = 1
	_free_top = capacity
	for i in capacity:
		active[i] = 0
		# Lowest slot on top, so allocation order is 0, 1, 2, ...
		_free[i] = capacity - 1 - i
		_reset_slot(i)


## Claims a free slot, zeroes it and assigns a fresh vehicle_id. Returns -1 when full.
func allocate() -> int:
	if _free_top == 0:
		return -1
	_free_top -= 1
	var i := _free[_free_top]
	_reset_slot(i)
	active[i] = 1
	vehicle_id[i] = next_vehicle_id
	next_vehicle_id += 1
	count += 1
	return i


## Releases slot i (despawn). Freeing an inactive slot is a programming error.
func free_slot(i: int) -> void:
	assert(active[i] == 1, "TrafficState.free_slot: slot %d is not active" % i)
	active[i] = 0
	_free[_free_top] = i
	_free_top += 1
	count -= 1


func is_active(i: int) -> bool:
	return active[i] == 1


func is_full() -> bool:
	return _free_top == 0


func has_flag(i: int, flag: int) -> bool:
	return (flags[i] & flag) != 0


func set_flag(i: int, flag: int, on: bool) -> void:
	if on:
		flags[i] |= flag
	else:
		flags[i] &= ~flag


## Copies every slot from `o` (same capacity) element-wise, so neither side's
## buffers are shared or reallocated. Used by passability's forward simulation.
func copy_from(o: TrafficState) -> void:
	assert(o.capacity == capacity, "TrafficState.copy_from: capacity mismatch")
	count = o.count
	next_vehicle_id = o.next_vehicle_id
	_free_top = o._free_top
	for i in capacity:
		active[i] = o.active[i]
		vehicle_id[i] = o.vehicle_id[i]
		s[i] = o.s[i]
		d[i] = o.d[i]
		v[i] = o.v[i]
		v0[i] = o.v0[i]
		v_lat[i] = o.v_lat[i]
		accel[i] = o.accel[i]
		length[i] = o.length[i]
		width[i] = o.width[i]
		lane[i] = o.lane[i]
		target_lane[i] = o.target_lane[i]
		lc_state[i] = o.lc_state[i]
		lc_timer[i] = o.lc_timer[i]
		lc_duration[i] = o.lc_duration[i]
		lc_start_d[i] = o.lc_start_d[i]
		react_timer[i] = o.react_timer[i]
		type_id[i] = o.type_id[i]
		profile_id[i] = o.profile_id[i]
		model_variant[i] = o.model_variant[i]
		color_index[i] = o.color_index[i]
		flags[i] = o.flags[i]
		_free[i] = o._free[i]


## Hash of every live slot (slot index and all fields, exact bits). Allocation-free.
func hash_into(h: int) -> int:
	h = TraceHash.mix_int(h, count)
	h = TraceHash.mix_int(h, next_vehicle_id)
	for i in capacity:
		if active[i] == 0:
			continue
		h = TraceHash.mix_int(h, i)
		h = TraceHash.mix_int(h, vehicle_id[i])
		h = TraceHash.mix_float(h, s[i])
		h = TraceHash.mix_float(h, d[i])
		h = TraceHash.mix_float(h, v[i])
		h = TraceHash.mix_float(h, v0[i])
		h = TraceHash.mix_float(h, v_lat[i])
		h = TraceHash.mix_float(h, accel[i])
		h = TraceHash.mix_float(h, length[i])
		h = TraceHash.mix_float(h, width[i])
		h = TraceHash.mix_int(h, lane[i])
		h = TraceHash.mix_int(h, target_lane[i])
		h = TraceHash.mix_int(h, lc_state[i])
		h = TraceHash.mix_float(h, lc_timer[i])
		h = TraceHash.mix_float(h, lc_duration[i])
		h = TraceHash.mix_float(h, lc_start_d[i])
		h = TraceHash.mix_float(h, react_timer[i])
		h = TraceHash.mix_int(h, type_id[i])
		h = TraceHash.mix_int(h, profile_id[i])
		h = TraceHash.mix_int(h, model_variant[i])
		h = TraceHash.mix_int(h, color_index[i])
		h = TraceHash.mix_int(h, flags[i])
	return h


func trace_hash() -> int:
	return hash_into(TraceHash.SEED)


func _reset_slot(i: int) -> void:
	vehicle_id[i] = 0
	s[i] = 0.0
	d[i] = 0.0
	v[i] = 0.0
	v0[i] = 0.0
	v_lat[i] = 0.0
	accel[i] = 0.0
	length[i] = 0.0
	width[i] = 0.0
	lane[i] = 0
	target_lane[i] = 0
	lc_state[i] = LaneChange.NONE
	lc_timer[i] = 0.0
	lc_duration[i] = 0.0
	lc_start_d[i] = 0.0
	react_timer[i] = 0.0
	type_id[i] = 0
	profile_id[i] = 0
	model_variant[i] = 0
	color_index[i] = 0
	flags[i] = 0


static func _floats(n: int) -> PackedFloat64Array:
	var a := PackedFloat64Array()
	a.resize(n)
	return a


static func _ints(n: int) -> PackedInt32Array:
	var a := PackedInt32Array()
	a.resize(n)
	return a


static func _bytes(n: int) -> PackedByteArray:
	var a := PackedByteArray()
	a.resize(n)
	return a
