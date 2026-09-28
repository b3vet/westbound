# Vehicle physics (WP1.5)

The player car is a hand-rolled grip bicycle model in road space at 120 Hz. It implements the spec's *Car physics and feel*.

- **Code:** `src/vehicle/vehicle_physics.gd` (`VehiclePhysics`, pure and static) and `src/vehicle/vehicle_params.gd` (`VehicleParams`, which holds the derived SI parameters and the capability curve).
- **Data:** `data/tuning/vehicle.tres` (`VehicleTuning`) and `data/cars/*.tres` (`CarDef`).
- **Tests:** `tests/unit/test_vehicle_physics.gd` and `tests/fixtures/vehicle/vehicle_test_driver.gd`.

## API

```gdscript
var params := VehicleParams.build(run.tuning, car_def)          # at load; ~0.35 s desktop (calibration + capability table)
VehiclePhysics.place(state, params, s, d, v)                    # spawn or teleport, with the gearbox in the right gear
VehiclePhysics.step(state, input, dt, params, road)             # per tick; mutates `state`, allocation-free
params.lane_change_time(v)           # s to move 3.6 m and settle (the spec's lane-change time for this car)
params.move_time(v, distance_m)      # s to move any lateral distance and settle
params.max_lateral_offset(v, t)      # m reachable (and settled) within t s: the inverse
params.target_lane_change_time(v)    # the spec target x handling, for comparison
params.predicted_brake_time(v0, v1)  # closed-form full-brake time
VehiclePhysics.surface_pitch(sample) / surface_height(sample, d)   # road surface for the visual
```

`VehicleParams.build(tuning, car, vtype = null)` takes an optional `VehicleType`. Its `lane_change_time_scale` multiplies the handling factor, and its `grip_scale` multiplies the grip limit.

**Contract notes:**

- `step` has a fifth, optional `road: RoadPath` argument, used for curvature at `s`. Null means a straight road.
- `state.yaw_rate` is **road-relative**: it is `d(yaw)/dt`. The world yaw rate is `yaw_rate + curvature * s_dot`.
- `accel_lat` includes the centripetal part from the road's own curvature, so body roll leans into bends.

## Model, per tick (in this order)

Here `v` is the speed at the start of the tick. The speed update is explicit, so every force below uses `v`.

1. **Steering pipeline.**
    - `steer_max(v) = lerp(30°, 3.5°, clamp(v / 250 km/h))`.
    - The steer angle moves toward `input.steer * steer_max(v)` at `steer_max(v) / 0.12 s`, so it reaches full lock in 0.12 s at any speed.
2. **Boost.**
    - An edge request starts a boost if `boost_meter >= boost_start_min_pct`. The boost then runs until the meter is empty.
    - The drain rate is `1 / (scoring.boost_full_s * car.boost_capacity_scale)` per second.
3. **Gearbox.**
    - Gear ratios are geometric. Top gear reaches redline at `top_speed x top_gear_speed_factor`, and first gear at `first_gear_speed_pct` of that speed.
    - The box upshifts at `shift_up_pct` of redline and downshifts below `shift_down_pct`.
    - The rpm moves toward the gear's rpm at a sync rate chosen so that an upshift's rpm drop takes `shift_dip_s`. While rpm is syncing, engine thrust is multiplied by `1 - shift_dip_pct`. The rpm lag serves as the shift timer, so no extra state is needed.
4. **Longitudinal (car frame).** With `throttle_eff = throttle * (1 - brake)`, so the brake overrides throttle:

    ```
    a = throttle_eff * a_eng(v) * dip + boost * a_boost(v) - brake * braking
        - (1 - throttle_eff) * engine_brake - rolling - c_d v²
    a_eng(v) = min(traction, P / v)                   (traction-limited, then constant power)
    a_boost(v) = clamp(c_d v² + rolling - a_eng(v) + k_b (V_b - v), 0, boost_thrust)
    ```

    - Top speed emerges from drag: `P / V = c_d V² + rolling`.
    - Under full-throttle boost, the net acceleration above the normal top speed is `k_b (V_b - v)`, so the boosted top speed is exactly `V_b = V x 1.08`.
    - Below the normal top speed, boost adds `boost_thrust_mps2`, felt on the next tick.
5. **Yaw.** This is the grip-limited bicycle model, plus the heading return and the yaw lag.

    ```
    r_steer = v tan(δ) / (L (1 + (v / v_ch)²)) / h²          bicycle + understeer
    r_cmd   = r_steer - k_align(v) · yaw                      road-relative heading return
    r_cmd   = clamp(r_cmd, -a_grip(v)/v - Ω_road, a_grip(v)/v - Ω_road),  Ω_road = κ s_dot
    yaw_rate += (r_cmd - yaw_rate) · b,  b = 1 - exp(-dt / τ_yaw(v))      yaw damping (lag)
    yaw += yaw_rate · dt
    ```

    - `k_align` makes the discrete release dynamics exactly critically damped: `k_align·dt = (2 - b - 2√(1-b)) / b` (in the continuous limit, `1 / (4 τ_yaw)`), times `1/ζ²` and faded out below 30 km/h. Zero input therefore returns the car parallel to the lane without oscillation.
    - Holding full input converges to a bounded heading, so the car never spins.
    - `yaw` is measured from the road tangent. The road's own turning is fed forward outside this loop, so zero input keeps the car parallel to the lane through bends. **Lateral position is never corrected.**
6. **Lateral grip.**
    - Update: `v_lat = (v_lat - v · yaw_rate · dt) · exp(-dt / τ_grip)`. The car frame turns under the velocity, and the tires scrub the lateral velocity (cornering stiffness).
    - Hard slip clamp: `|v_lat| <= tan(8°) · v`.
7. **Kinematics (exact for the offset curve).**
    - `s_dot = (v cos yaw - v_lat sin yaw) / (1 - κ d)`
    - `d_dot = v sin yaw + v_lat cos yaw`
    - `accel_lat = Δv_lat/dt + v (yaw_rate + κ s_dot)`
8. **Road surface.** Physics is planar. The visual puts the car on `RoadSample.local_point(d, …)`. The cross-section is flat, so the height is the elevation at `s`, and the car is pitched by `atan(grade)`.

**Integration** is semi-implicit Euler at the fixed tick:

- Relaxations (the yaw lag and lateral grip) use exact exponential discretization, so they are stable for any `dt`.
- `yaw` and position use the freshly updated rates.
- Everything is 64-bit, deterministic and allocation-free. The measured cost is about 7 µs per tick on desktop.

**Handling** time-scales the lateral dynamics. With `h = handling_scale x type.lane_change_time_scale`:

- the time constants `τ_yaw` and `τ_grip` are multiplied by `h`
- the grip limit and the steering gain are multiplied by `1/h²`

Every lateral motion therefore takes `h` times as long, and the lane-change target for a car is `spec time x h`. The only part that does not scale is the fixed 0.12 s steering rate, which costs under 1%.

## Engine calibration (per car, at build)

`P` (W/kg) is solved so the simulated full-throttle 0–200 km/h time equals `CarDef.zero_to_200_s`. Two quantities follow from it:

- **Drag:** `c_d = (P/V - rolling) / V²`.
- **Boost taper:** `k_b = boost_thrust / (V_b - V)`.

The solve uses the same `longitudinal_accel` and `step_gearbox` code as `step`, including shift dips. Because the top speed is fixed, more power also means more drag. The 0–200 time therefore falls and then rises as `P` grows, and the solver works on the falling branch.

## The lane-change procedure (spec definition, made precise)

The spec says "move 3.6 m sideways and settle straight; full input then release". In code:

1. The speed is held constant at `v` on a straight road (the tick's `v` is reset every tick).
2. Full steer input is held for **n whole ticks**, then released. Measurement runs until the car is quiescent.
3. **Time** runs from the input start until the car has settled for good, meaning `|d - d_final| <= lane_change_settle_m` (0.1 m) **and** `|yaw| <= lane_change_settle_yaw_deg` (0.5°).
4. The settled offset `d_final(n)` grows with `n` one tick at a time. The reported time is interpolated linearly between the two holds whose settled offsets bracket 3.6 m.
5. **Overshoot** is the peak `d` beyond `d_final`. **Drift** is `|d_final - d(release + 1 s)|`.

`VehicleParams.measure_lateral_move` implements this procedure, which also builds the capability table. `VehicleTestDriver` re-implements it independently, with plain bisection, a fixed horizon, a real road fixture and the car starting in lane 1. The tests use the driver. The target is `lane_change_times_s x h`, and the tolerance is ±5%.

**Capability curve (passability).** `cap_time_s` holds the procedure's time for each speed in `capability_speeds_kmh` and each distance in `capability_distances_m` (0.3–10.8 m). It is computed at build with `VehiclePhysics.step` itself:

- `move_time` interpolates bilinearly.
- `max_lateral_offset` is its inverse.
- The test holds the curve to the independent simulation: within one tick at the knots, and within 3% + 1 tick off the knots (measured worst case is about 2.2%). Traffic difficulty and car capability therefore cannot disagree.

## Tuning knobs (`VehicleTuning`) and what they affect

| Knob | Affects |
| --- | --- |
| `grip_lateral_max_mps2[100/200/280]` | Peak lateral acceleration, which is the main lever on lane-change time at each speed |
| `yaw_lag_ms[100/200/280]` | Yaw response ("weight"), heading-return speed on release, and input-to-yaw latency |
| `heading_damping_ratio` | 1 = critically damped return. Below 1 the car wobbles; above 1 it straightens more slowly |
| `understeer_speed_kmh`, `CarDef.wheelbase_m` | Yaw gain per steer angle, which shapes response to partial input and the steady heading while holding input |
| `lateral_grip_lag_ms` | Cornering stiffness: how much the car slips (lag between heading and travel) |
| `slip_angle_max_deg` (8°) | Hard slip clamp |
| `heading_align_fade_kmh` | Speed below which the heading return fades out |
| `steer_*` | The spec's steering pipeline |
| `engine_traction_max_mps2` | Low-speed launch cap. Power and drag are solved per car from the car stats |
| `rolling_resistance_mps2`, `engine_brake_mps2` | Coasting deceleration, and part of the braking time |
| `boost_thrust_mps2`, `boost_top_speed_bonus_pct`, `boost_start_min_pct` | Boost kick, boosted top speed, and the meter needed to start |
| `engine_idle_rpm`, `engine_redline_rpm`, `shift_up_pct`, `shift_down_pct`, `top_gear_speed_factor`, `first_gear_speed_pct`, `shift_dip_pct`, `shift_dip_s` | Gearbox, rpm and shift dip |
| `lane_change_settle_m`, `lane_change_settle_yaw_deg`, `capability_*` | The procedure's definition and the capability grid |

The lane-change grip and yaw-lag values were fitted for handling 1.0. Fit the grip value at one knot and the other knots do not move. The handling scaling then held every car within ±1.1%.

## Measured results

These come from `tools/test.sh --filter=vehicle` (`test_report_measurements`), plus a probe using the same driver. The step cost is 7 µs per tick and `build` takes about 0.35 s.

**Lane change** (3.6 m, settled). Columns: target = spec × handling; peak yaw, yaw rate, slip and lateral acceleration during the maneuver; yaw latency = time for the yaw rate to reach 25% of its peak.

| Car (handling) | km/h | Time (s) | Target (s) | Err | Overshoot (m) | Drift after 1 s (m) | Peak yaw | Peak yaw rate | Peak slip | Peak lat. acc. | Yaw latency |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Falcon GT (1.00) | 100 | 0.797 | 0.800 | −0.4% | 0.000 | 0.000 | 18.5° | 1.14 rad/s | 2.3° | 31.4 m/s² | 25 ms |
| | 200 | 0.997 | 1.000 | −0.3% | 0.000 | 0.001 | 7.4° | 0.30 | 0.6° | 16.6 | 17 ms |
| | 280 | 1.149 | 1.150 | −0.1% | 0.000 | 0.010 | 4.5° | 0.16 | 0.3° | 12.4 | 25 ms |
| Night Viper (0.92) | 100 | 0.736 | 0.736 | 0.0% | 0.000 | 0.000 | 20.5° | 1.35 | 2.5° | 37.2 | 25 ms |
| | 200 | 0.922 | 0.920 | +0.2% | 0.000 | 0.000 | 8.1° | 0.35 | 0.7° | 19.6 | 17 ms |
| | 280 | 1.061 | 1.058 | +0.2% | 0.000 | 0.005 | 4.9° | 0.19 | 0.4° | 14.6 | 25 ms |
| Brute V8 (1.08) | 100 | 0.868 | 0.864 | +0.4% | 0.000 | 0.000 | 16.4° | 0.98 | 2.2° | 26.8 | 33 ms |
| | 200 | 1.068 | 1.080 | −1.1% | 0.000 | 0.002 | 6.9° | 0.26 | 0.6° | 14.2 | 25 ms |
| | 280 | 1.249 | 1.242 | +0.5% | 0.000 | 0.016 | 4.1° | 0.14 | 0.3° | 10.6 | 25 ms |

**Performance:**

| Car | Top speed (spec) | Boosted top (target +8%) | 0–200 km/h (spec) | 250→100 km/h brake | P (W/kg) | Drag c_d (1/m) |
| --- | --- | --- | --- | --- | --- | --- |
| Falcon GT | 270.0 (270) | 291.6 (291.6) | 8.800 s (8.8) | 3.63 s | 275 | 6.24e-4 |
| Night Viper | 285.0 (285) | 307.8 (307.8) | 9.400 s (9.4) | 3.77 s | 237 | 4.53e-4 |
| Brute V8 | 260.0 (260) | 280.8 (280.8) | 8.200 s (8.2) | 3.47 s | 329 | 8.45e-4 |

Other checks:

- **Stability on a bend:** zero input for 60 s on R = 1200 m bends in both directions gives exactly 0.0 m of drift. Yaw stays 0 by construction, and position is never corrected.
- **Fuzz:** 10 simulated minutes of random input per car, on a straight and on bends, produced no NaN and no invalid state.
- **Determinism:** the trace hash is identical across runs.

## Spec feasibility flags

- **Braking (resolved, owner decision 2026-09-28):** braking stays 9 m/s², and the spec's "250→100 km/h in about 1.3 s" is dropped. The model gives 3.5–3.8 s. That is shorter than the brake-only 4.6 s because aero drag (about 3 m/s² at 250 km/h), engine braking and rolling resistance add to the brake. `brake_target_s = 3.6` with ±10%. The test also holds each car to the closed-form prediction within 2%.
- **The lane-change targets are feasible** with the 8° slip clamp. Peak slip is only 0.3–2.5°. However, they imply arcade-level lateral numbers at low speed. At 100 km/h, the 0.8 s target needs about **3.2 g** peak lateral acceleration and about **18° peak heading** off the lane (Night Viper at 0.92 handling: 3.8 g, 20°). At 280 km/h it is 1.3 g and 4.5°. These follow from the kinematics of 3.6 m in 0.8 s at 27.8 m/s, not from tuning. Playtesting should confirm the look.
- The spec gives lane-change targets only at 100, 200 and 280 km/h. Between them, `target_lane_change_time` interpolates linearly. The model runs up to about 5% faster than that line around 150 km/h. This is not a spec target; the capability curve is the model's truth.
