@warning_ignore_start("unused_signal")
extends Node
## Global event bus (autoload `Events`). Spec: Architecture rule 4.
##
## Gameplay systems emit; HUD, audio, haptics, camera and particles only listen
## and never drive gameplay from these signals.
##
## The catalog is declared up front so parallel work packages never need to edit
## this file. It is orchestrator-owned: request additions in your WP handoff note.
## Signals fire at event rate (never per tick), so Dictionary payloads are allowed
## where noted.

# --- Score event kinds (the `kind` argument of `scored`) ---
const PASS := &"pass"
const CLOSE_PASS := &"close_pass"
const CUT := &"cut"
const THREAD := &"thread"

# --- Chain-loss and bank reasons ---
const REASON_CHECKPOINT := &"checkpoint"
const REASON_CASH_OUT := &"cash_out"
const REASON_HIT := &"hit"
const REASON_HESITATED := &"hesitated"
const REASON_RUN_END := &"run_end"

# --- Hit sources ---
const HIT_TRAFFIC := &"traffic"
const HIT_BARRIER := &"barrier"
const HIT_PROP := &"prop"

# ---------------------------------------------------------------- Game flow
signal game_state_changed(from_state: StringName, to_state: StringName)
signal paused_changed(paused: bool)
## mode: &"journey" or &"daily". seed: the run seed all RNG streams derive from.
signal run_started(mode: StringName, seed: int)
signal countdown_tick(remaining: int)
## Final results payload (see run.gd for keys). Fired once when the run is over.
signal run_over(results: Dictionary)

# ---------------------------------------------------------------- Scoring
## Every scoring event. points already include all factors.
## clearance_m: hull-to-hull clearance for passes and threads, else -1.
signal scored(kind: StringName, points: int, multiplier: float, clearance_m: float)
signal multiplier_changed(value: float)
signal chain_changed(value: int)
signal chain_banked(amount: int, reason: StringName, banked_total: int)
signal chain_lost(amount: int, reason: StringName)
signal hesitated()
signal too_slow_changed(active: bool)
signal shoulder_penalty_changed(active: bool)
signal slipstream_changed(active: bool)
## Leg bonuses, objectives and the journey bonus. Paid straight into the banked total.
signal bonus_awarded(kind: StringName, points: int, banked_total: int)

# ---------------------------------------------------------------- Boost
signal boost_meter_changed(fill: float)
signal boost_started()
signal boost_ended()

# ---------------------------------------------------------------- Lives, hits, crash
signal hit(source: StringName, lives_left: int)
signal ghost_started(duration_s: float)
signal ghost_ended()
signal life_restored(lives: int)
signal barrier_scrape(world_pos: Vector3)
signal crash_started()
signal crash_finished()

# ---------------------------------------------------------------- Sun and sky
signal night_started()
signal dawn_started(duration_s: float)
signal morning_reached()
signal sun_lifted(fraction_of_day: float)

# ---------------------------------------------------------------- Legs and journey
signal leg_started(leg_index: int, biome: StringName, objective: StringName)
signal checkpoint_warning(distance_m: float)
## summary keys: leg_index, clean, pace, threads, heat, objective_done, bonus_points, at_night
signal checkpoint_crossed(leg_index: int, summary: Dictionary)
signal objective_completed(objective: StringName, points: int)
signal fork_announced(left_biome: StringName, right_biome: StringName)
signal fork_taken(biome: StringName)
signal coast_reached()
signal journey_complete()

# ---------------------------------------------------------------- Traffic
signal set_piece_warning(kind: StringName, distance_m: float)
signal set_piece_started(kind: StringName)
signal set_piece_ended(kind: StringName)
## Traffic reactions to the player (vehicle_id is the traffic sim slot index).
signal traffic_horn(vehicle_id: int, world_pos: Vector3)
signal traffic_brake_tap(vehicle_id: int)
signal traffic_hazards(vehicle_id: int, on: bool)

# ---------------------------------------------------------------- Player vehicle
signal gear_shifted(gear: int)
signal hard_braking_changed(active: bool)
## The player's manual high beams (D8): view only, never affects scoring or traffic.
signal high_beam_changed(on: bool)

# ---------------------------------------------------------------- World
## The floating origin re-centred the world. Every world-space system subtracts `offset`.
signal origin_shifted(offset: Vector3)
signal biome_changed(biome: StringName)

# ---------------------------------------------------------------- Feel requests
## Gameplay asks for slow motion; the time-scale service honours reduced motion.
signal slowmo_requested(scale: float, duration_s: float, reason: StringName)
signal camera_shake_requested(strength: float, duration_s: float)

# ---------------------------------------------------------------- Settings and platform
signal settings_changed(key: StringName)
signal camera_mode_changed(mode: StringName)
signal quality_changed(tier: StringName)
## rung 0 = nominal; 1..4 = the governor's step-down rungs.
signal governor_changed(rung: int)
signal thermal_state_changed(state: StringName)
