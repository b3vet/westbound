class_name VehicleParams
extends RefCounted
## Derived SI parameters for VehiclePhysics.step, built once per car per run (never in
## a tick) from VehicleTuning + CarDef (+ an optional VehicleType), plus the car's
## lane-change capability curve. Spec: Car physics and feel (model, car stats, lane-
## change targets); Traffic -> Passability guarantee step 2 ("moves are limited by
## the player car's real lane-change capability ... the passability check reads the
## same curve"). See docs/PHYSICS.md.
##
##   var params := VehicleParams.build(run.tuning, car_def)
##   VehiclePhysics.step(state, input, dt, params, road)
##   params.lane_change_time(v)             # passability, HUD, tests
##   params.move_time(v, distance_m)
##   params.max_lateral_offset(v, t)
##
## Derived per car: engine power and aero drag (from top speed + 0-200 km/h time, by
## simulating the same longitudinal code), the boost taper (from the boost top-speed
## bonus), and the capability table (by simulating the lane-change procedure with
## VehiclePhysics.step itself), so physics and capability can never disagree.
## All query methods are allocation-free and safe to call per tick.

## False-position steps for the engine-power calibration, and its time tolerance (s).
const POWER_ITERATIONS := 40
const POWER_TOLERANCE_S := 1e-6   # lint: allow-number numerical search tolerance
## A simulated move counts as finished (no further drift) below this lateral speed.
const QUIESCENT_MPS := 1e-2   # lint: allow-number numerical termination threshold (1 cm/s, ~1 mm left to drift)
## First hold probed by the lateral-move search (ticks).
const FIRST_HOLD_TICKS := 32
## Coarse samples of the power range before the bisection.
const POWER_SCAN_STEPS := 8
## time_to_speed gives up after this multiple of the target time.
const TIME_LIMIT_FACTOR := 4.0   # lint: allow-number search bound, not a tuning value

# ---------------------------------------------------------------- Identity and targets
var car_id: StringName = &""
var physics_dt: float
var top_speed_mps: float
var boost_top_speed_mps: float
var zero_to_200_target_s: float
## handling_scale x vehicle type lane_change_time_scale: multiplies lane-change times.
var handling_factor: float = 1.0

# ---------------------------------------------------------------- Steering
var steer_max_rest_rad: float
var steer_max_speed_rad: float
var steer_ease_end_mps: float
var steer_lock_s: float

# ---------------------------------------------------------------- Yaw and lateral grip
var wheelbase_m: float
var understeer_speed_mps: float
## Scales the bicycle yaw-rate gain: 1 / handling^2 (time-scaling, see PHYSICS.md).
var steer_gain_factor: float
var table_speeds_mps := PackedFloat64Array()
var grip_table_mps2 := PackedFloat64Array()   ## already scaled by handling and grip
var yaw_lag_table_s := PackedFloat64Array()   ## already scaled by handling
## Heading return strength relative to critical damping: 1 / damping_ratio^2.
var heading_align_ratio: float
var align_fade_mps: float
var lateral_grip_rate: float   ## 1/s
var _grip_decay_dt: float = -1.0
var _grip_decay: float = 1.0
var slip_max_tan: float

# ---------------------------------------------------------------- Longitudinal
var traction_mps2: float
var power_per_kg: float   ## W/kg = m^2/s^3
var drag_per_m: float     ## aero drag acceleration = drag_per_m * v^2
var rolling_mps2: float
var engine_brake_mps2: float
var braking_mps2: float
var boost_thrust_mps2: float
var boost_taper_per_s: float   ## 1/s, see VehiclePhysics.boost_accel
var boost_drain_per_s: float
var boost_start_min_frac: float

# ---------------------------------------------------------------- Gearbox
var gear_count: int
var gear_top_speed_mps := PackedFloat64Array()   ## redline speed per gear (index gear - 1)
var idle_rpm: float
var redline_rpm: float
var shift_up_rpm: float
var shift_down_rpm: float
var rpm_sync_per_s: float
var shift_dip_factor: float

# ---------------------------------------------------------------- Lane-change procedure and capability
var lane_change_distance_m: float
var settle_m: float
var settle_yaw_rad: float
var settle_window_s: float
var sim_max_s: float
var cap_speeds_mps := PackedFloat64Array()
var cap_distances_m := PackedFloat64Array()
var cap_time_s := PackedFloat64Array()   ## [speed_index * distances + distance_index]

var _vt: VehicleTuning
# Hold-phase snapshots for the hold-time search: _hold_states[k] = the state after k
# full-input ticks at speed _hold_v (build time only).
var _hold_states: Array[VehicleState] = []
var _hold_count := 0
var _hold_v := NAN
var _full_input := VehicleInput.new()
var _trace_d := PackedFloat64Array()
var _trace_yaw := PackedFloat64Array()


## Result of one simulated lateral move ("full input, then release"). Lengths in m,
## times in s, angles in rad.
class LateralMove:
	extends RefCounted
	var speed_mps: float = 0.0
	var distance_m: float = 0.0
	var hold_s: float = 0.0        ## full input held this long
	var time_s: float = 0.0        ## input start -> settled (and staying settled)
	var final_d: float = 0.0       ## settled lateral offset (= distance_m once interpolated)
	var peak_d: float = 0.0
	var overshoot_m: float = 0.0   ## peak beyond the settled offset (>= 0)
	var drift_after_window_m: float = 0.0   ## |d moved| from release + settle window on
	var peak_yaw: float = 0.0
	var peak_yaw_rate: float = 0.0
	var peak_slip: float = 0.0
	var peak_accel_lat: float = 0.0
	var ticks: int = 0

	func copy_from(o: LateralMove) -> void:
		speed_mps = o.speed_mps
		distance_m = o.distance_m
		hold_s = o.hold_s
		time_s = o.time_s
		final_d = o.final_d
		peak_d = o.peak_d
		overshoot_m = o.overshoot_m
		drift_after_window_m = o.drift_after_window_m
		peak_yaw = o.peak_yaw
		peak_yaw_rate = o.peak_yaw_rate
		peak_slip = o.peak_slip
		peak_accel_lat = o.peak_accel_lat
		ticks = o.ticks

	## Below one tick of hold: scale from the zero move (time and hold linear in distance).
	func scale_to(target_m: float) -> void:
		var w := target_m / final_d
		hold_s *= w
		time_s *= w
		_set_distance(target_m, w)

	## Interpolates this (the shorter hold) toward `longer` so the settled offset is
	## `target_m`. Peaks, overshoot and drift take the worse of the two.
	func blend_to(longer: LateralMove, target_m: float) -> void:
		var w := (target_m - final_d) / (longer.final_d - final_d)
		hold_s = lerpf(hold_s, longer.hold_s, w)
		time_s = lerpf(time_s, longer.time_s, w)
		overshoot_m = maxf(overshoot_m, longer.overshoot_m)
		drift_after_window_m = maxf(drift_after_window_m, longer.drift_after_window_m)
		peak_yaw = maxf(peak_yaw, longer.peak_yaw)
		peak_yaw_rate = maxf(peak_yaw_rate, longer.peak_yaw_rate)
		peak_slip = maxf(peak_slip, longer.peak_slip)
		peak_accel_lat = maxf(peak_accel_lat, longer.peak_accel_lat)
		ticks = longer.ticks
		_set_distance(target_m, 1.0)

	func _set_distance(target_m: float, peak_scale: float) -> void:
		peak_d = maxf(target_m, peak_d * peak_scale)
		final_d = target_m
		distance_m = target_m


# ---------------------------------------------------------------- Build

## Builds the params for `car` (and optionally a vehicle type's physics profile).
## Runs the calibrations and the capability table: call at load, never per tick.
static func build(tuning: Tuning, car: CarDef, vtype: VehicleType = null) -> VehicleParams:
	var p := VehicleParams.new()
	p._configure(tuning, car, vtype)
	p._calibrate_engine()
	p._build_capability()
	return p


func _configure(tuning: Tuning, car: CarDef, vtype: VehicleType) -> void:
	var vt := tuning.vehicle
	_vt = vt
	car_id = car.id
	physics_dt = vt.physics_dt()
	top_speed_mps = car.top_speed_mps()
	boost_top_speed_mps = top_speed_mps * (1.0 + Units.pct_to_frac(vt.boost_top_speed_bonus_pct))
	zero_to_200_target_s = car.zero_to_200_s
	var grip_scale := 1.0
	handling_factor = car.handling_scale
	if vtype != null:
		handling_factor *= vtype.lane_change_time_scale
		grip_scale = vtype.grip_scale
	var h := handling_factor

	steer_max_rest_rad = deg_to_rad(vt.steer_max_deg_at_rest)
	steer_max_speed_rad = deg_to_rad(vt.steer_max_deg_at_speed)
	steer_ease_end_mps = Units.kmh_to_mps(vt.steer_ease_end_kmh)
	steer_lock_s = vt.steer_full_lock_s

	# Handling time-scales the lateral dynamics: rates x 1/h, accelerations x 1/h^2.
	wheelbase_m = car.wheelbase_m
	understeer_speed_mps = Units.kmh_to_mps(vt.understeer_speed_kmh)
	steer_gain_factor = 1.0 / (h * h)
	var n := vt.lane_change_speeds_kmh.size()
	assert(vt.grip_lateral_max_mps2.size() == n and vt.yaw_lag_ms.size() == n,
		"VehicleTuning: grip and yaw-lag tables must match lane_change_speeds_kmh")
	table_speeds_mps.resize(n)
	grip_table_mps2.resize(n)
	yaw_lag_table_s.resize(n)
	for i in n:
		table_speeds_mps[i] = Units.kmh_to_mps(vt.lane_change_speeds_kmh[i])
		grip_table_mps2[i] = vt.grip_lateral_max_mps2[i] * grip_scale / (h * h)
		yaw_lag_table_s[i] = Units.ms_to_s(vt.yaw_lag_ms[i]) * h
	heading_align_ratio = 1.0 / (vt.heading_damping_ratio * vt.heading_damping_ratio)
	align_fade_mps = Units.kmh_to_mps(vt.heading_align_fade_kmh)
	lateral_grip_rate = 1.0 / (Units.ms_to_s(vt.lateral_grip_lag_ms) * h)
	slip_max_tan = DetMath.tan(vt.slip_angle_max_rad())

	traction_mps2 = vt.engine_traction_max_mps2
	rolling_mps2 = vt.rolling_resistance_mps2
	engine_brake_mps2 = vt.engine_brake_mps2
	braking_mps2 = car.braking_mps2
	boost_thrust_mps2 = vt.boost_thrust_mps2
	boost_taper_per_s = boost_thrust_mps2 / (boost_top_speed_mps - top_speed_mps)
	boost_drain_per_s = 1.0 / (tuning.scoring.boost_full_s * car.boost_capacity_scale)
	boost_start_min_frac = Units.pct_to_frac(vt.boost_start_min_pct)

	gear_count = car.gear_count
	gear_top_speed_mps.resize(gear_count)
	var top_gear_mps := top_speed_mps * vt.top_gear_speed_factor
	var ratio_step := 1.0
	if gear_count > 1:
		ratio_step = DetMath.pow(Units.pct_to_frac(vt.first_gear_speed_pct), 1.0 / float(gear_count - 1))
	for g in gear_count:
		gear_top_speed_mps[g] = top_gear_mps * DetMath.pow(ratio_step, float(gear_count - 1 - g))
	idle_rpm = vt.engine_idle_rpm
	redline_rpm = vt.engine_redline_rpm
	shift_up_rpm = redline_rpm * Units.pct_to_frac(vt.shift_up_pct)
	shift_down_rpm = redline_rpm * Units.pct_to_frac(vt.shift_down_pct)
	# An upshift drops the rpm by shift_up_rpm * (1 - ratio_step); syncing takes shift_dip_s.
	rpm_sync_per_s = shift_up_rpm * (1.0 - ratio_step) / vt.shift_dip_s
	shift_dip_factor = 1.0 - Units.pct_to_frac(vt.shift_dip_pct)

	lane_change_distance_m = vt.lane_change_distance_m
	settle_m = vt.lane_change_settle_m
	settle_yaw_rad = deg_to_rad(vt.lane_change_settle_yaw_deg)
	settle_window_s = vt.settle_window_s
	sim_max_s = vt.lane_change_sim_max_s
	cap_speeds_mps.resize(vt.capability_speeds_kmh.size())
	for i in cap_speeds_mps.size():
		cap_speeds_mps[i] = Units.kmh_to_mps(vt.capability_speeds_kmh[i])
	cap_distances_m = vt.capability_distances_m.duplicate()


# ---------------------------------------------------------------- Per-tick queries (allocation-free)

## exp(-dt × lateral_grip_rate): the lateral velocity's decay per tick (DetMath, cached per dt).
func lateral_grip_decay(dt: float) -> float:
	if dt != _grip_decay_dt:
		_grip_decay_dt = dt
		_grip_decay = DetMath.exp(-dt * lateral_grip_rate)
	return _grip_decay


## Speed-sensitive maximum steer angle (rad): 30 deg at rest easing linearly to 3.5 deg at
## 250 km/h, held above.
func steer_max_rad(v: float) -> float:
	return lerpf(steer_max_rest_rad, steer_max_speed_rad, clampf(v / steer_ease_end_mps, 0.0, 1.0))


## Lateral grip limit (m/s^2) at speed v.
func grip_mps2(v: float) -> float:
	return _interp(table_speeds_mps, grip_table_mps2, v)


## Yaw-rate lag time constant (s) at speed v.
func yaw_lag_s(v: float) -> float:
	return _interp(table_speeds_mps, yaw_lag_table_s, v)


## Engine rpm in gear g (1-based) at speed v.
func gear_rpm(v: float, g: int) -> float:
	return maxf(idle_rpm, redline_rpm * v / gear_top_speed_mps[g - 1])


# ---------------------------------------------------------------- Capability curve (passability)

## Time (s) to move one lane-change distance (3.6 m) sideways and settle straight at
## speed v (full input, then release). The spec's lane-change time.
func lane_change_time(v: float) -> float:
	return move_time(v, lane_change_distance_m)


## Time (s) to move `distance_m` sideways (either side) and settle straight at speed v.
## Bilinear in the precomputed table; linear from (0, 0) below the first distance and
## extrapolated from the last segment beyond the last one.
func move_time(v: float, distance_m: float) -> float:
	var i := _segment(cap_speeds_mps, v)
	var t := clampf((v - cap_speeds_mps[i]) / (cap_speeds_mps[i + 1] - cap_speeds_mps[i]), 0.0, 1.0)
	var dist := absf(distance_m)
	return lerpf(_time_at(i, dist), _time_at(i + 1, dist), t)


## Largest lateral distance (m) the car can move and settle within `time_s` at speed v:
## the inverse of move_time.
func max_lateral_offset(v: float, time_s: float) -> float:
	var i := _segment(cap_speeds_mps, v)
	var t := clampf((v - cap_speeds_mps[i]) / (cap_speeds_mps[i + 1] - cap_speeds_mps[i]), 0.0, 1.0)
	var nd := cap_distances_m.size()
	var prev_d := 0.0
	var prev_t := 0.0
	for j in nd:
		var tj := lerpf(cap_time_s[i * nd + j], cap_time_s[(i + 1) * nd + j], t)
		if time_s <= tj or j == nd - 1:
			if time_s <= prev_t:
				return prev_d
			return prev_d + (cap_distances_m[j] - prev_d) * (time_s - prev_t) / (tj - prev_t)
		prev_d = cap_distances_m[j]
		prev_t = tj
	return prev_d


## The spec's lane-change target at speed v for this car (targets x handling factor).
func target_lane_change_time(v: float) -> float:
	return _vt.lane_change_target_s(v) * handling_factor


## Model-predicted time (s) to brake from v_from to v_to (m/s) at full brake, throttle
## off: dv/dt = -(k0 + drag v^2) with k0 = braking + engine braking + rolling.
func predicted_brake_time(v_from: float, v_to: float) -> float:
	var k0 := braking_mps2 + engine_brake_mps2 + rolling_mps2
	var w := sqrt(drag_per_m / k0)
	return (DetMath.atan(v_from * w) - DetMath.atan(v_to * w)) / (k0 * w)


# ---------------------------------------------------------------- The lane-change procedure

## Simulates the spec's procedure at constant speed v on a straight road: full input
## to the right for a whole number of ticks, then release, and measures the time from
## input start until the car has settled at its final offset (|d - final| <= settle_m
## and |yaw| <= settle_yaw, staying so). The final offset grows with the hold, one
## tick at a time; the result is interpolated between the two holds whose settled
## offsets bracket `distance_m` (see docs/PHYSICS.md). Fills and returns a LateralMove.
## Allocates; build time and tests only, never per tick.
func measure_lateral_move(v: float, distance_m: float) -> LateralMove:
	var st := VehicleState.new()
	var inp := VehicleInput.new()
	# Find hold ticks n with final_d(n_lo) < distance <= final_d(n_hi), n_hi = n_lo + 1.
	# final_d is increasing in n and close to linear: interpolation search, with a
	# bisection step whenever an interpolation step fails to halve the bracket.
	var n_lo := 0
	var d_lo := 0.0
	var n_hi := FIRST_HOLD_TICKS
	var d_hi := _simulate_move(st, inp, v, n_hi, null)
	while d_hi < distance_m:
		var slope := (d_hi - d_lo) / float(n_hi - n_lo)
		var n_next := n_hi + maxi(ceili((distance_m - d_hi) / slope), 1)
		n_lo = n_hi
		d_lo = d_hi
		n_hi = n_next
		d_hi = _simulate_move(st, inp, v, n_hi, null)
	var bisect := false
	while n_hi - n_lo > 1:
		var width := n_hi - n_lo
		var n_mid := (n_lo + n_hi) >> 1
		if not bisect:
			n_mid = n_lo + roundi((distance_m - d_lo) / (d_hi - d_lo) * float(width))
			n_mid = clampi(n_mid, n_lo + 1, n_hi - 1)
		var d_mid := _simulate_move(st, inp, v, n_mid, null)
		if d_mid < distance_m:
			n_lo = n_mid
			d_lo = d_mid
		else:
			n_hi = n_mid
			d_hi = d_mid
		bisect = not bisect and (n_hi - n_lo) * 2 > width
	var hi := LateralMove.new()
	_simulate_move(st, inp, v, n_hi, hi)
	var out := LateralMove.new()
	if n_lo == 0:
		out.copy_from(hi)
		out.scale_to(distance_m)
	else:
		_simulate_move(st, inp, v, n_lo, out)
		out.blend_to(hi, distance_m)
	return out


## One maneuver at constant speed v: full input for `hold_ticks`, then release.
## Returns the settled offset. Resumes from the cached hold-phase snapshot; with `out`,
## also records the measurements (settling judged against the maneuver's own final
## offset).
func _simulate_move(st: VehicleState, inp: VehicleInput, v: float, hold_ticks: int,
		out: LateralMove) -> float:
	var dt := physics_dt
	st.copy_from(_hold_state(v, hold_ticks))
	inp.clear()
	var max_ticks := hold_ticks + ceili(sim_max_s / dt)
	var window_tick := hold_ticks + ceili(settle_window_s / dt)
	var ticks := max_ticks
	if out != null:
		if _trace_d.size() < max_ticks:
			_trace_d.resize(max_ticks)
			_trace_yaw.resize(max_ticks)
		for i in hold_ticks:
			_record(_hold_states[i + 1], i, out)
	for i in range(hold_ticks, max_ticks):
		inp.steer = 1.0 if i < hold_ticks else 0.0
		st.v = v
		VehiclePhysics.step(st, inp, dt, self, null)
		if out != null:
			_record(st, i, out)
		var sy := DetMath.sin_cos(st.yaw)
		var d_dot := v * sy + st.v_lat * DetMath.cos_out
		if i >= hold_ticks and st.steer_angle == 0.0 and absf(d_dot) < QUIESCENT_MPS \
				and absf(st.yaw) < settle_yaw_rad:
			ticks = i + 1
			break
	if out != null:
		var final_d := st.d
		var last_unsettled := -1
		var peak_d := 0.0
		for i in ticks:
			peak_d = maxf(peak_d, _trace_d[i])
			if absf(_trace_d[i] - final_d) > settle_m or absf(_trace_yaw[i]) > settle_yaw_rad:
				last_unsettled = i
		var d_window := _trace_d[window_tick - 1] if window_tick <= ticks else final_d
		out.speed_mps = v
		out.distance_m = final_d
		out.hold_s = float(hold_ticks) * dt
		out.final_d = final_d
		out.time_s = float(last_unsettled + 1) * dt
		out.peak_d = peak_d
		out.overshoot_m = maxf(peak_d - final_d, 0.0)
		out.drift_after_window_m = absf(final_d - d_window)
		out.ticks = ticks
	return st.d


func _record(st: VehicleState, i: int, out: LateralMove) -> void:
	_trace_d[i] = st.d
	_trace_yaw[i] = st.yaw
	out.peak_yaw = maxf(out.peak_yaw, absf(st.yaw))
	out.peak_yaw_rate = maxf(out.peak_yaw_rate, absf(st.yaw_rate))
	out.peak_slip = maxf(out.peak_slip, absf(VehiclePhysics.slip_angle(st)))
	out.peak_accel_lat = maxf(out.peak_accel_lat, absf(st.accel_lat))


## The state after k full-input ticks at constant speed v (cached per speed).
func _hold_state(v: float, k: int) -> VehicleState:
	if v != _hold_v:
		_hold_v = v
		_hold_count = 0
		_full_input.clear()
		_full_input.steer = 1.0
	while _hold_count <= k:
		if _hold_states.size() <= _hold_count:
			_hold_states.append(VehicleState.new())
		var hs := _hold_states[_hold_count]
		if _hold_count == 0:
			VehiclePhysics.place(hs, self, 0.0, 0.0, v)
		else:
			hs.copy_from(_hold_states[_hold_count - 1])
			hs.v = v
			VehiclePhysics.step(hs, _full_input, physics_dt, self, null)
		_hold_count += 1
	return _hold_states[k]


func _build_capability() -> void:
	var ns := cap_speeds_mps.size()
	var nd := cap_distances_m.size()
	cap_time_s.resize(ns * nd)
	for i in ns:
		for j in nd:
			cap_time_s[i * nd + j] = measure_lateral_move(cap_speeds_mps[i], cap_distances_m[j]).time_s
	_hold_states.clear()
	_hold_count = 0
	_hold_v = NAN


## Time for `dist` at capability speed row i (piecewise linear in distance).
func _time_at(i: int, dist: float) -> float:
	var nd := cap_distances_m.size()
	var base := i * nd
	if dist <= cap_distances_m[0]:
		return cap_time_s[base] * dist / cap_distances_m[0]
	for j in range(1, nd):
		if dist <= cap_distances_m[j] or j == nd - 1:
			var t := (dist - cap_distances_m[j - 1]) / (cap_distances_m[j] - cap_distances_m[j - 1])
			return lerpf(cap_time_s[base + j - 1], cap_time_s[base + j], t)
	return cap_time_s[base + nd - 1]


# ---------------------------------------------------------------- Engine calibration

## Solves engine power (and with it aero drag, from the top-speed balance P / V =
## drag V^2 + rolling) so the simulated 0-200 km/h time equals the car's stat.
## Power must stay <= V x traction (power-limited at top speed). Over that range the
## 0-200 time first falls with power, then rises again (more power means more drag at a
## fixed top speed), so the search runs on the falling branch up to the fastest power.
func _calibrate_engine() -> void:
	var v200 := Units.kmh_to_mps(_vt.accel_stat_to_kmh)
	var p_min := top_speed_mps * rolling_mps2
	var p_max := top_speed_mps * traction_mps2
	var p_best := p_max
	var t_best := INF
	for k in range(1, POWER_SCAN_STEPS + 1):
		var pk := lerpf(p_min, p_max, float(k) / float(POWER_SCAN_STEPS))
		_set_power(pk)
		var tk := time_to_speed(v200)
		if tk < t_best:
			t_best = tk
			p_best = pk
	if t_best > zero_to_200_target_s:
		push_warning("VehicleParams: %s cannot reach 0-%d km/h in %.2f s (best %.2f s)" % [
			car_id, _vt.accel_stat_to_kmh, zero_to_200_target_s, t_best])
	# Illinois false position on T(P) - target over [p_min, p_best] (T falls with P
	# there); bisection while the low end is too slow to reach the speed at all.
	var p_lo := p_min
	var p_hi := p_best
	_set_power(p_lo)
	var f_lo := time_to_speed(v200) - zero_to_200_target_s
	var f_hi := t_best - zero_to_200_target_s
	var p := p_hi
	var side := 0
	if f_hi < 0.0:
		for k in POWER_ITERATIONS:
			if is_inf(f_lo):
				p = (p_lo + p_hi) * 0.5   # bisect until the low end reaches the target speed
			else:
				p = (p_lo * f_hi - p_hi * f_lo) / (f_hi - f_lo)
			_set_power(p)
			var f := time_to_speed(v200) - zero_to_200_target_s
			if absf(f) <= POWER_TOLERANCE_S:
				break
			if f > 0.0:
				p_lo = p
				f_lo = f
				if side == -1:
					f_hi *= 0.5
				side = -1
			else:
				p_hi = p
				f_hi = f
				if side == 1:
					f_lo *= 0.5
				side = 1
	_set_power(p)


func _set_power(p: float) -> void:
	power_per_kg = p
	drag_per_m = (p / top_speed_mps - rolling_mps2) / (top_speed_mps * top_speed_mps)


## Full-throttle time (s) from rest to v_target, simulated with the same longitudinal
## and gearbox code as step() (sub-tick interpolated). INF if not reached in time.
func time_to_speed(v_target: float) -> float:
	var st := VehicleState.new()
	VehiclePhysics.place(st, self, 0.0, 0.0, 0.0)
	var dt := physics_dt
	var t := 0.0
	var limit := zero_to_200_target_s * TIME_LIMIT_FACTOR
	while t < limit:
		var v := st.v
		var dip := VehiclePhysics.step_gearbox(st, self, v, dt)
		var v_next := maxf(v + VehiclePhysics.longitudinal_accel(self, v, 1.0, 0.0, 0.0, dip) * dt, 0.0)
		st.v = v_next
		if v_next >= v_target:
			return t + dt * (v_target - v) / (v_next - v)
		t += dt
	return INF


# ---------------------------------------------------------------- Helpers

## Index i of the segment [xs[i], xs[i+1]] for x (clamped to the table).
static func _segment(xs: PackedFloat64Array, x: float) -> int:
	var n := xs.size()
	for i in range(1, n - 1):
		if x < xs[i]:
			return i - 1
	return n - 2


## Piecewise-linear interpolation, held beyond the ends. Allocation-free.
static func _interp(xs: PackedFloat64Array, ys: PackedFloat64Array, x: float) -> float:
	var n := xs.size()
	if x <= xs[0]:
		return ys[0]
	for i in range(1, n):
		if x <= xs[i]:
			return lerpf(ys[i - 1], ys[i], (x - xs[i - 1]) / (xs[i] - xs[i - 1]))
	return ys[n - 1]
