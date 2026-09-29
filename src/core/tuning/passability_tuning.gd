class_name PassabilityTuning
extends Resource
## Passability guarantee. Spec: Traffic → Passability guarantee.
## Saved as data/tuning/passability.tres. Batch length is DirectorTuning.spawn_batch_length_m;
## player lane-change capability comes from VehicleParams (the same curve as physics).
## The module is src/traffic/passability.gd; the algorithm and the director's use of
## it are in docs/PASSABILITY.md.

@export var sim_hz: int = 10
@export var horizon_s: float = 8.0
@export var step_s: float = 0.25
## Lateral grid: lane centers and half-lanes.
@export var lateral_step_lanes: float = 0.5
@export var clearance_m: float = 0.3
@export var max_rerolls: int = 5

@export_group("Director (WP6.1)")
## The director checks every batch before committing it (off: plan and commit as before).
@export var director_enabled: bool = true   # not in spec: a switch for tests and dev comparisons
## Slices of a batch check done per 120 Hz tick (Passability.advance): the check is
## spread over ticks so a re-roll storm never hitches a frame.
@export var director_slices_per_tick: int = 2   # not in spec: CPU spreading, see docs/PASSABILITY.md
## After the re-rolls, the director removes the worst blocker and checks again, at most
## this many times per batch; a batch still failing then is committed and counted.
@export var max_removals: int = 8   # not in spec: bound on the spec's "remove the vehicle that blocks the most paths"
## Batch (arrival) check: slow vehicles this far before the batch start are probed too
## (a wall across the boundary with the previous batch).
@export var arrival_probe_back_m: float = 50.0   # not in spec: see docs/PASSABILITY.md
## Batch (arrival) check: a probe goes behind every vehicle slower than the minimum
## speed by more than this (now or by desire): one a hair below it is no wall, and the
## player closing on it at the minimum speed has most of the horizon to go round.
@export var arrival_slow_margin_kmh: float = 5.0   # not in spec: see docs/PASSABILITY.md
## Batch (arrival) check: a probe's arrivals reach the slow vehicle at the minimum speed
## within this fraction of the horizon (the rest shows whether they get past it: an
## arrival reaching it only at the horizon's end would pass by just hanging back).
@export var arrival_reach_frac: float = 0.75   # not in spec: see docs/PASSABILITY.md
## Batch (arrival) check: probes (one behind each vehicle slower than the minimum
## speed) whose start windows differ by less than this are merged (a wall side by side).
@export var arrival_probe_merge_m: float = 10.0   # not in spec: bounds the probes per batch

@export_group("Forward simulation (WP6.1)")
## Vehicles up to this far beyond the player's reachable corridor are still simulated,
## so the ones inside it keep their leaders.
@export var leader_margin_m: float = 40.0   # not in spec: prediction context around the corridor
