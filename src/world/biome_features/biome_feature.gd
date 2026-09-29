class_name BiomeFeature
extends Node3D
## Base of the biome world features added by WP6.4b (water, elevated sections, fog
## cards): one mesh around the focus, built from road space in steps, time-sliced.
## Spec: World → Biomes (coast ocean, city elevated sections, valley fog cards), Road
## (floating origin), Performance budget (one draw call per feature, frame budget).
##
## World-system node (docs/CONTRACTS.md §13):
##   feature.biome_director = director    # optional; else `fallback_biome` everywhere
##   feature.setup(ctx, road, origin)
##   feature.update_view(player_s)         # once per frame
##
## Windows: for step k (focus rounded down to `step_m()`), W(k) = [k*step -
## road.roadside_behind_m, (k+1)*step + view distance], clamped to the generated road.
## While W(k) is shown, W(k+1) is built in the background, at most `units_per_frame()`
## work units per frame (a unit is a row, a pier, a fog bank: the subclass's choice;
## the data sets the budget), and swapped in when the focus enters step k+1 (whatever
## is left is finished then), so a rebuild never spikes a frame. Everything sits at
## absolute s, so a window change never moves what was already there. The first build,
## a quality change, a step-size change (another biome's data) and a biome plan change
## (BiomeDirector.plan_version) build synchronously.
##
## Floating origin: a build's vertices are relative to its anchor (the origin when it
## began, 64-bit subtraction first); the mesh node sits at anchor - origin, moved on
## Events.origin_shifted, so builds survive shifts and nothing is rebuilt for one.
##
## Subclasses implement `feature_id()`, `step_m()`, `_material()`, and the build:
## `_begin(s_lo, s_hi) -> int` (unit count) then `_emit(i, out)` for i in order.
## Rebuilds allocate (director rate, a few units per frame), never per tick.

## Builds completed (tests, dev HUD).
var rebuilds: int = 0
## Set before setup to follow legs and forks; null = every s is `fallback_biome`.
var biome_director: BiomeDirector
## Used without a director (loaded from BiomeDirector.DEFAULT_BIOME_PATH if null).
var fallback_biome: BiomeDef
## > 0 overrides Quality.view_distance_m (previews, tests).
var view_distance_override_m: float = 0.0
## Window of the mesh on show.
var window_s_lo: float = 0.0
var window_s_hi: float = 0.0

var road: RoadPath
var origin: FloatingOrigin
var road_tuning: RoadTuning
var quality_tuning: QualityTuning
## The run's props seed for this feature (RunContext.rng_props.derive(feature_id())).
var props_seed: int = 0
## Anchor (absolute) of the build in progress: vertices are relative to it.
var anchor_x: float = 0.0
var anchor_y: float = 0.0
var anchor_z: float = 0.0

var _mesh_instance: MeshInstance3D
var _mesh: ArrayMesh
var _shown_k: int = 0
var _shown_x: float = 0.0
var _shown_y: float = 0.0
var _shown_z: float = 0.0
var _dirty: bool = true
var _connected: bool = false
## The generated road ended inside the shown window: rebuild once more exists.
var _short: bool = false
var _triangles: int = 0
var _plan_version: int = -1
var _step_used: float = 0.0

## The background build of the next window.
var _pending: FeatureMesh
var _pending_k: int = 0
var _pending_lo: float = 0.0
var _pending_hi: float = 0.0
var _pending_units: int = 0
var _pending_next: int = 0
var _pending_short: bool = false
var _pending_ax: float = 0.0
var _pending_ay: float = 0.0
var _pending_az: float = 0.0


func setup(ctx: RunContext, road_path: RoadPath, floating_origin: FloatingOrigin) -> void:
	road = road_path
	origin = floating_origin
	road_tuning = ctx.tuning.road
	quality_tuning = ctx.tuning.quality
	props_seed = ctx.rng_props.derive(feature_id()).get_seed()
	if fallback_biome == null:
		fallback_biome = load(BiomeDirector.DEFAULT_BIOME_PATH) as BiomeDef
	if _mesh_instance == null:
		_mesh = ArrayMesh.new()
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "Mesh"
		_mesh_instance.mesh = _mesh
		_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_mesh_instance.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		add_child(_mesh_instance)
	_mesh_instance.material_override = _material()
	_on_setup()
	_pending = null
	_dirty = true
	_connect()


## Once per frame with the focus (player) s.
func update_view(focus_s: float) -> void:
	if road == null:
		return
	var step := step_m()
	if step != _step_used:
		# A new step size (another biome's data) re-bases the windows.
		_step_used = step
		_dirty = true
	var k := int(floor(focus_s / step))
	if biome_director != null and biome_director.plan_version != _plan_version:
		_plan_version = biome_director.plan_version
		_dirty = true
	var s_gen := road.length_generated()
	if _short and s_gen > window_s_hi:
		_dirty = true
	if _dirty or k != _shown_k:
		if not _dirty and _pending != null and _pending_k == k:
			_finish_pending()
		else:
			_pending = null
			_build_now(k, step)
		_dirty = false
	_advance_pending(step)


## Current view distance: the override, else the Quality tier (+ governor).
func view_distance_m() -> float:
	if view_distance_override_m > 0.0:
		return view_distance_override_m
	var q := get_node_or_null(^"/root/Quality") if is_inside_tree() else null
	if q != null:
		var v: float = q.get(&"view_distance_m")
		if v > 0.0:
			return v
	var i := maxi(quality_tuning.tier_names.find(String(quality_tuning.default_tier)), 0)
	return quality_tuning.view_distance_m[i]


func biome_at(s: float) -> BiomeDef:
	if biome_director != null:
		return biome_director.biome_at(s)
	return fallback_biome


## One draw call while the mesh has geometry.
func draw_calls() -> int:
	return 1 if _mesh_instance != null and _mesh_instance.visible and _triangles > 0 else 0


func triangles() -> int:
	return _triangles


func mesh() -> ArrayMesh:
	return _mesh


func mesh_instance() -> MeshInstance3D:
	return _mesh_instance


## True while the next window is being built in the background.
func is_prefetching() -> bool:
	return _pending != null and _pending_next < _pending_units


# ---------------------------------------------------------------- Subclass hooks

## Stream name under RunContext.rng_props (and the node's id).
func feature_id() -> StringName:
	return &"biome_feature"


## Window step along s (m).
func step_m() -> float:
	return road_tuning.roadside_update_step_m


func _material() -> Material:
	return null


## Background build budget: work units per frame.
func units_per_frame() -> int:
	return road_tuning.chunk_build_rows_per_frame_count


## The step in use (for subclasses whose data is absent at the focus: keeping it avoids
## a synchronous rebuild), else the roadside step.
func last_step_m() -> float:
	return _step_used if _step_used > 0.0 else road_tuning.roadside_update_step_m


func _on_setup() -> void:
	pass


## Starts a build of [s_lo, s_hi]; returns how many units `_emit` will be called for.
func _begin(_s_lo: float, _s_hi: float) -> int:
	return 0


## Emits unit i (called for i = 0 .. units - 1, in order) relative to the anchor.
func _emit(_i: int, _out: FeatureMesh) -> void:
	pass


## Point at lateral offset d of `smp`, relative to the build's anchor.
func local(smp: RoadSample, d: float) -> Vector3:
	return smp.local_point(d, anchor_x, anchor_y, anchor_z)


# ---------------------------------------------------------------- Internals

func _window(k: int, step: float) -> Vector3:
	var s_gen := road.length_generated()
	var lo := maxf(float(k) * step - road_tuning.roadside_behind_m, 0.0)
	var want_hi := float(k + 1) * step + view_distance_m()
	var hi := want_hi if is_inf(s_gen) else minf(want_hi, s_gen)
	return Vector3(lo, hi, 1.0 if hi < want_hi else 0.0)


func _set_anchor() -> void:
	anchor_x = origin.origin_x if origin != null else 0.0
	anchor_y = origin.origin_y if origin != null else 0.0
	anchor_z = origin.origin_z if origin != null else 0.0


func _build_now(k: int, step: float) -> void:
	var w := _window(k, step)
	_set_anchor()
	var fm := FeatureMesh.new()
	var n := _begin(w.x, w.y)
	for i in n:
		_emit(i, fm)
	_show(fm, k, w.x, w.y, w.z > 0.0)


func _advance_pending(step: float) -> void:
	var k := _shown_k + 1
	if _pending == null or _pending_k != k:
		var w := _window(k, step)
		_pending = FeatureMesh.new()
		_pending_k = k
		_pending_lo = w.x
		_pending_hi = w.y
		_pending_short = w.z > 0.0
		_set_anchor()
		_pending_units = _begin(w.x, w.y)
		_pending_next = 0
		_pending_ax = anchor_x
		_pending_ay = anchor_y
		_pending_az = anchor_z
	var budget := units_per_frame()
	_restore_pending_anchor()
	while budget > 0 and _pending_next < _pending_units:
		_emit(_pending_next, _pending)
		_pending_next += 1
		budget -= 1


func _restore_pending_anchor() -> void:
	anchor_x = _pending_ax
	anchor_y = _pending_ay
	anchor_z = _pending_az


func _finish_pending() -> void:
	_restore_pending_anchor()
	while _pending_next < _pending_units:
		_emit(_pending_next, _pending)
		_pending_next += 1
	var fm := _pending
	_pending = null
	_show(fm, _pending_k, _pending_lo, _pending_hi, _pending_short)


func _show(fm: FeatureMesh, k: int, lo: float, hi: float, short: bool) -> void:
	fm.commit(_mesh)
	_triangles = fm.triangle_count()
	_mesh_instance.visible = _triangles > 0
	_shown_k = k
	window_s_lo = lo
	window_s_hi = hi
	_short = short
	_shown_x = anchor_x
	_shown_y = anchor_y
	_shown_z = anchor_z
	_place_node()
	rebuilds += 1


## Node position = shown anchor - origin (64-bit subtraction first).
func _place_node() -> void:
	if _mesh_instance == null:
		return
	var ox := origin.origin_x if origin != null else 0.0
	var oy := origin.origin_y if origin != null else 0.0
	var oz := origin.origin_z if origin != null else 0.0
	_mesh_instance.position = Vector3(_shown_x - ox, _shown_y - oy, _shown_z - oz)
	_mesh_instance.reset_physics_interpolation()


func _connect() -> void:
	if _connected:
		return
	Events.origin_shifted.connect(_on_origin_shifted)
	Events.quality_changed.connect(_on_quality_changed)
	Events.governor_changed.connect(_on_governor_changed)
	_connected = true


func _disconnect() -> void:
	if not _connected:
		return
	Events.origin_shifted.disconnect(_on_origin_shifted)
	Events.quality_changed.disconnect(_on_quality_changed)
	Events.governor_changed.disconnect(_on_governor_changed)
	_connected = false


func _enter_tree() -> void:
	if road != null:
		_connect()


func _exit_tree() -> void:
	_disconnect()


func _on_origin_shifted(_offset: Vector3) -> void:
	_place_node()


func _on_quality_changed(_tier: StringName) -> void:
	_dirty = true


func _on_governor_changed(_rung: int) -> void:
	_dirty = true
