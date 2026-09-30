class_name VerifierLimits
extends RefCounted
## What a car can physically do, measured with the game's own VehiclePhysics: the
## capability table the replay verifier holds a recorded path against. Spec: multiplayer
## handoff → Leaderboards (the verifier "checks the path against the car's physics
## limits"). WP N8.1; docs/REPLAY_FORMAT.md → Verification.
##
## For each speed bin (0, step, 2 step, ... up to the boosted top speed plus a step) the
## car is driven on a straight road at that speed (held constant) through a full-lock
## turn one way, then a full-lock reversal, each NetTuning.verify_calibration_s long. The
## largest lateral speed |d'|, lateral acceleration |d''| (per tick) and road-relative yaw
## rate seen are the bin's capability. A query takes the larger of the two bins around
## the speed. Longitudinal limits come from VehiclePhysics.longitudinal_accel directly:
## full throttle with boost, and full brake.

var params: VehicleParams
var step_mps: float = 5.0
var lat_speed := PackedFloat64Array()
var lat_accel := PackedFloat64Array()
var yaw_rate := PackedFloat64Array()


func _init(vehicle_params: VehicleParams, net_tuning: NetTuning, dt: float) -> void:
	params = vehicle_params
	step_mps = maxf(net_tuning.verify_calibration_step_mps, 1.0)
	var bins := ceili(params.boost_top_speed_mps / step_mps) + 2
	lat_speed.resize(bins)
	lat_accel.resize(bins)
	yaw_rate.resize(bins)
	var ticks := maxi(roundi(net_tuning.verify_calibration_s / dt), 1)
	var st := VehicleState.new()
	var inp := VehicleInput.new()
	for b in bins:
		var v0 := float(b) * step_mps
		VehiclePhysics.place(st, params, 0.0, 0.0, v0)
		var max_ls := 0.0
		var max_la := 0.0
		var max_yr := 0.0
		var prev_dd := 0.0
		for phase in 2:
			inp.clear()
			inp.steer = 1.0 if phase == 0 else -1.0
			for i in ticks:
				st.v = v0
				VehiclePhysics.step(st, inp, dt, params, null)
				st.v = v0
				var sy := DetMath.sin_cos(st.yaw)
				var dd := st.v * sy + st.v_lat * DetMath.cos_out
				max_ls = maxf(max_ls, absf(dd))
				max_la = maxf(max_la, absf(dd - prev_dd) / dt)
				max_yr = maxf(max_yr, absf(st.yaw_rate))
				prev_dd = dd
		lat_speed[b] = max_ls
		lat_accel[b] = max_la
		yaw_rate[b] = max_yr


## Largest lateral speed (m/s) at speed v.
func max_lat_speed(v: float) -> float:
	return _at(lat_speed, v)


## Largest lateral acceleration (m/s^2) at speed v.
func max_lat_accel(v: float) -> float:
	return _at(lat_accel, v)


## Largest road-relative yaw rate (rad/s) at speed v, on a straight road.
func max_yaw_rate(v: float) -> float:
	return _at(yaw_rate, v)


## Full throttle with boost (m/s^2, the fastest a speed can rise).
func max_accel(v: float) -> float:
	return maxf(VehiclePhysics.longitudinal_accel(params, v, 1.0, 0.0, 1.0, 1.0), 0.0)


## Full brake (m/s^2, positive: the fastest a speed can fall).
func max_decel(v: float) -> float:
	return maxf(-VehiclePhysics.longitudinal_accel(params, v, 0.0, 1.0, 0.0, 1.0), 0.0)


func _at(table: PackedFloat64Array, v: float) -> float:
	var x := clampf(absf(v) / step_mps, 0.0, float(table.size() - 1))
	var lo := floori(x)
	var hi := mini(lo + 1, table.size() - 1)
	return maxf(table[lo], table[hi])
