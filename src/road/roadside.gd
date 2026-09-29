class_name Roadside
extends Node3D
## The roadside: road furniture rhythm and biome scenery as pooled MultiMeshes.
## Spec: World → Road ("Roadside rhythm (all MultiMeshInstance3D): light poles
## every 50 m, reflector posts every 25 m, guardrail posts, sign gantries,
## billboards with invented brands, fences. This rhythm sells speed and is
## nearly free"), Biomes (farmland), Performance budget (draw calls ≤ 100,
## triangles ≤ 150k, view distance per tier), Architecture rule 6 (floating origin).
##
## World-system node (docs/CONTRACTS.md §13):
##   roadside.biome_director = director     # optional; else the default biome
##   roadside.setup(ctx, road, origin)
##   roadside.update_view(player_s)          # once per frame
##
## Layers (src/road/roadside/) own fixed pools, one MultiMeshInstance3D per
## mesh (one draw call each). The window [s - behind, s + view distance] moves
## in steps of `road.roadside_update_step_m`; only cells entering or leaving it
## are rewritten, and pools never grow after setup. Placement is by absolute s
## and the run's props stream (per layer, cell and side), so it is the same
## however the player drove. On `Events.origin_shifted` the pool nodes move;
## each layer re-anchors on a later frame (one layer per frame) by translating
## its instances, so nothing is re-placed.
##
## Landmark clearance (WP5.5): no prop stands in a checkpoint landmark or warning sign
## (the median light poles at the toll and sign gantries and through the tunnel, posts,
## fences, fields, billboards and gantries at the booths, towers and tunnel hill). The
## zones come from a LandmarkClearance built at setup from the road features, the
## biome director and LandmarkTuning (the same inputs as Landmarks), prepared for the
## window whenever it moves; each layer skips the instances that fall in one.
##
## Water (WP6.4c): no billboard, gantry or prop stands over the coast's sea slope or a
## river's water on the water's side (RoadsideContext.water_blocks, from the same
## WaterPlan as the WaterRibbon: the props seed's "water" stream and the biome lookup).

const LIGHT_POLE_MESH := "res://assets/props/common/light_pole.res"
const REFLECTOR_POST_MESH := "res://assets/props/common/reflector_post.res"
const GUARDRAIL_POST_MESH := "res://assets/props/common/guardrail_post.res"
const SIGN_GANTRY_MESH := "res://assets/props/common/sign_gantry.res"
const BILLBOARD_MESHES: PackedStringArray = [
	"res://assets/props/common/billboard_sundog.res",
	"res://assets/props/common/billboard_mesa_cola.res",
	"res://assets/props/common/billboard_coyote_motel.res",
]
## Stream name under RunContext.rng_props.
const RNG_STREAM := &"roadside"

## Set before setup to follow legs/forks; null = every cell is `fallback_biome`.
var biome_director: BiomeDirector
## Used without a director (loaded from BiomeDirector.DEFAULT_BIOME_PATH if null).
var fallback_biome: BiomeDef
## > 0 overrides Quality.view_distance_m (previews, tests).
var view_distance_override_m: float = 0.0
## Keep props out of the landmarks' zones (false: place everything, as before WP5.5).
var clear_landmarks: bool = true
## Previews that force one landmark style (Landmarks.style_override) set the same here.
var landmark_style_override: StringName = &""
## The zones in use (built at setup when clear_landmarks; null otherwise).
var landmark_clearance: LandmarkClearance
## Keep every prop off the biome water on its side (WP6.4c; false: as before).
var clear_water: bool = true

var layers: Array[RoadsideLayer] = []

var _ctx: RoadsideContext
var _origin: FloatingOrigin
var _tuning: RoadTuning
var _quality: QualityTuning
var _max_view_m: float = 0.0
var _max_cell_m: float = 0.0
var _step_index: int = 0
var _refresh: bool = true
var _connected: bool = false
## Window of the last update (tests, previews).
var window_s_lo: float = 0.0
var window_s_hi: float = 0.0


func setup(ctx: RunContext, road: RoadPath, origin: FloatingOrigin) -> void:
	_teardown()
	_tuning = ctx.tuning.road
	_quality = ctx.tuning.quality
	_origin = origin
	if fallback_biome == null:
		fallback_biome = load(BiomeDirector.DEFAULT_BIOME_PATH) as BiomeDef
	var seed_value := ctx.rng_props.derive(RNG_STREAM).get_seed()
	_ctx = RoadsideContext.new(road, _tuning, seed_value, biome_director, fallback_biome)
	_max_view_m = maxf(view_distance_override_m, _max_quality_view_m())
	landmark_clearance = null
	if clear_landmarks:
		landmark_clearance = LandmarkClearance.new()
		var lt: Variant = ctx.tuning.get(&"landmarks")
		landmark_clearance.setup(road, lt as LandmarkTuning if lt is LandmarkTuning else LandmarkTuning.load_default(),
			biome_director, landmark_style_override)
	_ctx.clearance = landmark_clearance
	# Nothing stands over the biome water (WP6.4c): the WaterRibbon's plan, same inputs.
	var lookup := biome_director.biome_at if biome_director != null else Callable()
	_ctx.water = WaterPlan.new(ctx.rng_props.derive(WaterRibbon.STREAM).get_seed(), lookup, fallback_biome) \
		if clear_water else null
	_build_layers()
	_max_cell_m = 0.0
	for layer in layers:
		_max_cell_m = maxf(_max_cell_m, layer.cell_length_m)
	var window_max := _tuning.roadside_behind_m + _tuning.roadside_update_step_m + _max_view_m
	for layer in layers:
		layer.build(self, window_max)
		layer.set_anchor(origin.origin_x, origin.origin_y, origin.origin_z, origin)
	_refresh = true
	_connect()


## Once per frame with the focus (player) s. Rewrites cells only when the
## window advances a step; re-anchors at most one layer per call after a shift.
func update_view(focus_s: float) -> void:
	if _ctx == null:
		return
	var step := _tuning.roadside_update_step_m
	var k := int(floor(focus_s / step))
	if k != _step_index or _refresh:
		_step_index = k
		_refresh = false
		var q := float(k) * step
		window_s_lo = q - _tuning.roadside_behind_m
		window_s_hi = q + step + minf(view_distance_m(), _max_view_m)
		var s_gen := _ctx.road.length_generated()
		if landmark_clearance != null:
			# Cells reach up to one cell length past the window.
			landmark_clearance.prepare(maxf(window_s_lo - _max_cell_m, 0.0), window_s_hi + _max_cell_m)
		for layer in layers:
			layer.update_window(window_s_lo, window_s_hi, s_gen)
	for layer in layers:
		if layer.needs_rebase:
			layer.rebase(_origin)
			break
	for layer in layers:
		layer.flush()


## Current view distance: the override, else the Quality tier (+ governor).
func view_distance_m() -> float:
	if view_distance_override_m > 0.0:
		return view_distance_override_m
	var q: float = Quality.view_distance_m
	if q > 0.0:
		return q
	var i := maxi(_quality.tier_names.find(String(_quality.default_tier)), 0)
	return _quality.view_distance_m[i]


# ---------------------------------------------------------------- Stats (dev HUD, previews, tests)

## MultiMeshInstance3D nodes with instances (one draw call each).
func draw_calls() -> int:
	var n := 0
	for layer in layers:
		for pool in layer.pools:
			if pool.count > 0:
				n += 1
	return n


func triangles() -> int:
	var n := 0
	for layer in layers:
		for pool in layer.pools:
			n += pool.count * pool.triangles_per_instance
	return n


func instance_count() -> int:
	var n := 0
	for layer in layers:
		n += layer.instance_count()
	return n


## Instances skipped so far for the landmarks' clearance.
func cleared_count() -> int:
	var n := 0
	for layer in layers:
		n += layer.cleared
	return n


func pool_count() -> int:
	var n := 0
	for layer in layers:
		n += layer.pools.size()
	return n


## How far behind the focus layers may sample the road (window + one cell).
## The run keeps the road generated from `focus_s - reach_behind_m()`.
func reach_behind_m() -> float:
	var m := 0.0
	for layer in layers:
		m = maxf(m, layer.cell_length_m)
	return _tuning.roadside_behind_m + m


func find_layer(layer_id: StringName) -> RoadsideLayer:
	for layer in layers:
		if layer.id == layer_id:
			return layer
	return null


# ---------------------------------------------------------------- Internals

func _build_layers() -> void:
	var t := _tuning
	# Median-mounted twin-arm poles light both carriageways (one instance per 50 m).
	layers.append(RhythmLayer.new(_ctx, &"light_pole", t.light_pole_spacing_m, load(LIGHT_POLE_MESH),
		RhythmLayer.Edge.REFERENCE, 0.0, false))
	layers.append(RhythmLayer.new(_ctx, &"reflector_post", t.reflector_post_spacing_m, load(REFLECTOR_POST_MESH),
		RhythmLayer.Edge.GUARDRAIL, t.reflector_post_offset_m, true))
	layers.append(RhythmLayer.new(_ctx, &"guardrail_post", t.guardrail_post_spacing_m, load(GUARDRAIL_POST_MESH),
		RhythmLayer.Edge.GUARDRAIL, t.guardrail_post_offset_m, true))
	layers.append(GantryLayer.new(_ctx, load(SIGN_GANTRY_MESH)))
	layers.append(ScatterLayer.new(_ctx, _billboard_prop(), _load_meshes(BILLBOARD_MESHES)))
	var biomes: Array[BiomeDef] = [fallback_biome]
	if biome_director != null:
		biomes = biome_director.biomes()
	for b in biomes:
		_build_biome_layers(b)


func _build_biome_layers(b: BiomeDef) -> void:
	var prefix := String(b.id) + "/"
	if b.fence_mesh_path != "":
		var fence: Mesh = load(b.fence_mesh_path)
		var length := float(fence.get_meta(&"length_m", 1.0))
		var layer := RhythmLayer.new(_ctx, StringName(prefix + "fence"), length, fence,
			RhythmLayer.Edge.SCENERY, b.fence_setback_m, true, true)
		_add_biome_layer(layer, b)
	if b.field_grid != null:
		var g := b.field_grid
		_add_biome_layer(FieldGridLayer.new(_ctx, StringName(prefix + "fields"), g,
			_load_meshes(g.crop_mesh_paths), _load_meshes(g.yard_mesh_paths), _load_meshes(g.tree_mesh_paths)), b)
	for p in b.scatter_props:
		var def: RoadsideProp = p.duplicate()
		def.id = StringName(prefix + String(p.id))
		_add_biome_layer(ScatterLayer.new(_ctx, def, _load_meshes(p.mesh_paths)), b)


func _add_biome_layer(layer: RoadsideLayer, b: BiomeDef) -> void:
	layer.biome = b
	layers.append(layer)


## Billboards come from road tuning (a RoadsideProp built once at setup).
func _billboard_prop() -> RoadsideProp:
	var t := _tuning
	var p := RoadsideProp.new()
	p.id = &"billboard"
	p.pattern = RoadsideProp.Pattern.SCATTER
	p.cell_length_m = t.billboard_cell_length_m
	p.density_per_km = Units.km_to_m(1.0) / t.billboard_mean_spacing_m
	p.setback_min_m = t.billboard_setback_min_m
	p.setback_max_m = t.billboard_setback_max_m
	p.facing = RoadsideProp.Facing.ROAD
	p.yaw_offset_deg = t.billboard_toe_in_deg
	return p


func _load_meshes(paths: PackedStringArray) -> Array[Mesh]:
	var out: Array[Mesh] = []
	if paths.is_empty():
		# An empty list in data means the export dropped it (see project.godot [editor]).
		push_warning("Roadside: a prop layer has no mesh paths; it will draw nothing")
	for path in paths:
		var m: Mesh = load(path)
		if m == null:
			push_error("Roadside: cannot load mesh %s" % path)
			continue
		out.append(m)
	return out


func _max_quality_view_m() -> float:
	var m := 0.0
	for v in _quality.view_distance_m:
		m = maxf(m, v)
	return m


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


func _teardown() -> void:
	_disconnect()
	for layer in layers:
		for pool in layer.pools:
			if pool.mmi != null:
				pool.mmi.queue_free()
	layers.clear()
	_ctx = null


func _enter_tree() -> void:
	if _ctx != null:
		_connect()


func _exit_tree() -> void:
	_disconnect()


func _on_origin_shifted(_offset: Vector3) -> void:
	for layer in layers:
		layer.place_nodes(_origin)
		layer.needs_rebase = true


func _on_quality_changed(_tier: StringName) -> void:
	_refresh = true


func _on_governor_changed(_rung: int) -> void:
	_refresh = true
