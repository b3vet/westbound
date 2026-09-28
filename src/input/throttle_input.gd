class_name ThrottleInput
extends RefCounted
## Throttle and brake from every source. Spec: Controls (auto-accelerate vs manual
## gas and brake; "Manual throttle"). docs/CONTROLS.md → Throttle.
##
## - Auto: throttle = 1 unless braking.
## - Manual: throttle = the gas amount (pedal held = 1, released = 0: the car coasts
##   under the physics' engine braking; a gamepad trigger is analog).
## - Both: brake = the strongest brake source (0..1), and any brake > 0 cuts the
##   throttle to 0. So "brake 0.5" means the same to physics in every layout.
##
## Pure and allocation-free.

const AUTO := &"auto"
const MANUAL := &"manual"

var mode: StringName = AUTO
var throttle: float = 0.0
var brake: float = 0.0


func update(gas: float, brake_amount: float) -> void:
	brake = clampf(brake_amount, 0.0, 1.0)
	if brake > 0.0:
		throttle = 0.0
	elif mode == MANUAL:
		throttle = clampf(gas, 0.0, 1.0)
	else:
		throttle = 1.0


## Brake pedal: `up_frac` = how far up the pedal the thumb sits (0 = bottom edge,
## 1 = top); the bottom edge still brakes `min_frac`.
static func pedal_brake(up_frac: float, min_frac: float) -> float:
	var f := clampf(up_frac, 0.0, 1.0)
	return clampf(min_frac + (1.0 - min_frac) * f, 0.0, 1.0)
