class_name RoadBuilder
extends Node3D
## Renders a RoadPath as pooled ribbon chunks around the focus. Spec: World → Road
## (200 m ribbon chunks, pooled, floating origin every 2 km), Architecture rules 6
## (floating origin) and 7 (pooling), Performance budget (draw calls, view distance).
## World-system node API from docs/CONTRACTS.md §13.
##
##   builder.setup(ctx, road, origin)   # once per run
##   builder.build_all_now(s)           # optional warm-up (spawn, respawn): no pop-in
##   builder.update_view(player_s)      # once per frame
##
## Chunk k covers [k * chunk_length_m, (k + 1) * chunk_length_m]. Chunks are kept
## from `chunk_keep_behind_m` behind the focus to the quality view distance ahead
## (Quality.view_distance_m, re-read on Events.quality_changed / governor_changed).
## At most `chunk_builds_per_frame_count` chunks are (re)built per update_view,
## nearest first (ahead before behind). Chunk nodes and meshes are pooled: the pool
## grows only while warming up or when the view distance grows.
##
## Floating origin: chunk vertices are relative to the chunk's own anchor (64-bit
## math in RoadChunkMesher), and the node sits at origin.to_local(anchor). On
## Events.origin_shifted(offset) every live chunk node moves by -offset and resets
## physics interpolation: no rebuild, no seam.
##
## Draw calls: two per visible chunk (road + world material).

const ROAD_MATERIAL: Material = preload("res://assets/shaders/materials/road.tres")
const WORLD_MATERIAL: Material = preload("res://assets/shaders/materials/world.tres")
const FREE := -1
## Lowest chunk index built (the run starts at s = 0).
const FIRST_CHUNK := 0


## One pooled chunk.
class Chunk extends RefCounted:
	var node: MeshInstance3D
	var mesh: ArrayMesh
	## Chunk index k, or FREE.
	var index: int = FREE
	var anchor_x: float = 0.0
	var anchor_y: float = 0.0
	var anchor_z: float = 0.0
	var dirty: bool = false
	var triangles: int = 0


var tuning: RoadTuning
var palette: RoadPalette = RoadPalette.new()
## >= 0 overrides the quality view distance (tests, dev scenes).
var view_distance_override_m: float = -1.0:
	set(value):
		view_distance_override_m = value
		_refresh_view_distance()
var road: RoadPath
var origin: FloatingOrigin

## Stats (dev HUD, tests).
var builds_total: int = 0
var builds_last_update: int = 0
## Times the pool had to grow (warm-up, or a longer view distance).
var pool_grow_count: int = 0
var shifts_applied: int = 0

var _pool: Array[Chunk] = []
var _mesher: RoadChunkMesher
var _focus_s: float = 0.0
var _k_min: int = 0
var _k_max: int = FREE
var _view_m: float = 0.0
var _events_connected: bool = false


# ---------------------------------------------------------------- World-system API

func setup(ctx: RunContext, road_path: RoadPath, floating_origin: FloatingOrigin) -> void:
	var t: Tuning = ctx.tuning if ctx != null else Tuning.load_default()
	tuning = t.road
	road = road_path
	origin = floating_origin
	_mesher = RoadChunkMesher.new(tuning, palette)
	_release_all()
	_refresh_view_distance()
	_prewarm_pool()


## Once per frame with the player's s: frees chunks out of range, then builds at
## most `chunk_builds_per_frame_count` missing or dirty chunks, nearest first.
func update_view(focus_s: float) -> void:
	builds_last_update = _update(focus_s, tuning.chunk_builds_per_frame_count)


## Builds every chunk the view needs right now (spawn/respawn warm-up; not per frame).
func build_all_now(focus_s: float) -> void:
	builds_last_update = _update(focus_s, _pool.size() + _needed_count(focus_s) + 1)


## Sets the ground ribbon colors (biome); live chunks rebuild within the frame budget.
func set_ground_colors(verge: Color, field: Color) -> void:
	palette.ground_verge = verge
	palette.ground_field = field
	for c in _pool:
		if c.index != FREE:
			c.dirty = true


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


## First and last chunk index the current view needs.
func needed_range_min() -> int:
	return _k_min


func needed_range_max() -> int:
	return _k_max


## Triangles in live chunks (both surfaces).
func triangle_count() -> int:
	var n := 0
	for c in _pool:
		if c.index != FREE:
			n += c.triangles
	return n


## Draw calls for live chunks before frustum culling (two surfaces per chunk).
func draw_call_count() -> int:
	return active_chunk_count() * 2


# ---------------------------------------------------------------- Internals

func _update(focus_s: float, budget: int) -> int:
	if road == null:
		return 0
	_focus_s = focus_s
	var length := tuning.chunk_length_m
	_k_min = maxi(floori((focus_s - tuning.chunk_keep_behind_m) / length), FIRST_CHUNK)
	_k_max = floori((focus_s + _view_m) / length)
	for c in _pool:
		if c.index != FREE and (c.index < _k_min or c.index > _k_max):
			_free_chunk(c)

	var built := 0
	var k_focus := clampi(floori(focus_s / length), _k_min, _k_max)
	for k in range(k_focus, _k_max + 1):
		if built >= budget:
			return built
		if _find(k) == null and _build_new(k):
			built += 1
	for k in range(k_focus - 1, _k_min - 1, -1):
		if built >= budget:
			return built
		if _find(k) == null and _build_new(k):
			built += 1
	for c in _pool:
		if built >= budget:
			return built
		if c.index != FREE and c.dirty:
			_build_into(c, c.index)
			built += 1
	return built


func _needed_count(focus_s: float) -> int:
	var length := tuning.chunk_length_m
	var k0 := maxi(floori((focus_s - tuning.chunk_keep_behind_m) / length), FIRST_CHUNK)
	var k1 := floori((focus_s + _view_m) / length)
	return maxi(k1 - k0 + 1, 0)


func _find(k: int) -> Chunk:
	for c in _pool:
		if c.index == k:
			return c
	return null


func _build_new(k: int) -> bool:
	var s1 := float(k + 1) * tuning.chunk_length_m
	if s1 > road.length_generated():
		road.ensure_generated_to(s1)
		if s1 > road.length_generated():
			return false
	_build_into(_acquire(), k)
	return true


func _build_into(c: Chunk, k: int) -> void:
	var s0 := float(k) * tuning.chunk_length_m
	_mesher.build(road, s0, s0 + tuning.chunk_length_m)
	_mesher.commit(c.mesh, ROAD_MATERIAL, WORLD_MATERIAL)
	c.index = k
	c.dirty = false
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


func _acquire() -> Chunk:
	for c in _pool:
		if c.index == FREE:
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


func _release_all() -> void:
	for c in _pool:
		_free_chunk(c)


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


## Grows the pool to the most chunks the current view can ever need at once, so
## driving never allocates a chunk.
func _prewarm_pool() -> void:
	if tuning == null or not is_inside_tree():
		return
	var span := tuning.chunk_keep_behind_m + _view_m
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


func _enter_tree() -> void:
	_prewarm_pool()
	if not _events_connected:
		Events.origin_shifted.connect(_on_origin_shifted)
		Events.quality_changed.connect(_on_quality_changed)
		Events.governor_changed.connect(_on_governor_changed)
		_events_connected = true


func _exit_tree() -> void:
	if _events_connected:
		Events.origin_shifted.disconnect(_on_origin_shifted)
		Events.quality_changed.disconnect(_on_quality_changed)
		Events.governor_changed.disconnect(_on_governor_changed)
		_events_connected = false
