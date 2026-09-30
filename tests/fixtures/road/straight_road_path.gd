class_name StraightRoadPath
extends FixtureRoadPath
## Exact straight test road: reference line from `origin` along `heading0`
## (right-positive world yaw, 0 = -Z) with a constant `grade` (rise/run).
##   pos(s) = origin + s * (sin h0, grade, -cos h0), curvature 0.

var origin_x: float
var origin_y: float
var origin_z: float
var heading0: float
var grade: float


func _init(lanes: int = 3, road_tuning: RoadTuning = null, heading_rad: float = 0.0, grade_value: float = 0.0,
		origin: Vector3 = Vector3.ZERO) -> void:
	super(lanes, road_tuning)
	origin_x = origin.x
	origin_y = origin.y
	origin_z = origin.z
	heading0 = heading_rad
	grade = grade_value


func sample_into(s: float, out: RoadSample) -> void:
	out.s = s
	out.curvature = 0.0
	out.set_frame(heading0, grade)
	out.set_position(origin_x + s * sin(heading0), origin_y + s * grade, origin_z - s * cos(heading0))


func curvature_at(_s: float) -> float:
	return 0.0
