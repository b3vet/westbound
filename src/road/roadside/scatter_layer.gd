class_name ScatterLayer
extends RoadsideLayer
## Scattered props and rows of one RoadsideProp (trees, turbines, billboards).
## Spec: World → Biomes (prop sets and densities), Road (billboards with
## invented brands). Per cell and side: floor(mean) instances (or rows) plus
## one more with the fractional chance, each set back from the scenery line
## (guardrail face + prop clearance) by the footprint radius, so it can't reach
## the road. One pool per mesh variant.

const SALT_RIGHT := 1
const SALT_LEFT := 2

var prop: RoadsideProp
var _radius: PackedFloat64Array = []


func _init(context: RoadsideContext, def: RoadsideProp, meshes: Array[Mesh]) -> void:
	super(context, def.id, def.cell_length_m)
	prop = def
	var sides := 1 if def.sides != RoadsideProp.Sides.BOTH else 2
	for m in meshes:
		add_pool(m, def.per_cell_max() * sides)
		_radius.append(RoadsideLayer.footprint_radius(m))


func _emit(c: int) -> void:
	if prop.sides != RoadsideProp.Sides.LEFT:
		_side(c, SALT_RIGHT, 1.0)
	if prop.sides != RoadsideProp.Sides.RIGHT:
		_side(c, SALT_LEFT, -1.0)


func _side(c: int, salt: int, side: float) -> void:
	ctx.seed_cell(_seed, c, salt)
	var rng := ctx.rng
	var mean := prop.per_cell_mean()
	var n := int(floor(mean))
	if rng.chance(mean - float(n)):
		n += 1
	var s0 := float(c) * cell_length_m
	for i in n:
		var v := _pick(prop.variant_weights, pools.size())
		var scale := rng.float_range(prop.scale_min_factor, prop.scale_max_factor)
		var setback := rng.float_range(prop.setback_min_m, prop.setback_max_m)
		if prop.pattern == RoadsideProp.Pattern.ROW:
			var count := rng.int_range(prop.row_count_min, prop.row_count_max)
			var length := float(count - 1) * prop.row_spacing_m
			var start := s0 + rng.float_range(0.0, maxf(cell_length_m - length, 0.0))
			for k in count:
				_one(v, start + float(k) * prop.row_spacing_m, side, setback, scale)
		else:
			_one(v, s0 + rng.float_range(0.0, cell_length_m), side, setback, scale)


func _one(v: int, s: float, side: float, setback: float, scale: float) -> void:
	var rng := ctx.rng
	var yaw := 0.0
	if prop.facing == RoadsideProp.Facing.RANDOM:
		yaw = rng.float_range(0.0, TAU)
	else:
		var j := deg_to_rad(prop.yaw_jitter_deg)
		yaw = deg_to_rad(prop.yaw_offset_deg) + rng.float_range(-j, j)
	if side < 0.0:
		yaw += PI
	var line := ctx.road.guardrail_d(s) + ctx.tuning.prop_clearance_m
	var d := side * (line + setback + _radius[v] * scale)
	_sample(s)
	_place(v, d, yaw, scale, scale, scale)
