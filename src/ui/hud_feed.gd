class_name HudFeed
extends RefCounted
## Per-frame HUD values: the run writes them, the HUD reads them (CONTRACTS §14,
## plan WP4.1 ↔ WP4.3). Spec: UI, HUD and design system → HUD elements.
##
## Holds the values that have no event (speed, sun bar, checkpoint distance) plus
## snapshots of the evented ones, so a HUD shown mid-run (or after a retry) draws
## the current state at once. Animations (event stack, bank count-up, life icon
## breaking) still come from the `Events` bus. The HUD updates a label only when
## its displayed value changes ("nothing animates when idle").
##
## The run fills this once per rendered frame (`_process`), never per tick. It is
## display data only: nothing in gameplay reads it back.

## Player speed (m/s, forward).
var speed_mps: float = 0.0
## Scoring minimum speed (m/s), for the TOO SLOW bar.
var min_speed_mps: float = 0.0
## The player car's top speed (m/s), for speed bars and needles.
var top_speed_mps: float = 1.0
## Below minimum speed (after the grace period): TOO SLOW is showing.
var too_slow: bool = false
## Boost meter 0..1 and whether boost is burning now.
var boost_fill: float = 0.0
var boosting: bool = false
## Sun bar: 1 = run start height, 0 = sunset (SunClock.sun_height()).
var sun_height: float = 1.0
var night: bool = false
var dawning: bool = false
## Metres to the next checkpoint; negative when none is planned.
var checkpoint_distance_m: float = -1.0
## Current leg (1-based) and its optional objective id (&"" = none).
var leg_index: int = 1
var objective: StringName = &""
var objective_done: bool = false
## Lives left, the cap, and whether the ghost period is running.
var lives: int = 2
var max_lives: int = 2
var ghost: bool = false
## Scores: banked total, personal best, unbanked chain, multiplier.
var banked: int = 0
var best: int = 0
var chain: int = 0
var multiplier: float = 1.0
## Total distance this run (m).
var distance_m: float = 0.0


func reset() -> void:
	speed_mps = 0.0
	too_slow = false
	boost_fill = 0.0
	boosting = false
	sun_height = 1.0
	night = false
	dawning = false
	checkpoint_distance_m = -1.0
	leg_index = 1
	objective = &""
	objective_done = false
	lives = max_lives
	ghost = false
	banked = 0
	chain = 0
	multiplier = 1.0
	distance_m = 0.0
