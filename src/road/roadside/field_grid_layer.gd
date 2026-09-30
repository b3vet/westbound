class_name FieldGridLayer
extends RoadsideLayer
## Farmland field grid: per cell and side, `band_count` tiles outward from the
## road, each a crop (scaled unit tile), bare ground, or a yard with one
## structure; windbreak tree lines along some band edges. Spec: World → Biomes
## (farmland plains: golden fields, silos, windmills, water towers, long
## views). Tiles lie on the road plane (pitched with the grade); their length
## follows the curve (1 - curvature * d) so bands neither overlap nor gape.

const SALT_RIGHT := 1
const SALT_LEFT := 2

var grid: FieldGridDef
var _crop0: int = 0
var _yard0: int = 0
var _tree0: int = 0
var _n_crop: int = 0
var _n_yard: int = 0
var _n_tree: int = 0
var _yard_radius: PackedFloat64Array = []
var _crop_weights := PackedFloat64Array()


func _init(context: RoadsideContext, layer_id: StringName, def: FieldGridDef, crops: Array[Mesh],
		yards: Array[Mesh], trees: Array[Mesh]) -> void:
	super(context, layer_id, def.cell_length_m)
	grid = def
	_n_crop = crops.size()
	_n_yard = yards.size()
	_n_tree = trees.size()
	_crop0 = 0
	for m in crops:
		add_pool(m, 2 * def.band_count)
	_yard0 = pools.size()
	for m in yards:
		add_pool(m, 2 * def.yard_band_count)
		_yard_radius.append(RoadsideLayer.footprint_radius(m))
	_tree0 = pools.size()
	for m in trees:
		add_pool(m, 2 * def.band_count * def.trees_per_row())
	_crop_weights = def.crop_weights


func _emit(c: int) -> void:
	_side(c, SALT_RIGHT, 1.0)
	_side(c, SALT_LEFT, -1.0)


func _side(c: int, salt: int, side: float) -> void:
	ctx.seed_cell(_seed, c, salt)
	var rng := ctx.rng
	var cell_len := cell_length_m
	var s_mid := (float(c) + 0.5) * cell_len
	var line := ctx.road.guardrail_d(s_mid) + ctx.tuning.prop_clearance_m + grid.setback_m
	var k_curv := ctx.road.curvature_at(s_mid)
	var depth := grid.band_depth_m
	var tile_w := depth - grid.gap_m
	for band in grid.band_count:
		var d_mid := side * (line + (float(band) + 0.5) * depth)
		var bend := maxf(1.0 - k_curv * d_mid, 0.0)
		var tile_l := maxf(cell_len * bend - grid.gap_m, 0.0)
		# Every tile makes the same draws, whatever it becomes.
		var r_kind := rng.unit()
		var r_variant := rng.unit()
		var r_jx := rng.unit()
		var r_jz := rng.unit()
		var r_yaw := rng.int_range(0, 3)
		var r_row := rng.unit()
		var yard_ok := band < grid.yard_band_count and _n_yard > 0
		if yard_ok and r_kind < grid.yard_chance_frac:
			var v := _weighted(grid.yard_weights, _n_yard, r_variant)
			var r := _yard_radius[v]
			var jx := maxf(tile_w * 0.5 - r, 0.0) * (r_jx * 2.0 - 1.0)
			var jz := maxf(tile_l * 0.5 - r, 0.0) * (r_jz * 2.0 - 1.0)
			_sample(s_mid + jz)
			_place(_yard0 + v, d_mid + jx, float(r_yaw) * PI * 0.5 + (PI if side < 0.0 else 0.0))
		elif r_kind >= grid.yard_chance_frac + grid.bare_chance_frac and _n_crop > 0:
			_sample(s_mid)
			var v := _crop0 + _weighted(_crop_weights, _n_crop, r_variant)
			_place_on_grade(v, d_mid, side < 0.0, tile_w, 1.0, tile_l)
		if _n_tree > 0 and r_row < grid.tree_row_chance_frac and band < grid.band_count - 1:
			_tree_row(c, side * (line + float(band + 1) * depth - grid.gap_m * 0.5), side)


func _tree_row(c: int, d: float, side: float) -> void:
	var rng := ctx.rng
	var n := grid.trees_per_row()
	var s0 := float(c) * cell_length_m + grid.tree_spacing_m * 0.5
	for i in n:
		var v := _tree0 + _weighted(grid.tree_weights, _n_tree, rng.unit())
		var scale := rng.float_range(grid.tree_scale_min_factor, grid.tree_scale_max_factor)
		var yaw := rng.float_range(0.0, TAU)
		_sample(s0 + float(i) * grid.tree_spacing_m)
		_place(v, d, yaw + (PI if side < 0.0 else 0.0), scale, scale, scale)


## Index for a uniform draw `u` in [0, 1) by weights (empty = uniform).
static func _weighted(weights: PackedFloat64Array, n: int, u: float) -> int:
	if weights.size() != n:
		return mini(int(u * float(n)), n - 1)
	var total := 0.0
	for w in weights:
		total += w
	var r := u * total
	for i in n:
		r -= weights[i]
		if r < 0.0:
			return i
	return n - 1
