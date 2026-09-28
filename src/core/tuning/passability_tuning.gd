class_name PassabilityTuning
extends Resource
## Passability guarantee. Spec: Traffic → Passability guarantee.
## Saved as data/tuning/passability.tres. Batch length is DirectorTuning.spawn_batch_length_m;
## player lane-change capability comes from VehicleTuning (the same curve as physics).

@export var sim_hz: int = 10
@export var horizon_s: float = 8.0
@export var step_s: float = 0.25
## Lateral grid: lane centers and half-lanes.
@export var lateral_step_lanes: float = 0.5
@export var clearance_m: float = 0.3
@export var max_rerolls: int = 5
