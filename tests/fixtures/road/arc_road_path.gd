class_name ArcRoadPath
extends FixtureRoadPath
## Exact constant-curvature test road (flat). `bend` = +1 bends right, -1 bends left.
##   curvature k = bend / radius;  heading(s) = h0 + k s
##   x(s) = x0 + (cos h0 - cos(h0 + k s)) / k
##   z(s) = z0 - (sin(h0 + k s) - sin h0) / k
## The circle's center is origin + right(h0) / k; every point is `radius` from it.

var radius_m: float
var curvature: float
var origin_x: float
var origin_y: float
var origin_z: float
var heading0: float


func _init(radius: float = 1200.0, bend: int = 1, lanes: int = 3, road_tuning: RoadTuning = null,
		heading_rad: float = 0.0, origin: Vector3 = Vector3.ZERO) -> void:
	super(lanes, road_tuning)
	assert(radius > 0.0 and (bend == 1 or bend == -1))
	radius_m = radius
	curvature = float(bend) / radius
	origin_x = origin.x
	origin_y = origin.y
	origin_z = origin.z
	heading0 = heading_rad


func sample_into(s: float, out: RoadSample) -> void:
	var h := heading0 + curvature * s
	out.s = s
	out.curvature = curvature
	out.set_frame(h, 0.0)
	out.set_position(
		origin_x + (cos(heading0) - cos(h)) / curvature,
		origin_y,
		origin_z - (sin(h) - sin(heading0)) / curvature)


func curvature_at(_s: float) -> float:
	return curvature


func center_x() -> float:
	return origin_x + cos(heading0) / curvature


func center_z() -> float:
	return origin_z + sin(heading0) / curvature
