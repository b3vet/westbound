class_name GroundDropMesher
extends RoadChunkMesher
## RoadChunkMesher with the ground ribbon lowered where a biome feature needs the land
## below the road: under elevated stretches (city: verge and field, both sides) and
## beyond the scenery line on a cliff coast's sea side (field only). Spec: World →
## Biomes (city: elevated highway sections; coast: ocean on one side, cliffs), Road
## (ribbon chunks).
##
## RoadBuilder makes its mesher one of these when given the hook (WP6.4c):
##
##   builder.set_ground_drop(elevated.ground_drop_at, water.ground_drop_at)
##   # -> mesher.drop_at = (s) -> m, verge + field, both sides
##   #    mesher.field_drop_at = (s, side) -> m, field on that side
##
## Everything except the ground quads is the base mesher's output, unchanged; the quad
## count per row interval is the same, so the array sizing holds. The hooks are asked
## once per row and side (an interval's end row is the next one's start: cached), which
## keeps a coast chunk's build within ~1.5x a plain one.

## (s: float) -> float: the ground's drop below the road at s, both sides (verge + field).
var drop_at: Callable
## (s: float, side: float) -> float: the field's drop on side -1 / +1 (the verge stays).
var field_drop_at: Callable

var _s_a: float = 0.0
var _s_b: float = 0.0
var _drop_a: float = 0.0
var _drop_b: float = 0.0
## Field drops (both-side drop included) at row a and b, right (+1) then left (-1).
var _fdrop_a := PackedFloat64Array([0.0, 0.0])
var _fdrop_b := PackedFloat64Array([0.0, 0.0])
## The row s the b values belong to (reused as the next interval's a).
var _cached_s: float = NAN
var _pa := Vector3.ZERO
var _ra := Vector3.RIGHT
## The interval's ground colours as the base mesher emits them (row blend, tunnel shade).
var _verge_a: Color
var _field_a: Color


func begin(road: RoadPath, s0: float, s1: float) -> void:
	_cached_s = NAN   # a plan may have changed since the last build
	super(road, s0, s1)


func _emit_world_interval(i: int) -> void:
	_s_a = _row_s[i]
	_s_b = _row_s[i + 1]
	_pa = _row_p[i]
	_ra = _row_right[i]
	if _s_a == _cached_s:
		_drop_a = _drop_b
		_fdrop_a[0] = _fdrop_b[0]
		_fdrop_a[1] = _fdrop_b[1]
	else:
		_drop_a = _row_drops(_s_a, _fdrop_a)
	_drop_b = _row_drops(_s_b, _fdrop_b)
	_cached_s = _s_b
	var shade := _interval_shade(i)
	_verge_a = _shaded(_row_verge[i], shade)
	_field_a = _shaded(_row_field[i], shade)
	super(i)


## Ground quads are the verge and field quads of _emit_world_interval: (row a, row a,
## row b, row b) with the rows' blended ground colours.
func _world_quad_c(v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3, hint: Vector3,
		c0: Color, c1: Color, c2: Color, c3: Color, uv: Vector2) -> void:
	var field := c0 == _field_a and c1 == _field_a
	var verge := not field and c0 == _verge_a and c1 == _verge_a
	if not field and not verge:
		super(v0, v1, v2, v3, hint, c0, c1, c2, c3, uv)
		return
	var da := _drop_a
	var db := _drop_b
	if field:
		var k := 0 if (v0 - _pa).dot(_ra) >= 0.0 else 1
		da = _fdrop_a[k]
		db = _fdrop_b[k]
	if da <= 0.0 and db <= 0.0:
		super(v0, v1, v2, v3, hint, c0, c1, c2, c3, uv)
		return
	var la := Vector3.UP * da
	var lb := Vector3.UP * db
	super(v0 - la, v1 - la, v2 - lb, v3 - lb, hint, c0, c1, c2, c3, uv)


## Both-side drop at s (returned) and the field drop per side into `out` (right, left:
## at least the both-side drop).
func _row_drops(s: float, out: PackedFloat64Array) -> float:
	var d: float = drop_at.call(s) if drop_at.is_valid() else 0.0
	out[0] = d
	out[1] = d
	if field_drop_at.is_valid():
		out[0] = maxf(d, field_drop_at.call(s, 1.0))
		out[1] = maxf(d, field_drop_at.call(s, -1.0))
	return d
