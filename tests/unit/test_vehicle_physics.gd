extends WBTest
## Vehicle physics suite. Spec: Car physics and feel -> Tests (headless) and Feel
## targets; Scoring -> Boost; Traffic -> Passability guarantee step 2 (the capability
## curve). Definitions and measured numbers: docs/PHYSICS.md.
##
## Every car in data/cars is held to every target. Lane changes are measured with
## VehicleTestDriver (tests/fixtures/vehicle), independently of VehicleParams'
## own procedure, on a straight road fixture starting in the middle lane.

const CAR_IDS: Array[StringName] = [&"falcon_gt", &"night_viper", &"brute_v8"]
## Tick budget for one VehiclePhysics.step (usec): ~3x the local median (see TOOLS.md).
const STEP_BUDGET_USEC := 40.0
const FUZZ_FAST_S := 60.0
const FUZZ_SEED := 1234
## Random input segments last 1..FUZZ_SEGMENT_MAX_TICKS ticks.
const FUZZ_SEGMENT_MAX_TICKS := 90
## Off-knot capability checks: speeds (km/h) and distances (m).
const CAPABILITY_SPEEDS_KMH: Array[float] = [90.0, 150.0, 230.0, 300.0]
const CAPABILITY_DISTANCES_M: Array[float] = [1.2, 3.6, 5.4, 9.0]
## Interpolated capability vs simulation: relative tolerance, plus one tick.
const CAPABILITY_TOL_FRAC := 0.03

var t: Tuning
var vt: VehicleTuning
var dt: float
var cars: Array[CarDef] = []
var params: Array[VehicleParams] = []
var straight: StraightRoadPath
var start_d: float


func before_all() -> void:
	t = Tuning.load_default()
	vt = t.vehicle
	dt = vt.physics_dt()
	straight = StraightRoadPath.new(t.road.lanes_default, t.road)
	start_d = straight.lane_center_d(1, 0.0)
	for id in CAR_IDS:
		var car := load("res://data/cars/%s.tres" % id) as CarDef
		cars.append(car)
		params.append(VehicleParams.build(t, car))


func _driver(i: int, road: RoadPath = null) -> VehicleTestDriver:
	return VehicleTestDriver.new(params[i], road if road != null else straight, start_d)


func _kmh(x: float) -> float:
	return Units.kmh_to_mps(x)


# ---------------------------------------------------------------- Car roster

func test_car_roster_stats_within_spec() -> void:
	eq(cars.size(), CAR_IDS.size())
	var spread := Units.pct_to_frac(vt.car_stat_spread_pct)
	var stats := ["top_speed_kmh", "zero_to_200_s", "braking_mps2", "handling_scale", "boost_capacity_scale"]
	for stat: String in stats:
		var mean := 0.0
		for car in cars:
			mean += float(car.get(stat))
		mean /= cars.size()
		for car in cars:
			within_pct(float(car.get(stat)), mean, spread, "%s %s within the roster spread" % [car.id, stat])
	for car in cars:
		ge(car.top_speed_kmh, vt.car_top_speed_min_kmh, "%s top speed" % car.id)
		le(car.top_speed_kmh, vt.car_top_speed_max_kmh, "%s top speed" % car.id)
		ge(car.handling_scale, vt.handling_scale_min, "%s handling" % car.id)
		le(car.handling_scale, vt.handling_scale_max, "%s handling" % car.id)
		ge(car.gear_count, vt.gear_count_min, "%s gears" % car.id)
		le(car.gear_count, vt.gear_count_max, "%s gears" % car.id)
		near(car.braking_mps2, vt.braking_mps2, 1e-9, "%s braking is the spec's 9 m/s^2" % car.id)


# ---------------------------------------------------------------- Lane change (spec table)

func test_lane_change_time_each_car() -> void:
	var tol := Units.pct_to_frac(vt.lane_change_tolerance_pct)
	for i in cars.size():
		var drv := _driver(i)
		for k in vt.lane_change_speeds_kmh.size():
			var v := _kmh(vt.lane_change_speeds_kmh[k])
			var target := vt.lane_change_times_s[k] * cars[i].handling_scale
			near(params[i].target_lane_change_time(v), target, 1e-9, "target = spec time x handling")
			var m := drv.lane_change(v, vt.lane_change_distance_m)
			within_pct(m.time_s, target, tol, "%s lane change at %d km/h" % [cars[i].id, vt.lane_change_speeds_kmh[k]])
			# Mirror image to the left.
			var ml := drv.lane_change(v, vt.lane_change_distance_m, -1.0)
			near(ml.time_s, m.time_s, dt, "%s left = right at %d km/h" % [cars[i].id, vt.lane_change_speeds_kmh[k]])


func test_settling_each_car() -> void:
	var lane_w := t.road.lane_width_m
	for i in cars.size():
		var drv := _driver(i)
		for k in vt.lane_change_speeds_kmh.size():
			var v := _kmh(vt.lane_change_speeds_kmh[k])
			var m := drv.lane_change(v, vt.lane_change_distance_m)
			var what := "%s at %d km/h" % [cars[i].id, vt.lane_change_speeds_kmh[k]]
			lt(m.overshoot_m, Units.pct_to_frac(vt.settle_overshoot_max_pct) * lane_w, what + " overshoot")
			lt(m.drift_after_window_m, vt.settle_drift_max_m, what + " drift from 1 s after release")
			# Critically damped: the heading does not swing past straight after release.
			lt(m.reverse_yaw_after_release, params[i].settle_yaw_rad, what + " no heading overshoot")


func test_release_straightens_without_oscillation() -> void:
	# Hold a partial input for a while, release: yaw returns to 0 monotonically.
	var drv := _driver(0)
	for kmh: float in [100.0, 200.0, 280.0]:
		var hold := ceili(0.6 / dt)
		drv.run_move(_kmh(kmh), hold)
		var prev := absf(drv.yaw_trace[hold + ceili(vt.steer_full_lock_s / dt)])
		var sign_changes := 0
		for i in range(hold + ceili(vt.steer_full_lock_s / dt) + 1, drv.ticks):
			var y := drv.yaw_trace[i]
			if y < -1e-9:
				sign_changes += 1
			le(absf(y), prev + 1e-12, "yaw decays monotonically at %d km/h" % kmh)
			prev = absf(y)
		eq(sign_changes, 0, "no reverse heading at %d km/h" % kmh)


# ---------------------------------------------------------------- Stability on a bend (road-relative steering)

func test_straight_line_stability_on_curve() -> void:
	for i in cars.size():
		for bend: int in [1, -1]:
			var arc := ArcRoadPath.new(t.road.min_curve_radius_m, bend, 3, t.road)
			var st := VehicleState.new()
			var inp := VehicleInput.new()
			var d0 := arc.lane_center_d(1, 0.0)
			VehiclePhysics.place(st, params[i], 0.0, d0, _kmh(200.0))
			inp.throttle = 1.0
			var worst := 0.0
			for n in ceili(vt.straight_stability_s / dt):
				VehiclePhysics.step(st, inp, dt, params[i], arc)
				worst = maxf(worst, absf(st.d - d0))
			lt(worst, vt.straight_stability_drift_max_m, "%s zero input on a %s bend" % [cars[i].id, "right" if bend > 0 else "left"])
			eq(arc.lane_index_at(st.d, st.s), 1, "still in its lane")
			gt(st.s, vt.straight_stability_s * _kmh(200.0), "drove the whole minute")
			# Cornering is real: lateral acceleration toward the inside of the bend.
			near(st.accel_lat, float(bend) * st.v * st.v / (t.road.min_curve_radius_m - float(bend) * st.d), 0.05,
				"centripetal acceleration")


func test_sign_conventions() -> void:
	var st := VehicleState.new()
	var inp := VehicleInput.new()
	VehiclePhysics.place(st, params[0], 0.0, start_d, _kmh(150.0))
	inp.steer = 1.0
	for n in 30:
		VehiclePhysics.step(st, inp, dt, params[0], straight)
	gt(st.steer_angle, 0.0, "steer right -> steer_angle > 0")
	gt(st.yaw_rate, 0.0, "turning right -> yaw_rate > 0")
	gt(st.yaw, 0.0, "nose right -> yaw > 0")
	gt(st.d, start_d, "moves right -> d grows")
	gt(st.accel_lat, 0.0, "accelerates toward the right")
	lt(st.v_lat, 0.0, "velocity lags the nose (slip to the outside)")


# ---------------------------------------------------------------- Steering pipeline

func test_steering_pipeline() -> void:
	var p := params[0]
	near(p.steer_max_rad(0.0), deg_to_rad(vt.steer_max_deg_at_rest), 1e-12)
	near(p.steer_max_rad(_kmh(vt.steer_ease_end_kmh)), deg_to_rad(vt.steer_max_deg_at_speed), 1e-12)
	near(p.steer_max_rad(_kmh(320.0)), deg_to_rad(vt.steer_max_deg_at_speed), 1e-12, "held above")
	var st := VehicleState.new()
	var inp := VehicleInput.new()
	for kmh: float in [50.0, 200.0, 300.0]:
		VehiclePhysics.place(st, p, 0.0, start_d, _kmh(kmh))
		inp.clear()
		inp.steer = 1.0
		var lock_ticks := ceili(vt.steer_full_lock_s / dt)
		var t_full := -1
		for n in lock_ticks * 3:
			st.v = _kmh(kmh)
			VehiclePhysics.step(st, inp, dt, p, straight)
			if t_full < 0 and st.steer_angle >= p.steer_max_rad(_kmh(kmh)) - 1e-12:
				t_full = n + 1
		eq(t_full, lock_ticks, "full lock in %s s (first tick at or after it) at %d km/h" % [vt.steer_full_lock_s, kmh])
		inp.steer = 0.0
		for n in lock_ticks:
			st.v = _kmh(kmh)
			VehiclePhysics.step(st, inp, dt, p, straight)
		eq(st.steer_angle, 0.0, "centered after release")


func test_input_to_visible_yaw() -> void:
	var visible_frac := Units.pct_to_frac(vt.input_visible_yaw_rate_pct)
	for i in cars.size():
		var drv := _driver(i)
		for kmh in vt.lane_change_speeds_kmh:
			var v := _kmh(kmh)
			var m := drv.lane_change(v, vt.lane_change_distance_m)
			drv.run_move(v, ceili(0.5 / dt))
			var hit := -1
			for n in drv.ticks:
				if absf(drv.yaw_rate_trace[n]) >= visible_frac * m.peak_yaw_rate:
					hit = n + 1
					break
			gt(hit, 0, "yaw responds")
			le(float(hit) * dt, Units.ms_to_s(vt.input_to_yaw_max_ms),
				"%s visible yaw within %s ms at %d km/h" % [cars[i].id, vt.input_to_yaw_max_ms, kmh])


func test_full_input_never_spins() -> void:
	var slip_max := vt.slip_angle_max_rad()
	for i in cars.size():
		var st := VehicleState.new()
		var inp := VehicleInput.new()
		for kmh: float in [20.0, 60.0, 100.0, 200.0, 280.0, 320.0]:
			for dir: float in [1.0, -1.0]:
				VehiclePhysics.place(st, params[i], 0.0, start_d, _kmh(kmh))
				inp.clear()
				inp.steer = dir
				inp.throttle = 1.0
				var worst_slip := 0.0
				var worst_yaw := 0.0
				var worst_rate_excess := 0.0
				for n in ceili(10.0 / dt):
					var v0 := st.v
					var r0 := absf(st.yaw_rate)
					VehiclePhysics.step(st, inp, dt, params[i], straight)
					worst_slip = maxf(worst_slip, absf(VehiclePhysics.slip_angle(st)))
					worst_yaw = maxf(worst_yaw, absf(st.yaw))
					# The yaw rate only moves toward the grip-limited command: it never
					# exceeds both the limit and its own previous value.
					var lim := params[i].grip_mps2(v0) / maxf(v0, params[i].align_fade_mps)
					worst_rate_excess = maxf(worst_rate_excess, absf(st.yaw_rate) - maxf(lim, r0))
				var what := "%s full %s at %d km/h" % [cars[i].id, "right" if dir > 0 else "left", kmh]
				le(worst_slip, slip_max + 1e-9, what + ": slip clamp")
				lt(worst_yaw, PI / 4.0, what + ": heading stays bounded")
				le(worst_rate_excess, 1e-9, what + ": yaw rate within the grip limit")
				finite(st.d, what)


# ---------------------------------------------------------------- Performance specs

func test_top_speed_each_car() -> void:
	var tol := Units.pct_to_frac(vt.performance_tolerance_pct)
	for i in cars.size():
		var st := VehicleState.new()
		var inp := VehicleInput.new()
		VehiclePhysics.place(st, params[i], 0.0, start_d, _kmh(200.0))
		inp.throttle = 1.0
		for n in ceili(90.0 / dt):
			VehiclePhysics.step(st, inp, dt, params[i], straight)
		within_pct(Units.mps_to_kmh(st.v), cars[i].top_speed_kmh, tol, "%s top speed" % cars[i].id)
		eq(st.gear, cars[i].gear_count, "%s top gear at top speed" % cars[i].id)
		near(st.accel_long, 0.0, 0.05, "%s settled at top speed" % cars[i].id)


func test_zero_to_200_each_car() -> void:
	var tol := Units.pct_to_frac(vt.performance_tolerance_pct)
	for i in cars.size():
		var drv := _driver(i)
		var t200 := drv.time_to_speed(_kmh(vt.accel_stat_to_kmh), 60.0)
		within_pct(t200, cars[i].zero_to_200_s, tol, "%s 0-200 km/h" % cars[i].id)


func test_braking_each_car() -> void:
	var from_v := _kmh(vt.brake_target_from_kmh)
	var to_v := _kmh(vt.brake_target_to_kmh)
	for i in cars.size():
		var drv := _driver(i)
		var tb := drv.brake_time(from_v, to_v, 30.0)
		var what := "%s %d->%d km/h" % [cars[i].id, vt.brake_target_from_kmh, vt.brake_target_to_kmh]
		within_pct(tb, params[i].predicted_brake_time(from_v, to_v), Units.pct_to_frac(vt.performance_tolerance_pct),
			what + " matches the model (9 m/s^2 + drag + engine braking + rolling)")
		within_pct(tb, vt.brake_target_s, Units.pct_to_frac(vt.brake_target_tolerance_pct), what + " target")
		# The brake itself is exactly the car's braking deceleration.
		var st := VehicleState.new()
		var inp := VehicleInput.new()
		VehiclePhysics.place(st, params[i], 0.0, start_d, _kmh(50.0))
		inp.brake = 1.0
		VehiclePhysics.step(st, inp, dt, params[i], straight)
		var a_drag := params[i].drag_per_m * _kmh(50.0) * _kmh(50.0)
		near(-st.accel_long, cars[i].braking_mps2 + params[i].engine_brake_mps2 + params[i].rolling_mps2 + a_drag,
			1e-9, "%s braking deceleration" % cars[i].id)


func test_gearbox_shifts_and_dips() -> void:
	for i in cars.size():
		var p := params[i]
		var st := VehicleState.new()
		var inp := VehicleInput.new()
		VehiclePhysics.place(st, p, 0.0, start_d, 0.0)
		inp.throttle = 1.0
		var gear := st.gear
		var upshifts := 0
		var dips := 0
		var dip_ticks := 0
		var in_dip := false
		for n in ceili(60.0 / dt):
			var v0 := st.v
			VehiclePhysics.step(st, inp, dt, p, straight)
			ge(st.rpm, p.idle_rpm - 1e-9, "rpm >= idle")
			le(st.rpm, p.redline_rpm + 1e-9, "rpm <= redline")
			if st.gear != gear:
				eq(st.gear, gear + 1, "one upshift at a time, never down while accelerating")
				upshifts += 1
				gear = st.gear
			# Dipped = less than the undipped full-throttle acceleration at this speed.
			var undipped := VehiclePhysics.longitudinal_accel(p, v0, 1.0, 0.0, 0.0, 1.0)
			var dipped := st.accel_long < undipped - 1e-9
			if dipped:
				dip_ticks += 1
				near(st.accel_long, VehiclePhysics.longitudinal_accel(p, v0, 1.0, 0.0, 0.0, p.shift_dip_factor), 1e-9,
					"dip depth = shift_dip_pct of engine thrust")
				if not in_dip:
					dips += 1
			in_dip = dipped
		eq(upshifts, cars[i].gear_count - 1, "%s shifts through every gear" % cars[i].id)
		eq(dips, upshifts, "%s one acceleration dip per shift" % cars[i].id)
		near(float(dip_ticks) * dt / float(upshifts), vt.shift_dip_s, dt * 2.0, "%s dip length" % cars[i].id)
		# Braking to a stop downshifts back to first.
		inp.clear()
		inp.brake = 1.0
		for n in ceili(20.0 / dt):
			VehiclePhysics.step(st, inp, dt, p, straight)
		eq(st.v, 0.0, "stopped")
		eq(st.gear, 1, "back in first")


# ---------------------------------------------------------------- Boost

func test_boost_top_speed_and_feel() -> void:
	var bonus := Units.pct_to_frac(vt.boost_top_speed_bonus_pct)
	var tol := Units.pct_to_frac(vt.performance_tolerance_pct)
	for i in cars.size():
		var p := params[i]
		var st := VehicleState.new()
		var inp := VehicleInput.new()
		VehiclePhysics.place(st, p, 0.0, start_d, p.top_speed_mps)
		inp.throttle = 1.0
		for n in ceili(90.0 / dt):
			st.boost_meter = 1.0   # the caller keeps it topped up (scoring fill)
			inp.boost = n == 0
			VehiclePhysics.step(st, inp, dt, p, straight)
			check(st.boost_active, "boost stays on while the meter lasts")
		within_pct(st.v, p.top_speed_mps * (1.0 + bonus), tol, "%s boosted top speed +%s%%" % [cars[i].id, vt.boost_top_speed_bonus_pct])
		# Felt within 0.1 s: thrust arrives on the next tick at cruise.
		VehiclePhysics.place(st, p, 0.0, start_d, _kmh(200.0))
		inp.clear()
		inp.throttle = 1.0
		VehiclePhysics.step(st, inp, dt, p, straight)
		var a0 := st.accel_long
		st.boost_meter = 1.0
		inp.boost = true
		var felt := -1.0
		for n in ceili(vt.boost_feel_max_s / dt):
			VehiclePhysics.step(st, inp, dt, p, straight)
			inp.boost = false
			if felt < 0.0 and st.accel_long - a0 >= vt.boost_thrust_mps2 * 0.9:
				felt = float(n + 1) * dt
		ge(felt, 0.0, "%s boost thrust felt" % cars[i].id)
		le(felt, vt.boost_feel_max_s, "%s boost felt within %s s" % [cars[i].id, vt.boost_feel_max_s])


func test_boost_meter_drain() -> void:
	for i in cars.size():
		var p := params[i]
		var st := VehicleState.new()
		var inp := VehicleInput.new()
		VehiclePhysics.place(st, p, 0.0, start_d, _kmh(200.0))
		inp.throttle = 1.0
		# Below the start minimum a request does nothing.
		st.boost_meter = p.boost_start_min_frac * 0.5
		inp.boost = true
		VehiclePhysics.step(st, inp, dt, p, straight)
		check(not st.boost_active, "no boost below the start minimum")
		# A full meter lasts boost_full_s x capacity.
		st.boost_meter = 1.0
		var n_active := 0
		for n in ceili(10.0 / dt):
			VehiclePhysics.step(st, inp, dt, p, straight)
			inp.boost = false
			if st.boost_active or st.boost_meter > 0.0:
				n_active += 1
		near(float(n_active) * dt, t.scoring.boost_full_s * cars[i].boost_capacity_scale, dt * 1.5,
			"%s full meter duration" % cars[i].id)
		check(not st.boost_active, "off when empty")
		eq(st.boost_meter, 0.0, "meter empty")


# ---------------------------------------------------------------- Capability curve (passability)

func test_capability_agrees_with_simulation() -> void:
	for i in cars.size():
		var p := params[i]
		var drv := _driver(i)
		# Knots: exact up to the tick quantum.
		for kmh in vt.lane_change_speeds_kmh:
			var m := drv.lane_change(_kmh(kmh), vt.lane_change_distance_m)
			near(p.lane_change_time(_kmh(kmh)), m.time_s, dt, "%s capability at knot %d km/h" % [cars[i].id, kmh])
		# Between knots: interpolation stays within tolerance of the simulation.
		var worst := 0.0
		for kmh in CAPABILITY_SPEEDS_KMH:
			for dist in CAPABILITY_DISTANCES_M:
				var v := _kmh(kmh)
				var sim := drv.lane_change(v, dist).time_s
				worst = maxf(worst, absf(p.move_time(v, dist) - sim) / sim)
				near(p.move_time(v, dist), sim, sim * CAPABILITY_TOL_FRAC + dt,
					"%s move %.1f m at %d km/h" % [cars[i].id, dist, kmh])
				near(p.max_lateral_offset(v, p.move_time(v, dist)), dist, 1e-6, "inverse at %.1f m" % dist)
		print("      %s capability vs simulation off the knots: worst %.2f%%" % [cars[i].id, worst * 100.0])
		# Monotone: farther takes longer; the curve is the spec's time scaled by handling.
		for kmh in vt.capability_speeds_kmh:
			var v := _kmh(kmh)
			lt(p.move_time(v, 1.8), p.move_time(v, 3.6), "monotone in distance")
			lt(p.move_time(v, 3.6), p.move_time(v, 7.2), "monotone in distance")
		eq(p.move_time(_kmh(200.0), 0.0), 0.0, "no move, no time")
		near(p.move_time(_kmh(200.0), -3.6), p.move_time(_kmh(200.0), 3.6), 0.0, "symmetric")


func test_vehicle_type_scales_lane_change() -> void:
	var vtype := VehicleType.new()
	vtype.lane_change_time_scale = 1.05
	var p := VehicleParams.build(t, cars[0], vtype)
	near(p.handling_factor, cars[0].handling_scale * 1.05, 1e-12)
	var tol := Units.pct_to_frac(vt.lane_change_tolerance_pct)
	for k in vt.lane_change_speeds_kmh.size():
		var v := _kmh(vt.lane_change_speeds_kmh[k])
		within_pct(p.lane_change_time(v), p.target_lane_change_time(v), tol, "type-scaled lane change")


# ---------------------------------------------------------------- Determinism and robustness

func test_determinism_same_inputs_same_trace() -> void:
	var a := _fuzz_run(0, FUZZ_SEED, FUZZ_FAST_S * 0.5, true)
	var b := _fuzz_run(0, FUZZ_SEED, FUZZ_FAST_S * 0.5, true)
	eq(a, b, "identical input trace -> identical state trace hash")
	ne(_fuzz_run(0, FUZZ_SEED + 1, FUZZ_FAST_S * 0.5, true), a, "different inputs -> different trace")


func test_fuzz_fast() -> void:
	for i in cars.size():
		_fuzz_run(i, FUZZ_SEED + i, FUZZ_FAST_S, false)


func soak_fuzz_ten_minutes() -> void:
	for i in cars.size():
		_fuzz_run(i, FUZZ_SEED + 100 + i, Units.min_to_s(vt.fuzz_duration_min), false)


func soak_fuzz_ten_minutes_on_bends() -> void:
	for i in cars.size():
		var arc := ArcRoadPath.new(t.road.min_curve_radius_m, 1 if i % 2 == 0 else -1, 3, t.road)
		_fuzz_run(i, FUZZ_SEED + 200 + i, Units.min_to_s(vt.fuzz_duration_min), false, arc)


## Random inputs held for random short segments (seeded Rng), including boost requests
## with the meter refilled at random. Checks every tick; returns the trace hash
## (state hashed every trace_hash_interval_s) when `hash_only`.
func _fuzz_run(i: int, seed_value: int, seconds: float, hash_only: bool, road: RoadPath = null) -> int:
	var p := params[i]
	var rng := Rng.new(seed_value)
	var st := VehicleState.new()
	var inp := VehicleInput.new()
	var r := road if road != null else straight
	VehiclePhysics.place(st, p, 0.0, start_d, _kmh(150.0))
	var h := TraceHash.SEED
	var hash_every := roundi(t.traffic.trace_hash_interval_s / dt)
	var segment := 0
	var slip_max := vt.slip_angle_max_rad() + 1e-9
	var v_max := p.boost_top_speed_mps * 1.001
	var bad := 0
	for n in ceili(seconds / dt):
		if segment <= 0:
			segment = rng.int_range(1, FUZZ_SEGMENT_MAX_TICKS)
			inp.steer = rng.float_range(-1.0, 1.0) if rng.chance(0.7) else signf(rng.float_range(-1.0, 1.0))
			inp.throttle = rng.unit() if rng.chance(0.5) else 1.0
			inp.brake = rng.unit() if rng.chance(0.15) else 0.0
			inp.boost = rng.chance(0.1)
			if rng.chance(0.1):
				st.boost_meter = minf(st.boost_meter + rng.unit(), 1.0)
		else:
			inp.boost = false
		segment -= 1
		VehiclePhysics.step(st, inp, dt, p, r)
		if hash_only:
			if n % hash_every == 0:
				h = st.hash_into(inp.hash_into(h))
			continue
		var ok := _all_finite(st) and absf(VehiclePhysics.slip_angle(st)) <= slip_max \
			and absf(st.yaw) < PI / 4.0 and st.v >= 0.0 and st.v <= v_max \
			and st.boost_meter >= 0.0 and st.boost_meter <= 1.0 \
			and st.gear >= 1 and st.gear <= p.gear_count
		if not ok:
			bad += 1
			if bad == 1:
				fail("%s fuzz invalid state at tick %d: v=%s yaw=%s v_lat=%s d=%s" % [p.car_id, n, st.v, st.yaw, st.v_lat, st.d])
	if not hash_only:
		eq(bad, 0, "%s fuzz %.0f s: invalid ticks" % [p.car_id, seconds])
	return h


func _all_finite(st: VehicleState) -> bool:
	for x: float in [st.s, st.d, st.yaw, st.v, st.v_lat, st.yaw_rate, st.steer_angle, st.accel_long, st.accel_lat, st.rpm, st.boost_meter]:
		if is_nan(x) or is_inf(x):
			return false
	return true


# ---------------------------------------------------------------- Road surface and budget

func test_road_surface_helpers() -> void:
	var graded := StraightRoadPath.new(3, t.road, 0.3, 0.04)
	var sample := RoadSample.new()
	graded.sample_into(250.0, sample)
	near(VehiclePhysics.surface_pitch(sample), atan(0.04), 1e-12, "pitch from grade")
	near(VehiclePhysics.surface_height(sample, 7.1), 250.0 * 0.04, 1e-9, "height = elevation (flat cross-section)")


func test_step_tick_budget() -> void:
	var p := params[0]
	var arc := ArcRoadPath.new(t.road.min_curve_radius_m, 1, 3, t.road)
	var st := VehicleState.new()
	var inp := VehicleInput.new()
	VehiclePhysics.place(st, p, 0.0, start_d, _kmh(200.0))
	inp.throttle = 1.0
	inp.steer = 0.2
	var fn := func() -> void:
		VehiclePhysics.step(st, inp, dt, p, arc)
	var usec := WBBench.usec_per_call(fn, 2000)
	WBBench.report("vehicle step", usec, STEP_BUDGET_USEC)
	le(usec, WBBench.budget(STEP_BUDGET_USEC), "vehicle step usec")


func test_params_build_budget() -> void:
	# Built once per run at load: engine calibration + capability table.
	var t0 := Time.get_ticks_usec()
	VehicleParams.build(t, cars[1])
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	WBBench.report("VehicleParams.build (ms)", ms, 1500.0)
	le(ms, WBBench.budget(1500.0), "params build ms")


func test_report_measurements() -> void:
	# Not an assertion: the measured table for docs/PHYSICS.md, printed in every run.
	for i in cars.size():
		var drv := _driver(i)
		var line := "      %s:" % cars[i].id
		for kmh in vt.lane_change_speeds_kmh:
			var m := drv.lane_change(_kmh(kmh), vt.lane_change_distance_m)
			line += " lc%d=%.3fs(ov %.3f dr %.3f)" % [kmh, m.time_s, m.overshoot_m, m.drift_after_window_m]
		line += " t200=%.3f brake=%.3f boostV=%.1f" % [
			drv.time_to_speed(_kmh(vt.accel_stat_to_kmh), 60.0),
			drv.brake_time(_kmh(vt.brake_target_from_kmh), _kmh(vt.brake_target_to_kmh), 30.0),
			Units.mps_to_kmh(params[i].boost_top_speed_mps)]
		print(line)
	check(true)
