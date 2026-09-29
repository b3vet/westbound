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
## Plan D11 (owner, M3): the spec's 16 at leg 8 raised; see density_window_*.
@export var density_last_per_km_lane: float = 18.0
@export var aggressive_share_first_pct: float = 5.0
@export var aggressive_share_last_pct: float = 20.0
@export var hesitant_first_leg: int = 3

@export_group("Fairness")
## Within this distance after a blind crest or bend: density capped, no set pieces.
@export var blind_window_m: float = 150.0
@export var blind_density_cap_pct: float = 60.0
## Set pieces may exceed the 6 m/s^2 deceleration clamp only if announced this far ahead.
@export var set_piece_min_warning_m: float = 300.0

@export_group("Density around the player (plan D11; not in spec)")
## The window the director's effective density is measured over (dev report, the
## density survey): [player s - behind, player s + ahead].
@export var density_window_behind_m: float = 150.0   # not in spec
@export var density_window_ahead_m: float = 600.0   # not in spec
## The effective density is measured this often; its relative shortfall is integrated
## into the planning gain at this rate (per second per unit of relative error).
@export var density_control_interval_s: float = 0.25   # not in spec
@export var density_gain_rate_per_s: float = 0.05   # not in spec: slow (spawns reach the window 10-40 s later)
## Planning gain range (1 = the target density exactly).
@export var density_gain_min: float = 0.7   # not in spec
@export var density_gain_max: float = 1.5   # not in spec
## After each batch, lanes the player is catching (their flow speed + this below the
## player's speed) are topped up to target x gain in the band beyond the fog.
@export var density_topup_speed_margin_kmh: float = 10.0   # not in spec
## At most this many top-up spawns per batch (keeps the director-rate cost bounded).
@export var density_topup_max_per_batch: int = 16   # not in spec

@export_group("Closer following in late legs (plan D11; not in spec)")
## Every driver profile's IDM time headway T is scaled by this, ramped like the density
## (first -> last leg). IDM's equilibrium gaps, not the director, cap how dense a lane
## can stay at its flow speed (~13-14 vehicles per km per lane with the profiles' own
## T around a fast player); denser late legs need closer following.
@export var headway_scale_first: float = 1.0   # not in spec
@export var headway_scale_last: float = 0.8   # not in spec

@export_group("Behind spawns: the view test (orchestrator, D11; not in spec)")
## Fairness rule 5 ("behind the camera frustum") as a fixed virtual view volume, not the
## live camera: a road point more than this far behind the player is out of view, any
## other is in view. Every camera mode sits <= 11 m behind the car and looks forward,
## so a behind spawn (spawn_behind_m, ~150 m) is never visible, and camera mode and
## screen aspect never change traffic (leaderboards, Daily Drive on every device).
@export var behind_spawn_view_margin_m: float = 25.0   # not in spec

@export_group("Batches")
@export var spawn_batch_length_m: float = 300.0


## 0 at ramp_first_leg, 1 at ramp_last_leg and beyond. Legs are 1-based.
func leg_ramp(leg: int) -> float:
	return clampf(float(leg - ramp_first_leg) / float(ramp_last_leg - ramp_first_leg), 0.0, 1.0)


func density_per_km_lane(leg: int) -> float:
	return lerpf(density_first_per_km_lane, density_last_per_km_lane, leg_ramp(leg))


func headway_scale(leg: int) -> float:
	return lerpf(headway_scale_first, headway_scale_last, leg_ramp(leg))


func aggressive_share_frac(leg: int) -> float:
	return Units.pct_to_frac(lerpf(aggressive_share_first_pct, aggressive_share_last_pct, leg_ramp(leg)))
