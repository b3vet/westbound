class_name TimeScale
extends Node
## Slow-motion service. Spec: Audio, haptics and game feel → Slow motion (thread 0.6x
## for 0.25 s, first hit 0.5x for 0.3 s, crash 0.25x for 2.5 s); Lives, hits and
## crashes; Accessibility → Reduced motion ("turns off ... slow motion").
##
## Listens to Events.slowmo_requested(scale, duration_s, reason). Gameplay only asks;
## this node decides. With the reduced_motion setting on, requests are ignored.
##
## Keeping the 120 Hz simulation deterministic: Godot's Engine.time_scale alone keeps
## the physics tick rate and shrinks the delta, so a slowed tick would integrate a
## shorter dt. Here the physics tick RATE is scaled with it
## (physics_ticks_per_second = base x scale, rounded), so each tick still stands for
## the same simulated 1/120 s: the run always steps its sims with the fixed dt
## (VehicleTuning.physics_dt()), and slow motion only means fewer ticks per real
## second. Rendering, camera springs and particles see the scaled delta and slow down
## smoothly with physics interpolation.
##
## A request replaces a weaker (higher) scale that is running, never a stronger one,
## unless the stronger one has ended. Durations are real (unscaled) seconds.
## Leaving the tree restores 1.0x and the base tick rate.

const REASON_THREAD := &"thread"
const REASON_FIRST_HIT := &"first_hit"
const REASON_CRASH := &"crash"

## The physics tick rate at 1.0x (read from the engine when the node enters the tree).
var base_ticks_per_second: int = 0
## The current scale (1.0 when idle) and real seconds left.
var scale: float = 1.0
var remaining_s: float = 0.0
var reason: StringName = &""
## Requests honoured / ignored for reduced motion (tests, dev stats).
var applied_count: int = 0
var ignored_count: int = 0


func _enter_tree() -> void:
	if base_ticks_per_second <= 0:
		base_ticks_per_second = Engine.physics_ticks_per_second
	if not Events.slowmo_requested.is_connected(request):
		Events.slowmo_requested.connect(request)


func _exit_tree() -> void:
	if Events.slowmo_requested.is_connected(request):
		Events.slowmo_requested.disconnect(request)
	restore()


func _process(delta: float) -> void:
	if remaining_s <= 0.0:
		return
	# delta is scaled by Engine.time_scale; the duration counts real seconds.
	advance_real(delta / Engine.time_scale)


## Asks for `new_scale` (0 < scale < 1) for `duration_s` real seconds.
func request(new_scale: float, duration_s: float, why: StringName = &"") -> void:
	if new_scale <= 0.0 or new_scale >= 1.0 or duration_s <= 0.0:
		return
	if bool(Settings.get_value(&"reduced_motion")):
		ignored_count += 1
		return
	if remaining_s > 0.0 and new_scale > scale:
		return   # a weaker request never cuts a stronger slow motion short
	scale = new_scale
	remaining_s = duration_s
	reason = why
	applied_count += 1
	_apply(scale)


## Counts down `real_dt` seconds; restores 1.0x when the slow motion ends.
func advance_real(real_dt: float) -> void:
	if remaining_s <= 0.0:
		return
	remaining_s -= real_dt
	if remaining_s <= 0.0:
		restore()


## Back to 1.0x now (retry, scene exit).
func restore() -> void:
	scale = 1.0
	remaining_s = 0.0
	reason = &""
	_apply(1.0)


func is_slowed() -> bool:
	return remaining_s > 0.0


## Physics ticks per real second at `s` (at least one).
func ticks_for(s: float) -> int:
	return maxi(roundi(float(base_ticks_per_second) * s), 1)


func _apply(s: float) -> void:
	if base_ticks_per_second <= 0:
		base_ticks_per_second = Engine.physics_ticks_per_second
	var ticks := ticks_for(s)
	Engine.physics_ticks_per_second = ticks
	# The exact scale the rounded tick rate gives: every tick is one base tick of sim time.
	Engine.time_scale = float(ticks) / float(base_ticks_per_second)
