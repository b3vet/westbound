class_name VehicleInput
extends RefCounted
## The control signals every layout produces. Spec: Controls ("steering -1 to 1,
## throttle 0 to 1, brake 0 to 1, and a boost trigger. Physics and scoring cannot
## tell them apart"). Written by a VehicleController, read by vehicle_physics.

var steer: float = 0.0     ## -1..1, + = right
var throttle: float = 0.0  ## 0..1
var brake: float = 0.0     ## 0..1
## Edge-triggered request: true for the single tick on which boost was asked for.
## Physics starts a boost only if the meter allows; controllers clear it next tick.
var boost: bool = false


func clear() -> void:
	steer = 0.0
	throttle = 0.0
	brake = 0.0
	boost = false


func copy_from(o: VehicleInput) -> void:
	steer = o.steer
	throttle = o.throttle
	brake = o.brake
	boost = o.boost


func hash_into(h: int) -> int:
	h = TraceHash.mix_float(h, steer)
	h = TraceHash.mix_float(h, throttle)
	h = TraceHash.mix_float(h, brake)
	return TraceHash.mix_bool(h, boost)
