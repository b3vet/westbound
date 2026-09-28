# Westbound — Architecture Contracts

Frozen at the end of Phase 0 (WP0.2). Parallel work packages build against what is written here. Changing a contract needs an orchestrator decision, recorded in the change log at the bottom. Where this file and the spec (`WESTBOUND HANDOFF.md`) disagree, the spec wins. Flag the conflict; don't diverge silently.

Contents: [1 Units](#1-units-and-numbers) · [2 Road space](#2-road-space) · [3 RoadPath](#3-roadpath) · [4 Vehicles](#4-vehicles) · [5 TrafficState](#5-trafficstate) · [6 SpawnSource](#6-spawnsource) · [7 Scoring and events](#7-scoring-and-events) · [8 SunClock](#8-sunclock) · [9 RunContext and determinism](#9-runcontext-and-determinism) · [10 Data resources](#10-data-resources) · [11 Tuning](#11-tuning) · [12 No-allocation rules](#12-no-allocation-rules)

---

## 1. Units and numbers

- **Simulation is SI:** meters, seconds, radians, m/s and m/s². All sim math uses GDScript `float` (64-bit). Sim state never holds `Vector3`/`Vector2` (32-bit). Vectors are for rendering and for the unit direction vectors in `RoadSample`.
- **Tuning holds the spec's numbers in the spec's units.** Units are km/h, degrees, %, cm, ms, km and minutes. Every field name has a unit suffix: `_m _s _ms _km _min _kmh _mps _mps2 _deg _hz _pct _frac _px`, plus `_factor` for plain multipliers, and `_points` / `_count` / `_gain`. Convert once when params load, using `Units` (`src/core/tuning/units.gd`: `kmh_to_mps`, `pct_to_frac`, `cm_to_m`, `ms_to_s`, `km_to_m`, `min_to_s`, `hz_to_dt`) or the per-class helpers (`ScoringTuning.min_speed_mps()`, `speed_factor(v)`, `decay_term(v)`, `VehicleTuning.steer_max_rad(v)`, `DirectorTuning.density_per_km_lane(leg)`, and so on). For degrees, use Godot's `deg_to_rad()`.
- **No magic numbers in code.** Every gameplay number lives in tuning or entity data. Structural literals (0, 1, 0.5, 2, indices) are fine.

## 2. Road space

### Coordinates

| Symbol | Meaning |
| --- | --- |
| `s` | Meters along the **reference line**, in the direction of travel (westbound), increasing. Plan-view (horizontal) arc length. `s = 0` at the run start. |
| reference line | The **center of the median** that divides the two carriageways. |
| `d` | Lateral offset from the reference line in meters, **positive to the right** of travel. Right-hand traffic: the player's carriageway is `d > 0`. The opposite carriageway is `d < 0`, mirrored. |
| vehicle `(s, d)` | The center of the vehicle's box (plan view). Gap to a leader = `s_lead − s − (len_lead + len)/2`. |

### Lanes and cross-section

Lane 0 is **next to the median** (leftmost, fastest), and the index increases to the right. `lane_count − 1` is the slow lane, where merges and lane drops happen. Indices stay stable when a right lane ends. Flow speed rises toward the left.

```
lane_center_d(i) = median_half_width + inner_shoulder + (i + 0.5) * lane_width
```

Cross-section looking in the direction of travel, 3 lanes, default `data/tuning/road.tres` (median half-width 0.5, inner shoulder 1.2, lane 3.6, shoulder 3.0, guardrail offset 0.5):

```
   opposite carriageway (d < 0, traffic toward -s)  |  player carriageway (d > 0, travel +s)
                                                    |
 rail|shoulder| lane 2| lane 1| lane 0 |inner|  median |inner| lane 0| lane 1| lane 2|shoulder|rail
     |        |       |       |        |shld | barrier |shld |       |       |       |        |
 d: -16.0  -15.5   -12.5          -1.7  -0.5   0   +0.5  +1.7  +3.5    +7.1   +10.7 +12.5  +15.5 +16.0
                                                                (lane centers)
      median_barrier_d = +0.5    lanes_left_edge_d = +1.7    lanes_right_edge_d = +12.5
      shoulder_outer_d = +15.5   guardrail_d = +16.0
```

"Shoulder" in scoring means either the inner or the outer shoulder: `RoadPath.is_on_shoulder(d, s)`.

### Sign conventions (sim code is right-positive throughout)

| Quantity | Positive when |
| --- | --- |
| `d` | right of the reference line |
| `yaw` (vehicle heading − road tangent heading, rad) | nose points right |
| `steer` input (−1..1), `steer_angle` | steering right |
| `yaw_rate` | turning right |
| `v_lat`, `accel_lat` | toward the car's right |
| road `curvature` (1/m) = d(heading)/ds | the road bends right |
| world `heading` (rad) | clockwise seen from above. 0 faces −Z, +π/2 faces +X |

Kinematics (first order; `vehicle_physics` owns the exact integration): `d_dot = v·sin(yaw)`, `s_dot = v·cos(yaw) / (1 − curvature·d)`.

### World frame

- Godot: Y up, meters. Vehicles face −Z at heading 0, so the right of travel is +X.
- A `RoadSample` gives world-space position, tangent, right and up at `s` on the reference line, **before** the floating-origin offset. World point = `pos + right·d` (+ `up·0`: flat cross-section, no banking).
- `tangent` is the 3D unit tangent (includes grade). `right` is horizontal. `up = right × tangent` is the road normal (it pitches with grade and never banks). `right = tangent × up`.
- **Conversions to Godot happen only in render adapters:** `rotation.y = −(road heading + yaw)` (`RoadSample.godot_yaw(yaw)`). Positive Godot Y rotation is a left turn.
- **Floating origin:** the world is re-centred every `road.floating_origin_shift_km` (2 km). `Events.origin_shifted(offset)` fires once per shift. Absolute positions are 64-bit (`pos_x/pos_y/pos_z`). Render adapters call `RoadSample.local_point(d, origin_x, origin_y, origin_z)`, which subtracts the origin in 64-bit before narrowing to `Vector3`. `RoadSample.pos` (32-bit) is a convenience only; it loses precision far from the start.

## 3. RoadPath

`class_name RoadPath extends RefCounted` (`src/road/road_path.gd`) is the base contract. WP1.1 implements the seeded generator. The exact fixtures live in `tests/fixtures/road/`: `StraightRoadPath(lanes, tuning, heading, grade, origin)` and `ArcRoadPath(radius, bend ±1, lanes, tuning, heading, origin)`. Both are infinite, flat or constant-grade, and closed-form. Build them from `FixtureRoadPath`, which adds `add_feature()`.

| Method | Rate | Notes |
| --- | --- | --- |
| `sample_into(s, out: RoadSample)` | tick, **no alloc** | Fills `s, pos_x/y/z, pos, tangent, right, up, heading, curvature, elevation, grade`. `grade = d(elevation)/ds`. |
| `curvature_at(s) -> float` | tick | Signed, + = right. |
| `sample(s) -> RoadSample` | non-tick | Allocating convenience. |
| `lane_count(s) -> int` | tick | Player carriageway; the opposite side mirrors it. |
| `lane_width(s)`, `lane_center_d(lane, s)`, `opposite_lane_center_d(lane, s)` (= −center) | tick | |
| `lane_index_at(d, s) -> int` | tick | −1 when off the driving lanes. |
| `median_barrier_d(s)`, `lanes_left_edge_d(s)`, `lanes_right_edge_d(s)`, `shoulder_outer_d(s)`, `guardrail_d(s)` | tick | Positive-side edges; negate them for the opposite side. |
| `is_on_shoulder(d, s) -> bool` | tick | Inner or outer shoulder. |
| `features_in(s0, s1, out: Array[RoadFeature])` | director, may alloc | Appends every feature overlapping `[s0, s1)`, sorted by `s_start`. |
| `length_generated() -> float` | any | Furthest safe `s`. Never sample beyond it. |
| `ensure_generated_to(s)` / `forget_before(s)` | director, may alloc | Hooks for the endless generator. |

The base implements the cross-section queries from `RoadTuning` (`configure_cross_section`). Override them only for tapers. A `RoadFeature` holds `kind, s_start, s_end, value, tag, tag2`. The kinds are:

- `BLIND_CREST` and `BLIND_BEND`: the director caps density for 150 m after `s_end`.
- `BEND`: `value` = apex curvature.
- `LANE_COUNT_CHANGE`: `value` = the new count, with the taper over `s_start..s_end`.
- `FORK`: `tag` = left biome, `tag2` = right biome.
- `CHECKPOINT`: `value` = leg index, `tag` = landmark style.
- `TUNNEL`.
- `SIGN`: `tag` = what the sign announces, `value` = the distance it announces.

The generator must keep radius ≥ 1,200 m, grade ≤ 5%, C1 continuity, and the sun 15–30° off the camera axis (`RoadTuning`).

## 4. Vehicles

**`VehicleState`** (`src/vehicle/vehicle_state.gd`, RefCounted, plain floats): `s, d, yaw, v` (forward speed), `v_lat, yaw_rate, steer_angle, accel_long, accel_lat, rpm, gear, boost_active, boost_meter` (0..1). It also has `reset()`, `copy_from(o)`, `hash_into(h)` and `trace_hash()`, which hash exact bits over every field. World heading = road heading at `s` + `yaw`.

- **Writers:** `vehicle_physics`, which owns every field except the gearbox placeholders and the boost-meter fill. The caller adds `ScoringRuleSet.take_boost_fill()` to `boost_meter`, clamped to 1. Physics drains `boost_meter` and sets `boost_active`.
- **Readers:** scoring, camera, `car_visual`, traffic (the player as participant), passability and the HUD.

**`VehicleInput`** (`src/vehicle/vehicle_input.gd`): `steer` (−1..1, + right), `throttle` (0..1), `brake` (0..1) and `boost` (bool, edge-triggered: true for the one tick a boost is requested). It has `clear()`, `copy_from()` and `hash_into()`. Every control layout produces exactly this, and physics and scoring can't tell layouts apart.

**`VehicleController`** (`src/vehicle/vehicle_controller.gd`) is the base:

```
func on_attached(state: VehicleState) -> void   # takes over a vehicle (also at spawn)
func on_detached() -> void
func update(dt: float, state: VehicleState, out_input: VehicleInput) -> void   # per physics tick, no alloc
```

`PlayerController` and `AIController` subclass it, and later `HopController` does too. The owner holds `controller` as a plain reference and can **swap it between ticks at runtime without respawning**. The `VehicleState` is untouched, and controllers only read state. Context such as road, traffic or input sources goes into a controller's constructor.

**Per-tick order** (run.gd, 120 Hz):

1. `controller.update`
2. `vehicle_physics.step(state, input, dt, params)`
3. `traffic_sim.step` (player as participant)
4. collisions and hits
5. `scoring.step`
6. `sun_clock.advance`

After the ticks, the Node adapters drain the event buffers onto `Events` once per frame.

## 5. TrafficState

`class_name TrafficState extends RefCounted` (`src/traffic/traffic_state.gd`) is a structure of arrays with fixed `capacity`: `traffic.max_active_vehicles` = 60 for the player's carriageway. The visual-only opposite carriageway uses its own instance (`traffic.opposite_max_vehicles`, `d < 0`, moving toward −s, `v` = speed). Every array is allocated once in `_init` and never resized.

| Field | Type | Meaning |
| --- | --- | --- |
| `active` | byte | 1 = live slot |
| `vehicle_id` | int32 | Unique per spawn within a run. Key per-car memory on it (cut cooldowns, pass tracking). |
| `s, d, v, v0` | f64 | Box center; speed; IDM desired speed |
| `v_lat` | f64 | `d_dot`. Visual yaw = `atan2(v_lat, v)`. |
| `accel` | f64 | Longitudinal, after clamps |
| `length, width` | f64 | Visual body. Consumers apply `lives.collision_inset_m`. |
| `lane, target_lane` | int32 | 0 = next to the median |
| `lc_state` | int32 | `LaneChange.NONE / SIGNALING / MOVING` |
| `lc_timer, lc_duration, lc_start_d` | f64 | Time in state; signal or move time; smoothstep origin |
| `react_timer` | f64 | Hit recovery (~4 s), brake tap, horn timers |
| `type_id, profile_id` | int32 | Indices into the `VehicleType` and `DriverProfile` registries (load order) |
| `model_variant, color_index` | int32 | Model in `VehicleType.model_scene_paths`; biome palette entry |
| `flags` | int32 | `FLAG_BRAKE`, `FLAG_BRAKE_STRONG`, `FLAG_BLINKER_LEFT/RIGHT`, `FLAG_HAZARD`, `FLAG_HEADLIGHTS`, `FLAG_HIGH_BEAM`, `FLAG_SCRIPTED` (set piece), `FLAG_HIT` (recovering), `FLAG_FAR` (30 Hz tick) |

API (all allocation-free):

- `allocate() -> int`: lowest free slot first; zeroes the slot and assigns a new `vehicle_id`; returns −1 when full.
- `free_slot(i)`, `clear()`, `is_active(i)`, `is_full()`, `has_flag(i, f)`, `set_flag(i, f, on)`.
- `copy_from(o)`: element-wise, same capacity.
- `hash_into(h)` / `trace_hash()`: live slots only, exact bits.
- `count`, `capacity`, `next_vehicle_id`.

Iterate with `for i in capacity: if active[i] == 0: continue`.

**Ownership.** Only `traffic_sim` writes. Spawns and despawns also go through `traffic_sim`, which the director calls with committed `SpawnSource.Record`s. `set_flag(FLAG_HIT)` and hit reactions come from `traffic_sim.notify_hit(slot)`, which run.gd calls. `FLAG_HEADLIGHTS` follows the sun clock through `traffic_sim`.

| Reader | Uses |
| --- | --- |
| `traffic_view`, sandbox | Everything, read-only; interpolates between ticks |
| scoring | `s, d, v, length, width, lane, vehicle_id`, `active` |
| passability | Works on its own `copy_from` copy and forward-simulates that |
| collisions | `s, d, v_lat, v, length, width` |

Events use the **slot index** (`Events.traffic_horn(vehicle_id=slot, ...)` etc.).

## 6. SpawnSource

`class_name SpawnSource extends RefCounted` (`src/traffic/spawn_source.gd`) is the base. It runs at director rate: once per ~300 m batch, and again on each passability re-roll. It may allocate.

```
func source_id() -> StringName                       # &"flow", &"set_piece", &"daily", later &"beatmap", &"hop_targets"
func plan_batch(ctx: SpawnSource.Context, s_from: float, s_to: float, out_spawns: Array[SpawnSource.Record]) -> void
```

- **`Context`:** `run: RunContext`, `rng: Rng` (from `run.rng_traffic`), `road`, `traffic`, `player`, `leg` (1-based), `density_per_km_lane`, `aggressive_share`, `hesitant_allowed`, `intensity` (0 breather .. 1 peak), `set_pieces_allowed`, `is_night`, `biome`.
- **`Record`:** `s`, `lane`, `d` (NAN = lane center), `v` (initial speed: the lane flow speed, IDM-consistent), `v0`, `type_id`, `profile_id`, `model_variant`, `color_index`, `flags` (initial `FLAG_*`), `set_piece` (SetPieceDef id or `&""`).
- **Rules:** deterministic given `ctx` (all randomness from `ctx.rng`); never spawn overlapping the player or the ghost zone; ahead spawns go beyond the fog (~750 m); behind spawns (~150 m) only when the player is slower and the spawn is outside the frustum. The director owns passability and the commit.

## 7. Scoring and events

### ScoreEventBuffer (the pattern for every pure system that emits)

`class_name ScoreEventBuffer extends RefCounted` (`src/scoring/score_event_buffer.gd`) is preallocated to `capacity` (`scoring.event_buffer_capacity`). Each record is `kind: StringName, tag: StringName, points: int, multiplier: float, clearance_m: float (−1 = n/a), slot: int (−1 = n/a), value: float`.

- `push(kind, points=0, multiplier=0, clearance_m=-1, slot=-1, value=0, tag=&"") -> bool` is allocation-free. When the buffer is full it **drops the new event**, returns false and increments `dropped`. Size it so this never happens.
- **Drain once per frame** in the owning Node adapter: `for i in buf.size(): ...read buf.kind[i], buf.points[i]...`, then `buf.clear()`. `reset()` also zeroes `dropped`.
- Pure systems (scoring, sun clock, collisions and lives, traffic reactions) each write into a caller-provided buffer. The adapter maps kinds to `Events` signals:

| kind | Written by | Adapter emits |
| --- | --- | --- |
| `Events.PASS`, `CLOSE_PASS`, `CUT`, `THREAD` | scoring (`slot` = car) | `scored(kind, points, multiplier, clearance_m)` |
| `ScoringRuleSet.KIND_BANKED` (`tag` = `Events.REASON_*`, `value` = banked total) | scoring | `chain_banked(points, tag, int(value))` |
| `KIND_CHAIN_LOST` (`tag` = reason) | scoring | `chain_lost(points, tag)` |
| `KIND_HESITATED` | scoring | `hesitated()` |
| `KIND_TOO_SLOW`, `KIND_SHOULDER`, `KIND_SLIPSTREAM` (`value` 1/0) | scoring | `too_slow_changed` / `shoulder_penalty_changed` / `slipstream_changed` |
| `KIND_BONUS` (`tag` = bonus kind, `value` = banked total) | scoring | `bonus_awarded(tag, points, int(value))` |
| `KIND_SUN_NUDGE` (`value` = fraction of the day span) | scoring | Not a signal: run.gd calls `SunClock.lift(value)` |
| `&"night_started"`, `&"dawn_started"` (`value` = duration), `&"morning_reached"`, `&"sun_lifted"` (`value` = fraction) | sun clock | The signal of the same name |
| `&"hit"` (`tag` = `Events.HIT_*`, `value` = lives left) | collisions and lives | `hit(tag, int(value))` |

`multiplier_changed` and `chain_changed` are emitted by the adapter when `ScoringRuleSet.multiplier()` or `chain()` changed since the last frame, not per tick.

### ScoringRuleSet

`class_name ScoringRuleSet extends RefCounted` (`src/scoring/scoring_rule_set.gd`) is swappable per mode. WP3.4 implements `scoring.gd`. `step` and the `notify_*` methods don't allocate.

```
func reset(ctx: RunContext) -> void
func step(dt, player: VehicleState, traffic: TrafficState, road: RoadPath, out_events: ScoreEventBuffer) -> void
func set_night(on) / set_ghost(on)                              # night x2; nothing scores in the ghost period
func notify_hit(out) / notify_checkpoint(out) / notify_run_end(out)
func award_bonus(bonus_kind, base_points, out)                   # straight to banked; night factor applied
func multiplier() -> float / chain() -> int / banked() -> int
func take_boost_fill() -> float                                  # meter fraction earned since last call
```

The rule set owns the multiplier, chain, banked total, cut cooldowns (keyed by `vehicle_id`), the thread window, and the shoulder and minimum-speed timers. `points = base × multiplier × speed_factor(v) × night_factor`. Rounding is WP3.4's choice, but it must be documented and deterministic.

## 8. SunClock

This is the API for `src/sun/sun_clock.gd` (WP3.5). It is documentation only: no base class. It is pure, headless and allocation-free per tick.

```
class_name SunClock extends RefCounted
func _init(sun: SunTuning, legs: LegsTuning) -> void
func reset() -> void                                   # sky_t = sun.sky_t_run_start, day
var sky_t: float                                       # read-only outside; cyclic [0, 1)
func advance(dt: float, too_slow: bool, out: ScoreEventBuffer) -> void
func lift(fraction_of_day_span: float, out: ScoreEventBuffer) -> void
func on_checkpoint(leg_avg_speed_mps: float, out: ScoreEventBuffer) -> void
func is_night() -> bool
func is_dawning() -> bool
func sun_height() -> float                             # 0..1 for the HUD bar (1 = run start, 0 = sunset)
```

- **Timeline:** `sky_t` is cyclic in [0, 1). The keyframes and their order are in `SunTuning.sky_t_*`: morning 0 → afternoon → golden hour → sunset → dusk → night → dawn → 1.0 ≡ morning. These positions are the single source for both the clock and `data/color_script.tres`. **Day span** = `sky_t_sunset − sky_t_run_start`: the span covered by the spec's "5 minutes from the starting afternoon".
- **Day:** `sky_t` advances by `base_sink_per_s()`, ×`too_slow_sink_factor` (3) while too slow.
- **Sunset:** crossing `sky_t_sunset` makes `is_night()` true and emits `night_started`. `sky_t` then runs to `sky_t_night` over `nightfall_s` and holds there. Night has no timer.
- **Lifts** (day only): `lift(f)` moves `sky_t` back by `f × day_span` and never earlier than `sky_t_run_start`. It emits `sun_lifted`.
- **Checkpoint (day):** lift by `checkpoint_lift_pct` plus `checkpoint_pace_lift_max_pct × clamp((avg − pace_target) / pace_full_lift_margin, 0, 1)`.
- **Checkpoint (night):** starts the dawn transition. `is_night()` becomes false and `dawn_started(dawn_transition_s)` fires. `sky_t` goes night → dawn → 1.0 ≡ morning over 6 s while play continues, then `morning_reached` fires. `sky_t` lands at morning (0), which is earlier than the run start, as the spec says.

## 9. RunContext and determinism

`class_name RunContext extends RefCounted` (`src/core/run_context.gd`) is created once per run and passed to every seeded system:

- `run_seed`, `mode` (`MODE_JOURNEY` / `MODE_DAILY`), `tuning` (defaults to `Tuning.load_default()`).
- `rng_road`, `rng_traffic`, `rng_props`, `rng_events` = `Rng.new(run_seed).derive(Rng.STREAM_*)`.
- `RunContext.daily(y, m, d)` builds a Daily Drive context with `Rng.daily_seed`.

A system that needs more streams derives them from its own stream, e.g. `ctx.rng_traffic.derive(&"passability")`. It never uses global RNG, `Time` or frame timing.

- **Trace hashing:** `TraceHash` (`src/core/trace_hash.gd`) provides `mix_int`, `mix_float` (exact IEEE bits), `mix_bool` and `mix_f64_array`. It is 32-bit FNV-style and allocation-free. `VehicleState`, `VehicleInput`, `TrafficState` and `ScoreEventBuffer` expose `hash_into(h)`. Determinism tests hash the state every `traffic.trace_hash_interval_s` (1 s) and compare runs.
- **Music clock:** `MusicClock` (`src/audio/music_clock.gd`) exposes `beat_phase()`, `bar()`, `beat_in_bar()`, `bpm()` and `is_running()`. All return 0/false in v1; it is the Tempo Highway hook.

## 10. Data resources

These are resource classes only. Their `.tres` files come from later WPs. Class defaults are neutral placeholders, and every data file sets its own values.

| Class | File(s) | Key fields |
| --- | --- | --- |
| `CarDef` (`src/vehicle/car_def.gd`) | `data/cars/*.tres` | `id`, `display_name`, `model_scene_path`, `top_speed_kmh` (240–300), `zero_to_200_s`, `braking_mps2`, `handling_scale` (0.9–1.1), `boost_capacity_scale`, body dims, `mass_kg`, `gear_count`, paint and rim defaults and options. WP1.5 adds physics coefficients. |
| `VehicleType` (`src/vehicle/vehicle_type.gd`) | `data/vehicle_types/*.tres` | `id`, `length_m/width_m/height_m` (truck 16 m, bus 12 m), `blocks_sightlines`, `is_motorbike`, `mass_kg`, `grip_scale`, `lane_change_time_scale`, `shove_strength`, `durability`, `allowed_profiles`, `model_scene_paths` |
| `DriverProfile` (`src/traffic/driver_profile.gd`) | `data/driver_profiles/*.tres` (8) | Desired speed range (km/h, from the spec's driver-types table); IDM `a_max`, `b_comfort`, `T`, `s0`, `δ = 4`; MOBIL `p`, `Δa_th`, `a_bias` (keep right), `b_safe`; `signal_time_s`; move time range; `lane_change_frequency_scale`; `cancel_probability` (Hesitant ~0.2); `keep_right`; `lane_split` (motorbike); `min_leg` (Hesitant 3) |
| `BiomeDef` (`src/road/biome_def.gd`) | `data/biomes/*.tres` | `lane_count`, curve/crest/tunnel frequency scales, prop scenes and densities, tint offsets, horizon cards, traffic palette, set-piece ids and weights, `landmark_style` (`LANDMARK_*`) |
| `SetPieceDef` (`src/traffic/set_piece_def.gd`) | `data/set_pieces/*.tres` | `kind` (8 kinds), `warning` style, `warning_sign_distances_m` (merge 500/250, road works 400, toll 1000/500), length, lanes closed or open, `lane_count_override`, `drops_right_lane`, `hazards`, `allows_hard_decel` (needs ≥ 300 m warning), `min_leg`, `weight` |

Global traffic rules apply on top of every profile: the 6 m/s² clamp, the 0.5 s signal floor, the player `b_safe` of 2 m/s², no-ambush, and the density caps (`TrafficTuning`, `DirectorTuning`).

## 11. Tuning

`Tuning.load_default()` loads and caches `res://data/tuning.tres`. The root file is orchestrator-owned and only references the per-system files. Each per-system file is owned by the WP that owns the system (plan D3). Pure sims never call `load_default()`: they receive params, usually through `RunContext.tuning`.

| Field | File | Class | Covers | Owner |
| --- | --- | --- | --- | --- |
| `quality` | `data/tuning/quality.tres` | `QualityTuning` | Tiers, fps caps, governor, draw and triangle budgets (**frozen schema**) | WP0.3 / WP9.1 |
| `road` | `road.tres` | `RoadTuning` | Cross-section, lanes 3 (2–4), radius, grade, chunks, floating origin, sun offset, roadside rhythm | WP1.1–1.4 |
| `vehicle` | `vehicle.tres` | `VehicleTuning` | Tick, lane-change targets, steering, braking, slip clamp, boost physics, test targets, gearbox, body motion | WP1.5 / WP2.1 |
| `controls` | `controls.tres` | `ControlsTuning` | Drag, gyro, keyboard ramp, first-run warm-up | WP2.2 |
| `camera` | `camera.tres` | `CameraTuning` | Modes, FOV 62→78, pull-back, look-ahead, roll, finale swing | WP2.3 |
| `traffic` | `traffic.tres` | `TrafficTuning` | Cap 60, near/far ticks, IDM δ, decel clamp, brake lights, telegraphing, no-ambush, flow speeds, spawn distances, opposite side, reactions, soak and metrics | WP2.4 / WP2.5 / WP3.3 |
| `director` | `director.tres` | `DirectorTuning` | Waves, density and aggressive ramps by leg, Hesitant from leg 3, blind windows, set-piece warning, batch length | WP6.2 |
| `passability` | `passability.tres` | `PassabilityTuning` | 10 Hz, 8 s, 0.25 s steps, half-lane grid, 0.3 m, 5 re-rolls | WP6.1 |
| `scoring` | `scoring.tres` | `ScoringTuning` | Speed factor, multiplier decay, minimum speed, hesitation, grace, event points and gains, windows, shoulder, boost meter | WP3.4 |
| `lives` | `lives.tres` | `LivesTuning` | Lives, ghost period, first hit, clean-leg restore, collision inset | WP3.5 / WP4.1 |
| `sun` | `sun.tres` | `SunTuning` | `sky_t` keyframes, sinking, lifts and nudges, dawn | WP3.5 / WP5.1 |
| `legs` | `legs.tres` | `LegsTuning` | Leg length, legs to coast, warnings, forks, pace, leg bonuses, objectives, journey bonus | WP5.2 |
| `feel` | `feel.tres` | `FeelTuning` | Slow motion, haptics, speed lines, FOV punch, shake | WP7.4 |
| `hud` | `hud.tres` | `HudTuning` | Event stack, multiplier display, toasts, countdown, retry, design-system metrics, text scales | WP4.3 / WP4.4 |
| `progression` | `progression.tres` | `ProgressionTuning` | Ghost 20 Hz, roster and unlocks, achievements, asset triangle budgets | WP8.x / ART2 |

- **Adding fields:** a WP may add fields to the sub-resource it owns. Add the field to the class (spec value as the default, unit suffix, `## doc`), write it into the `.tres`, and test it. Remove or rename a field only by orchestrator decision.
- **Values not in the spec** carry a `# not in spec: <reason>` comment on the field. `tests/unit/test_tuning.gd` asserts every row of the spec's Tuning reference table.
- **Not in `Tuning`:** per-entity numbers live in entity data (driver-type speeds and lengths, set-piece sign distances, car stats) as described in §10. Colors live in `data/color_script.tres` and `ui/theme.tres`. The spec's No Hesi reference numbers (80 km/h, 7 m, 4 m) describe the source game and are not Westbound tuning.

## 12. No-allocation rules

- **Per-tick code** (physics, `traffic_sim`, scoring, sun clock, controllers, collisions) creates no `Array`, `Dictionary`, `String`, object or `Packed*Array`. It does no string formatting and doesn't use `str()`, `%`, `+` on strings or `StringName(String)`. `Vector3` values are fine (value types). Preallocate at init and reuse.
- **Allocation-free APIs:** `*_into(..., out)` and `hash_into(h)` APIs write into caller-owned objects: `RoadPath.sample_into`, `VehicleState/VehicleInput/TrafficState.copy_from`, `ScoreEventBuffer.push`, `TrafficState.allocate/free_slot`, `TraceHash.*`. `ScoreEventBuffer.hash_into` hashes names, so use it at trace rate only.
- **Director rate** (per batch, per re-roll, per chunk) may allocate: `RoadPath.sample()`, `features_in`, `ensure_generated_to`, `SpawnSource.plan_batch`, `RoadFeature.make`. Keep it off the tick path.
- **Packed arrays:** never assign one Packed array to another field (`a = b` shares the buffer, and the next write copies it). Copy element-wise, as `TrafficState.copy_from` does.

## Change log

| Date | Change | Decision |
| --- | --- | --- |
| 2026-09-28 | Initial contracts (WP0.2) | Orchestrator brief for WP0.2 |
