class_name VehicleController
extends RefCounted
## Drives a vehicle by producing VehicleInput each physics tick. Base contract.
## Spec: Architecture rule 8 (controller abstraction); Hooks to build in v1
## ("a traffic vehicle can switch controller at runtime without respawning").
##
## Subclasses: PlayerController (WP2.1/2.2: reads the steering/throttle input
## sources), AIController (a driver following a DriverProfile), later HopController
## (Car Hopper). The owner of a vehicle holds `controller` as a plain reference and
## may swap it between ticks; the VehicleState is untouched by the swap, so the
## vehicle keeps its position, speed and heading (no respawn). A new controller gets
## on_attached() with the current state before its first update().
##
## update() runs at the physics tick and must not allocate. Controllers never write
## VehicleState: they only read it (for AI decisions) and fill out_input.


## Called once when this controller takes over a vehicle (also at spawn).
func on_attached(_state: VehicleState) -> void:
	pass


## Called when another controller replaces this one.
func on_detached() -> void:
	pass


## Fills out_input for this tick. out_input may hold last tick's values; overwrite
## every field (or call out_input.clear() first).
func update(_dt: float, _state: VehicleState, _out_input: VehicleInput) -> void:
	push_error("VehicleController.update not implemented")
