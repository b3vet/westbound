class_name SunTuning
extends Resource
## Sky timeline and sun clock. Spec: Core loop → Sky timeline and sun clock, Night.
## Saved as data/tuning/sun.tres. See docs/CONTRACTS.md "SunClock".
##
## sky_t is cyclic in [0, 1): morning -> afternoon -> golden hour -> sunset -> dusk
## -> night -> dawn -> (1.0 == 0.0) morning. The keyframe positions below are the
## single source for both the sun clock and data/color_script.tres.
## "Day span" = sky_t_sunset - sky_t_run_start (the span the spec's 5 minutes cover).

@export_group("Keyframe positions on sky_t")
@export var sky_t_morning: float = 0.0   # not in spec: keyframe spacing is a design choice
@export var sky_t_afternoon: float = 0.2   # not in spec
@export var sky_t_golden_hour: float = 0.38   # not in spec
@export var sky_t_sunset: float = 0.5   # not in spec
@export var sky_t_dusk: float = 0.58   # not in spec
@export var sky_t_night: float = 0.66   # not in spec
@export var sky_t_dawn: float = 0.85   # not in spec
## Runs start in the afternoon ("the run's starting afternoon").
@export var sky_t_run_start: float = 0.2   # not in spec: = sky_t_afternoon

@export_group("Sinking")
## From the run's starting afternoon to sunset at the base rate, if never lifted.
@export var sunset_from_start_min: float = 5.0
@export var too_slow_sink_factor: float = 3.0
## After sunset, sky_t runs on through dusk to the night keyframe and holds there.
@export var nightfall_s: float = 8.0   # not in spec: visual sunset -> night progression

@export_group("Lifts (fractions of the day span)")
@export var checkpoint_lift_pct: float = 40.0
## Extra lift for a fast leg (average speed above the pace target), up to this much.
@export var checkpoint_pace_lift_max_pct: float = 20.0
@export var thread_nudge_pct: float = 1.0
@export var close_pass_nudge_count: int = 5
@export var close_pass_nudge_window_s: float = 10.0
@export var close_pass_nudge_pct: float = 1.0

@export_group("Traffic headlights")
## Traffic headlights (and the director's night mix) are on while the color script's
## emissive_headlight ramp at the sun clock's sky_t is above this: lights come on in
## the golden hour and go off during the dawn, as the sky shows.
@export var traffic_headlights_on_ramp: float = 0.3   # not in spec: the M3 drive scene's threshold

@export_group("Dawn")
## Night -> dawn -> morning after a checkpoint at night, while play continues.
@export var dawn_transition_s: float = 6.0


func day_span() -> float:
	return sky_t_sunset - sky_t_run_start


## Base sky_t advance per second during the day.
func base_sink_per_s() -> float:
	return day_span() / Units.min_to_s(sunset_from_start_min)
