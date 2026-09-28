class_name VehicleTestDriver
extends RefCounted
## Scripted-input driver for the vehicle physics tests (not a test suite: the runner
## skips tests/fixtures). Drives VehiclePhysics.step on a real road fixture and
## measures the spec's lane change independently of VehicleParams' own procedure
## (plain bisection, fixed horizon, a road and a non-zero start offset), so the test
## can prove the capability curve agrees with simulation.
##
## Lane-change definition (docs/PHYSICS.md): speed held constant; full input for a
## whole number of ticks, then release; time = input start until |d - final| <=
## settle_m and |yaw| <= settle_yaw for good; interpolated between the two holds whose
## settled offsets bracket the distance.

## Ticks simulated after the release (the car is long settled by then).
const HORIZON_S := 3.0

var params: VehicleParams
var road: RoadPath
var dt: float
var state := VehicleState.new()
var input := VehicleInput.new()
var d0 := 0.0
var d_trace := PackedFloat64Array()
var yaw_trace := PackedFloat64Array()
var yaw_rate_trace := PackedFloat64Array()
var ticks := 0


class Move:
	extends RefCounted
	var time_s := 0.0
	var final_d := 0.0
	var overshoot_m := 0.0
	var drift_after_window_m := 0.0
	var reverse_yaw_after_release := 0.0   ## largest |yaw| of the opposite sign after release
	var peak_yaw_rate := 0.0
	var hold_ticks := 0


func _init(p: VehicleParams, r: RoadPath, start_d: float) -> void:
	params = p
	road = r
	dt = p.physics_dt
	d0 = start_d


## Full input (`dir` = +1 right, -1 left) for hold_ticks at constant speed v, then
## release; runs HORIZON_S more. Traces d (relative to the start), yaw and yaw rate.
## Returns the final offset (signed).
func run_move(v: float, hold_ticks: int, dir: float = 1.0) -> float:
	VehiclePhysics.place(state, params, 0.0, d0, v)
	input.clear()
	ticks = hold_ticks + ceili(HORIZON_S / dt)
	d_trace.resize(ticks)
	yaw_trace.resize(ticks)
	yaw_rate_trace.resize(ticks)
	for i in ticks:
		input.steer = dir if i < hold_ticks else 0.0
		state.v = v
		VehiclePhysics.step(state, input, dt, params, road)
		d_trace[i] = state.d - d0
		yaw_trace[i] = state.yaw
		yaw_rate_trace[i] = state.yaw_rate
	return d_trace[ticks - 1]


## Measures the run in the traces (hold_ticks given), against its own final offset.
func measure_run(hold_ticks: int) -> Move:
	var m := Move.new()
	var final_d := d_trace[ticks - 1]
	var last_bad := -1
	var peak := 0.0
	for i in ticks:
		peak = maxf(peak, absf(d_trace[i]))
		m.peak_yaw_rate = maxf(m.peak_yaw_rate, absf(yaw_rate_trace[i]))
		if absf(d_trace[i] - final_d) > params.settle_m or absf(yaw_trace[i]) > params.settle_yaw_rad:
			last_bad = i
		if i >= hold_ticks and yaw_trace[i] * signf(final_d) < 0.0:
			m.reverse_yaw_after_release = maxf(m.reverse_yaw_after_release, absf(yaw_trace[i]))
	var window := hold_ticks + ceili(params.settle_window_s / dt) - 1
	m.time_s = float(last_bad + 1) * dt
	m.final_d = final_d
	m.overshoot_m = maxf(peak - absf(final_d), 0.0)
	m.drift_after_window_m = absf(final_d - d_trace[mini(window, ticks - 1)])
	m.hold_ticks = hold_ticks
	return m


## The spec's lane change of `distance` at speed v (to the right when dir > 0).
## Overshoot, drift and reverse yaw are the worse of the two bracketing runs.
func lane_change(v: float, distance: float, dir: float = 1.0) -> Move:
	var lo := 0
	var hi := 1
	while absf(run_move(v, hi, dir)) < distance:
		lo = hi
		hi *= 2
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if absf(run_move(v, mid, dir)) < distance:
			lo = mid
		else:
			hi = mid
	run_move(v, hi, dir)
	var b := measure_run(hi)
	if lo == 0:
		var w0 := distance / absf(b.final_d)
		b.time_s *= w0
		return b
	run_move(v, lo, dir)
	var a := measure_run(lo)
	var w := (distance - absf(a.final_d)) / (absf(b.final_d) - absf(a.final_d))
	a.time_s = lerpf(a.time_s, b.time_s, w)
	a.final_d = distance * signf(dir)
	a.overshoot_m = maxf(a.overshoot_m, b.overshoot_m)
	a.drift_after_window_m = maxf(a.drift_after_window_m, b.drift_after_window_m)
	a.reverse_yaw_after_release = maxf(a.reverse_yaw_after_release, b.reverse_yaw_after_release)
	a.peak_yaw_rate = maxf(a.peak_yaw_rate, b.peak_yaw_rate)
	return a


## Full-throttle time from rest to v_target via VehiclePhysics.step (sub-tick
## interpolated); INF if not reached within max_s.
func time_to_speed(v_target: float, max_s: float) -> float:
	VehiclePhysics.place(state, params, 0.0, d0, 0.0)
	input.clear()
	input.throttle = 1.0
	var t := 0.0
	while t < max_s:
		var v := state.v
		VehiclePhysics.step(state, input, dt, params, road)
		if state.v >= v_target:
			return t + dt * (v_target - v) / (state.v - v)
		t += dt
	return INF


## Full-brake time from v_from down to v_to (throttle off), sub-tick interpolated.
func brake_time(v_from: float, v_to: float, max_s: float) -> float:
	VehiclePhysics.place(state, params, 0.0, d0, v_from)
	input.clear()
	input.brake = 1.0
	var t := 0.0
	while t < max_s:
		var v := state.v
		VehiclePhysics.step(state, input, dt, params, road)
		if state.v <= v_to:
			return t + dt * (v - v_to) / (v - state.v)
		t += dt
	return INF
