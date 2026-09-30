class_name FloatingOrigin
extends Node
## Floating origin. Spec: Architecture rule 6, World → Road ("floating origin every 2 km").
##
## The endless road outruns 32-bit float precision, so rendering happens relative to
## a 64-bit origin that jumps to the focus (player/camera) whenever the focus gets
## more than `shift_distance_m` away horizontally. The shift happens in one frame:
##   - `origin_x/y/z` update first, then `Events.origin_shifted(offset)` fires once;
##   - every world-space system either rebuilds from road space with `to_local()`,
##     or subtracts `offset` from its node positions in the handler;
##   - moved nodes must call `reset_physics_interpolation()` so physics
##     interpolation doesn't smear the jump across a frame.
## Road space (s, d) is unaffected; only rendering positions move.

## The last shift, in the old frame (new origin - old origin).
var last_offset := Vector3.ZERO
var origin_x: float = 0.0
var origin_y: float = 0.0
var origin_z: float = 0.0
var shift_distance_m: float = 0.0
## Shifts performed since setup (debug/tests).
var shift_count: int = 0


## `shift_km` comes from RoadTuning.floating_origin_shift_km.
func setup(shift_km: float) -> void:
	shift_distance_m = Units.km_to_m(shift_km)
	origin_x = 0.0
	origin_y = 0.0
	origin_z = 0.0
	shift_count = 0
	last_offset = Vector3.ZERO


## Call once per physics tick (or frame) with the focus' absolute 64-bit world
## position. Returns true when the origin shifted (and the signal fired).
func update_focus(x: float, y: float, z: float) -> bool:
	var dx := x - origin_x
	var dz := z - origin_z
	if dx * dx + dz * dz <= shift_distance_m * shift_distance_m:
		return false
	var dy := y - origin_y
	origin_x = x
	origin_y = y
	origin_z = z
	shift_count += 1
	last_offset = Vector3(dx, dy, dz)
	Events.origin_shifted.emit(last_offset)
	return true


## Absolute 64-bit world position -> render-space Vector3.
func to_local(x: float, y: float, z: float) -> Vector3:
	return Vector3(x - origin_x, y - origin_y, z - origin_z)
