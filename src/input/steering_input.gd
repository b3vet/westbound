class_name SteeringInput
extends RefCounted
## Shared steering response math. Spec: Controls → Drag steering ("steer =
## sign(x) · curve(|x| / max_drag)", dead zone 4%, exponent 1.6) and Gyro steering
## ("steer = curve(clamp(angle / max_angle))", dead zone 2°, "same response curve
## exponent as drag"). Also used for the gamepad stick. docs/CONTROLS.md → Math.
##
## curve(u): u is the normalized input (drag offset / max_drag, tilt / max_angle).
##   |u| <= dead_zone          -> 0
##   dead_zone < |u| < 1       -> sign(u) · ((|u| - dead_zone) / (1 - dead_zone)) ^ exponent
##   |u| >= 1                  -> sign(u)
## The live range is rescaled after the dead zone, so the output is continuous at
## the edge (no jump to dead_zone^exponent) and still reaches exactly ±1.
##
## Static, pure, allocation-free.


static func curve(u: float, dead_zone: float, exponent: float) -> float:
	var m := absf(u)
	if m <= dead_zone:
		return 0.0
	if m >= 1.0:
		return signf(u)
	var t := (m - dead_zone) / (1.0 - dead_zone)
	return signf(u) * pow(t, exponent)


## Inverse of curve() on the live range: the normalized input that gives `steer`.
## For tests and the input preview (never on the input path).
static func inverse_curve(steer: float, dead_zone: float, exponent: float) -> float:
	var m := absf(steer)
	if m <= 0.0:
		return 0.0
	if m >= 1.0:
		return signf(steer)
	return signf(steer) * (dead_zone + (1.0 - dead_zone) * pow(m, 1.0 / exponent))

