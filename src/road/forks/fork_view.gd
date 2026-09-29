class_name ForkView
extends Node3D
## Both branches of a fork past its split (WP6.5). Spec: Core loop → Legs and
## checkpoints → Forks ("split the road OutRun-style into two branches"); World → Road
## (ribbon chunks, pooled, floating origin); Performance budget. docs/FORKS.md.
##
##   view.setup(ctx, origin)                     # once per run
##   view.begin(fork, left_path, right_path, left_plan, right_plan)
##   view.update_view(player_s)                  # once per frame (time-sliced builds)
##   view.resolve(taken_side, left_path, right_path)   # the player picked
##   view.end()                                  # the fork is behind
##
## While a fork is pending, the main RoadBuilder leaves [split, split + fork_draw_m) to
## this node (RoadBuilder.set_skip_range) and nothing else is built past the split (the
## main path's hold). Here each branch path is meshed with the road's own
## RoadChunkMesher, so a branch looks exactly like the road it becomes: the left branch
## with the ground over the gore up to the right branch's rail, the right branch with no
## ground on its left; the opposite carriageway is away (the fork's veer). A crash
## cushion stands on the gore nose.
##
## After the choice the taken branch keeps its pieces up to split + fork_draw_m (the
## builder takes over from there, from the same path: no seam); the other branch is
## lowered by fork_other_sink_m (so its ground always sits under the taken branch's where
## they overlap) and extended until it has narrowed to nothing (RoadFork.vanish_factor)
## and handed its ground over (fork_ground_blend_m).
##
## Time-sliced like RoadBuilder: at most chunk_build_rows_per_frame_count rows per frame,
## nearest pieces first, only within the view distance + prefetch. Pieces are pooled.

const ROAD_MATERIAL: Material = preload("res://assets/shaders/materials/road.tres")
const WORLD_MATERIAL: Material = preload("res://assets/shaders/materials/world.tres")
## Work budget meaning "no limit" (warm-up, teleports).
const UNLIMITED := 1 << 30


## One mesh piece of one branch.
class Piece:
	extends RefCounted
	var node: MeshInstance3D
	var mesh: ArrayMesh
	var side: int = 0
	var s0: float = 0.0
	var s1: float = 0.0
	var built: bool = false
	var live: bool = false
	var anchor_x: float = 0.0
	var anchor_y: float = 0.0
	var anchor_z: float = 0.0


var tuning: RoadTuning
var legs: LegsTuning
var origin: FloatingOrigin
## >= 0 overrides the quality view distance (tests).
var view_distance_override_m: float = -1.0

## The pending or current fork (null: none).
var fork: RoadFork
## 0 until the player picks, then ForkPlan.LEFT / RIGHT.
var taken: int = 0
var pieces: Array[Piece] = []
var builds_total: int = 0

var _left: ProceduralRoadPath
var _right: ProceduralRoadPath
var _left_plan: BiomePlan
var _right_plan: BiomePlan
var _mesher: RoadChunkMesher
var _palette := RoadPalette.new()
var _pending: Piece
var _blend := BiomePlan.Blend.new()
var _cliff_seed: int = 0
var _cushion: MeshInstance3D
var _cushion_anchor := PackedFloat64Array([0.0, 0.0, 0.0])
var _connected: bool = false


func setup(ctx: RunContext, floating_origin: FloatingOrigin) -> void:
	var t: Tuning = ctx.tuning if ctx != null else Tuning.load_default()
	tuning = t.road
	legs = t.legs
	origin = floating_origin
	_cliff_seed = ctx.rng_props.derive(RoadBuilder.CLIFF_STREAM).get_seed() if ctx != null else 0
	var lt: Variant = t.get(&"landmarks")
	_mesher = RoadChunkMesher.new(tuning, _palette, lt as LandmarkTuning if lt is LandmarkTuning else null)
	_mesher.merge_surfaces = true
	_mesher.cliff_seed = _cliff_seed
	end()
	_connect()


## Starts drawing fork `f` (the left path's RoadFork) with both branch paths and the
## plans their colours come from.
func begin(f: RoadFork, left_path: ProceduralRoadPath, right_path: ProceduralRoadPath,
		left_plan: BiomePlan, right_plan: BiomePlan) -> void:
	end()
	fork = f
	taken = 0
	_left = left_path
	_right = right_path
	_left_plan = left_plan
	_right_plan = right_plan
	for side: int in [ForkPlan.LEFT, ForkPlan.RIGHT]:
		_add_pieces(side, f.split_s, f.split_s + f.draw_m)
	_place_cushion()


## The player picked `side`. The paths are passed again: the run swaps the main path's
## state when the right branch is taken, so the objects holding each branch change.
func resolve(side: int, left_path: ProceduralRoadPath, right_path: ProceduralRoadPath) -> void:
	if fork == null or taken != 0:
		return
	taken = side
	_left = left_path
	_right = right_path
	var other := -side
	for p in pieces:
		if p.side == other and p.live:
			_place(p)
	var start := fork.split_s + fork.draw_m
	_add_pieces(other, start, start + tuning.fork_vanish_start_m + fork.vanish_length_m + fork.ground_blend_m
		+ tuning.chunk_length_m)


## Frees every piece (the fork is behind, or a new run).
func end() -> void:
	if _pending != null and _mesher != null:
		_mesher.cancel()
	_pending = null
	for p in pieces:
		p.live = false
		p.built = false
		if p.node != null:
			p.node.visible = false
	fork = null
	taken = 0
	_left = null
	_right = null
	if _cushion != null:
		_cushion.visible = false


func is_active() -> bool:
	return fork != null


func update_view(focus_s: float) -> void:
	_update(focus_s, tuning.chunk_build_rows_per_frame_count if tuning != null else 0)


func build_all_now(focus_s: float) -> void:
	_update(focus_s, UNLIMITED)


func view_distance_m() -> float:
	if view_distance_override_m >= 0.0:
		return view_distance_override_m
	if Quality.view_distance_m > 0.0:
		return Quality.view_distance_m
	var qt := Tuning.load_default().quality
	return qt.view_distance_m[qt.tier_index(qt.default_tier)]


## Built, live pieces of `side` (tests).
func built_count(side: int) -> int:
	var n := 0
	for p in pieces:
		if p.live and p.built and p.side == side:
			n += 1
	return n


## How far past the split `side` is built without a gap (tests: both branches visible).
func built_to(side: int) -> float:
	if fork == null:
		return -INF
	var to := fork.split_s
	var moved := true
	while moved:
		moved = false
		for p in pieces:
			if p.live and p.built and p.side == side and absf(p.s0 - to) < RoadChunkMesher.ROW_EPS_M:
				to = p.s1
				moved = true
	return to


func cushion_visible() -> bool:
	return _cushion != null and _cushion.visible


# ---------------------------------------------------------------- Internals

func _add_pieces(side: int, s0: float, s1: float) -> void:
	var step := tuning.chunk_length_m
	var a := s0
	while a < s1 - RoadChunkMesher.ROW_EPS_M:
		var p := _acquire()
		p.side = side
		p.s0 = a
		p.s1 = minf(a + step, s1)
		p.built = false
		p.live = true
		p.node.visible = false
		a = p.s1


func _acquire() -> Piece:
	for p in pieces:
		if not p.live and p != _pending:
			return p
	var p := Piece.new()
	p.mesh = ArrayMesh.new()
	p.node = MeshInstance3D.new()
	p.node.mesh = p.mesh
	p.node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	p.node.visible = false
	add_child(p.node)
	pieces.append(p)
	return p


func _path(side: int) -> ProceduralRoadPath:
	return _left if side == ForkPlan.LEFT else _right


func _update(focus_s: float, row_budget: int) -> void:
	if fork == null or tuning == null:
		return
	var lo := focus_s - tuning.chunk_keep_behind_m
	var hi := focus_s + view_distance_m() + tuning.chunk_prefetch_m
	for p in pieces:
		if p.live and p.s1 < lo:
			p.live = false
			p.built = false
			p.node.visible = false
	var rows := 0
	while rows < row_budget:
		if _pending == null and not _start_next(lo, hi):
			return
		var before := _mesher.units_done()
		var done := _mesher.step(row_budget - rows)
		rows += _mesher.units_done() - before
		if done:
			_commit()


## Begins the nearest unbuilt piece within [lo, hi]; false when there is none.
func _start_next(lo: float, hi: float) -> bool:
	var best: Piece = null
	for p in pieces:
		if p.live and not p.built and p.s1 >= lo and p.s0 <= hi and (best == null or p.s0 < best.s0):
			best = p
	if best == null:
		return false
	var path := _path(best.side)
	var plan := _left_plan if best.side == ForkPlan.LEFT else _right_plan
	path.ensure_generated_to(best.s1)
	_colors(plan, best.s0, best.s1)
	_mesher.biome_plan = plan
	_mesher.probe_end_before_m = 0.0
	var held := path.hold_at_forks
	path.hold_at_forks = false
	_mesher.begin(path, best.s0, best.s1)
	path.hold_at_forks = held
	_pending = best
	return true


func _commit() -> void:
	var p := _pending
	_pending = null
	_mesher.commit_merged(p.mesh, ROAD_MATERIAL)
	p.anchor_x = _mesher.anchor_x
	p.anchor_y = _mesher.anchor_y
	p.anchor_z = _mesher.anchor_z
	p.built = true
	builds_total += 1
	_place(p)
	p.node.visible = true
	p.node.reset_physics_interpolation()


## Node position from the anchor; the branch not taken sits fork_other_sink_m lower.
func _place(p: Piece) -> void:
	var pos := Vector3(p.anchor_x, p.anchor_y, p.anchor_z)
	if origin != null:
		pos = origin.to_local(p.anchor_x, p.anchor_y, p.anchor_z)
	if taken != 0 and p.side != taken:
		pos.y -= tuning.fork_other_sink_m
	p.node.position = pos


## The branch plan's ground colours at s0 and s1 into the mesher's palette.
func _colors(plan: BiomePlan, s0: float, s1: float) -> void:
	for e in 2:
		plan.blend_into(s0 if e == 0 else s1, legs.biome_blend_before_m, legs.biome_blend_after_m, _blend)
		var verge := _blend.from.verge_color.lerp(_blend.to.verge_color, _blend.t)
		var field := _blend.from.ground_color.lerp(_blend.to.ground_color, _blend.t)
		var rock := _blend.from.rock_color.lerp(_blend.to.rock_color, _blend.t)
		var shade := _blend.from.rock_shade_color.lerp(_blend.to.rock_shade_color, _blend.t)
		if e == 0:
			_palette.ground_verge = verge
			_palette.ground_field = field
			_palette.rock = rock
			_palette.rock_shade = shade
		else:
			_palette.ground_verge_end = verge
			_palette.ground_field_end = field
			_palette.rock_end = rock
			_palette.rock_shade_end = shade


# ---------------------------------------------------------------- Crash cushion

## The attenuator on the gore nose: a box across the lane line between the branches,
## from the split along the road, hazard yellow with ink chevrons facing the traffic
## (retro-reflective, emissive class 1).
func _place_cushion() -> void:
	if _cushion == null:
		_cushion = MeshInstance3D.new()
		_cushion.name = "Cushion"
		_cushion.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_cushion.mesh = _cushion_mesh()
		add_child(_cushion)
	var smp := _left.sample(fork.split_s)
	var d := _left.lanes_left_edge_d(fork.split_s - RoadBuilder.SPLIT_PROBE_M) \
		+ float(fork.lanes_left) * _left.lane_width(fork.split_s - RoadBuilder.SPLIT_PROBE_M)
	_cushion_anchor[0] = smp.pos_x + float(smp.right.x) * d
	_cushion_anchor[1] = smp.pos_y + float(smp.right.y) * d
	_cushion_anchor[2] = smp.pos_z + float(smp.right.z) * d
	_cushion.rotation = Vector3(0.0, smp.godot_yaw(0.0), 0.0)
	_place_cushion_node()
	_cushion.visible = true


func _place_cushion_node() -> void:
	if origin != null:
		_cushion.position = origin.to_local(_cushion_anchor[0], _cushion_anchor[1], _cushion_anchor[2])
	else:
		_cushion.position = Vector3(_cushion_anchor[0], _cushion_anchor[1], _cushion_anchor[2])
	_cushion.reset_physics_interpolation()


func _cushion_mesh() -> ArrayMesh:
	var pal := WBPalette.load_default()
	var body := pal.color(&"hazard_yellow")
	var ink := pal.color(&"ink")
	var hw := tuning.fork_cushion_width_m * 0.5
	var ln := tuning.fork_cushion_length_m
	var h := tuning.median_barrier_height_m
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Local frame: +x right, +y up, -z along the road (the nose at z = 0 faces +z).
	var bands := 4
	for b in bands:
		var y0 := h * float(b) / float(bands)
		var y1 := h * float(b + 1) / float(bands)
		var c := ink if b % 2 == 0 else body
		_quad(st, Vector3(-hw, y0, 0.0), Vector3(hw, y0, 0.0), Vector3(hw, y1, 0.0), Vector3(-hw, y1, 0.0),
			Vector3.BACK, c, RoadChunkMesher.EMISSIVE_REFLECTOR)
	_quad(st, Vector3(-hw, h, 0.0), Vector3(hw, h, 0.0), Vector3(hw, h, -ln), Vector3(-hw, h, -ln), Vector3.UP, body,
		RoadChunkMesher.EMISSIVE_NONE)
	_quad(st, Vector3(hw, 0.0, 0.0), Vector3(hw, 0.0, -ln), Vector3(hw, h, -ln), Vector3(hw, h, 0.0), Vector3.RIGHT,
		body, RoadChunkMesher.EMISSIVE_NONE)
	_quad(st, Vector3(-hw, 0.0, 0.0), Vector3(-hw, 0.0, -ln), Vector3(-hw, h, -ln), Vector3(-hw, h, 0.0), Vector3.LEFT,
		body, RoadChunkMesher.EMISSIVE_NONE)
	var mesh := st.commit()
	mesh.surface_set_material(0, WORLD_MATERIAL)
	return mesh


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: Color,
		emissive: float) -> void:
	var fn := (c - a).cross(b - a)
	if fn.dot(n) < 0.0:
		var tmp := b
		b = d
		d = tmp
	for v: Vector3 in [a, b, c, a, c, d]:
		st.set_normal(n)
		st.set_color(col)
		st.set_uv2(Vector2(emissive, RoadChunkMesher.TINT_NONE))
		st.add_vertex(v)


# ---------------------------------------------------------------- Floating origin

func _connect() -> void:
	if _connected or not is_inside_tree():
		return
	Events.origin_shifted.connect(_on_origin_shifted)
	_connected = true


func _enter_tree() -> void:
	_connect()


func _exit_tree() -> void:
	if _connected:
		Events.origin_shifted.disconnect(_on_origin_shifted)
		_connected = false


func _on_origin_shifted(_offset: Vector3) -> void:
	for p in pieces:
		if p.live and p.built:
			_place(p)
			p.node.reset_physics_interpolation()
	if _cushion != null and _cushion.visible:
		_place_cushion_node()
