class_name RoadBuilder
extends Node3D
## Renders a RoadPath as pooled ribbon chunks around the focus. Spec: World → Road
## (200 m ribbon chunks, pooled, floating origin every 2 km), Architecture rules 6
## (floating origin) and 7 (pooling), Performance budget (draw calls, view distance).
## World-system node API from docs/CONTRACTS.md §13.
##
##   builder.setup(ctx, road, origin)   # once per run
##   builder.build_all_now(s)           # warm-up (spawn, respawn): everything at once
##   builder.update_view(player_s)      # once per frame
##
## Chunk k covers [k * chunk_length_m, (k + 1) * chunk_length_m]. Chunks are kept
## from `chunk_keep_behind_m` behind the focus to the quality view distance ahead
## (Quality.view_distance_m, re-read on Events.quality_changed / governor_changed),
## plus `chunk_prefetch_m` so a chunk is finished before it is needed.
##
## Frame budget: building is time-sliced. update_view emits at most
## `chunk_build_rows_per_frame_count` mesh rows and completes at most
## `chunk_builds_per_frame_count` chunks; one chunk is in flight at a time, picked
## nearest first (ahead before behind), then dirty chunks (ground color changes).
## A new chunk stays hidden until its mesh is committed; a dirty one keeps showing
## its old mesh. Chunk nodes and meshes are pooled and pre-warmed to the most chunks
## the view can need, so driving never allocates a chunk.
##
## Floating origin: chunk vertices are relative to the chunk's own anchor (64-bit
## math in RoadChunkMesher), and the node sits at origin.to_local(anchor). On
## Events.origin_shifted(offset) every live chunk node moves by -offset and resets
## physics interpolation: no rebuild, no seam. An in-flight build is unaffected
## (it is anchor-relative and placed on commit).
##
## Ground colors: with a biome director, the verge, field and rock colours at the
## chunk's start and end (BiomeDirector.verge_color_at etc., blended across biome
## boundaries), which the mesher blends per row; else set_ground_colors(). Chunks whose
## colors went stale (the plan changed: BiomeDirector.plan_version) rebuild within the
## frame budget. Road tunnels (TUNNEL features) are part of the chunk mesh.
##
## Ground drop (WP6.4c): `set_ground_drop(drop_at, field_drop_at)` makes the mesher a
## GroundDropMesher, which lowers the ground ribbon where a biome feature needs the land
## below the road: `drop_at(s)` under both sides (ElevatedSections.ground_drop_at: the
## city's viaducts) and `field_drop_at(s, side)` beyond the scenery line on one side
## (WaterRibbon.ground_drop_at: the coast's sea slope). Set it before setup (the run
## does); set later, it swaps the mesher and rebuilds every chunk within the budget.
##
## Fork zones (WP6.5): `set_skip_range(lo, hi)` leaves [lo, hi) to the ForkView (both
## branches past a split): a chunk overlapping it is clipped to the part outside (the
## last row of a chunk clipped at `lo` reads its cross-section just before it, the trunk's).
##
## Draw calls: one per visible chunk. Road surface, markings, reflectors, barrier,
## rails and ground ribbon are one surface (RoadChunkMesher.commit_merged): the road
## and world shaders are the same code, so merging them changes no pixel (WP4.6;
## tests/unit/test_road_builder.gd guards the shaders staying identical).

const ROAD_MATERIAL: Material = preload("res://assets/shaders/materials/road.tres")
const FREE := -1
## Lowest chunk index built (the run starts at s = 0).
const FIRST_CHUNK := 0
## Work budget meaning "no limit" (warm-up).
const UNLIMITED := 1 << 30
## Chunk colour record: verge, field, rock, rock shade at the start, then at the end.
const COLOR_COUNT := 8
## Props sub-stream seeding the cliff runs and facets.
const CLIFF_STREAM := &"cliffs"
## A chunk clipped at a fork split reads its last row's cross-section this far before it.
const SPLIT_PROBE_M := 0.01   # lint: allow-number numeric offset, not tuning


## One pooled chunk.
class Chunk extends RefCounted:
	var node: MeshInstance3D
	var mesh: ArrayMesh
	## Chunk index k, or FREE. Set when the mesh is committed.
	var index: int = FREE
	var anchor_x: float = 0.0
	var anchor_y: float = 0.0
	var anchor_z: float = 0.0
	var dirty: bool = false
	var triangles: int = 0
	## Ground colors the mesh was built with (at the chunk's start).
	var verge: Color
	var field: Color
	## Every colour the mesh was built with (RoadBuilder.COLOR_*).
	var colors := PackedColorArray()
	## The biomes at its start and end when built (cliffs follow the biome).
	var biome_a: BiomeDef
	var biome_b: BiomeDef


var tuning: RoadTuning
var palette: RoadPalette = RoadPalette.new()
## >= 0 overrides the quality view distance (tests, dev scenes).
var view_distance_override_m: float = -1.0:
	set(value):
		view_distance_override_m = value
		_refresh_view_distance()
var road: RoadPath
var origin: FloatingOrigin
## Optional: ground ribbon colors follow BiomeDef.verge_color / ground_color of the
## biome at each chunk's start (re-checked on Events.biome_changed / fork_taken).
## Without one, set_ground_colors() sets them.
var biome_director: BiomeDirector

## Stats (dev HUD, tests).
var builds_total: int = 0
## Chunk builds completed by the last update_view / build_all_now.
var builds_last_update: int = 0
## Mesh rows emitted by the last update_view / build_all_now.
var rows_last_update: int = 0
## Times a chunk node was created (pre-warm, or a longer view distance).
var pool_grow_count: int = 0
var shifts_applied: int = 0

var _pool: Array[Chunk] = []
var _mesher: RoadChunkMesher
## Ground-drop hooks (set_ground_drop): (s) -> m and (s, side) -> m.
var _drop_at: Callable
var _field_drop_at: Callable
var _landmark_tuning: LandmarkTuning
var _cliff_seed: int = 0
var _k_min: int = 0
var _k_max: int = FREE
var _view_m: float = 0.0
var _events_connected: bool = false
## The chunk being built (null when idle), the index it is built for, and whether
## it is a rebuild of a live chunk.
var _pending: Chunk
var _pending_k: int = FREE
var _pending_rebuild: bool = false
## The palette changed while the in-flight chunk was being built.
var _pending_stale: bool = false
var _pending_colors := PackedColorArray()
var _pending_biome_a: BiomeDef
var _pending_biome_b: BiomeDef
## Ground colors without a biome director (set_ground_colors), and the scratch
## result of _want_colors().
var _manual_verge: Color
var _manual_field: Color
var _want := PackedColorArray()
var _plan_version: int = -1
## Fork zone left to the ForkView (none: lo = INF).
var _skip_lo: float = INF
var _skip_hi: float = -INF
## The clipped range of the chunk last asked about (_chunk_range).
var _cr0: float = 0.0
var _cr1: float = 0.0


func _init() -> void:
	_manual_verge = palette.ground_verge
	_manual_field = palette.ground_field
	_want.resize(COLOR_COUNT)
	_pending_colors.resize(COLOR_COUNT)


# ---------------------------------------------------------------- World-system API

func setup(ctx: RunContext, road_path: RoadPath, floating_origin: FloatingOrigin) -> void:
	var t: Tuning = ctx.tuning if ctx != null else Tuning.load_default()
	tuning = t.road
	road = road_path
	origin = floating_origin
	var lt: Variant = t.get(&"landmarks")
	_landmark_tuning = lt as LandmarkTuning if lt is LandmarkTuning else null
	_cliff_seed = ctx.rng_props.derive(CLIFF_STREAM).get_seed() if ctx != null else 0
	_make_mesher()
	_plan_version = biome_director.plan_version if biome_director != null else -1
	_cancel_pending()
	for c in _pool:
		_free_chunk(c)
	_refresh_view_distance()


## Once per frame with the player's s: frees chunks out of range, then advances the
## time-sliced build within the per-frame budget.
func update_view(focus_s: float) -> void:
	if tuning == null:
		return
	if biome_director != null and biome_director.plan_version != _plan_version:
		_plan_version = biome_director.plan_version
		_recheck_colors()
	_update(focus_s, tuning.chunk_build_rows_per_frame_count, tuning.chunk_builds_per_frame_count)


## Builds every chunk the view needs right now (spawn/respawn warm-up; not per frame).
func build_all_now(focus_s: float) -> void:
	if tuning == null:
		return
	_update(focus_s, UNLIMITED, UNLIMITED)


## Sets the ground ribbon colors when no biome_director is set; live chunks
## rebuild within the frame budget.
func set_ground_colors(verge: Color, field: Color) -> void:
	_manual_verge = verge
	_manual_field = field
	_recheck_colors()


## Ground colors from a biome (convenience for set_ground_colors).
func apply_biome(biome: BiomeDef) -> void:
	set_ground_colors(biome.verge_color, biome.ground_color)


## The ground-drop hook (see the header): `drop_at(s: float) -> float` lowers the verge
## and field on both sides, `field_drop_at(s: float, side: float) -> float` the field on
## side -1 / +1. Either may be an empty Callable; both empty = the plain mesher. Before
## setup it only configures; after setup it swaps the mesher and marks every live chunk
## dirty (rebuilt within the frame budget).
func set_ground_drop(drop_at: Callable, field_drop_at: Callable) -> void:
	_drop_at = drop_at
	_field_drop_at = field_drop_at
	if tuning == null:
		return
	_cancel_pending()
	_make_mesher()
	for c in _pool:
		if c.index != FREE:
			c.dirty = true


## Leaves [lo, hi) to the ForkView (WP6.5). Set it before the builder reaches lo.
func set_skip_range(lo: float, hi: float) -> void:
	_skip_lo = lo
	_skip_hi = hi


func clear_skip_range() -> void:
	_skip_lo = INF
	_skip_hi = -INF


func skip_range_lo() -> float:
	return _skip_lo


## True when the ground-drop hook is set (the mesher is a GroundDropMesher).
func has_ground_drop() -> bool:
	return _mesher is GroundDropMesher


# ---------------------------------------------------------------- Queries

func view_distance_m() -> float:
	return _view_m


func pool_size() -> int:
	return _pool.size()


func active_chunk_count() -> int:
	var n := 0
	for c in _pool:
		if c.index != FREE:
			n += 1
	return n


## True when chunk k is built and live.
func has_chunk(k: int) -> bool:
	return _find(k) != null


## The live chunk k (null if not built). Tests and debug tools.
func get_chunk(k: int) -> Chunk:
	return _find(k)


## True while a chunk build is spread over frames.
func is_building() -> bool:
	return _pending != null


## First and last chunk index kept for the current focus.
func needed_range_min() -> int:
	return _k_min


func needed_range_max() -> int:
	return _k_max


## Triangles in live chunks.
func triangle_count() -> int:
	var n := 0
	for c in _pool:
		if c.index != FREE:
			n += c.triangles
	return n


## Draw calls for live chunks before frustum culling (one surface per chunk).
func draw_call_count() -> int:
	return active_chunk_count()


# ---------------------------------------------------------------- Internals

func _update(focus_s: float, row_budget: int, build_budget: int) -> void:
	builds_last_update = 0
	rows_last_update = 0
	if road == null:
		return
	var length := tuning.chunk_length_m
	_k_min = maxi(floori((focus_s - tuning.chunk_keep_behind_m) / length), FIRST_CHUNK)
	_k_max = floori((focus_s + _view_m + tuning.chunk_prefetch_m) / length)
	for c in _pool:
		if c.index != FREE and (c.index < _k_min or c.index > _k_max):
			_free_chunk(c)
	if _pending != null and (_pending_k < _k_min or _pending_k > _k_max):
		_cancel_pending()

	var k_focus := clampi(floori(focus_s / length), _k_min, _k_max)
	while rows_last_update < row_budget and builds_last_update < build_budget:
		if _pending == null and not _start_next(k_focus):
			return
		var before := _mesher.units_done()
		var done := _mesher.step(row_budget - rows_last_update)
		rows_last_update += _mesher.units_done() - before
		if done:
			_commit_pending()
			builds_last_update += 1


## Picks the next chunk to build (missing ones nearest first, then dirty ones) and
## begins it. False when there is nothing to do.
func _start_next(k_focus: int) -> bool:
	for k in range(k_focus, _k_max + 1):
		if _find(k) == null and _chunk_range(k) and _generated(k):
			_begin(k, _acquire(), false)
			return true
	for k in range(k_focus - 1, _k_min - 1, -1):
		if _find(k) == null and _chunk_range(k) and _generated(k):
			_begin(k, _acquire(), false)
			return true
	for c in _pool:
		if c.index != FREE and c.dirty:
			c.dirty = false
			if _chunk_range(c.index):
				_begin(c.index, c, true)
				return true
	return false


## True when chunk k's range is generated (asks the road to generate it first).
func _generated(k: int) -> bool:
	_chunk_range(k)
	var s1 := _cr1
	if s1 > road.length_generated():
		road.ensure_generated_to(s1)
	return s1 <= road.length_generated()


## Chunk k's range outside the fork skip range into _cr0.._cr1; false when none is left.
func _chunk_range(k: int) -> bool:
	_cr0 = float(k) * tuning.chunk_length_m
	_cr1 = _cr0 + tuning.chunk_length_m
	if _cr1 <= _skip_lo or _cr0 >= _skip_hi:
		return true
	if _cr0 < _skip_lo:
		_cr1 = _skip_lo
		return true
	if _cr1 > _skip_hi:
		_cr0 = _skip_hi
		return true
	return false


func _begin(k: int, c: Chunk, rebuild: bool) -> void:
	var s0 := float(k) * tuning.chunk_length_m
	_want_colors(k)
	for i in COLOR_COUNT:
		_pending_colors[i] = _want[i]
	palette.ground_verge = _want[0]
	palette.ground_field = _want[1]
	palette.rock = _want[2]
	palette.rock_shade = _want[3]
	palette.ground_verge_end = _want[4]
	palette.ground_field_end = _want[5]
	palette.rock_end = _want[6]
	palette.rock_shade_end = _want[7]
	_mesher.biome_plan = biome_director.plan if biome_director != null else null
	_pending_biome_a = _biome_at(s0)
	_pending_biome_b = _biome_at(s0 + tuning.chunk_length_m)
	_chunk_range(k)
	_mesher.probe_end_before_m = SPLIT_PROBE_M if _cr1 == _skip_lo else 0.0
	_mesher.begin(road, _cr0, _cr1)
	_pending = c
	_pending_k = k
	_pending_rebuild = rebuild
	_pending_stale = false


func _commit_pending() -> void:
	var c := _pending
	_mesher.commit_merged(c.mesh, ROAD_MATERIAL)
	c.index = _pending_k
	c.dirty = _pending_stale
	c.verge = _pending_colors[0]
	c.field = _pending_colors[1]
	c.colors = _pending_colors.duplicate()
	c.biome_a = _pending_biome_a
	c.biome_b = _pending_biome_b
	c.triangles = _mesher.triangle_count()
	c.anchor_x = _mesher.anchor_x
	c.anchor_y = _mesher.anchor_y
	c.anchor_z = _mesher.anchor_z
	if origin != null:
		c.node.position = origin.to_local(c.anchor_x, c.anchor_y, c.anchor_z)
	else:
		c.node.position = Vector3(c.anchor_x, c.anchor_y, c.anchor_z)
	c.node.visible = true
	c.node.reset_physics_interpolation()
	builds_total += 1
	_pending = null
	_pending_k = FREE
	_pending_rebuild = false


func _make_mesher() -> void:
	if _drop_at.is_valid() or _field_drop_at.is_valid():
		var gd := GroundDropMesher.new(tuning, palette, _landmark_tuning)
		gd.drop_at = _drop_at
		gd.field_drop_at = _field_drop_at
		_mesher = gd
	else:
		_mesher = RoadChunkMesher.new(tuning, palette, _landmark_tuning)
	_mesher.merge_surfaces = true
	_mesher.cliff_seed = _cliff_seed


func _cancel_pending() -> void:
	if _pending == null:
		return
	if _mesher != null:
		_mesher.cancel()
	if _pending_rebuild and _pending.index != FREE:
		_pending.dirty = true
	_pending = null
	_pending_k = FREE
	_pending_rebuild = false


## Colors chunk k should have, into _want (COLOR_COUNT: start then end).
func _want_colors(k: int) -> void:
	if biome_director != null:
		for e in 2:
			var s := float(k + e) * tuning.chunk_length_m
			var o := e * (COLOR_COUNT >> 1)
			_want[o] = biome_director.verge_color_at(s)
			_want[o + 1] = biome_director.ground_color_at(s)
			_want[o + 2] = biome_director.rock_color_at(s)
			_want[o + 3] = biome_director.rock_shade_color_at(s)
		return
	for e in 2:
		var o := e * (COLOR_COUNT >> 1)
		_want[o] = _manual_verge
		_want[o + 1] = _manual_field
		_want[o + 2] = palette.rock
		_want[o + 3] = palette.rock_shade


## Marks live chunks whose colors are out of date (and the one in flight).
func _recheck_colors() -> void:
	if tuning == null:
		return
	for c in _pool:
		if c.index == FREE:
			continue
		_want_colors(c.index)
		var s0 := float(c.index) * tuning.chunk_length_m
		if c.colors != _want or c.biome_a != _biome_at(s0) or c.biome_b != _biome_at(s0 + tuning.chunk_length_m):
			c.dirty = true
	if _pending != null:
		_want_colors(_pending_k)
		var ps := float(_pending_k) * tuning.chunk_length_m
		if _pending_colors != _want or _pending_biome_a != _biome_at(ps) \
				or _pending_biome_b != _biome_at(ps + tuning.chunk_length_m):
			_pending_stale = true


func _biome_at(s: float) -> BiomeDef:
	return biome_director.biome_at(s) if biome_director != null else null


func _find(k: int) -> Chunk:
	for c in _pool:
		if c.index == k:
			return c
	return null


## A free chunk that is not the one in flight (the pool grows only if none is left).
func _acquire() -> Chunk:
	for c in _pool:
		if c.index == FREE and c != _pending:
			return c
	return _new_chunk()


func _new_chunk() -> Chunk:
	var c := Chunk.new()
	c.mesh = ArrayMesh.new()
	c.node = MeshInstance3D.new()
	c.node.mesh = c.mesh
	c.node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	c.node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	c.node.visible = false
	add_child(c.node)
	_pool.append(c)
	pool_grow_count += 1
	return c


func _free_chunk(c: Chunk) -> void:
	c.index = FREE
	c.dirty = false
	c.triangles = 0
	c.node.visible = false


func _refresh_view_distance() -> void:
	if view_distance_override_m >= 0.0:
		_view_m = view_distance_override_m
	elif Quality.view_distance_m > 0.0:
		_view_m = Quality.view_distance_m
	else:
		# No applied quality yet (e.g. headless): the default tier's distance.
		var qt := Tuning.load_default().quality
		_view_m = qt.view_distance_m[qt.tier_index(qt.default_tier)]
	_prewarm_pool()


## Grows the pool to the most chunks the current view can ever need at once (plus
## the one in flight), so driving never allocates a chunk.
func _prewarm_pool() -> void:
	if tuning == null or not is_inside_tree():
		return
	var span := tuning.chunk_keep_behind_m + _view_m + tuning.chunk_prefetch_m
	var most := ceili(span / tuning.chunk_length_m) + 1
	while _pool.size() < most:
		_new_chunk()


func _on_origin_shifted(offset: Vector3) -> void:
	for c in _pool:
		if c.index != FREE:
			c.node.position -= offset
			c.node.reset_physics_interpolation()
	shifts_applied += 1


func _on_quality_changed(_tier: StringName) -> void:
	_refresh_view_distance()


func _on_governor_changed(_rung: int) -> void:
	_refresh_view_distance()


func _on_biome_changed(_biome: StringName) -> void:
	_recheck_colors()


func _enter_tree() -> void:
	_prewarm_pool()
	if not _events_connected:
		Events.origin_shifted.connect(_on_origin_shifted)
		Events.quality_changed.connect(_on_quality_changed)
		Events.governor_changed.connect(_on_governor_changed)
		Events.biome_changed.connect(_on_biome_changed)
		Events.fork_taken.connect(_on_biome_changed)
		_events_connected = true


func _exit_tree() -> void:
	if _events_connected:
		Events.origin_shifted.disconnect(_on_origin_shifted)
		Events.quality_changed.disconnect(_on_quality_changed)
		Events.governor_changed.disconnect(_on_governor_changed)
		Events.biome_changed.disconnect(_on_biome_changed)
		Events.fork_taken.disconnect(_on_biome_changed)
		_events_connected = false
