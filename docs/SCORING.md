# Scoring (WP3.4)

This page describes the v1 Chase-the-Sun scoring rules as they are implemented in `src/scoring/scoring.gd` (`class_name Scoring extends ScoringRuleSet`). The spec's **Scoring** section is the source of truth. This page records how each rule reads in code, every threshold, the rounding, and the choices made where the spec is open. Every number comes from `data/tuning/scoring.tres` (`ScoringTuning`). The exceptions are the collision inset, which comes from `lives.tres`, the sun nudges from `sun.tres`, and the default player body from `traffic.tres`.

Files:

- `src/scoring/scoring.gd`: the rule set. It is pure, deterministic and allocation-free per tick.
- `src/scoring/road_hull.gd`: `RoadHull.clearance(...)`, the minimum distance between two oriented boxes in road space.
- `src/scoring/score_events.gd`: `ScoreEvents.PASS/CLOSE_PASS/CUT/THREAD/REASON_*`. These are the same StringNames as the `Events` constants. `Events` is an autoload, which pure sims may not touch (lint WB103), and a test keeps the two lists equal.
- `tests/unit/test_scoring.gd` and `tests/fixtures/scoring/scoring_scenario.gd`: a scripted player plus constant-speed cars on fixed lines, so every boundary is exact.

## Using it (run.gd, Phase 4)

```gdscript
var rules := Scoring.new(ctx)                        # reset(ctx) reads ctx.tuning
rules.set_player_body(car.length_m, car.width_m)     # default: traffic.player_length_m / _width_m
# per 120 Hz tick, after vehicle physics, traffic_sim and collisions:
rules.step(dt, player_state, traffic.state, road, score_events)
player_state.boost_meter = minf(1.0, player_state.boost_meter + rules.take_boost_fill())
sun_clock.advance(dt, rules.is_too_slow(), sun_events)
# collisions: on a hit -> rules.notify_hit(ev); rules.set_ghost(true) ... set_ghost(false) after 2 s
# checkpoint: rules.notify_checkpoint(ev); award leg bonuses (rules.award_bonus) BEFORE the dawn
#             clears the night, so bonuses for a leg finished at night are doubled; then set_night(false)
# sun clock night_started / dawn_started -> rules.set_night(true / false)
# run over (second hit): rules.notify_hit(ev) (or not) then rules.notify_run_end(ev); final = rules.banked()
```

Draining the buffer: `KIND_SUN_NUDGE` → `SunClock.lift(value)`. `Scoring.KIND_NEAR_MISS` → `TrafficSim.notify_close_pass(slot)`, which honks about 30% of the time. Every other kind maps to its `Events` signal as listed in CONTRACTS §7.

Queries: `multiplier()`, `chain()`, `banked()`, `take_boost_fill()`, `is_too_slow()`, `is_on_shoulder()`, `shoulder_penalty_active()`, `gains_blocked()`, `is_slipstreaming()`, `is_ghost()`, `is_night()`, `is_ended()`, and `hash_into(h)` / `trace_hash()` for determinism traces.

## Points and rounding

```
points = roundi(base × multiplier × speed_factor(v) × night_factor)
```

- **`multiplier`** is the value *before* this event's gain, so a pass at 1.0× pays 10 × 1.0 and then the multiplier becomes 2.0×. No Hesi's Overtake script works the same way ("10 × combo, then +1"). The event record's `multiplier` field carries this value.
- **`speed_factor(v)`** = `ScoringTuning.speed_factor`: linear from 1.0 at 100 km/h to 2.0 at 250 km/h, clamped at both ends. `v` is `VehicleState.v`, the player's forward speed on that tick, so boost raises it.
- **`night_factor`** is 2.0 while `set_night(true)`, else 1.
- **Rounding:** each event is rounded on its own with `roundi` (round half away from zero) and the chain is an integer sum. The float math is IEEE double and fully determined by the inputs.
- **Several events in one tick** are processed in TrafficState slot order: passes first (per slot), then a cut, and each event sees the multiplier left by the previous one. A thread is paid right after the pass that completes it.

## Events

All distances are in road space (`s`, `d`). **Hulls** are the visual body inset by `lives.collision_inset_m` (8 cm) on each side, as oriented boxes. The player's hull turns with `VehicleState.yaw`, and a traffic car's with `atan2(v_lat, v)`. The **overlap window** of a car is the time its hull overlaps the player's hull *longitudinally* (`|s_car − s_player| < L_car/2 + L_player/2`, both inset). **Clearance** is the minimum `RoadHull.clearance` (the exact minimum distance between the two oriented boxes, 0 if they touch) over that window.

| Event | Rule as implemented | Base | Gain | Boost |
| --- | --- | --- | --- | --- |
| **Pass** | A car that was fully **ahead** (no overlap) enters the overlap window and leaves it fully **behind**. Its center-to-center lateral offset at the tick where the centers cross (`s_car − s_player` goes from > 0 to ≤ 0) must be **≤ 5.4 m**. It is paid when the car is fully behind, because only then is the minimum clearance known. | 10 | +1 | none |
| **Close pass** | A pass whose clearance is **< 1.0 m**. It **replaces** the pass: one `CLOSE_PASS` event, not `PASS` + `CLOSE_PASS`. The spec writes "30 (×3)", i.e. the tripled pass of the Overtake plugin. | 30 | +3 | +10% |
| **Cut** | The player's center crosses from one driving lane into another (`RoadPath.lane_index_at`, both ≥ 0) at **≥ 140 km/h**, with at least one traffic car whose `lane` is the lane left or the lane entered and whose longitudinal hull gap is **≤ 15 m** ahead or behind (overlapping counts). The car must not be on cooldown (see anti-exploit). The event's `slot` is the nearest such car. | 15 | +1 | none |
| **Thread** | Two scored passes (pass or close pass) on **opposite sides** (sign of the lateral offset at the crossing), both with clearance **< 1.5 m**, whose center-crossing times are **≤ 0.5 s** apart. It is paid on top of both passes, on the tick the second pass completes, with `slot` = the second car and `clearance_m` = the larger of the two clearances. Each pass joins at most one thread. | 50 | +5 | +25% |
| **Slipstream** | A car in the player's lane (`traffic.lane == lane_index_at(player.d)`) ahead of the player with a longitudinal hull gap of **≤ 15 m**, with the player at **≥ 120 km/h**. No points, no multiplier. `KIND_SLIPSTREAM` is written with value 1 when it starts and 0 when it stops. | none | none | +20%/s |

Boost fill is a fraction of a full meter (0.10 = 10%), collected by `take_boost_fill()`.

**Why crossing times for the thread window.** The spec's "within one 0.5 s window you pass one car on each side" is read as the moments you draw level with each car. If completion times were used, a car beside a 16 m truck would finish its pass about (16 − 4.5)/2 m earlier than the truck. At a 30 km/h closing speed that is about 0.7 s, so threading a truck and a car side by side would never count.

### Sun nudges and the horn hook

- A **thread** writes `KIND_SUN_NUDGE` with value `sun.thread_nudge_pct / 100` (0.01 of the day span).
- **Five close passes within 10 s** write `KIND_SUN_NUDGE` with value `sun.close_pass_nudge_pct / 100` (0.01). The check fires when the n-th close pass lands within `close_pass_nudge_window_s` of the one n − 1 before it. The count then starts over, so 10 close passes in a row give two nudges. Only scored close passes count.
- The rule set writes nudges day or night. `SunClock.lift` ignores them at night (contract §8).
- `KIND_NEAR_MISS` (with `slot`) is written for every *physical* close pass (clearance < 1.0 m inside the pass window), **scored or not**. A car you brush past on the shoulder still honks. The one exception is the ghost period: the player is intangible then, so no horn.

## Anti-exploit rules

| Rule | Implementation |
| --- | --- |
| A cut needs traffic nearby | A cut is paid only if at least one eligible car is in the lane left or entered within 15 m. Weaving on an empty road, or next to traffic in other lanes or further away, scores nothing. |
| Each car contributes to at most one cut per 3 s | Every eligible car within the window of a scored cut gets `cut_t = now`. A car contributes again only when `now − cut_t ≥ 3 s`. The memory lives in per-slot arrays and is reset whenever the slot's `vehicle_id` changes, so a new car in a reused slot starts fresh. A car on cooldown doesn't count as "traffic nearby". |
| Nothing scores during the ghost period | While `set_ghost(true)`: no pass, close pass, thread, cut, slipstream or boost fill, and no cut cooldown is consumed. A pass whose overlap window touches the ghost period at all never scores, even if it completes after the ghost ends. Bonuses (`award_bonus`) are still paid, because they are earned over the whole leg. |
| Passing on the shoulder scores nothing | A pass whose overlap window includes any tick with the player on the shoulder scores nothing (no points, gain, boost, thread or nudge). "On the shoulder" = **any wheel**: either side edge of the player's hull (`d ± hull half-width`) satisfies `RoadPath.is_on_shoulder`, inner or outer. |

## Multiplier

- **Start and floor:** `multiplier_start` = 1.0. There is **no cap**.
- **Decay** each tick, when not too slow: `0.5/s × decay_term(v)`, where the term falls linearly from 1.0 at 100 km/h to 0.1 at 250 km/h (clamped). This is multiplied by `boost_decay_factor` (0.5) while `VehicleState.boost_active` and by `shoulder_decay_factor` (3) with any wheel on the shoulder. The value never goes below 1.0.

  | Speed | Decay per second |
  | --- | --- |
  | 100 km/h | 0.50 |
  | 175 km/h | 0.275 |
  | 250 km/h | 0.05 |
  | 175 km/h with boost | 0.1375 |
  | 100 km/h on the shoulder | 1.50 |

- **Shoulder:** multiplier gains are blocked with any wheel on the shoulder. If a continuous stint on the shoulder lasts **> 2 s**, the **shoulder penalty** turns on while you are still there. It stays on for **3 s after you leave** (the countdown runs only off the shoulder) and keeps gains blocked. `KIND_SHOULDER` value 1/0 marks the penalty. A stint of 2 s or less leaves no penalty. While gains are blocked, events off the shoulder still pay their points at the current multiplier. They just don't add to it.
- **Minimum speed, 100 km/h (TOO SLOW):** while the rule is active and `v < 100 km/h`, the multiplier **drains at 3/s** in place of the normal decay. `KIND_TOO_SLOW` value 1/0 marks the state, and `is_too_slow()` feeds the sun clock (×3 sinking).
- **Hesitation:** when the rule has been active and the player below minimum speed for **more than 3 continuous seconds** (`slow_time > 3 s`), the rule set writes `KIND_HESITATED`, then `KIND_CHAIN_LOST` (tag `hesitated`, only if the chain is > 0), and resets the multiplier to 1.0. This fires once per continuous slow stretch. Getting back to 100 km/h re-arms it.
- **Grace periods:** the minimum-speed rule is inactive until the player first reaches 100 km/h in the run (`min_speed_grace_until_reached`), and for `min_speed_grace_after_hit_s` (3 s) after `notify_hit`. A hit while TOO SLOW switches it off (value 0) and restarts the hesitation timer.

## Chain and banking

- Every event's points go into the unbanked **chain**.
- **Checkpoint banking:** `notify_checkpoint` banks the whole chain (`KIND_BANKED`, tag `checkpoint`, value = new banked total). The multiplier is kept. An empty chain writes nothing.
- **Cash-out banking:** at the end of every tick, if the chain is > 0, the multiplier is at 1.0, and the player has not been below 100 km/h since the last multiplier gain, the chain banks (tag `cash_out`).
    - This is the reading of "letting the multiplier decay back to 1.0× while staying above minimum speed".
    - If the multiplier reached 1.0 through the TOO SLOW drain, or during a dip below 100 km/h, the chain stays at risk. It stays that way until a checkpoint, a new gain above minimum speed (after which the next decay to 1.0 cashes out), or its loss.
    - Without this rule, a brief dip below 100 km/h would be a 3/s shortcut to cashing out.
    - An event scored while gains are blocked and the multiplier is already at 1.0 banks on the same tick.
- **Losing the chain:** `notify_hit` (tag `hit`; the multiplier drops to 1.0, the hit grace starts and the thread memory clears) and hesitation (tag `hesitated`). **Banked points are never lost.**
- **Bonuses:** `award_bonus(kind, base, out)` adds `roundi(base × night_factor)` straight to the banked total (`KIND_BONUS`, tag = kind, value = banked total). The chain is untouched.
- **Run end:** `notify_run_end` loses the held chain (tag `run_end`). The **final score is `banked()`**. After it, `step`, the `notify_*` methods and `award_bonus` do nothing. If run.gd calls `notify_hit` for the second hit first, the loss is reported with tag `hit` and run end then has nothing left to lose.

## Event records (ScoreEventBuffer)

| kind | points | multiplier | clearance_m | slot | value | tag |
| --- | --- | --- | --- | --- | --- | --- |
| `pass`, `close_pass` | paid | before gain | min clearance | car | 0 | |
| `thread` | paid | before gain | larger of the two | second car | 0 | |
| `cut` | paid | before gain | −1 | nearest car | 0 | |
| `banked` | amount | current | −1 | −1 | banked total | `checkpoint` / `cash_out` |
| `chain_lost` | amount | current | −1 | −1 | 0 | `hit` / `hesitated` / `run_end` |
| `hesitated` | 0 | 0 | −1 | −1 | 0 | |
| `too_slow`, `shoulder_penalty`, `slipstream` | 0 | 0 | −1 | −1 | 1 on / 0 off | |
| `bonus` | paid | 0 | −1 | −1 | banked total | bonus kind |
| `sun_nudge` | 0 | 0 | −1 | −1 | fraction of day span | |
| `near_miss` | 0 | 0 | clearance | car | 0 | |

## Worked examples

All at the default tuning.

1. **A pass at 175 km/h, day, 1.0×:** 10 × 1.0 × 1.5 = **15**. The multiplier becomes 2.0× and the chain 15. At 175 km/h it decays at 0.275/s, so with nothing else happening it reaches 1.0× after 3.6 s and the 15 points bank (cash-out).
2. **A thread at 150 km/h from 1.0×** (speed factor 1.333), both cars 1.4 m clear, same tick:
    - pass at 1.0×: 13.33 → **13**
    - pass at 2.0×: 26.67 → **27**
    - thread at 3.0×: 200 → **200**

    Chain 240, multiplier 8.0×, boost +25%, sun lifted 1% of the day span.
3. **A close pass at night at 200 km/h at 4.3×:** 30 × 4.3 × 1.667 × 2 = **430**, and the multiplier becomes 7.3×.
4. **Cash-out timing from 8.0×:** 14 s at 100 km/h (0.5/s), 25.5 s at 175 km/h, 140 s at 250 km/h. "Cashing out takes longer at high speed."
5. **Hesitation:** at 110 km/h with a 500-point chain at 4×, the player brakes to 90 km/h. TOO SLOW turns on, and the multiplier drains 3/s and reaches 1.0× after 1 s. The chain does *not* cash out, because the player dipped below the minimum. At 3 s + 1 tick: HESITATED, the 500 points are lost, and banked is unchanged. If the player accelerates back to 100 km/h before 3 s, the 500 points stay at risk until the next checkpoint or the next gain followed by a cash-out.
6. **Shoulder:** 2.5 s on the shoulder turns the penalty on at 2.0 s + 1 tick. Back in lane, a pass within the next 3 s pays 10 × 1.0 × speed factor with no +1. Because the multiplier is 1.0×, the points bank immediately.

## Determinism and cost

- No randomness at all. The state depends only on the inputs and `dt`. `hash_into` covers the timers, multiplier, chain, banked total, boost fill and the per-slot pass and cut memory. The determinism test hashes it (plus the event buffer) every second over 30 s of real traffic (TrafficSim + weaving bot) and compares two runs.
- **Allocation-free per tick:** per-slot memory is `Packed*Array`s sized at `reset` to `traffic.max_active_vehicles`, and grown once only if a larger TrafficState shows up. The thread memory is an 8-entry ring and the close-pass nudge memory a `close_pass_nudge_count` ring. The no-allocation test checks that the engine object count stays constant over 60 s of a scripted weaving run.
- **Cost:** about 20–45 µs per 120 Hz step with 60 cars on a desktop (`test_step_budget_60_cars`, budget 150 µs).

## Tests (`tools/test.sh --filter=scoring`)

- **Every event at its boundaries:**
    - lateral window: 5.39 / 5.41 m
    - close pass: 0.99 / 1.01 m
    - cut speed: 139 / 141 km/h
    - cut window: 14.9 / 15.1 m, ahead and behind
    - thread window: 0.45 / 0.55 s
    - thread clearance: 1.49 / 1.51 m
    - slipstream: 119 / 121 km/h and 14.9 / 15.1 m
- **Factors:** speed factor and night ×2.
- **Multiplier:** decay at 100/175/250 km/h and with boost; no cap and the 1.0 floor.
- **Shoulder:** decay ×3, no gains, the 2 s → 3 s penalty, a short visit, passes on the inner and outer shoulder and with one wheel over.
- **Minimum speed:** the TOO SLOW drain, hesitation at 3 s (continuous only, once per stretch), and both grace periods.
- **Banking and losses:** cash-out vs checkpoint banking, no cash-out after a dip, hit and hesitation losses, run end losing the held chain, and bonuses (with night ×2).
- **Anti-exploit:** the empty-road weave, the per-car cut cooldown (including slot reuse with a new `vehicle_id`), and the ghost period (including a pass straddling its end).
- **Boost and sun:** boost fills and `take_boost_fill`, and sun nudges (5 in 10 s, 4, over 10.4 s, 10 in a row).
- **Engine checks:** the hull math, determinism, no allocations, and the step budget.
- **Soak** (`--tier=soak`): 10 minutes of real traffic. The invariants hold, the buffer never overflows, and scored passes match an independent count of center crossings within 5.4 m.
