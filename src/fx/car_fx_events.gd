class_name CarFxEvents
extends Node
## Publishes the player car's feel events that no sim emits yet: hard braking and
## barrier scrapes. Spec: Audio, haptics and game feel → Particles ("tire smoke on hard
## braking, and sparks on barrier scrapes (the scrape is still a hit)"); Architecture
## rule 8 (a thin adapter publishes; listeners only listen).
##
##   - Events.hard_braking_changed(active): when CarVisual.tire_smoke (braking input,
##     deceleration and speed over VehicleTuning.tire_smoke_*) changes, checked once
##     per frame. Off again on a new run or a crash.
##   - Events.barrier_scrape(world_pos): on Events.hit(HIT_BARRIER), at the barrier the
##     car touched (the median barrier face or the guardrail, whichever its centre is
##     nearer, the same faces HitDetection tests), at the car's s and
##     FeelTuning.sparks_height_m above the road, in render space.
## View-derived and read-only: it reads PlayerCar (state, visual, road, origin) and
## never writes gameplay state. RunEvents is the natural owner of both signals; move
## them there if it grows them (then this node goes away).

var car: PlayerCar
var feel: FeelTuning
## The last published hard-braking state.
var hard_braking: bool = false

var _smp := RoadSample.new()


func _init() -> void:
	name = "CarFxEvents"


func _enter_tree() -> void:
	if feel == null:
		feel = Tuning.load_default().feel
	_connect(Events.hit, _on_hit)
	_connect(Events.run_started, _on_run_started)
	_connect(Events.crash_started, _on_crash_started)


func _exit_tree() -> void:
	_disconnect(Events.hit, _on_hit)
	_disconnect(Events.run_started, _on_run_started)
	_disconnect(Events.crash_started, _on_crash_started)


func bind(player_car: PlayerCar) -> void:
	car = player_car
	_set_hard_braking(false)


func _process(_delta: float) -> void:
	poll()


## Publishes a hard-braking change (tests call it directly).
func poll() -> void:
	var on := car != null and is_instance_valid(car) and car.visual != null and car.visual.tire_smoke
	if on != hard_braking:
		_set_hard_braking(on)


## The render-space point on the barrier the car at (s, d) touches.
func barrier_point(s: float, d: float) -> Vector3:
	var road := car.road
	var median := road.median_barrier_d(s)
	var rail := road.guardrail_d(s)
	var bd := median if absf(d - median) < absf(rail - d) else rail
	road.sample_into(s, _smp)
	var ox := 0.0
	var oy := 0.0
	var oz := 0.0
	if car.origin != null:
		ox = car.origin.origin_x
		oy = car.origin.origin_y
		oz = car.origin.origin_z
	return _smp.local_point(bd, ox, oy, oz) + _smp.up * feel.sparks_height_m


func _set_hard_braking(on: bool) -> void:
	if on == hard_braking:
		return
	hard_braking = on
	Events.hard_braking_changed.emit(on)


func _on_hit(source: StringName, _lives_left: int) -> void:
	if source != Events.HIT_BARRIER or car == null or not is_instance_valid(car) or car.road == null:
		return
	Events.barrier_scrape.emit(barrier_point(car.state.s, car.state.d))


func _on_run_started(_mode: StringName, _seed: int) -> void:
	_set_hard_braking(false)
	set_process(true)


func _on_crash_started() -> void:
	_set_hard_braking(false)
	set_process(false)


static func _connect(sig: Signal, fn: Callable) -> void:
	if not sig.is_connected(fn):
		sig.connect(fn)


static func _disconnect(sig: Signal, fn: Callable) -> void:
	if sig.is_connected(fn):
		sig.disconnect(fn)
