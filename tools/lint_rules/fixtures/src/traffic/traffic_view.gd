extends Node3D
# lint: not-sim rendering adapter; it reads TrafficSim state and never feeds it back
## A Node adapter living next to the sims: opted out, so Node access, autoloads
## and numbers are fine here.

const FADE_SECONDS := 0.35


func _process(_delta: float) -> void:
	var car := $Cars
	car.position.y = 1.25
	Events.emit_signal("pass")
