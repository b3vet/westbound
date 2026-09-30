class_name DailyScriptDriver
extends VehicleController
## The determinism check's open-loop driver (WP8.4; docs/DAILY.md → Determinism check):
## inputs that are a pure function of the tick count, never of the car's or the traffic's
## state, so two platforms feed the simulation exactly the same inputs (the spec's "same
## seed and same inputs give the same run"). A closed-loop bot (SandboxBot) also puts its
## own math (asin, IDM) between the state and the inputs; this one does not.
##
## Pattern (DailyTuning.check_script_*): full throttle; every period a lane change, as a
## steer pulse one way then the same pulse the other way, in the sequence right, right,
## left, left (so the car wanders across the lanes and back); every brake period a brake
## tap. Allocation-free.

var tuning: DailyTuning
var ticks: int = 0

var _period: int = 1
var _pulse: int = 1
var _brake_every: int = 1
var _brake_len: int = 1


func _init(daily_tuning: DailyTuning, tick_hz: int) -> void:
	tuning = daily_tuning
	var hz := float(tick_hz)
	_period = maxi(roundi(tuning.check_script_period_s * hz), 1)
	_pulse = maxi(roundi(tuning.check_script_pulse_s * hz), 1)
	_brake_every = maxi(roundi(tuning.check_script_brake_every_s * hz), 1)
	_brake_len = maxi(roundi(tuning.check_script_brake_s * hz), 1)


func update(_dt: float, _state: VehicleState, out_input: VehicleInput) -> void:
	ticks += 1
	var k := ticks % _period
	@warning_ignore("integer_division")
	var n := ticks / _period
	var dir := 1.0 if (n % 4) < 2 else -1.0
	var steer := 0.0
	if k < _pulse:
		steer = dir
	elif k < 2 * _pulse:
		steer = -dir
	out_input.steer = steer * tuning.check_script_steer
	var braking := (ticks % _brake_every) < _brake_len and ticks > _brake_every
	out_input.throttle = 0.0 if braking else tuning.check_script_throttle
	out_input.brake = tuning.check_script_brake if braking else 0.0
	out_input.boost = false
