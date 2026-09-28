class_name PlayerController
extends VehicleController
## The player's controller: copies the input hub's signals into VehicleInput each
## physics tick. Spec: Controls ("Every layout outputs the same signals ... Physics
## and scoring cannot tell them apart"); Architecture rule 8 (controller abstraction).
## docs/CONTRACTS.md §4.
##
## Holds the hub as a plain reference; the hub has already advanced this tick (it
## runs at PlayerInput.PHYSICS_PRIORITY, before the car). Allocation-free.

var hub: PlayerInput


func _init(input_hub: PlayerInput) -> void:
	hub = input_hub


func update(_dt: float, _state: VehicleState, out_input: VehicleInput) -> void:
	out_input.steer = hub.steer
	out_input.throttle = hub.throttle
	out_input.brake = hub.brake
	out_input.boost = hub.consume_boost()
