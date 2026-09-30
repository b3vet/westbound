class_name TrafficRegistry
extends RefCounted
## The loaded DriverProfile and VehicleType lists in a stable order, so
## TrafficState.profile_id / type_id are plain indices. Spec: Traffic → Driver types
## (the spec's 8 profiles + Racer, plan D15; IDM/MOBIL parameters per profile in
## data/driver_profiles/); Traffic roster (vehicle types). docs/CONTRACTS.md §5
## ("indices into the registries, load order") and §10. Built once per run (never in
## a tick).
##
##   var reg := TrafficRegistry.load_default(ctx.tuning.traffic)
##   var pid := reg.profile_index(&"aggressive")
##   var tids := reg.types_for_profile(pid)      # director rate (allocates)
##
## Besides the resources it caches every per-tick number in SI, structure-of-arrays,
## with the global floors of TrafficTuning applied (the 0.5 s signal floor), so
## traffic_sim reads plain packed arrays in its tick.

## Load order = profile_id / type_id. Append new entries at the end only (ids are
## stored in traces and saves).
const PROFILE_IDS: Array[StringName] = [
	&"cruiser", &"commuter", &"aggressive", &"truck", &"bus", &"van", &"motorbike", &"hesitant",
	&"racer",   # plan D15 (WP6.6)
]
const TYPE_IDS: Array[StringName] = [
	&"sedan", &"hatchback", &"suv", &"pickup", &"van", &"semi", &"coach", &"motorbike",
	&"sports", &"coupe",
]
const PROFILE_DIR := "res://data/driver_profiles/"
const TYPE_DIR := "res://data/vehicle_types/"

var profiles: Array[DriverProfile] = []
var types: Array[VehicleType] = []

# ---------------------------------------------------------------- Per profile (SI)
var v0_min := PackedFloat64Array()        ## m/s
var v0_max := PackedFloat64Array()        ## m/s
var a_max := PackedFloat64Array()         ## m/s^2
var b_comfort := PackedFloat64Array()     ## m/s^2
var headway := PackedFloat64Array()       ## s (IDM T)
var s0 := PackedFloat64Array()            ## m
var delta := PackedInt32Array()           ## IDM exponent (integral, spec: 4)
var politeness := PackedFloat64Array()    ## MOBIL p
var a_threshold := PackedFloat64Array()   ## MOBIL delta a_th, m/s^2
var a_bias := PackedFloat64Array()        ## MOBIL keep-right bias, m/s^2
var b_safe := PackedFloat64Array()        ## MOBIL b_safe, m/s^2
var signal_s := PackedFloat64Array()      ## blinker time before lateral motion (>= floor)
var move_min_s := PackedFloat64Array()
var move_max_s := PackedFloat64Array()
var eval_interval_s := PackedFloat64Array()   ## MOBIL evaluation period (tuning / frequency scale)
var cancel_p := PackedFloat64Array()      ## Hesitant: chance to cancel after signaling
var keep_right := PackedByteArray()
var keep_right_lanes := PackedInt32Array()   ## 0 = any lane
var lane_split := PackedByteArray()

# ---------------------------------------------------------------- Per type (SI)
var length := PackedFloat64Array()        ## m
var width := PackedFloat64Array()         ## m
var is_motorbike := PackedByteArray()

var _types_for_profile: Array[PackedInt32Array] = []


## Loads PROFILE_IDS and TYPE_IDS from data/ in order.
static func load_default(traffic: TrafficTuning) -> TrafficRegistry:
	var ps: Array[DriverProfile] = []
	for id in PROFILE_IDS:
		var p := load(PROFILE_DIR + String(id) + ".tres") as DriverProfile
		assert(p != null, "TrafficRegistry: missing driver profile %s" % id)
		ps.append(p)
	var ts: Array[VehicleType] = []
	for id in TYPE_IDS:
		var t := load(TYPE_DIR + String(id) + ".tres") as VehicleType
		assert(t != null, "TrafficRegistry: missing vehicle type %s" % id)
		ts.append(t)
	return TrafficRegistry.new(ps, ts, traffic)


## Tests may pass their own lists (index = position in the list).
func _init(profile_list: Array[DriverProfile], type_list: Array[VehicleType], traffic: TrafficTuning) -> void:
	profiles = profile_list.duplicate()
	types = type_list.duplicate()
	for p in profiles:
		v0_min.append(p.desired_speed_min_mps())
		v0_max.append(p.desired_speed_max_mps())
		a_max.append(p.idm_a_max_mps2)
		b_comfort.append(p.idm_b_comfort_mps2)
		headway.append(p.idm_headway_s)
		s0.append(p.idm_s0_m)
		var dl := roundi(p.idm_delta)
		assert(is_equal_approx(float(dl), p.idm_delta) and dl >= 1,
			"TrafficRegistry: %s idm_delta must be a positive integer" % p.id)
		delta.append(dl)
		politeness.append(p.mobil_politeness)
		a_threshold.append(p.mobil_threshold_mps2)
		a_bias.append(p.mobil_keep_right_bias_mps2)
		b_safe.append(p.mobil_b_safe_mps2)
		signal_s.append(maxf(p.signal_time_s, traffic.signal_time_floor_s))
		move_min_s.append(p.lane_change_move_min_s)
		move_max_s.append(maxf(p.lane_change_move_min_s, p.lane_change_move_max_s))
		eval_interval_s.append(traffic.mobil_eval_interval_s / maxf(p.lane_change_frequency_scale, 1e-3))  # lint: allow-number guard against a zero scale
		cancel_p.append(p.cancel_probability)
		keep_right.append(1 if p.keep_right else 0)
		keep_right_lanes.append(maxi(0, p.keep_right_lane_count))
		lane_split.append(1 if p.lane_split else 0)
	for t in types:
		length.append(t.length_m)
		width.append(t.width_m)
		is_motorbike.append(1 if t.is_motorbike else 0)
	for pi in profiles.size():
		var ids := PackedInt32Array()
		for ti in types.size():
			if types[ti].allowed_profiles.has(profiles[pi].id):
				ids.append(ti)
		_types_for_profile.append(ids)


func profile_count() -> int:
	return profiles.size()


func type_count() -> int:
	return types.size()


## Index of the profile with this id, or -1.
func profile_index(id: StringName) -> int:
	for i in profiles.size():
		if profiles[i].id == id:
			return i
	return -1


## Index of the vehicle type with this id, or -1.
func type_index(id: StringName) -> int:
	for i in types.size():
		if types[i].id == id:
			return i
	return -1


## Vehicle types that list this profile in allowed_profiles (director rate: returns a copy).
func types_for_profile(profile_id: int) -> PackedInt32Array:
	return _types_for_profile[profile_id].duplicate()
