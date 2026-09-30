class_name ScoringTuning
extends Resource
## Scoring events, multiplier, minimum speed, shoulder penalty, chain and boost meter.
## Spec: Scoring (events table, anti-exploit rules, multiplier, chain, boost).
## Saved as data/tuning/scoring.tres.
## points = base x multiplier x speed factor x night factor.

@export_group("Speed factor (linear, clamped)")
@export var speed_factor_min_kmh: float = 100.0
@export var speed_factor_max_kmh: float = 250.0
@export var speed_factor_at_min: float = 1.0
@export var speed_factor_at_max: float = 2.0
@export var night_factor: float = 2.0

@export_group("Multiplier")
@export var multiplier_start: float = 1.0
@export var multiplier_decay_per_s: float = 0.5
## The decay is scaled by a speed term falling linearly between these speeds.
@export var decay_term_min_kmh: float = 100.0
@export var decay_term_max_kmh: float = 250.0
@export var decay_term_at_min: float = 1.0
@export var decay_term_at_max: float = 0.1
## Boost makes the multiplier decay more slowly.
@export var boost_decay_factor: float = 0.5   # not in spec: "decay more slowly" while boosting

@export_group("Minimum speed and hesitation")
@export var min_speed_kmh: float = 100.0
@export var below_min_drain_per_s: float = 3.0
@export var hesitation_timeout_s: float = 3.0
## The rule is inactive until the player first reaches min_speed_kmh in a run...
@export var min_speed_grace_until_reached: bool = true
## ...and for this long after a hit.
@export var min_speed_grace_after_hit_s: float = 3.0

@export_group("Pass")
@export var pass_points: int = 10
@export var pass_multiplier_gain: float = 1.0
## Centers within this lateral distance (your lane or the next one).
@export var pass_lateral_window_m: float = 5.4

@export_group("Close pass")
@export var close_pass_points: int = 30
@export var close_pass_multiplier_gain: float = 3.0
## Minimum hull-to-hull clearance during the overlap must be under this.
@export var close_pass_clearance_m: float = 1.0

@export_group("Cut")
@export var cut_points: int = 15
@export var cut_multiplier_gain: float = 1.0
@export var cut_min_speed_kmh: float = 140.0
## A traffic car within this distance ahead or behind in the lane left or entered.
@export var cut_traffic_window_m: float = 15.0
## Each traffic car contributes to at most one cut per this period.
@export var cut_per_car_cooldown_s: float = 3.0

@export_group("Thread")
@export var thread_points: int = 50
@export var thread_multiplier_gain: float = 5.0
@export var thread_window_s: float = 0.5
@export var thread_clearance_m: float = 1.5

@export_group("Slipstream")
@export var slipstream_distance_m: float = 15.0
@export var slipstream_min_speed_kmh: float = 120.0

@export_group("Shoulder")
@export var shoulder_decay_factor: float = 3.0
## After more than this long on the shoulder...
@export var shoulder_penalty_after_s: float = 2.0
## ...gains stay blocked this long after leaving it.
@export var shoulder_penalty_block_s: float = 3.0

@export_group("Boost meter")
## A full meter gives this much boost.
@export var boost_full_s: float = 3.0
@export var boost_fill_slipstream_pct_per_s: float = 20.0
@export var boost_fill_close_pass_pct: float = 10.0
@export var boost_fill_thread_pct: float = 25.0

@export_group("Plumbing")
@export var event_buffer_capacity: int = 32   # not in spec: ScoreEventBuffer size per tick batch


func min_speed_mps() -> float:
	return Units.kmh_to_mps(min_speed_kmh)


func cut_min_speed_mps() -> float:
	return Units.kmh_to_mps(cut_min_speed_kmh)


func slipstream_min_speed_mps() -> float:
	return Units.kmh_to_mps(slipstream_min_speed_kmh)


## Speed factor for a speed in m/s (1.0 at 100 km/h -> 2.0 at 250 km/h, clamped).
func speed_factor(speed_mps: float) -> float:
	var t := inverse_lerp(speed_factor_min_kmh, speed_factor_max_kmh, Units.mps_to_kmh(speed_mps))
	return lerpf(speed_factor_at_min, speed_factor_at_max, clampf(t, 0.0, 1.0))


## Multiplier decay speed term for a speed in m/s (1.0 at 100 km/h -> 0.1 at 250 km/h, clamped).
func decay_term(speed_mps: float) -> float:
	var t := inverse_lerp(decay_term_min_kmh, decay_term_max_kmh, Units.mps_to_kmh(speed_mps))
	return lerpf(decay_term_at_min, decay_term_at_max, clampf(t, 0.0, 1.0))
