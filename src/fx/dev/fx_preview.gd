extends Node3D
## Snap scene for the WP7.4 juice (src/fx): the full run (src/run/run.tscn) with the
## effects forced, for tools/snap.sh look reviews. Spec: Audio, haptics and game feel →
## Speed effects, Particles. Dev only.
##
## Every option goes to Run.snap_setup (--speed_kmh, --cam, --sky_t, --hud, ...), then:
##   --fx=lines   the car holds --speed_kmh (its speed is reset after every tick, a
##                dev hack so traffic ahead cannot slow it): speed lines above 180 km/h
##   --fx=smoke   the car brakes fully from here (real hard braking: CarVisual.tire_smoke)
##   --fx=sparks  the car is moved next to the guardrail (--side=median: the median
##                barrier) and a barrier hit is forced (Run.force_hit): the real path
##                Events.hit -> CarFxEvents -> Events.barrier_scrape -> sparks.
## Capture sparks soon after (--frames=3..12): they live 0.25-0.55 s.
## --juice_top  moves the run's JuiceFx under this scene's root, so tools/drawcalls.sh
##              reports its draws as their own top-level row.

const RUN_SCENE := preload("res://src/run/run.tscn")
## Clearance left between the car's flank and the barrier face when placed for sparks.
const SPARK_GAP_M := 0.2   # lint: allow-number dev placement, not tuning

## --fx=sparks: frames to wait before the hit (the world streams in around the snap).
const SETTLE_FRAMES := 45

var run: Run
## --fx=lines: the speed held (m/s; 0 = none).
var hold_mps: float = 0.0


class BrakeController:
	extends VehicleController

	func update(_dt: float, _state: VehicleState, out_input: VehicleInput) -> void:
		out_input.clear()
		out_input.brake = 1.0


func _ready() -> void:
	run = RUN_SCENE.instantiate() as Run
	add_child(run)


func _physics_process(_delta: float) -> void:
	if hold_mps > 0.0 and run.car != null:
		run.car.state.v = hold_mps


func snap_setup(args: Dictionary) -> void:
	run.snap_setup(args)
	if bool(args.get("juice_top", false)) and run.fx.juice.get_parent() != self:
		run.fx.juice.reparent(self)
	match str(args.get("fx", "lines")):
		"lines":
			hold_mps = run.car.state.v
		"smoke":
			run.car.controller = BrakeController.new()
		"sparks":
			# Let the road builder fill in around the snap point first.
			for i in int(args.get("settle_frames", SETTLE_FRAMES)):
				await get_tree().process_frame
			var car := run.car
			var s := car.state.s
			var half := car.car.width_m * 0.5 + SPARK_GAP_M
			var median := str(args.get("side", "rail")) == "median"
			var d := run.road.median_barrier_d(s) + half if median else run.road.guardrail_d(s) - half
			car.place_at(s, d, car.state.v)
			run.hits.reset(car.state, run.sim.state)
			run.rig.snap_to_target()
			run.force_hit(HitDetection.HIT_BARRIER, -1, 1 if median else -1)
