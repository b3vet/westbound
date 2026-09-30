class_name WaterRibbon
extends BiomeFeature
## The ocean beside the coastal highway and the valley's river glimpses: a faceted,
## animated water strip following the road on one side, with a beach / bank strip and
## surf. Spec: World → Biomes ("Coastal highway: ocean on one side, cliffs ...; the
## sun sinks into the sea"; valley river glimpses), Color script (the sky and sun
## colors reflect through the shared world shading: no real reflections), Performance
## budget (one draw call, vertex-lit custom shader). Data: BiomeDef.water (WaterDef),
## placement: WaterPlan. Shader: assets/shaders/water.gdshader.
##
##   water.biome_director = director
##   water.horizon_material = sky_horizon_material   # optional: sea-side horizon mask
##   water.setup(ctx, road, origin); water.update_view(player_s)
##
## Mesh (windows per `WaterDef.rebuild_step_m`, see BiomeFeature): rows every
## `row_step_m` at absolute multiples of it. Flat water: a shore strip, the water from
## the waterline out to `width_m` in growing columns, an optional far bank. Sea slopes
## (`drop_m` > 0): a road-level strip, the craggy slope down to the sea level, the
## beach, the sea. Rows join only when both have water from the same WaterDef. Islets
## (sea stacks, the lighthouse) are copied in per islet cell. Vertex channels for
## water.gdshader: COLOR.rgb albedo (sRGB), COLOR.a water weight (1 water, 0 land),
## UV.x distance from the waterline (m), UV2.x the wave phase (water; hashed from the
## absolute row and column) or the emissive class (land).
##
## `ground_drop_at(s, side)` is the road mesher hook (GroundDropMesher.field_drop_at):
## the ground ribbon must lie below the sea on a sea slope's side.

const MATERIAL_PATH := "res://assets/shaders/materials/water.tres"
## Props sub-stream (feature_id): Roadside derives the same WaterPlan from it.
const STREAM := &"water"
## Horizon shader parameter that receives the sea direction (horizon.gdshader).
const SEA_DIR_PARAM := &"sea_dir"
const _PHASE_SALT := 0x5A17
const SLOPE_SALT := 0xC11F
const ISLET_SALT := 0x151E
## Slope breaks (fraction of the run, fraction of the drop): gentle and scrubby near
## the road, steep and rocky above the beach.
const SLOPE_BREAKS: Array[Vector2] = [Vector2(0.35, 0.18), Vector2(0.72, 0.52)]
## Slope vertices per row: edge, the breaks, foot.
const SLOPE_VERTS := 4
## Road samples averaged for the sea level.
const LEVEL_SAMPLES := 9
## Probe spacing (in roadside steps) when looking ahead for water.
const NEAREST_PROBE_STEPS := 4

## Optional: the sky's horizon material (horizon.gdshader, SkyRig.horizon_material()); its `sea_dir`
## follows the water's side and the road heading ahead of the focus.
var horizon_material: ShaderMaterial
## How far ahead of the focus the road heading sets the sea direction.
var sea_dir_ahead_m: float = 300.0

var plan: WaterPlan
## The water def whose uniforms are in use: at the focus, else the nearest ahead.
var _focus_def: WaterDef
var _material_instance: ShaderMaterial
var _smp := RoadSample.new()
var _lvl := RoadSample.new()
var _sea_dir := Vector2.ZERO
var _uniform_def: WaterDef
var _time_s: float = 0.0
# Build state (one build at a time: see BiomeFeature).
var _row_step_m: float = 0.0
var _r0: int = 0
var _n_rows: int = 0
var _b_lo: float = 0.0
var _b_hi: float = 0.0
var _islet_c0: int = 0
var _n_islet_cells: int = 0
var _islet_cell_m: float = 0.0
## Islet meshes' arrays, by path (loaded once).
var _islet_arrays: Dictionary = {}
var _prev_def: WaterDef
var _prev := PackedInt32Array()
var _cur := PackedInt32Array()
var _cols := PackedFloat64Array()
var _cols_def: WaterDef


func feature_id() -> StringName:
	return STREAM


func step_m() -> float:
	return _focus_def.rebuild_step_m if _focus_def != null else last_step_m()


func units_per_frame() -> int:
	return _focus_def.build_units_per_frame if _focus_def != null else super()


func _material() -> Material:
	if _material_instance == null:
		_material_instance = (load(MATERIAL_PATH) as ShaderMaterial).duplicate() as ShaderMaterial
	return _material_instance


func _reach_behind_for(b: BiomeDef) -> float:
	return b.water.rebuild_step_m + b.water.level_smoothing_m if b.water != null else 0.0


func _on_setup() -> void:
	var lookup := Callable()
	if biome_director != null:
		lookup = biome_director.biome_at
	plan = WaterPlan.new(props_seed, lookup, fallback_biome)
	if biome_director != null:
		plan.add_fork_spans(road, biome_director.biomes())   # WP6.5: no water across a fork


func update_view(focus_s: float) -> void:
	if road == null:
		return
	_focus_def = _nearest_def(focus_s)
	_apply_uniforms(_focus_def)
	super(focus_s)
	_update_sea_dir(focus_s)


func _process(delta: float) -> void:
	_time_s += delta
	if _material_instance != null:
		_material_instance.set_shader_parameter(&"time_s", _time_s)


## Sets the wave clock (snaps and parity use a fixed value).
func set_time(t: float) -> void:
	_time_s = t
	if _material_instance != null:
		_material_instance.set_shader_parameter(&"time_s", _time_s)


## World XZ unit vector toward the sea (Vector2.ZERO without ocean-like water).
func sea_dir() -> Vector2:
	return _sea_dir


## The water def at s, else the first one ahead within the view (coarse probes).
func _nearest_def(s: float) -> WaterDef:
	if plan == null:
		return null
	var probe := road_tuning.roadside_update_step_m * float(NEAREST_PROBE_STEPS)
	var x := 0.0
	var view := view_distance_m()
	while x <= view:
		var d := plan.def_at(s + x)
		if d != null:
			return d
		x += probe
	return null


func _apply_uniforms(def: WaterDef) -> void:
	if def == null or def == _uniform_def or _material_instance == null:
		return
	_uniform_def = def
	var m := _material_instance
	m.set_shader_parameter(&"wave_height_m", def.wave_height_m)
	m.set_shader_parameter(&"wave_ramp_m", def.wave_ramp_m)
	m.set_shader_parameter(&"wave_period_s", def.wave_period_s)
	m.set_shader_parameter(&"sky_reflect", def.sky_reflect_factor)
	m.set_shader_parameter(&"sun_path_gain", def.sun_path_gain)
	m.set_shader_parameter(&"depth_pull_frac", def.depth_pull_frac)


func _update_sea_dir(focus_s: float) -> void:
	var def := _focus_def
	var dir := Vector2.ZERO
	if def != null:
		road.sample_into(minf(focus_s + sea_dir_ahead_m, road.length_generated()), _smp)
		dir = Vector2(_smp.right.x, _smp.right.z).normalized() * float(signi(def.side))
	if dir == _sea_dir:
		return
	_sea_dir = dir
	if horizon_material != null:
		horizon_material.set_shader_parameter(SEA_DIR_PARAM, _sea_dir)


# ---------------------------------------------------------------- Build

## Units: the rows, then the islet cells of the window.
func _begin(s_lo: float, s_hi: float) -> int:
	_row_step_m = _row_step(s_lo)
	_r0 = int(floor(s_lo / _row_step_m))
	_b_lo = s_lo
	_b_hi = s_hi
	_prev_def = null
	_prev.clear()
	_cols_def = null
	_n_rows = maxi(int(ceil(s_hi / _row_step_m)) - _r0 + 1, 0)
	_n_islet_cells = 0
	var idef := _focus_def if _focus_def != null else (fallback_biome.water if fallback_biome != null else null)
	if idef != null and idef.islet_chance_frac > 0.0 and idef.islet_cell_m > 0.0:
		_islet_c0 = int(floor(s_lo / idef.islet_cell_m))
		_n_islet_cells = maxi(int(floor(s_hi / idef.islet_cell_m)) - _islet_c0 + 1, 0)
		_islet_cell_m = idef.islet_cell_m
	return _n_rows + _n_islet_cells


## Unit i = one row (at absolute multiples of the row step; the last one at s_hi), or
## one islet cell.
func _emit(i: int, out: FeatureMesh) -> void:
	if i >= _n_rows:
		_islet(out, _islet_c0 + i - _n_rows)
		return
	var r := _r0 + i
	var s := minf(float(r) * _row_step_m, _b_hi)
	var def := plan.def_at(s)
	var off := plan.shore_offset_at(s) if def != null else WaterPlan.NONE
	_cur.clear()
	if def != null and off >= 0.0:
		if def != _cols_def:
			_cols = def.water_columns()
			_cols_def = def
		road.sample_into(s, _smp)
		_row(out, def, _cols, r, off, _cur)
		if def == _prev_def and _prev.size() == _cur.size():
			_join(out, _prev, _cur, def)
	else:
		def = null
	_prev_def = def
	_prev.resize(_cur.size())
	for k in _cur.size():
		_prev[k] = _cur[k]


func _row_step(s: float) -> float:
	var def := plan.def_at(s)
	if def == null:
		def = _focus_def
	if def == null and fallback_biome != null:
		def = fallback_biome.water
	return def.row_step_m if def != null else road_tuning.roadside_update_step_m


## Strip sizes of a row for `def`, in vertex order: sea slopes [strip 2, slope 4,
## beach 2, water n]; flat water [shore 2, water n, far bank 2].
func _strip_sizes(def: WaterDef, n_cols: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if def.drop_m > 0.0:
		out.append_array(PackedInt32Array([2, SLOPE_VERTS]))
	if def.shore_width_m > 0.0:
		out.append(2)
	out.append(n_cols)
	if def.drop_m <= 0.0 and def.far_bank_width_m > 0.0:
		out.append(2)
	return out


## One row's vertices in strip order (see _strip_sizes); indices go to `idx`.
func _row(out: FeatureMesh, def: WaterDef, cols: PackedFloat64Array, r: int, off: float,
		idx: PackedInt32Array) -> void:
	var side := float(signi(def.side))
	var line := road.guardrail_d(_smp.s) + road_tuning.prop_clearance_m
	var up := _smp.up
	var shore0 := line + off
	# Water level of this row, relative to the build anchor; flat water rides the road.
	var level := Vector3.UP * def.lift_m
	var water0 := shore0 + def.shore_width_m
	if def.drop_m > 0.0:
		var top := Vector3.UP * def.top_lift_m
		var sea_y := sea_level_at(_smp.s, def)
		level = Vector3.UP * (sea_y - _smp.pos_y + def.lift_m)
		var top_col := def.top_color
		top_col.a = 0.0
		idx.append(out.vertex(local(_smp, side * line) + top, up, top_col))
		idx.append(out.vertex(local(_smp, side * shore0) + top, up, top_col))
		# The slope: edge (scrub), two craggy breaks, foot at the sea.
		var rock := def.cliff_color
		rock.a = 0.0
		var dark := def.cliff_dark_color
		dark.a = 0.0
		idx.append(out.vertex(local(_smp, side * shore0) + top, up, top_col))
		for k in SLOPE_BREAKS.size():
			var brk: Vector2 = SLOPE_BREAKS[k]
			var jag := def.slope_jag_m * (_hash01(r, SLOPE_SALT + k) - 0.5) * 2.0
			idx.append(out.vertex(local(_smp, side * (shore0 + def.slope_run_m * brk.x + jag)) + level * brk.y, up,
				rock if k == 0 else dark))
		var foot := shore0 + def.slope_run_m
		idx.append(out.vertex(local(_smp, side * foot) + level, up, dark))
		shore0 = foot
		water0 = foot + def.shore_width_m
	if def.shore_width_m > 0.0:
		var shore := def.shore_color
		shore.a = 0.0
		for x: float in [shore0, water0]:
			idx.append(out.vertex(local(_smp, side * x) + level, up, shore))
	for c in cols.size():
		var x := cols[c]
		idx.append(out.vertex(local(_smp, side * (water0 + x)) + level, up, _water_color(def, x),
			Vector2(x, 0.0), Vector2(_phase(r, c), 0.0)))
	if def.drop_m <= 0.0 and def.far_bank_width_m > 0.0:
		var bank := def.far_bank_color
		bank.a = 0.0
		var b0 := water0 + def.width_m
		for x: float in [b0, b0 + def.far_bank_width_m]:
			idx.append(out.vertex(local(_smp, side * x) + level, up, bank))


## Quads between two rows' strips (never across strip boundaries).
func _join(out: FeatureMesh, a: PackedInt32Array, b: PackedInt32Array, def: WaterDef) -> void:
	var sizes := _strip_sizes(def, a.size() - _fixed_verts(def))
	var start := 0
	for k in sizes.size():
		for i in range(start, start + sizes[k] - 1):
			out.quad_idx(a[i], a[i + 1], b[i + 1], b[i], Vector3.UP)
		start += sizes[k]


## Vertices per row outside the water columns.
func _fixed_verts(def: WaterDef) -> int:
	var n := 0
	if def.drop_m > 0.0:
		n += 2 + SLOPE_VERTS
	if def.shore_width_m > 0.0:
		n += 2
	if def.drop_m <= 0.0 and def.far_bank_width_m > 0.0:
		n += 2
	return n


# ---------------------------------------------------------------- Sea level

## Absolute sea level at s for a cliff coast: the road's elevation averaged over
## +-level_smoothing_m (LEVEL_SAMPLES samples), minus drop_m, and at least min_drop_m
## below the road at s. A pure function of s: continuous across windows and shifts.
##
## The road is generated to s + level_smoothing_m first (director rate; the table does
## not depend on how far it goes), so the level never depends on how far the road
## happened to be generated. Behind, the samples need the road kept from
## s - level_smoothing_m (the run retains it: BiomeFeatures.reach_behind_m); anything
## forgotten clamps to the first retained s.
func sea_level_at(s: float, def: WaterDef) -> float:
	if road.length_generated() < s + def.level_smoothing_m:
		road.ensure_generated_to(s + def.level_smoothing_m)
	var s_gen := road.length_generated()
	var s_min := 0.0
	if road is ProceduralRoadPath:
		s_min = (road as ProceduralRoadPath).first_retained_s()
	var sum := 0.0
	for k in LEVEL_SAMPLES:
		var t := float(k) / float(LEVEL_SAMPLES - 1) * 2.0 - 1.0
		var sk := clampf(s + t * def.level_smoothing_m, s_min, s_gen)
		road.sample_into(sk, _lvl)
		sum += _lvl.pos_y
	road.sample_into(minf(s, s_gen), _lvl)
	return minf(sum / float(LEVEL_SAMPLES) - def.drop_m, _lvl.pos_y - def.min_drop_m)


## How far the road mesher must lower the ground ribbon beyond the scenery line on
## `side` (-1 / +1) at s: below the sea where a cliff coast runs, else 0. The hook for
## RoadChunkMesher (GroundDropMesher.field_drop_at).
func ground_drop_at(s: float, side: float) -> float:
	if plan == null:
		return 0.0
	var def := plan.def_at(s)
	if def == null or def.drop_m <= 0.0 or signf(side) != float(signi(def.side)):
		return 0.0
	# Continuous water (no river cells) is present wherever its def is.
	if def.span_cell_m > 0.0 and plan.shore_offset_at(s) < 0.0:
		return 0.0
	road.sample_into(minf(s, road.length_generated()), _lvl)
	return _lvl.pos_y - sea_level_at(s, def) + def.lift_m


## Islet cell c: with the def's chance, one islet mesh in the sea (at the sea level,
## `islet_offset` beyond the waterline), copied into the water mesh (non-water
## vertices: COLOR.a = 0, UV2.x = the mesh's emissive class).
func _islet(out: FeatureMesh, c: int) -> void:
	var s := (float(c) + _hash01(c, ISLET_SALT + 1)) * _islet_cell_m
	if s < _b_lo or s > _b_hi:
		return
	var def := plan.def_at(s)
	if def == null or def.islet_mesh_paths.is_empty() or _hash01(c, ISLET_SALT) >= def.islet_chance_frac:
		return
	var off := plan.shore_offset_at(s)
	if off < 0.0:
		return
	road.sample_into(s, _smp)
	var side := float(signi(def.side))
	var line := road.guardrail_d(s) + road_tuning.prop_clearance_m
	var run := def.slope_run_m if def.drop_m > 0.0 else 0.0
	var dist := lerpf(def.islet_offset_min_m, def.islet_offset_max_m, _hash01(c, ISLET_SALT + 2))
	var d := side * (line + off + run + def.shore_width_m + dist)
	var y := sea_level_at(s, def) - _smp.pos_y if def.drop_m > 0.0 else 0.0
	var k := _pick(def.islet_weights, def.islet_mesh_paths.size(), _hash01(c, ISLET_SALT + 3))
	var arrays := _islet_mesh(def.islet_mesh_paths[k])
	if arrays.is_empty():
		return
	var k_scale := lerpf(def.islet_scale_min_factor, def.islet_scale_max_factor, _hash01(c, ISLET_SALT + 4))
	var rot := Basis(Vector3.UP, TAU * _hash01(c, ISLET_SALT + 5)).scaled(Vector3.ONE * k_scale)
	var xf := Transform3D(rot, local(_smp, d) + Vector3.UP * y)
	out.append_arrays(arrays, xf)


## Index for a uniform draw `u` in [0, 1) by weights (empty = uniform).
static func _pick(weights: PackedFloat64Array, n: int, u: float) -> int:
	if weights.size() != n:
		return mini(int(u * float(n)), n - 1)
	var total := 0.0
	for w in weights:
		total += w
	var x := u * total
	for i in n:
		x -= weights[i]
		if x < 0.0:
			return i
	return n - 1


func _islet_mesh(path: String) -> Array:
	if not _islet_arrays.has(path):
		var m := load(path) as Mesh
		_islet_arrays[path] = m.surface_get_arrays(0) if m != null else []
	return _islet_arrays[path]


func _hash01(r: int, salt: int) -> float:
	var h := TraceHash.mix_int(TraceHash.mix_int(salt, r), props_seed)
	return float(h & WaterPlan._MASK31) * WaterPlan._INV_2_31


func _water_color(def: WaterDef, x: float) -> Color:
	var c: Color
	if x <= 0.0:
		c = def.foam_color
	elif x <= def.surf_width_m:
		c = def.shallow_color
	else:
		var t := clampf((x - def.surf_width_m) / maxf(def.deep_distance_m, 1.0), 0.0, 1.0)
		c = def.shallow_color.lerp(def.deep_color, t)
	c.a = 1.0
	return c


## Wave phase of absolute row r, column c: stable across rebuilds and origin shifts.
func _phase(r: int, c: int) -> float:
	var h := TraceHash.mix_int(TraceHash.mix_int(_PHASE_SALT, r), c)
	return float(h & WaterPlan._MASK31) * WaterPlan._INV_2_31 * TAU
