class_name DailyTuning
extends Resource
## Daily Drive's ghost and its cross-platform determinism check. Spec: Core loop → Modes
## at launch ("Daily Drive: ... Your best daily run is recorded and shown as a translucent
## ghost car on later attempts (the car's s, d and heading sampled at 20 Hz)"), Save data
## ("Daily Drive ghosts"), Implementation milestones → M8 ("Daily Drive gives identical
## runs on two devices for the same date"). WP8.4; docs/DAILY.md. Saved as
## data/tuning/daily.tres.
##
## Until the orchestrator adds `Tuning.daily`, resolve() loads it from PATH.

const PATH := "res://data/tuning/daily.tres"

@export_group("Ghost")
## Show the best run of the day as a ghost on later attempts. The spec has no setting for
## it (UI → Settings lists none), so it is a tuning flag, on.
@export var ghost_enabled: bool = true
## Ghost samples per second (spec: 20 Hz). The physics tick rate must be a multiple.
@export var ghost_sample_hz: int = 20
## Ghost files kept: today's UTC date and the days before it (2 = today and yesterday: a
## retry keeps the seed it started with, so a session that crosses UTC midnight still
## plays yesterday's route). Older ones are deleted.
@export var ghost_keep_days: int = 2   # not in spec
## The recorder's columns are sized for this much driving up front (they double after).
@export var ghost_reserve_s: float = 900.0   # not in spec
## The ghost is drawn only this far ahead of / behind the player (m); beyond, the fog
## hides it anyway and the road there may not be generated yet, or already forgotten.
@export var ghost_view_ahead_m: float = 900.0   # not in spec
@export var ghost_view_behind_m: float = 150.0   # not in spec

@export_group("Determinism check")
## The scripted Daily run of the check (tools/determinism, `?determinism=daily`), this many
## seconds, driven by `check_driver`: &"script" (DailyScriptDriver: open-loop inputs, a
## function of the tick only: the "same inputs" of the determinism contract) or &"bot"
## (the weaving SandboxBot with this seed and target speed: closed-loop, like a player).
@export var check_driver: StringName = &"script"
@export var check_bot_seed: int = 11
@export var check_bot_speed_kmh: float = 190.0
@export var check_seconds: float = 60.0
## DailyScriptDriver: a lane change (a steer pulse each way) every period, a brake tap every
## brake period, full throttle otherwise.
@export var check_script_period_s: float = 4.0
@export var check_script_pulse_s: float = 0.35
@export var check_script_steer: float = 0.25
@export var check_script_throttle: float = 1.0
@export var check_script_brake_every_s: float = 11.0
@export var check_script_brake_s: float = 0.5
@export var check_script_brake: float = 0.6
## One Run.frame() (event drain, views) every this many ticks, as a 60 fps game does.
@export var check_ticks_per_frame: int = 2
## The web page runs this many ticks per engine frame (keeps the tab responsive).
@export var check_web_ticks_per_step: int = 120


## Physics ticks per ghost sample (6 at 120 Hz).
func ghost_sample_ticks(tick_hz: int) -> int:
	@warning_ignore("integer_division")
	return maxi(tick_hz / maxi(ghost_sample_hz, 1), 1)


func check_bot_speed_mps() -> float:
	return Units.kmh_to_mps(check_bot_speed_kmh)


static func resolve() -> DailyTuning:
	var t := Tuning.load_default()
	var v: Variant = t.get(&"daily") if &"daily" in t else null
	if v is DailyTuning:
		return v as DailyTuning
	var loaded := load(PATH) as DailyTuning
	return loaded if loaded != null else DailyTuning.new()
