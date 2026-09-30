class_name RoadSample
extends RefCounted
## The road reference line at one `s`. Filled by RoadPath.sample_into() (allocation-free).
## Spec: Architecture rule 5 (road space first). See docs/CONTRACTS.md "Road space".
##
## Conventions (sim code is right-positive throughout):
##  - Positions are absolute world coordinates (Y up, meters), before the floating-
##    origin offset. pos_x/pos_y/pos_z are 64-bit and authoritative; `pos` is the same
##    point as a 32-bit Vector3 for convenience near the start of a run only.
##    Render adapters subtract the origin in 64-bit: see local_point().
##  - heading: world yaw of the tangent in radians, RIGHT-positive (clockwise seen
##    from above); 0 faces -Z, +PI/2 faces +X. Godot's rotation.y = -heading.
##  - curvature: d(heading)/ds in 1/m, positive when the road bends right.
##  - s is plan-view (horizontal) arc length; grade = d(elevation)/ds (rise/run).
##  - tangent: 3D unit tangent (includes grade). right: horizontal unit vector to the
##    right of travel (no banking). up: road surface normal = right x tangent.

var s: float = 0.0
var pos_x: float = 0.0
var pos_y: float = 0.0
var pos_z: float = 0.0
var pos: Vector3 = Vector3.ZERO
var tangent: Vector3 = Vector3.FORWARD
var right: Vector3 = Vector3.RIGHT
var up: Vector3 = Vector3.UP
var heading: float = 0.0
var curvature: float = 0.0
var elevation: float = 0.0
var grade: float = 0.0


## World point at lateral offset d (flat cross-section: pos + right * d). 32-bit.
func world_point(d: float) -> Vector3:
	return Vector3(pos_x + right.x * d, pos_y + right.y * d, pos_z + right.z * d)


## Point at lateral offset d relative to a floating-origin offset, computed in 64-bit
## before narrowing to Vector3. Use this for rendering.
func local_point(d: float, origin_x: float, origin_y: float, origin_z: float) -> Vector3:
	return Vector3(
		(pos_x - origin_x) + right.x * d,
		(pos_y - origin_y) + right.y * d,
		(pos_z - origin_z) + right.z * d)


## Godot rotation.y for something aligned with the road plus a right-positive relative yaw.
func godot_yaw(relative_yaw: float = 0.0) -> float:
	return -(heading + relative_yaw)


## Sets the horizontal frame from a heading and a grade (flat cross-section).
## Helper for RoadPath implementations; allocation-free.
func set_frame(heading_rad: float, grade_value: float) -> void:
	heading = heading_rad
	grade = grade_value
	var sh := sin(heading_rad)
	var ch := cos(heading_rad)
	var n := sqrt(1.0 + grade_value * grade_value)
	tangent = Vector3(sh / n, grade_value / n, -ch / n)
	right = Vector3(ch, 0.0, sh)
	up = right.cross(tangent)


## Sets pos_x/pos_y/pos_z, pos and elevation together.
func set_position(x: float, y: float, z: float) -> void:
	pos_x = x
	pos_y = y
	pos_z = z
	pos = Vector3(x, y, z)
	elevation = y


func copy_from(o: RoadSample) -> void:
	s = o.s
	pos_x = o.pos_x
	pos_y = o.pos_y
	pos_z = o.pos_z
	pos = o.pos
	tangent = o.tangent
	right = o.right
	up = o.up
	heading = o.heading
	curvature = o.curvature
	elevation = o.elevation
	grade = o.grade
