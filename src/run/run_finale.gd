class_name RunFinale
extends RefCounted
## The journey finale (WP6.5). Spec: The journey goal ("The coast is the destination,
## reached after 8 legs. Arriving plays a finale: the road opens onto the ocean, the
## camera swings wide, and the sun meets the sea ... A journey bonus is paid and
## 'Journey complete' is recorded. The road continues as an endless coastal highway"),
## Cameras → Scripted cameras ("Journey finale: a 3-second wide swing onto the ocean at
## the coast. It runs during a traffic-free breather while the car holds its lane. No
## scripted camera ever takes control while traffic can still hit the player"),
## Accessibility (reduced motion). docs/FORKS.md → Coast finale.
##
##   finale.reset(run)             # every run start
##   finale.arm(coast_line_s)      # the crossing that reached the coast
##   finale.tick(dt, player)       # every RUNNING tick, after traffic
##
## Arming (the journey bonus is paid at that crossing by the run) asks the traffic
## director for a breather around the finale point, LegsTuning.finale_after_m past the
## coast's line (the ocean has opened by then). From that point, as soon as no car on the
## player's carriageway is within finale_breather_before_m behind or _after_m ahead, the
## camera swings (CameraRig.start_finale, to the land side: it looks back at the car
## against the sea and the sun) and the car holds its lane and speed (FinaleController,
## input ignored) for CameraTuning.finale_swing_s; then control returns and the endless
## coastal highway goes on. Cars behind the view (camera-independent, like spawns) are
## removed from the breather so none can come up from behind. The journey completes
## (KIND_JOURNEY_COMPLETE, once) when the swing starts, or at the point itself with
## reduced motion (no swing), or after finale_give_up_m if traffic never cleared.

const KIND_JOURNEY_COMPLETE := &"journey_complete"

enum Phase { IDLE, ARMED, WAITING, SWING, DONE }

var phase: Phase = Phase.IDLE
## Where the finale plays (INF until armed).
var finale_s: float = INF
## The camera swung (false: skipped for reduced motion or traffic).
var swung: bool = false
## journey_complete was pushed.
var completed: bool = false
var swing_time_s: float = 0.0
## The car's lane-and-speed hold during the swing.
var controller := FinaleController.new()

var _run: Run
var _t: Tuning
var _saved: VehicleController
var _breather: bool = false


func reset(run: Run) -> void:
	_run = run
	_t = run.tuning
	phase = Phase.IDLE
	finale_s = INF
	swung = false
	completed = false
	swing_time_s = 0.0
	_saved = null
	_breather = false
	controller.legs = _t.legs
	if run.rig != null:
		run.rig.stop_finale()


func is_swinging() -> bool:
	return phase == Phase.SWING


## The crossing at `coast_line_s` reached the coast: the finale is next.
func arm(coast_line_s: float) -> void:
	if phase != Phase.IDLE:
		return
	var legs := _t.legs
	finale_s = coast_line_s + legs.finale_after_m
	phase = Phase.ARMED
	_run.director.request_breather(finale_s - legs.finale_breather_lead_m,
		finale_s + legs.finale_give_up_m + legs.finale_breather_after_m)
	_breather = true


func tick(dt: float, player: VehicleState) -> void:
	match phase:
		Phase.ARMED:
			if player.s >= finale_s:
				phase = Phase.WAITING
			else:
				return
		Phase.SWING:
			_guard(player)
			swing_time_s += dt
			if swing_time_s >= _t.camera.finale_swing_s:
				_end_swing()
			return
		_:
			pass
	if phase != Phase.WAITING:
		return
	_guard(player)
	if _run.rig.is_reduced_motion():
		_finish()   # no swing with reduced motion: the journey completes at the point
		return
	if _clear(player):
		if _run.rig.start_finale(-float(_sea_side())):
			swung = true
			swing_time_s = 0.0
			controller.begin(_run.road, player)
			_saved = _run.drive_controller
			_run.car.controller = controller
			phase = Phase.SWING
			_complete()
			return
		_finish()
	elif player.s > finale_s + _t.legs.finale_give_up_m:
		_finish()


## True when no car on the player's carriageway can reach the player during the swing.
func _clear(player: VehicleState) -> bool:
	var ts := _run.sim.state
	var lo := player.s - _t.legs.finale_breather_before_m
	var hi := player.s + _t.legs.finale_breather_after_m
	for i in ts.capacity:
		if ts.active[i] != 0 and ts.s[i] >= lo and ts.s[i] <= hi:
			return false
	return true


## Cars out of view behind the player inside the breather are removed (the spawn rules'
## camera-independent view volume). Allocation-free.
func _guard(player: VehicleState) -> void:
	var ts := _run.sim.state
	var back := player.s - _t.director.behind_spawn_view_margin_m
	for i in ts.capacity:
		if ts.active[i] != 0 and ts.s[i] < back:
			_run.sim.despawn(i)


func _end_swing() -> void:
	_run.rig.stop_finale()
	if _run.car.controller == controller:
		_run.car.controller = _saved if _saved != null else _run.drive_controller
	_saved = null
	_finish()


func _finish() -> void:
	_complete()
	phase = Phase.DONE
	if _breather:
		_run.director.clear_breathers()
		_breather = false


func _complete() -> void:
	if completed:
		return
	completed = true
	_run.events.push(KIND_JOURNEY_COMPLETE)
	_run.on_journey_complete()


## The side of the road the coast's sea is on (+1 right).
func _sea_side() -> int:
	var b := _run.biome_director.biome_at(_run.car.state.s)
	if b != null and b.water != null:
		return b.water.side
	return 1


## Holds the lane the car is in and the speed it had (the finale swing; input ignored).
## Reads the state only (VehicleController contract).
class FinaleController:
	extends VehicleController

	var legs: LegsTuning
	var road: RoadPath
	var lane: int = 0
	var v_hold: float = 0.0

	func begin(road_path: RoadPath, state: VehicleState) -> void:
		road = road_path
		lane = maxi(road.lane_index_at(state.d, state.s), 0)
		v_hold = state.v

	func update(_dt: float, state: VehicleState, out_input: VehicleInput) -> void:
		var lanes := road.lane_count(state.s)
		var d_t := road.lane_center_d(clampi(lane, 0, lanes - 1), state.s)
		var v := maxf(state.v, 1.0)
		var vlat := legs.finale_hold_lateral_gain * (d_t - state.d)
		var yaw_goal := asin(clampf(vlat / v, -1.0, 1.0))
		out_input.steer = clampf(legs.finale_hold_steer_gain * (yaw_goal - state.yaw)
			- legs.finale_hold_rate_gain * state.yaw_rate, -1.0, 1.0)
		var dv := v_hold - state.v
		out_input.throttle = clampf(dv / maxf(legs.finale_hold_speed_time_s, 1e-3), 0.0, 1.0)   # lint: allow-number divide guard
		out_input.brake = clampf(-dv / maxf(legs.finale_hold_speed_time_s, 1e-3), 0.0, 1.0)   # lint: allow-number divide guard
		out_input.boost = false
