class_name RoadsideLayer
extends RefCounted
## Base of one roadside prop layer: a ring of s-cells, each owning the instances
## it placed in one or more RoadsidePools. Spec: World → Road (roadside rhythm,
## MultiMesh), Architecture rule 6 (floating origin), Performance budget.
##
## Cells are fixed slices of absolute s ([c * L, (c + 1) * L)), so what a cell
## holds depends only on (seed, layer, c): never on the order or step size of
## the window's movement. `update_window` clears cells that left and fills cells
## that entered; nothing is rewritten while the window stands still.
##
## Positions are written relative to the layer's 64-bit anchor. The pools' nodes
## sit at (anchor - origin). On an origin shift the nodes move (instances are
## untouched); `rebase` later re-anchors at the new origin (one layer per frame)
## by translating the instances, so local coordinates stay small forever.

var id: StringName
var cell_length_m: float
var n_cells: int = 0
var pools: Array[RoadsidePool] = []
## Only cells whose biome is this one are filled (null = every biome).
var biome: BiomeDef
## Active cell range [c0, c1).
var c0: int = 0
var c1: int = 0
var anchor_x: float = 0.0
var anchor_y: float = 0.0
var anchor_z: float = 0.0
var needs_rebase: bool = false

var ctx: RoadsideContext
var _seed: int = 0
## Block (ring slot) of the cell being filled.
var _block: int = 0


func _init(context: RoadsideContext, layer_id: StringName, cell_len_m: float) -> void:
	ctx = context
	id = layer_id
	cell_length_m = cell_len_m
	_seed = context.layer_seed(layer_id)


## Adds a pool (one mesh variant); `per_block` = most instances one cell can place.
func add_pool(mesh: Mesh, per_block: int) -> int:
	pools.append(RoadsidePool.new(mesh, per_block))
	return pools.size() - 1


## Allocates every pool for a window of at most `window_max_m`.
func build(parent: Node3D, window_max_m: float) -> void:
	n_cells = int(ceil(window_max_m / cell_length_m)) + 2
	for i in pools.size():
		pools[i].build(parent, n_cells, "%s_%d" % [id, i])


func set_anchor(x: float, y: float, z: float, origin: FloatingOrigin) -> void:
	anchor_x = x
	anchor_y = y
	anchor_z = z
	place_nodes(origin)


## Node position = anchor - origin (64-bit subtraction first).
func place_nodes(origin: FloatingOrigin) -> void:
	var p := Vector3(anchor_x - origin.origin_x, anchor_y - origin.origin_y, anchor_z - origin.origin_z)
	for pool in pools:
		pool.mmi.position = p
		pool.mmi.reset_physics_interpolation()


## Cells overlapping [s_lo, s_hi) and fully generated (end <= s_gen).
func update_window(s_lo: float, s_hi: float, s_gen: float) -> void:
	var n0 := maxi(0, int(floor(s_lo / cell_length_m)))
	var n1 := int(ceil(s_hi / cell_length_m))
	if not is_inf(s_gen):
		n1 = mini(n1, int(floor(s_gen / cell_length_m)))
	n1 = clampi(n1, n0, n0 + n_cells)
	if n0 == c0 and n1 == c1:
		return
	for c in range(c0, c1):
		if c < n0 or c >= n1:
			_clear_cell(c)
	for c in range(n0, n1):
		if c < c0 or c >= c1:
			_fill_cell(c)
	c0 = n0
	c1 = n1


## Re-anchor at the current origin: instances move by (old - new anchor), the
## nodes back to (anchor - origin) = 0. No road sampling, no re-placement.
func rebase(origin: FloatingOrigin) -> void:
	var dx := anchor_x - origin.origin_x
	var dy := anchor_y - origin.origin_y
	var dz := anchor_z - origin.origin_z
	for pool in pools:
		pool.translate(dx, dy, dz)
	set_anchor(origin.origin_x, origin.origin_y, origin.origin_z, origin)
	needs_rebase = false


func flush() -> void:
	for pool in pools:
		pool.flush()


func instance_count() -> int:
	var n := 0
	for pool in pools:
		n += pool.count
	return n


func block_of(c: int) -> int:
	return posmod(c, n_cells)


func _clear_cell(c: int) -> void:
	var b := block_of(c)
	for pool in pools:
		pool.clear_block(b)


func _fill_cell(c: int) -> void:
	_clear_cell(c)
	_block = block_of(c)
	if biome != null and ctx.biome_at((float(c) + 0.5) * cell_length_m) != biome:
		return
	_emit(c)


## Subclasses place cell `c`'s instances with the _place_* helpers.
func _emit(_c: int) -> void:
	pass


# ---------------------------------------------------------------- Placement helpers

## Samples the road at `s` into ctx.sample (for several placements at one s).
func _sample(s: float) -> void:
	ctx.road.sample_into(s, ctx.sample)


## Upright instance at lateral `d` of the current sample. `yaw` is right-positive
## relative to the road; `sx/sy/sz` scale the mesh's local axes.
func _place(pool: int, d: float, yaw: float, sx: float = 1.0, sy: float = 1.0, sz: float = 1.0) -> void:
	var smp := ctx.sample
	var b := Basis(Vector3.UP, smp.godot_yaw(yaw))
	b.x *= sx
	b.y *= sy
	b.z *= sz
	pools[pool].add(_block, b, smp.local_point(d, anchor_x, anchor_y, anchor_z))


## Instance lying on the road plane (pitched with the grade): fields, pads.
func _place_on_grade(pool: int, d: float, flip: bool, sx: float, sy: float, sz: float) -> void:
	var smp := ctx.sample
	var b := Basis(smp.right, smp.up, -smp.tangent)
	if flip:
		b = Basis(-smp.right, smp.up, smp.tangent)
	b.x *= sx
	b.y *= sy
	b.z *= sz
	pools[pool].add(_block, b, smp.local_point(d, anchor_x, anchor_y, anchor_z))


## A segment mesh (authored from z = 0 to z = -length) stretched from
## (s0, d) to (s1, d): continuous end to end on curves and grades.
func _place_segment(pool: int, s0: float, s1: float, d: float, mesh_length_m: float) -> void:
	ctx.road.sample_into(s1, ctx.sample_b)
	ctx.road.sample_into(s0, ctx.sample)
	var p0 := ctx.sample.local_point(d, anchor_x, anchor_y, anchor_z)
	var p1 := ctx.sample_b.local_point(d, anchor_x, anchor_y, anchor_z)
	# Right side: the mesh runs from p0 toward p1 (+s). Left side: from p1 back to
	# p0, so the mesh's +X still points away from the road with a proper rotation.
	var start := p0 if d >= 0.0 else p1
	var z_axis := (p0 - p1) if d >= 0.0 else (p1 - p0)
	var zn := z_axis.normalized()
	var x_axis := Vector3.UP.cross(zn).normalized()
	var b := Basis(x_axis, Vector3.UP, z_axis / mesh_length_m)
	pools[pool].add(_block, b, start)


## Weighted pick (empty weights = uniform).
func _pick(weights: PackedFloat64Array, n: int) -> int:
	if weights.size() != n:
		return ctx.rng.int_range(0, n - 1)
	return ctx.rng.pick_weighted(weights)


## Horizontal footprint radius of a mesh (conservative, from its AABB).
static func footprint_radius(mesh: Mesh) -> float:
	var a := mesh.get_aabb()
	var rx := maxf(absf(a.position.x), absf(a.end.x))
	var rz := maxf(absf(a.position.z), absf(a.end.z))
	return sqrt(rx * rx + rz * rz)
