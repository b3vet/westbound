# Core loop: sun clock, legs, hits and lives (as implemented)

WP3.5. Spec: "Core loop: Chase the Sun" and "Lives, hits and crashes". Contract: [CONTRACTS.md §8](CONTRACTS.md#8-sunclock). All four systems are pure `RefCounted` classes. They are headless, deterministic and allocation-free per tick, and they emit into a caller-provided `ScoreEventBuffer`.

| File | Class | Owns |
| --- | --- | --- |
| `src/sun/sun_clock.gd` | `SunClock` | `sky_t`, day / night / dawn phase |
| `src/core/leg_tracker.gd` | `LegTracker` | leg index, checkpoint and sign queue, per-leg facts, coast |
| `src/vehicle/hit_detection.gd` | `HitDetection` | swept contact tests of the player box |
| `src/vehicle/lives.gd` | `Lives` | lives, ghost timer, first-hit response and wobble |

## Sun clock timeline

Keyframes come from `SunTuning.sky_t_*` (morning 0, afternoon 0.2, golden 0.38, sunset 0.5, dusk 0.58, night 0.66, dawn 0.85, then 1.0 ≡ morning). The day span is `sunset − run_start` (0.3).

| Phase | `sky_t` per tick | Leaves when |
| --- | --- | --- |
| DAY | `+= day_span / (sunset_from_start_min · 60) · dt`, ×`too_slow_sink_factor` (3) when too slow | it reaches sunset. Emits `night_started`, and the rest of that tick already runs the nightfall |
| NIGHTFALL | `+= (night − sunset) / nightfall_s · dt` (8 s, visual only) | it reaches `sky_t_night` and holds there |
| NIGHT | constant. **No timer.** | a checkpoint |
| DAWN | linear from the value at the checkpoint to 1.0 over `dawn_transition_s` (6 s), passing the dawn key. `too_slow` is ignored | 6 s later (exactly 720 ticks at 120 Hz): `sky_t = sky_t_morning`, `morning_reached`, then DAY |

- **`is_night()`** is true in NIGHTFALL and NIGHT. **`is_dawning()`** is true in DAWN.
- **`lift(f)`** works in DAY only. It sets `sky_t = max(sky_t − f·day_span, min(run_start, sky_t))`, so it never goes earlier than the run start, and never earlier than where it already is. After a dawn (morning is 0 < 0.2), lifts do nothing until the sun sinks past the run start again. `sun_lifted` carries the fraction actually applied, and nothing is emitted if that is 0.
- **Day checkpoint:** `lift(0.40 + 0.20 · clamp((avg − pace_target) / pace_full_lift_margin, 0, 1))`. The targets are 170 km/h and +40 km/h (`LegsTuning`).
- **Night checkpoint** (NIGHTFALL or NIGHT): starts DAWN and emits `dawn_started(6)`. **Checkpoint while dawning:** ignored. This can't happen with 3.5 km legs.
- **`sun_height()`** is `clamp((sunset − sky_t) / day_span, 0, 1)` by day, 0 at night, and the dawn's progress (0 → 1) while dawning.
- **Nudges** (thread, 5 close passes in 10 s) come from scoring as `KIND_SUN_NUDGE`. run.gd calls `lift(value)`.

## Legs and checkpoints

`LegTracker` reads the road only through features. `plan_ahead(road, s_to)` runs at director rate. It generates the road up to `s_to` and queues `CHECKPOINT` features (`value` = the leg ending there, `tag` = landmark) and `SIGN` features tagged `ProceduralRoadPath.SIGN_CHECKPOINT` (`value` = announced distance). The queue holds 16 of each. Calling it again never queues a feature twice. `step(dt, player_s, is_night, out)` is tick-safe:

- **Passing a sign** emits `checkpoint_warning` (`value` = 1000 / 500), once per sign.
- **Crossing a checkpoint** fills `crossing` and emits `checkpoint_crossed` (`value` = leg index), then `coast_reached` (once, on the crossing that ends leg `legs_to_coast` = 8), then `leg_started` (`value` = next leg). It returns true. Legs continue past the coast without end.

`crossing` holds `leg_index`, `s`, `landmark`, `distance_m`, `duration_s`, `avg_speed_mps`, `clean` (no counted hit), `pace` (avg ≥ target), `threads` / `threads_bonus` (≥ 3), `close_passes`, `heat_best_s` / `heat` (longest continuous run of `observe_multiplier` ≥ 10×, at least 15 s within the leg), `objective` / `objective_done`, `at_night` and `coast`. `bonus_count()`, `bonus_kind(i)` and `bonus_base_points(i, legs)` list the earned leg bonuses in the order Clean, Pace, Threads, Heat.

**The run's dispatch** of a crossing, in the spec's order:

1. `scoring.notify_checkpoint(out)`: banks the chain.
2. `sun.on_checkpoint(crossing.avg_speed_mps, out)`: lifts the sun, or brings the dawn.
3. `scoring.award_bonus(kind, base, out)` for each earned bonus, plus the objective. Scoring applies ×2 at night. A leg finished at night (`crossing.at_night`) pays ×2, so update `scoring.set_night(sun.is_night())` only after the bonuses.
4. `if crossing.clean: lives.restore_life(out)`.
5. The toast (HUD, from `checkpoint_crossed`).

Hooks the run forwards: `notify_hit()` (counted hits only), `notify_thread()`, `notify_close_pass()`, `observe_multiplier(dt, mult)`, `set_objective(id)` / `complete_objective()` (objective content comes in Phase 5), and `distance_to_checkpoint(s)` for the HUD bar.

## Hit detection

**Boxes.**

- **Player:** `(s, d)` with heading `yaw` and the `CarDef` body from `set_player_body`.
- **Traffic slot:** `(s, d)` with heading `atan2(v_lat, v)` and `length × width`.
- **Inset:** both are inset by `collision_inset_m` (8 cm) on every side.
- **Frame:** `(s, d)` is treated as locally Cartesian. The error is below 0.4% at R ≥ 1,200 m.

**Swept test.** Each body moves linearly from its pose at the previous `step()` to its pose now.

- **Previous poses:** kept per slot and keyed by `vehicle_id`, so a reused slot is never swept from the old car. Traffic beyond `collision_broadphase_m` (40 m along s) is skipped and untracked. It cannot reach the player within one tick.
- **Headings:** held at the current tick's values.
- **Contact time:** a separating-axis test over the 4 box axes on the relative motion gives the exact first overlap time `toi` in the tick. A contact that starts and ends between two ticks (a corner clip at 350 km/h) is found.
- **Normal and contact point:** the normal is the axis of least penetration at `toi`. The contact point is on the player's face along the normal, centered on the overlap.
- **Barriers:** each inset corner is checked at its own `s`. Left corners are checked against `median_barrier_d(s)` and right corners against `guardrail_d(s)`, which follows lane tapers. The gap is interpolated over the tick. Scrapes count.
- **Roadside objects:** `set_prop_query(PropQuery)` is a subclass hook. It is an object, not a `Callable`, so the call does not allocate. Props sit beyond the guardrail, so the guardrail check covers them for now.

**Result.** The earliest contact of the tick goes into a caller-owned `HitDetection.Contact` with these fields:

- `source`: `HIT_TRAFFIC` / `HIT_BARRIER` / `HIT_PROP`, which equal `Events.HIT_*`
- `slot` and `vehicle_id`
- `toi`
- contact point `s, d`
- normal
- relative velocity: player minus other, in road space
- `side` (±1 flank), `end` (±1 nose or tail) and `away_side`, the lateral direction to deflect

**Cost.** About 17 µs per tick with 60 cars (desktop).

## Lives

The per-tick order is tick step 4 (CONTRACTS §4): `lives.step(dt, player, out)`, then `hits.step(...)`, then on a contact `lives.on_contact(contact, player, out)`.

| Outcome | When | Effects |
| --- | --- | --- |
| `NONE` | no contact | none |
| `IGNORED` | during the ghost (`ghost_period_s` = 2.0 s, exactly 240 ticks) or after the run is over | none. It doesn't count |
| `FIRST_HIT` | a life lost with at least one left | `hit(tag = source, value = lives left)`, `ghost_started(2.0)`, and `apply_hit_response`: speed ×0.8, a heading kick `atan(first_hit_deflect_mps / v)` away from the contact (capped at 10°), and a 0.6 s wobble (a decaying yaw sine that is heading-neutral). `VehiclePhysics` then returns the heading. Measured: 0.3–0.4 m of deflection, and settled within 1° by about 0.7 s |
| `RUN_OVER` | the last life lost | `hit(value = 0)`. The crash hand-off comes in Phase 4 |

- **The run also forwards** `scoring.notify_hit(out)` (chain lost, multiplier 1.0, and the 3 s minimum-speed grace, which scoring owns), `scoring.set_ghost(lives.is_ghost())`, `traffic_sim.notify_hit(contact.slot)` for traffic, and `leg_tracker.notify_hit()`.
- **`restore_life(out)`** runs on a clean leg. It adds one life up to `lives` (2), only while `clean_leg_restore` is on and the run is not over, and emits `life_restored(lives)`.
- **The ghost** ends with `ghost_ended`.
- **After the ghost,** a player still touching a body is hit again. The deflection normally separates them first.

## Event kinds

The run's adapter emits the `Events` signal of the same name for each kind.

| Kind | Writer | `value` / fields |
| --- | --- | --- |
| `night_started`, `morning_reached` | SunClock | none |
| `dawn_started` | SunClock | duration (s) |
| `sun_lifted` | SunClock | fraction of the day span applied |
| `checkpoint_warning` | LegTracker | distance announced (m) |
| `checkpoint_crossed` | LegTracker | leg index. The summary is in `LegTracker.crossing` |
| `leg_started` | LegTracker | new leg index. The biome and objective come from the run |
| `coast_reached` | LegTracker | none |
| `hit` | Lives | `tag` = `Events.HIT_*`, `slot`, `value` = lives left |
| `ghost_started` | Lives | duration (s) |
| `ghost_ended` | Lives | none |
| `life_restored` | Lives | lives |
| `objective_completed` | run.gd for LegObjectives (WP5.2) | `tag` = objective id, `points` = bonus paid |

## Leg objectives (WP5.2)

Spec: "Each leg shows one optional objective on entry, such as '5 close passes', 'thread twice' or 'no braking'. Completing it pays a bonus." `LegObjectives` (`src/core/leg_objectives.gd`) is pure, headless, deterministic by seed and allocation-free per tick. The numbers are `LegsTuning.objective_*`.

| Id | HUD text | Rule | Completes |
| --- | --- | --- | --- |
| `close_passes` | 5 CLOSE PASSES | count scored `CLOSE_PASS` events (`objective_close_passes_count`) | at once |
| `threads` | THREAD TWICE | count scored `THREAD` events (`objective_threads_count`) | at once |
| `cuts` | 6 CUTS | count scored `CUT` events (`objective_cuts_count`) | at once |
| `top_speed` | HIT 250 KM/H | the player's speed reaches `objective_top_speed_kmh` once | at once |
| `slipstream` | 5 S OF SLIPSTREAM | seconds with `scoring.is_slipstreaming()` add up to `objective_slipstream_s` | at once |
| `no_braking` | NO BRAKING | fails on brake input above `objective_brake_threshold` after the leg's first `objective_avoid_grace_s` | at the checkpoint |
| `no_shoulder` | NO SHOULDER | fails on any wheel on the shoulder after the grace | at the checkpoint |

- **Choice.** `reset(ctx)` derives `ctx.rng_events.derive(&"objectives")`. `start_leg(leg)` draws once per leg, uniformly from `objective_pool` minus the previous leg's objective (never twice in a row). Legs before `objective_first_leg` (1: every leg, including leg 1) get none and draw nothing. The same seed gives the same sequence. Draws from `rng_events` elsewhere never shift it. `force(id)` (dev, tests) replaces the current objective without drawing.
- **Counting.** Only *scored* events count: nothing counts in the ghost period or on the shoulder, like the score itself.
- **Paid exactly once.** `notify_scored()`, `step()` and `finish_leg()` each return true only on the tick the objective completes, once per leg. The run then calls `_pay_objective()`: `scoring.award_bonus(LegTracker.BONUS_OBJECTIVE, objective_bonus_points)` straight into the banked total (×2 at night, like every bonus) and pushes `objective_completed` (tag = id, points = what was paid).
    - Counting, reaching and holding objectives are paid **when completed** ("Completing it pays a bonus"), so the reward lands on the moment.
    - "No X" objectives can only be judged at the line: they are paid in crossing step 3, with the leg bonuses. A leg finished at night pays ×2.
    - The crossing never pays an objective completed earlier. `crossing.objective_done` and `crossing.objective_points` (the summary's `objective_points`) record what was paid.
- **LegTracker hooks** (additive): `complete_objective(points)` (mid-leg), `complete_crossing_objective(points)` (at the line, after `step()` started the next leg), `leg_start_s()`.
- **Run wiring** (`run.gd`): the objective is drawn at the run start and after every crossing. Leg 1 is announced with `leg_started(1, biome, objective)` like the others. Scored kinds go to `notify_scored()` from `_forward_scoring`. `step(dt, car.input.brake, v, slipstream, shoulder)` runs at tick step 7, before the leg tracker. `trace_hash()` includes the objective state. The HUD feed gets `objective_progress`, `objective_target` and `objective_failed`.

### Gate M5 test

`tests/run/test_run_legs.gd::test_m5_day_night_dawn_across_legs` drives the real run with the weaving bot across five legs (teleporting to just before each checkpoint, and bringing the sunset forward by setting `sky_t`). It checks:

- the warnings at 1 km, then 500 m, then the crossing
- day bonuses ×1
- an objective paid mid-leg by day and not again at the line
- night, then the crossing (bonuses ×2, `at_night`), then the dawn (6 s), then morning, with `sky_t` at morning
- a hit leg without a restore, then a clean leg restoring the life, capped at 2
- a "no X" objective paid at the line
- one objective bonus per `objective_completed`
- the six `leg_started` objectives equal to the pure seeded sequence, never repeating back to back

It takes about 1.5 s.
