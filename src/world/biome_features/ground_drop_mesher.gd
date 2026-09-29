class_name GroundDropMesher
extends RoadChunkMesher
## RoadChunkMesher with the ground ribbon lowered where a biome feature needs the land
## below the road: under elevated stretches (city: verge and field, both sides) and
## beyond the scenery line on a cliff coast's sea side (field only). Spec: World →
## Biomes (city: elevated highway sections; coast: ocean on one side, cliffs), Road
## (ribbon chunks).
##
## This is the proposed hook for RoadBuilder (owned by the road/biome sequencing WP):
## the builder would give its mesher these callables. Until it does, the biome preview
## swaps it in (src/road/dev/biome_preview.gd). Everything except the ground quads is
## the base mesher's output, unchanged; the quad count per row interval is the same,
## so the array sizing holds.
##
##   mesher.drop_at = elevated.plan.drop_at          # (s) -> m, verge + field, both sides
##   mesher.field_drop_at = water.ground_drop_at     # (s, side) -> m, field on that side

## (s: float) -> float: the ground's drop below the road at s, both sides (verge + field).
var drop_at: Callable
## (s: float, side: float) -> float: the field's drop on side -1 / +1 (the verge stays).
var field_drop_at: Callable

var _s_a: float = 0.0
var _s_b: float = 0.0
var _drop_a: float = 0.0
var _drop_b: float = 0.0
var _pa := Vector3.ZERO
var _ra := Vector3.RIGHT


func _emit_world_interval(i: int) -> void:
	_s_a = _row_s[i]
	_s_b = _row_s[i + 1]
	_pa = _row_p[i]
	_ra = _row_right[i]
	_drop_a = drop_at.call(_s_a) if drop_at.is_valid() else 0.0
	_drop_b = drop_at.call(_s_b) if drop_at.is_valid() else 0.0
	super(i)


func _world_quad(v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3, hint: Vector3,
		col: Color, uv: Vector2) -> void:
	var field := col == palette.ground_field
	if not field and col != palette.ground_verge:
		super(v0, v1, v2, v3, hint, col, uv)
		return
	# Ground quads are emitted as (row a, row a, row b, row b).
	var da := _drop_a
	var db := _drop_b
	if field and field_drop_at.is_valid():
		var side := signf((v0 - _pa).dot(_ra))
		da = maxf(da, field_drop_at.call(_s_a, side))
		db = maxf(db, field_drop_at.call(_s_b, side))
	if da <= 0.0 and db <= 0.0:
		super(v0, v1, v2, v3, hint, col, uv)
		return
	var la := Vector3.UP * da
	var lb := Vector3.UP * db
	super(v0 - la, v1 - la, v2 - lb, v3 - lb, hint, col, uv)
