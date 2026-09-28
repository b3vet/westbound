class_name DirectorTuning
extends Resource
## Traffic director: intensity waves, difficulty by leg, crest caps, set-piece rules.
## Spec: Traffic → Traffic director, fairness rules 4 and 6, Passability (batch length).
## Saved as data/tuning/director.tres. Per-set-piece numbers live in SetPieceDef data.

@export_group("Intensity waves")
@export var wave_period_min_s: float = 45.0
@export var wave_period_max_s: float = 90.0
@export var breather_min_s: float = 10.0
@export var breather_max_s: float = 15.0

@export_group("Difficulty by leg (ramps linearly first -> last leg, then holds)")
@export var ramp_first_leg: int = 1
@export var ramp_last_leg: int = 8
@export var density_first_per_km_lane: float = 8.0
@export var density_last_per_km_lane: float = 16.0
@export var aggressive_share_first_pct: float = 5.0
@export var aggressive_share_last_pct: float = 20.0
@export var hesitant_first_leg: int = 3

@export_group("Fairness")
## Within this distance after a blind crest or bend: density capped, no set pieces.
@export var blind_window_m: float = 150.0
@export var blind_density_cap_pct: float = 60.0
## Set pieces may exceed the 6 m/s^2 deceleration clamp only if announced this far ahead.
@export var set_piece_min_warning_m: float = 300.0

@export_group("Batches")
@export var spawn_batch_length_m: float = 300.0


## 0 at ramp_first_leg, 1 at ramp_last_leg and beyond. Legs are 1-based.
func leg_ramp(leg: int) -> float:
	return clampf(float(leg - ramp_first_leg) / float(ramp_last_leg - ramp_first_leg), 0.0, 1.0)


func density_per_km_lane(leg: int) -> float:
	return lerpf(density_first_per_km_lane, density_last_per_km_lane, leg_ramp(leg))


func aggressive_share_frac(leg: int) -> float:
	return Units.pct_to_frac(lerpf(aggressive_share_first_pct, aggressive_share_last_pct, leg_ramp(leg)))
