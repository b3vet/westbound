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

## N8.2: the car's physics takes its inputs as multiples of 1 / QUANTUM (PlayerCar.tick
## quantizes what the controller wrote), so a replay records them exactly
## (NetReplayFile.Q_INPUT is the same scale) and the verifier re-simulates the car bit for
## bit. 1e-4 of full lock or pedal: far below what a player can feel.
const QUANTUM := 10000.0


func clear() -> void:
	steer = 0.0
	throttle = 0.0
	brake = 0.0
	boost = false


## Rounds steer, throttle and brake to multiples of 1 / QUANTUM, clamped to their ranges
## (the physics clamps them the same way). Idempotent. Allocation-free.
func quantize() -> void:
	steer = roundf(clampf(steer, -1.0, 1.0) * QUANTUM) / QUANTUM
	throttle = roundf(clampf(throttle, 0.0, 1.0) * QUANTUM) / QUANTUM
	brake = roundf(clampf(brake, 0.0, 1.0) * QUANTUM) / QUANTUM


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
