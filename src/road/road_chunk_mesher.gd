class_name RoadChunkMesher
extends RefCounted
## Pure mesh generation for one road chunk: RoadPath + [s0, s1] -> two surfaces of
## vertex arrays. Spec: World → Road (layout, ribbon chunks, markings), Performance
## budget (vertex-lit, few draw calls), Architecture rule 6 (floating origin).
## See docs/CONTRACTS.md §2 (cross-section), §13 (vertex conventions, materials).
##
## Surfaces (one draw call each):
##   SURFACE_ROAD  (materials/road.tres):  lanes and shoulders (tint class 1), lane and
##                 edge lines as geometry (tint class 2), raised reflectors (emissive 1).
##   SURFACE_WORLD (materials/world.tres): median barrier, guardrail rails, ground ribbon.
## Both carriageways are built; the opposite one is mirrored at d < 0.
## With `merge_surfaces` (RoadBuilder, WP4.6), commit_merged() writes both as ONE
## surface (one draw call per chunk): road.gdshader and world.gdshader are the same
## code, so the pixels do not change. The output arrays stay split either way; only
## the world indices are offset past the road vertices while merging.
##
## Precision: vertices are relative to the chunk's anchor (the reference line at s0),
## computed in 64-bit (RoadSample.local_point) before narrowing, so a chunk 5,000 km
## out is as exact as one at the start. The node goes at FloatingOrigin.to_local(anchor).
##
## Rows: every chunk row is a full cross-section at one s. Rows fall on every dash
## boundary (dash phase from absolute s, so dashes continue across chunks and origin
## shifts), at most `mesh_max_step_m` apart, and on s0 and s1 exactly (so neighbouring
## chunks share their boundary row: no seams). Lane lines are strips of the road
## surface itself (never overlaid), so there is no z-fighting at any distance.
##
## Lane-count changes: the right lane edge follows a smoothstep taper over each
## LANE_COUNT_CHANGE feature (or `lane_taper_length_m` after a bare lane_count(s)
## step). The strip layout per chunk is fixed (`lane_slots`); strips beyond the edge
## collapse onto it, so the surface has no gaps. A dashed line is drawn only while it
## lies fully inside the tapering edge line.
##
## Ground blending (WP6.4a): the verge and field colours (and the tunnel hill's rock)
## go from the palette's start value at s0 to its `_end` value at s1, per row, so a
## biome transition blends smoothly across chunks (RoadBuilder sets both from the
## biome director at s0 and s1).
##
## Road tunnels (WP6.4a): every TUNNEL feature gets a road-following shell built into
## the world surface (no extra draw call): the outer walls beyond the guardrails, a
## central wall on the median (twin bores), the roof, lamp strips on the walls
## (emissive class 2, the street-lamp ramp, every LandmarkTuning.tunnel_lamp_spacing_m),
## the hill over it (rock top and slopes) with hipped ends and wing walls beyond both
## portals, and a portal face at each end. Inside, the road, barrier, rails and walls
## are darkened (RoadTuning.tunnel_interior_shade_frac). The shell's dimensions are
## the landmark tunnel's (LandmarkTuning.tunnel_*, LandmarkBuilds' hill proportions),
## so LandmarkClearance's road-tunnel zones match it. Rows fall on every portal and
## hip end.
##
## Cliffs (WP6.4a, canyon): where the biome at a row has a CliffDef (`biome_plan`),
## rock walls are built into the world surface on both sides beyond the scenery line,
## like the guardrails: per row a jittered cross-section profile in strata colours,
## present in seeded runs (`cliff_seed`), rising and falling at run ends and cleared
## around checkpoints and their warning signs (CliffDef). No extra draw call.
##
## Allocation: arrays are reused. They are resized to the exact size of each build
## (Godot keeps power-of-two capacity, so steady-state builds reuse the buffers).

const SURFACE_ROAD := 0
const SURFACE_WORLD := 1

## §13 vertex classes (UV2.x emissive, UV2.y tint).
const EMISSIVE_NONE := 0.0
const EMISSIVE_REFLECTOR := 1.0
const EMISSIVE_STREETLAMP := 2.0
const TINT_NONE := 0.0
const TINT_ROAD := 1.0
const TINT_LINE := 2.0

## Rows closer than this are merged (float noise at dash boundaries).
const ROW_EPS_M := 1e-4  # lint: allow-number numeric tolerance, not a tuning value
## How far before a taper feature's start the "old" lane count is read.
const TAPER_PROBE_M := 0.01  # lint: allow-number numeric tolerance, not a tuning value
## Bisection steps to locate a bare lane_count step (150 m / 2^24 ~ 10 um).
const LANE_STEP_BISECT := 24
## Quads per row interval on the world surface: barrier 5, per side rail 3 + ground 2.
const BARRIER_PANELS := 5
const RAIL_QUADS := 3
const GROUND_QUADS := 2
const WORLD_QUADS_PER_INTERVAL := BARRIER_PANELS + 2 * (RAIL_QUADS + GROUND_QUADS)
const REFLECTOR_QUADS := 5
const ROW_CAPACITY := 64
## Road tunnels, quads: per interval inside (per side: wall, central wall, roof, hill
## top, two slopes), per hip interval (per side: two slopes, wing wall), per portal
## face (per side: band, wing, two chamfers; plus the pier), per lamp station (the
## outer and central wall of each carriageway).
const TUNNEL_QUADS_PER_INTERVAL := 12
const HIP_QUADS_PER_INTERVAL := 6
const PORTAL_QUADS := 9
const LAMP_QUADS := 4
const INTERVAL_OPEN := 0
const INTERVAL_TUNNEL := 1
const INTERVAL_HIP := 2
## The central wall stands just inside the median barrier's base; the lamps sit just
## proud of the walls; the portal's opening has chamfered top corners. Placeholder-art
## proportions shared with LandmarkBuilds' tunnel.
const PIER_INSET_M := 0.05
const LAMP_PROUD_M := 0.04
const LAMP_TOP_BELOW_M := 0.6
const LAMP_BOTTOM_BELOW_M := 0.9
## Noise channel of the cliffs' per-row lateral wobble (height channels are 1..).
const CLIFF_NOISE_LATERAL := 0
## The ridge over a bore lifts the hill's knee by this share of its height.
const HIP_RIDGE_MID_FRAC := 0.6

var tuning: RoadTuning
var palette: RoadPalette
## Biome per row for cliffs (null: no cliffs). RoadBuilder sets the director's plan.
var biome_plan: BiomePlan
## Seed of the cliff runs and facets (RoadBuilder: the run's props stream).
var cliff_seed: int = 0
## Road tunnel shell dimensions (tunnel_clearance_m, _wall_offset_m, _cover_top_m,
## _hill_width_m, _lamp_spacing_m).
var landmark_tuning: LandmarkTuning
## Build for commit_merged(): world indices continue after the road vertices. Set
## before begin().
var merge_surfaces: bool = false

# ---------------------------------------------------------------- Output (read after build)

var road_vertices := PackedVector3Array()
var road_normals := PackedVector3Array()
var road_colors := PackedColorArray()
var road_uv2 := PackedVector2Array()
var road_indices := PackedInt32Array()
var world_vertices := PackedVector3Array()
var world_normals := PackedVector3Array()
var world_colors := PackedColorArray()
var world_uv2 := PackedVector2Array()
var world_indices := PackedInt32Array()

## The chunk's anchor: absolute 64-bit reference-line position at s0.
var anchor_x: float = 0.0
var anchor_y: float = 0.0
var anchor_z: float = 0.0
var chunk_s0: float = 0.0
var chunk_s1: float = 0.0
## Lane slots in this chunk's strip layout (max lane count over the chunk).
var lane_slots: int = 0
var row_count: int = 0
## Raised reflectors in this chunk (both carriageways).
var reflector_count: int = 0
## Road-surface quads per row interval (both sides), excluding reflectors.
var road_quads_per_interval: int = 0

# ---------------------------------------------------------------- Scratch (reused)

var _row_s := PackedFloat64Array()
var _row_p := PackedVector3Array()
var _row_right := PackedVector3Array()
var _row_up := PackedVector3Array()
var _row_barrier := PackedFloat64Array()
var _row_left := PackedFloat64Array()
var _row_edge := PackedFloat64Array()
var _row_outer := PackedFloat64Array()
var _row_guard := PackedFloat64Array()
var _row_lanes := PackedFloat64Array()
var _row_width := PackedFloat64Array()
var _row_tangent := PackedVector3Array()
## Per-row blended ground and rock colours.
var _row_verge := PackedColorArray()
var _row_field := PackedColorArray()
var _row_rock := PackedColorArray()
var _row_rock_shade := PackedColorArray()
## Per-interval kind (INTERVAL_*), tunnel index and lamp stations.
var _iv_kind := PackedInt32Array()
var _iv_tunnel := PackedInt32Array()
var _iv_lamp_lo := PackedInt32Array()
var _iv_lamp_n := PackedInt32Array()
## Rows forced into the layout (portals, hip ends), sorted.
var _breaks := PackedFloat64Array()
var _tunnels: Array[RoadFeature] = []
## Every tunnel the feature query found (cliffs frame them from further away).
var _all_tunnels: Array[RoadFeature] = []
## Cliff factor (0 = none .. 1 = full wall) per row and side, the row's CliffDef, and
## the faces each interval emits.
var _row_cliff_r := PackedFloat64Array()
var _row_cliff_l := PackedFloat64Array()
var _row_cliff_def: Array[CliffDef] = []
var _iv_cliff_def: Array[CliffDef] = []
var _iv_cliff_sides := PackedInt32Array()
var _checkpoints := PackedFloat64Array()
var _cp_signs := PackedFloat64Array()
var _portal_rows := PackedInt32Array()
var _portal_tunnel := PackedInt32Array()
var _portal_exit := PackedByteArray()
## Cross-section breakpoints, row-major: row r occupies [r * _bp_n, (r + 1) * _bp_n).
var _bp := PackedFloat64Array()
var _bp_n: int = 0
var _refl_s := PackedFloat64Array()
var _refl_lines := PackedInt32Array()
var _refl_n: int = 0

var _smp := RoadSample.new()
var _features: Array[RoadFeature] = []
var _tapers: Array[RoadFeature] = []
var _arrays: Array = []
var _road: RoadPath

var _road_quads: int = 0
var _next_interval: int = 0
var _units_done: int = 0
var _world_quads: int = 0
var _rv: int = 0
var _ri: int = 0
var _wv: int = 0
var _wi: int = 0
## Added to every world index (the road vertex count while merging, else 0).
var _world_index_base: int = 0


func _init(road_tuning: RoadTuning = null, road_palette: RoadPalette = null,
		tunnel_tuning: LandmarkTuning = null) -> void:
	tuning = road_tuning if road_tuning != null else Tuning.load_default().road
	palette = road_palette if road_palette != null else RoadPalette.new()
	landmark_tuning = tunnel_tuning if tunnel_tuning != null else LandmarkTuning.load_default()
	_arrays.resize(Mesh.ARRAY_MAX)
	_ensure_row_capacity(ROW_CAPACITY)
	_refl_s.resize(ROW_CAPACITY)
	_refl_lines.resize(ROW_CAPACITY)


# ---------------------------------------------------------------- API

## Builds the chunk [s0, s1] of `road` into the output arrays in one go.
func build(road: RoadPath, s0: float, s1: float) -> void:
	begin(road, s0, s1)
	while not step(row_count):
		pass


## Starts an incremental build of [s0, s1]: samples the rows, lays out the cross-
## section and sizes the arrays. Then call step() until it returns true.
func begin(road: RoadPath, s0: float, s1: float) -> void:
	_road = road
	chunk_s0 = s0
	chunk_s1 = s1
	road.sample_into(s0, _smp)
	anchor_x = _smp.pos_x
	anchor_y = _smp.pos_y
	anchor_z = _smp.pos_z

	_features.clear()
	_tapers.clear()
	_tunnels.clear()
	_all_tunnels.clear()
	_breaks.clear()
	_checkpoints.clear()
	_cp_signs.clear()
	var hip := landmark_tuning.tunnel_hill_width_m
	var pad := maxf(hip, _cliff_reach(s0, s1))
	# A feature starting exactly at s1 must count here too: the boundary row is shared.
	# Tunnels up to a hip length beyond the chunk (and checkpoints within a cliff's
	# clearance) still reach into it.
	road.features_in(s0 - maxf(tuning.lane_taper_length_m, pad), s1 + pad + ROW_EPS_M, _features)
	for f in _features:
		if f.kind == RoadFeature.Kind.LANE_COUNT_CHANGE and f.s_end > f.s_start:
			_tapers.append(f)
		elif f.kind == RoadFeature.Kind.CHECKPOINT:
			_checkpoints.append(f.s_start)
		elif Landmarks.is_panel_sign(f):
			# Warning and lane-ends panels (Landmarks): cliffs fall away around them.
			_cp_signs.append(f.s_start)
		elif f.kind == RoadFeature.Kind.TUNNEL and f.s_end > f.s_start:
			_all_tunnels.append(f)
			if f.s_end + hip <= s0 or f.s_start - hip >= s1:
				continue
			_tunnels.append(f)
			for b: float in [f.s_start - hip, f.s_start, f.s_end, f.s_end + hip]:
				if b > s0 + ROW_EPS_M and b < s1 - ROW_EPS_M:
					_breaks.append(b)
	_breaks.sort()

	_compute_rows(s0, s1)
	var max_lanes := 0.0
	for r in row_count:
		_fill_row(r)
		max_lanes = maxf(max_lanes, _row_lanes[r])
	lane_slots = maxi(1, ceili(max_lanes - ROW_EPS_M))
	_compute_breakpoints()
	_compute_reflectors(s0, s1)
	_compute_row_colors(s0, s1)
	var tunnel_quads := _classify_intervals(s0, s1)
	tunnel_quads += _classify_cliffs()

	var intervals := row_count - 1
	road_quads_per_interval = 2 * (2 * lane_slots + 3)
	_road_quads = intervals * road_quads_per_interval + reflector_count * REFLECTOR_QUADS
	_world_quads = intervals * WORLD_QUADS_PER_INTERVAL + tunnel_quads
	_size_road(_road_quads)
	_size_world(_world_quads)
	_world_index_base = _road_quads * 4 if merge_surfaces else 0
	_rv = 0
	_ri = 0
	_wv = 0
	_wi = 0
	_next_interval = 0
	_units_done = 0


## Emits up to `max_units` units of work (one unit = one row interval; the
## reflectors are the last unit). Returns true when the build is complete.
func step(max_units: int) -> bool:
	if _road == null:
		return true
	var intervals := row_count - 1
	var units := 0
	while units < max_units and _next_interval < intervals:
		_emit_road_interval(_next_interval)
		_emit_world_interval(_next_interval)
		_next_interval += 1
		units += 1
	_units_done += units
	if units < max_units and _next_interval >= intervals:
		_emit_reflectors()
		_emit_portals()
		_units_done += 1
		_road = null
		return true
	return false


## Work units emitted since begin().
func units_done() -> int:
	return _units_done


## True between begin() and the step() that completes the build.
func is_building() -> bool:
	return _road != null


## Work units a full build takes (row intervals + the reflector unit).
func build_units() -> int:
	return row_count


## Drops an unfinished build (the arrays keep partial data until the next begin()).
func cancel() -> void:
	_road = null


## Replaces `mesh`'s surfaces with the last build (0 = road, 1 = world).
func commit(mesh: ArrayMesh, road_material: Material, world_material: Material) -> void:
	mesh.clear_surfaces()
	_arrays[Mesh.ARRAY_VERTEX] = road_vertices
	_arrays[Mesh.ARRAY_NORMAL] = road_normals
	_arrays[Mesh.ARRAY_COLOR] = road_colors
	_arrays[Mesh.ARRAY_TEX_UV2] = road_uv2
	_arrays[Mesh.ARRAY_INDEX] = road_indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays)
	mesh.surface_set_material(SURFACE_ROAD, road_material)
	_arrays[Mesh.ARRAY_VERTEX] = world_vertices
	_arrays[Mesh.ARRAY_NORMAL] = world_normals
	_arrays[Mesh.ARRAY_COLOR] = world_colors
	_arrays[Mesh.ARRAY_TEX_UV2] = world_uv2
	_arrays[Mesh.ARRAY_INDEX] = world_indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays)
	mesh.surface_set_material(SURFACE_WORLD, world_material)
	# Drop the extra references so the next build writes in place (no copy-on-write).
	_arrays[Mesh.ARRAY_VERTEX] = null
	_arrays[Mesh.ARRAY_NORMAL] = null
	_arrays[Mesh.ARRAY_COLOR] = null
	_arrays[Mesh.ARRAY_TEX_UV2] = null
	_arrays[Mesh.ARRAY_INDEX] = null


## Replaces `mesh`'s surfaces with the last build as ONE surface (road then world
## geometry) with `material`. Needs a build made with merge_surfaces on. Load/commit
## time: it allocates the joined arrays once per chunk, never per tick.
func commit_merged(mesh: ArrayMesh, material: Material) -> void:
	assert(merge_surfaces, "commit_merged needs a build with merge_surfaces on")
	mesh.clear_surfaces()
	var verts := road_vertices.duplicate()
	verts.append_array(world_vertices)
	var normals := road_normals.duplicate()
	normals.append_array(world_normals)
	var colors := road_colors.duplicate()
	colors.append_array(world_colors)
	var uv2 := road_uv2.duplicate()
	uv2.append_array(world_uv2)
	var indices := road_indices.duplicate()
	indices.append_array(world_indices)
	_arrays[Mesh.ARRAY_VERTEX] = verts
	_arrays[Mesh.ARRAY_NORMAL] = normals
	_arrays[Mesh.ARRAY_COLOR] = colors
	_arrays[Mesh.ARRAY_TEX_UV2] = uv2
	_arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays)
	mesh.surface_set_material(0, material)
	_arrays[Mesh.ARRAY_VERTEX] = null
	_arrays[Mesh.ARRAY_NORMAL] = null
	_arrays[Mesh.ARRAY_COLOR] = null
	_arrays[Mesh.ARRAY_TEX_UV2] = null
	_arrays[Mesh.ARRAY_INDEX] = null


func road_triangle_count() -> int:
	return _road_quads * 2


func world_triangle_count() -> int:
	return _world_quads * 2


func triangle_count() -> int:
	return road_triangle_count() + world_triangle_count()


## s of mesh row `r` of the last build.
func row_s(r: int) -> float:
	return _row_s[r]


## Right lane edge d (after tapering) at row `r` of the last build.
func row_edge_d(r: int) -> float:
	return _row_edge[r]


## Paved outer shoulder edge d at row `r` of the last build.
func row_outer_d(r: int) -> float:
	return _row_outer[r]


## Effective right lane edge at `s` (taper applied). Director rate: queries features.
func lanes_right_edge_at(road: RoadPath, s: float) -> float:
	assert(not is_building(), "lanes_right_edge_at during an incremental build")
	_road = road
	_features.clear()
	_tapers.clear()
	road.features_in(s - tuning.lane_taper_length_m, s + ROW_EPS_M, _features)
	for f in _features:
		if f.kind == RoadFeature.Kind.LANE_COUNT_CHANGE and f.s_end > f.s_start:
			_tapers.append(f)
	var e := _edge_d(s)
	_road = null
	return e


## True when dashes are painted at absolute `s` (dash phase from absolute s).
func dash_on_at(s: float) -> bool:
	return fposmod(s, tuning.dash_length_m + tuning.dash_gap_m) < tuning.dash_length_m


# ---------------------------------------------------------------- Rows

func _compute_rows(s0: float, s1: float) -> void:
	row_count = 0
	_push_row(s0)
	var s := s0
	var bi := 0
	while true:
		var nxt := minf(_next_dash_boundary(s), s + tuning.mesh_max_step_m)
		while bi < _breaks.size() and _breaks[bi] <= s + ROW_EPS_M:
			bi += 1
		if bi < _breaks.size() and _breaks[bi] < nxt - ROW_EPS_M:
			nxt = _breaks[bi]
		if nxt >= s1 - ROW_EPS_M:
			break
		_push_row(nxt)
		s = nxt
	_push_row(s1)


func _next_dash_boundary(s: float) -> float:
	var dash := tuning.dash_length_m
	var period := dash + tuning.dash_gap_m
	var ph := fposmod(s, period)
	var start := s - ph
	if ph < dash - ROW_EPS_M:
		return start + dash
	if ph > period - ROW_EPS_M:
		return start + period + dash
	return start + period


func _push_row(s: float) -> void:
	if row_count >= _row_s.size():
		_ensure_row_capacity(_row_s.size() * 2)
	_row_s[row_count] = s
	row_count += 1


func _ensure_row_capacity(n: int) -> void:
	_row_s.resize(n)
	_row_p.resize(n)
	_row_right.resize(n)
	_row_up.resize(n)
	_row_barrier.resize(n)
	_row_left.resize(n)
	_row_edge.resize(n)
	_row_outer.resize(n)
	_row_guard.resize(n)
	_row_lanes.resize(n)
	_row_width.resize(n)
	_row_tangent.resize(n)
	_row_verge.resize(n)
	_row_field.resize(n)
	_row_rock.resize(n)
	_row_rock_shade.resize(n)
	_row_cliff_r.resize(n)
	_row_cliff_l.resize(n)


func _fill_row(r: int) -> void:
	var s := _row_s[r]
	_road.sample_into(s, _smp)
	_row_p[r] = _smp.local_point(0.0, anchor_x, anchor_y, anchor_z)
	_row_right[r] = _smp.right
	_row_up[r] = _smp.up
	_row_tangent[r] = _smp.tangent
	var w := _road.lane_width(s)
	var left := _road.lanes_left_edge_d(s)
	var road_edge := _road.lanes_right_edge_d(s)
	var edge := _edge_d(s)
	_row_width[r] = w
	_row_left[r] = left
	_row_edge[r] = edge
	_row_lanes[r] = (edge - left) / w
	_row_barrier[r] = _road.median_barrier_d(s)
	_row_outer[r] = edge + (_road.shoulder_outer_d(s) - road_edge)
	_row_guard[r] = edge + (_road.guardrail_d(s) - road_edge)


## Right lane edge with lane-count tapers applied.
func _edge_d(s: float) -> float:
	var w := _road.lane_width(s)
	var left := _road.lanes_left_edge_d(s)
	for f in _tapers:
		if s >= f.s_start and s <= f.s_end:
			var n0 := float(_road.lane_count(f.s_start - TAPER_PROBE_M))
			var t := smoothstep(f.s_start, f.s_end, s)
			return left + lerpf(n0, f.value, t) * w
	var taper := tuning.lane_taper_length_m
	if taper > 0.0:
		var n := _road.lane_count(s)
		var s_prev := s - taper
		var n_prev := _road.lane_count(s_prev)
		if n_prev != n:
			var c := _find_lane_step(s_prev, s, n_prev)
			if not _covered_by_taper(c):
				var t := smoothstep(0.0, 1.0, (s - c) / taper)
				return left + lerpf(float(n_prev), float(n), t) * w
	return _road.lanes_right_edge_d(s)


## First s in (lo, hi] where lane_count differs from `n_lo` (bisection).
func _find_lane_step(lo: float, hi: float, n_lo: int) -> float:
	var a := lo
	var b := hi
	for i in LANE_STEP_BISECT:
		var m := 0.5 * (a + b)
		if _road.lane_count(m) == n_lo:
			a = m
		else:
			b = m
	return b


func _covered_by_taper(s: float) -> bool:
	for f in _tapers:
		if s >= f.s_start - TAPER_PROBE_M and s <= f.s_end + TAPER_PROBE_M:
			return true
	return false


## Breakpoints per row (player side, d > 0), 2 * lane_slots + 4 of them:
##   [0] median barrier face, [1..2] left edge line, then per line k = 1..slots-1
##   [2k+1..2k+2], then [2n+1..2n+2] right edge line, [2n+3] outer shoulder edge.
## Lane-area breakpoints are clamped inside the (tapering) right edge line.
func _compute_breakpoints() -> void:
	var n := lane_slots
	_bp_n = 2 * n + 4
	if _bp.size() < row_count * _bp_n:
		_bp.resize(row_count * _bp_n)
	var hwe := 0.5 * tuning.edge_line_width_m
	var hwl := 0.5 * tuning.lane_line_width_m
	for r in row_count:
		var o := r * _bp_n
		var left := _row_left[r]
		var w := _row_width[r]
		var edge := _row_edge[r]
		var cap := edge - hwe
		_bp[o] = _row_barrier[r]
		_bp[o + 1] = left - hwe
		_bp[o + 2] = minf(left + hwe, cap)
		for k in range(1, n):
			_bp[o + 2 * k + 1] = clampf(left + float(k) * w - hwl, _bp[o + 2 * k], cap)
			_bp[o + 2 * k + 2] = clampf(left + float(k) * w + hwl, _bp[o + 2 * k + 1], cap)
		_bp[o + 2 * n + 1] = cap
		_bp[o + 2 * n + 2] = edge + hwe
		_bp[o + 2 * n + 3] = maxf(_row_outer[r], edge + hwe)


## Lane line k (between lanes k-1 and k) is painted while it lies fully inside the
## right edge line.
func _line_exists(k: int, lanes: float, w: float) -> bool:
	var margin := (0.5 * tuning.lane_line_width_m + 0.5 * tuning.edge_line_width_m) / w
	return float(k) + margin <= lanes


# ---------------------------------------------------------------- Reflectors

func _compute_reflectors(s0: float, s1: float) -> void:
	_refl_n = 0
	reflector_count = 0
	var spacing := tuning.reflector_spacing_m
	if spacing <= 0.0:
		return
	# Centred in the dash gaps: phase = dash + gap / 2, from absolute s.
	var phase := tuning.dash_length_m + 0.5 * tuning.dash_gap_m
	var s := ceilf((s0 - phase) / spacing) * spacing + phase
	while s < s1:
		if s >= s0:
			var w := _road.lane_width(s)
			var lanes := (_edge_d(s) - _road.lanes_left_edge_d(s)) / w
			var lines := 0
			for k in range(1, lane_slots):
				if _line_exists(k, lanes, w):
					lines += 1
			if lines > 0:
				if _refl_n >= _refl_s.size():
					_refl_s.resize(_refl_s.size() * 2)
					_refl_lines.resize(_refl_lines.size() * 2)
				_refl_s[_refl_n] = s
				_refl_lines[_refl_n] = lines
				_refl_n += 1
				reflector_count += 2 * lines
		s += spacing


func _emit_reflectors() -> void:
	var hw := 0.5 * tuning.reflector_width_m
	var hl := 0.5 * tuning.reflector_length_m
	var h := tuning.reflector_height_m
	var uv := Vector2(EMISSIVE_REFLECTOR, TINT_NONE)
	var col := palette.reflector
	for i in _refl_n:
		var s := _refl_s[i]
		_road.sample_into(s, _smp)
		var p := _smp.local_point(0.0, anchor_x, anchor_y, anchor_z)
		var rt := _smp.right
		var up := _smp.up
		var tg := _smp.tangent
		var left := _road.lanes_left_edge_d(s)
		var w := _road.lane_width(s)
		var lines := _refl_lines[i]
		for k in range(1, lines + 1):
			var d := left + float(k) * w
			for side in 2:
				var c := p + rt * (d if side == 0 else -d)
				var x0 := c - rt * hw
				var x1 := c + rt * hw
				var b00 := x0 - tg * hl
				var b10 := x1 - tg * hl
				var b11 := x1 + tg * hl
				var b01 := x0 + tg * hl
				var hh := up * h
				_road_quad(b00 + hh, b10 + hh, b11 + hh, b01 + hh, up, col, uv)
				_road_quad(b00, b10, b10 + hh, b00 + hh, -tg, col, uv)
				_road_quad(b01, b11, b11 + hh, b01 + hh, tg, col, uv)
				_road_quad(b00, b01, b01 + hh, b00 + hh, -rt, col, uv)
				_road_quad(b10, b11, b11 + hh, b10 + hh, rt, col, uv)


# ---------------------------------------------------------------- Intervals

func _emit_road_interval(i: int) -> void:
	var a := i
	var b := i + 1
	var n := lane_slots
	var pa := _row_p[a]
	var pb := _row_p[b]
	var ra := _row_right[a]
	var rb := _row_right[b]
	var up := _row_up[a]
	var oa := a * _bp_n
	var ob := b * _bp_n
	var dash := dash_on_at(0.5 * (_row_s[a] + _row_s[b]))
	var road_uv := Vector2(EMISSIVE_NONE, TINT_ROAD)
	var line_uv := Vector2(EMISSIVE_NONE, TINT_LINE)
	var last := 2 * n + 2
	var shade := _interval_shade(i)
	var asphalt := _shaded(palette.asphalt, shade)
	var shoulder := _shaded(palette.shoulder, shade)
	var line := _shaded(palette.line, shade)
	for side in 2:
		var sg := 1.0 if side == 0 else -1.0
		for j in last + 1:
			var col := asphalt
			var uv := road_uv
			if j == 0 or j == last:
				col = shoulder
			elif j == 1 or j == last - 1:
				col = line
				uv = line_uv
			elif j % 2 == 1:
				var k := (j - 1) >> 1
				if dash and _line_exists(k, _row_lanes[a], _row_width[a]) \
						and _line_exists(k, _row_lanes[b], _row_width[b]):
					col = line
					uv = line_uv
			var d0a := sg * _bp[oa + j]
			var d1a := sg * _bp[oa + j + 1]
			var d0b := sg * _bp[ob + j]
			var d1b := sg * _bp[ob + j + 1]
			_road_quad(pa + ra * d0a, pa + ra * d1a, pb + rb * d1b, pb + rb * d0b, up, col, uv)


func _emit_world_interval(i: int) -> void:
	var a := i
	var b := i + 1
	var pa := _row_p[a]
	var pb := _row_p[b]
	var ra := _row_right[a]
	var rb := _row_right[b]
	var ua := _row_up[a]
	var ub := _row_up[b]
	var uv := Vector2(EMISSIVE_NONE, TINT_NONE)
	var shade := _interval_shade(i)
	var barrier := _shaded(palette.barrier, shade)
	var rail := _shaded(palette.guardrail, shade)

	# Median barrier: base at the barrier faces, one slope break, flat top.
	var t := tuning
	var ba := _row_barrier[a]
	var bb := _row_barrier[b]
	var kh := t.median_barrier_kink_height_m
	var hh := t.median_barrier_height_m
	var kwa := minf(t.median_barrier_kink_half_width_m, ba)
	var kwb := minf(t.median_barrier_kink_half_width_m, bb)
	var twa := minf(t.median_barrier_top_half_width_m, kwa)
	var twb := minf(t.median_barrier_top_half_width_m, kwb)
	_profile_panel(pa, ra, ua, pb, rb, ub, -ba, 0.0, -bb, 0.0, -kwa, kh, -kwb, kh, 1.0, barrier, uv)
	_profile_panel(pa, ra, ua, pb, rb, ub, -kwa, kh, -kwb, kh, -twa, hh, -twb, hh, 1.0, barrier, uv)
	_profile_panel(pa, ra, ua, pb, rb, ub, -twa, hh, -twb, hh, twa, hh, twb, hh, 1.0, barrier, uv)
	_profile_panel(pa, ra, ua, pb, rb, ub, twa, hh, twb, hh, kwa, kh, kwb, kh, 1.0, barrier, uv)
	_profile_panel(pa, ra, ua, pb, rb, ub, kwa, kh, kwb, kh, ba, 0.0, bb, 0.0, 1.0, barrier, uv)

	# Guardrail rails (a "<" W-beam pointing at the road, plus the back face) and the
	# ground ribbon from the paved shoulder edge outward, per side.
	var bot := t.guardrail_bottom_m
	var top := t.guardrail_top_m
	var mid := 0.5 * (bot + top)
	var dep := t.guardrail_depth_m
	var ga := _row_guard[a]
	var gb := _row_guard[b]
	var outa := _row_outer[a]
	var outb := _row_outer[b]
	var far := t.ground_ribbon_width_m
	for side in 2:
		var sg := 1.0 if side == 0 else -1.0
		_profile_panel(pa, ra, ua, pb, rb, ub, sg * (ga + dep), bot, sg * (gb + dep), bot,
				sg * ga, mid, sg * gb, mid, sg, rail, uv)
		_profile_panel(pa, ra, ua, pb, rb, ub, sg * ga, mid, sg * gb, mid,
				sg * (ga + dep), top, sg * (gb + dep), top, sg, rail, uv)
		_profile_panel(pa, ra, ua, pb, rb, ub, sg * (ga + dep), top, sg * (gb + dep), top,
				sg * (ga + dep), bot, sg * (gb + dep), bot, sg, rail, uv)
		# Verge (clear zone) out to the scenery line, as the roadside layers use it.
		var d0a := sg * outa
		var d0b := sg * outb
		var d1a := sg * maxf(ga + t.prop_clearance_m, outa)
		var d1b := sg * maxf(gb + t.prop_clearance_m, outb)
		var d2a := sg * (outa + far)
		var d2b := sg * (outb + far)
		var va := _shaded(_row_verge[a], shade)
		var vb := _shaded(_row_verge[b], shade)
		var fa := _shaded(_row_field[a], shade)
		var fb := _shaded(_row_field[b], shade)
		_world_quad_c(pa + ra * d0a, pa + ra * d1a, pb + rb * d1b, pb + rb * d0b, ua, va, va, vb, vb, uv)
		_world_quad_c(pa + ra * d1a, pa + ra * d2a, pb + rb * d2b, pb + rb * d1b, ua, fa, fa, fb, fb, uv)
	match _iv_kind[i]:
		INTERVAL_TUNNEL:
			_emit_tunnel_interval(i)
		INTERVAL_HIP:
			_emit_hip_interval(i)
	if _iv_cliff_def[i] != null:
		_emit_cliff_interval(i)


# ---------------------------------------------------------------- Ground colours and road tunnels

func _compute_row_colors(s0: float, s1: float) -> void:
	var span := s1 - s0
	for r in row_count:
		var u := clampf((_row_s[r] - s0) / span, 0.0, 1.0) if span > 0.0 else 0.0
		_row_verge[r] = palette.ground_verge.lerp(palette.ground_verge_end, u)
		_row_field[r] = palette.ground_field.lerp(palette.ground_field_end, u)
		_row_rock[r] = palette.rock.lerp(palette.rock_end, u)
		_row_rock_shade[r] = palette.rock_shade.lerp(palette.rock_shade_end, u)


## Classifies every interval (open road, inside a tunnel, a hip end), finds the lamp
## stations and portal rows, and returns the tunnel quads this build will emit.
func _classify_intervals(_s0: float, _s1: float) -> int:
	var intervals := maxi(row_count - 1, 0)
	_iv_kind.resize(intervals)
	_iv_tunnel.resize(intervals)
	_iv_lamp_lo.resize(intervals)
	_iv_lamp_n.resize(intervals)
	_portal_rows.clear()
	_portal_tunnel.clear()
	_portal_exit.clear()
	var quads := 0
	var hip := landmark_tuning.tunnel_hill_width_m
	var spacing := landmark_tuning.tunnel_lamp_spacing_m
	var lamp_len := tuning.tunnel_lamp_length_m
	for i in intervals:
		var sa := _row_s[i]
		var sb := _row_s[i + 1]
		var sm := 0.5 * (sa + sb)
		_iv_kind[i] = INTERVAL_OPEN
		_iv_tunnel[i] = -1
		_iv_lamp_lo[i] = 0
		_iv_lamp_n[i] = 0
		for ti in _tunnels.size():
			var f := _tunnels[ti]
			if sm >= f.s_start and sm <= f.s_end:
				_iv_kind[i] = INTERVAL_TUNNEL
				_iv_tunnel[i] = ti
				quads += TUNNEL_QUADS_PER_INTERVAL
				if spacing > 0.0:
					var last_j := floori((f.s_end - f.s_start - lamp_len) / spacing - 0.5)
					var lo := maxi(ceili((sa - f.s_start) / spacing - 0.5), 0)
					var hi := mini(ceili((sb - f.s_start) / spacing - 0.5) - 1, last_j)
					if hi >= lo:
						_iv_lamp_lo[i] = lo
						_iv_lamp_n[i] = hi - lo + 1
						quads += LAMP_QUADS * (hi - lo + 1)
				break
			if (sm > f.s_start - hip and sm < f.s_start) or (sm > f.s_end and sm < f.s_end + hip):
				_iv_kind[i] = INTERVAL_HIP
				_iv_tunnel[i] = ti
				quads += HIP_QUADS_PER_INTERVAL
				break
	# Portal faces on their rows; the last row is the next chunk's first.
	for r in maxi(row_count - 1, 1):
		for ti in _tunnels.size():
			var f := _tunnels[ti]
			for e in 2:
				if absf(_row_s[r] - (f.s_start if e == 0 else f.s_end)) < ROW_EPS_M:
					_portal_rows.append(r)
					_portal_tunnel.append(ti)
					_portal_exit.append(e)
					quads += PORTAL_QUADS
	return quads


## Albedo factor of interval i (darker inside a tunnel).
func _interval_shade(i: int) -> float:
	if i < _iv_kind.size() and _iv_kind[i] == INTERVAL_TUNNEL:
		return tuning.tunnel_interior_shade_frac
	return 1.0


static func _shaded(c: Color, k: float) -> Color:
	return Color(c.r * k, c.g * k, c.b * k, c.a)


## Inside a tunnel: per side the outer wall's inner face, the central wall, the roof,
## the hill's top and its two slopes; then the interval's lamp stations.
func _emit_tunnel_interval(i: int) -> void:
	var a := i
	var b := i + 1
	var pa := _row_p[a]
	var pb := _row_p[b]
	var ra := _row_right[a]
	var rb := _row_right[b]
	var ua := _row_up[a]
	var ub := _row_up[b]
	var lt := landmark_tuning
	var uv := Vector2(EMISSIVE_NONE, TINT_NONE)
	var shade := tuning.tunnel_interior_shade_frac
	var wall_col := _shaded(palette.tunnel_wall, shade)
	var roof_col := _shaded(palette.tunnel_roof, shade)
	var c := lt.tunnel_clearance_m
	var cover := lt.tunnel_cover_top_m
	var mid_y := cover * LandmarkBuilds.HILL_MID_Y_FRAC
	var foot_y := LandmarkBuilds.HILL_FOOT_Y_M
	var pier_a := _row_barrier[a] - PIER_INSET_M
	var pier_b := _row_barrier[b] - PIER_INSET_M
	var wall_a := _row_guard[a] + lt.tunnel_wall_offset_m
	var wall_b := _row_guard[b] + lt.tunnel_wall_offset_m
	var top_a := wall_a + LandmarkBuilds.TUNNEL_SHELL_M
	var top_b := wall_b + LandmarkBuilds.TUNNEL_SHELL_M
	var mid_a := top_a + lt.tunnel_hill_width_m * LandmarkBuilds.HILL_MID_X_FRAC
	var mid_b := top_b + lt.tunnel_hill_width_m * LandmarkBuilds.HILL_MID_X_FRAC
	var foot_a := top_a + lt.tunnel_hill_width_m
	var foot_b := top_b + lt.tunnel_hill_width_m
	var tf := _tunnels[_iv_tunnel[i]]
	var ridge_a := tuning.tunnel_ridge_height_m * _ridge_factor(tf, _row_s[a])
	var ridge_b := tuning.tunnel_ridge_height_m * _ridge_factor(tf, _row_s[b])
	for side in 2:
		var sg := 1.0 if side == 0 else -1.0
		_profile_panel(pa, ra, ua, pb, rb, ub, sg * wall_a, 0.0, sg * wall_b, 0.0, sg * wall_a, c, sg * wall_b, c,
			sg, wall_col, uv)
		_profile_panel(pa, ra, ua, pb, rb, ub, sg * pier_a, c, sg * pier_b, c, sg * pier_a, 0.0, sg * pier_b, 0.0,
			sg, wall_col, uv)
		_profile_panel(pa, ra, ua, pb, rb, ub, sg * wall_a, c, sg * wall_b, c, sg * pier_a, c, sg * pier_b, c,
			sg, roof_col, uv)
		_profile_panel_c(pa, ra, ua, pb, rb, ub, 0.0, cover + ridge_a, 0.0, cover + ridge_b, sg * top_a,
			cover + ridge_a, sg * top_b, cover + ridge_b, sg, _row_rock[a], _row_rock[b], uv)
		_profile_panel_c(pa, ra, ua, pb, rb, ub, sg * top_a, cover + ridge_a, sg * top_b, cover + ridge_b, sg * mid_a,
			mid_y + ridge_a * HIP_RIDGE_MID_FRAC, sg * mid_b, mid_y + ridge_b * HIP_RIDGE_MID_FRAC, sg,
			_row_rock_shade[a], _row_rock_shade[b], uv)
		_profile_panel_c(pa, ra, ua, pb, rb, ub, sg * mid_a, mid_y + ridge_a * HIP_RIDGE_MID_FRAC, sg * mid_b,
			mid_y + ridge_b * HIP_RIDGE_MID_FRAC, sg * foot_a, foot_y, sg * foot_b, foot_y, sg,
			_row_rock_shade[a], _row_rock_shade[b], uv)
	var n := _iv_lamp_n[i]
	if n <= 0:
		return
	var f := _tunnels[_iv_tunnel[i]]
	var sa := _row_s[a]
	var len_ab := maxf(_row_s[b] - sa, ROW_EPS_M)
	var spacing := lt.tunnel_lamp_spacing_m
	var lamp_uv := Vector2(EMISSIVE_STREETLAMP, TINT_NONE)
	var y0 := c - LAMP_BOTTOM_BELOW_M
	var y1 := c - LAMP_TOP_BELOW_M
	for k in n:
		var s_l := f.s_start + (float(_iv_lamp_lo[i] + k) + 0.5) * spacing
		var u0 := (s_l - sa) / len_ab
		var u1 := (s_l + tuning.tunnel_lamp_length_m - sa) / len_ab
		var p0 := pa.lerp(pb, u0)
		var p1 := pa.lerp(pb, u1)
		var r0 := ra.lerp(rb, u0)
		var r1 := ra.lerp(rb, u1)
		var w0 := lerpf(wall_a, wall_b, u0) - LAMP_PROUD_M
		var w1 := lerpf(wall_a, wall_b, u1) - LAMP_PROUD_M
		var q0 := lerpf(pier_a, pier_b, u0) + LAMP_PROUD_M
		var q1 := lerpf(pier_a, pier_b, u1) + LAMP_PROUD_M
		for side in 2:
			var sg := 1.0 if side == 0 else -1.0
			_world_quad(p0 + r0 * (sg * w0) + ua * y0, p1 + r1 * (sg * w1) + ua * y0, p1 + r1 * (sg * w1) + ua * y1,
				p0 + r0 * (sg * w0) + ua * y1, -r0 * sg, palette.tunnel_lamp, lamp_uv)
			_world_quad(p0 + r0 * (sg * q0) + ua * y0, p1 + r1 * (sg * q1) + ua * y0, p1 + r1 * (sg * q1) + ua * y1,
				p0 + r0 * (sg * q0) + ua * y1, r0 * sg, palette.tunnel_lamp, lamp_uv)


## Hip ends beyond a portal: per side the hill's two slopes, their heights fading to
## the ground over LandmarkTuning.tunnel_hill_width_m, and the wing wall facing the road.
func _emit_hip_interval(i: int) -> void:
	var a := i
	var b := i + 1
	var pa := _row_p[a]
	var pb := _row_p[b]
	var ra := _row_right[a]
	var rb := _row_right[b]
	var ua := _row_up[a]
	var ub := _row_up[b]
	var lt := landmark_tuning
	var uv := Vector2(EMISSIVE_NONE, TINT_NONE)
	var f := _tunnels[_iv_tunnel[i]]
	var ka := _hip_factor(f, _row_s[a])
	var kb := _hip_factor(f, _row_s[b])
	var cover := lt.tunnel_cover_top_m
	var mid_y := cover * LandmarkBuilds.HILL_MID_Y_FRAC
	var foot_y := LandmarkBuilds.HILL_FOOT_Y_M
	var top_a := _row_guard[a] + lt.tunnel_wall_offset_m + LandmarkBuilds.TUNNEL_SHELL_M
	var top_b := _row_guard[b] + lt.tunnel_wall_offset_m + LandmarkBuilds.TUNNEL_SHELL_M
	var mid_a := top_a + lt.tunnel_hill_width_m * LandmarkBuilds.HILL_MID_X_FRAC
	var mid_b := top_b + lt.tunnel_hill_width_m * LandmarkBuilds.HILL_MID_X_FRAC
	var foot_a := top_a + lt.tunnel_hill_width_m
	var foot_b := top_b + lt.tunnel_hill_width_m
	var ha := maxf(cover * ka, foot_y)
	var hb := maxf(cover * kb, foot_y)
	var ma := maxf(mid_y * ka, foot_y)
	var mb := maxf(mid_y * kb, foot_y)
	for side in 2:
		var sg := 1.0 if side == 0 else -1.0
		_profile_panel_c(pa, ra, ua, pb, rb, ub, sg * top_a, ha, sg * top_b, hb, sg * mid_a, ma, sg * mid_b, mb,
			sg, _row_rock[a], _row_rock[b], uv)
		_profile_panel_c(pa, ra, ua, pb, rb, ub, sg * mid_a, ma, sg * mid_b, mb, sg * foot_a, foot_y, sg * foot_b,
			foot_y, sg, _row_rock_shade[a], _row_rock_shade[b], uv)
		_profile_panel_c(pa, ra, ua, pb, rb, ub, sg * top_a, foot_y, sg * top_b, foot_y, sg * top_a, ha, sg * top_b,
			hb, sg, _row_rock_shade[a], _row_rock_shade[b], uv)


## 0 at the portals, 1 once tunnel_ridge_ramp_m inside the bore.
func _ridge_factor(f: RoadFeature, s: float) -> float:
	var ramp := tuning.tunnel_ridge_ramp_m
	if ramp <= 0.0:
		return 1.0
	return smoothstep(0.0, ramp, minf(s - f.s_start, f.s_end - s))


## 0 at a hip's far end, 1 at its portal.
func _hip_factor(f: RoadFeature, s: float) -> float:
	var hip := landmark_tuning.tunnel_hill_width_m
	if s <= f.s_start:
		return clampf((s - (f.s_start - hip)) / hip, 0.0, 1.0)
	return clampf(((f.s_end + hip) - s) / hip, 0.0, 1.0)


## Portal faces in the cross-section plane at their rows: the band over both openings
## (chamfered top corners), the wings out to the hill and the pier on the median.
## Entrances face approaching traffic, exits the opposite carriageway's.
func _emit_portals() -> void:
	var lt := landmark_tuning
	var uv := Vector2(EMISSIVE_NONE, TINT_NONE)
	var c := lt.tunnel_clearance_m
	var top := lt.tunnel_cover_top_m + LandmarkBuilds.FACADE_PARAPET_M
	var ch := LandmarkBuilds.PORTAL_CHAMFER_M
	for k in _portal_rows.size():
		var r := _portal_rows[k]
		var p := _row_p[r]
		var rt := _row_right[r]
		var up := _row_up[r]
		var fn := -_row_tangent[r] if _portal_exit[k] == 0 else _row_tangent[r]
		var pier := _row_barrier[r] - PIER_INSET_M
		var wall := _row_guard[r] + lt.tunnel_wall_offset_m
		var top_x := wall + LandmarkBuilds.TUNNEL_SHELL_M
		_world_quad(p + rt * -pier, p + rt * pier, p + rt * pier + up * c, p + rt * -pier + up * c, fn,
			palette.tunnel_wall, uv)
		for side in 2:
			var sg := 1.0 if side == 0 else -1.0
			var w := sg * wall
			var q := sg * pier
			var tx := sg * top_x
			_world_quad(p + up * c, p + rt * w + up * c, p + rt * w + up * top, p + up * top, fn, palette.portal, uv)
			_world_quad(p + rt * w, p + rt * tx, p + rt * tx + up * top, p + rt * w + up * top, fn, palette.portal, uv)
			var wc := p + rt * w + up * c
			_world_quad(p + rt * w + up * (c - ch), wc, p + rt * (w - sg * ch) + up * c, wc, fn, palette.portal_band, uv)
			var qc := p + rt * q + up * c
			_world_quad(p + rt * q + up * (c - ch), qc, p + rt * (q + sg * ch) + up * c, qc, fn, palette.portal_band, uv)


# ---------------------------------------------------------------- Cliffs

## How far beyond the chunk a checkpoint or sign still shapes its cliffs.
func _cliff_reach(s0: float, s1: float) -> float:
	var m := 0.0
	if biome_plan == null:
		return m
	for s: float in [s0, s1]:
		var b := biome_plan.biome_at(s)
		if b != null and b.cliffs != null:
			m = maxf(m, b.cliffs.checkpoint_clear_m + b.cliffs.ramp_m)
	return m


## Per row the cliff def and factor on each side; per interval the def to emit (null =
## none). Returns the cliff quads this build will emit.
func _classify_cliffs() -> int:
	_row_cliff_def.resize(row_count)
	var intervals := maxi(row_count - 1, 0)
	_iv_cliff_def.resize(intervals)
	_iv_cliff_sides.resize(intervals)
	for r in row_count:
		var def: CliffDef = null
		if biome_plan != null:
			var b := biome_plan.biome_at(_row_s[r])
			if b != null:
				def = b.cliffs
		_row_cliff_def[r] = def
		_row_cliff_r[r] = _cliff_factor(def, _row_s[r], 0) if def != null else 0.0
		_row_cliff_l[r] = _cliff_factor(def, _row_s[r], 1) if def != null else 0.0
	var quads := 0
	for i in intervals:
		var def := _row_cliff_def[i] if _row_cliff_def[i] != null else _row_cliff_def[i + 1]
		var sides := 0
		if def != null:
			if _row_cliff_r[i] > 0.0 or _row_cliff_r[i + 1] > 0.0:
				sides |= 1
			if _row_cliff_l[i] > 0.0 or _row_cliff_l[i + 1] > 0.0:
				sides |= 2
		_iv_cliff_sides[i] = sides
		_iv_cliff_def[i] = def if sides != 0 else null
		if sides & 1:
			quads += def.face_count()
		if sides & 2:
			quads += def.face_count()
	return quads


## 0..1: how much of a wall stands at s on side `side` (0 right, 1 left).
func _cliff_factor(def: CliffDef, s: float, side: int) -> float:
	var run := def.run_length_m
	if run <= 0.0:
		return 0.0
	var r := floori(s / run)
	var frac := def.presence_right_frac if side == 0 else def.presence_left_frac
	var k := 0.0
	if _run_present(r, side, frac):
		k = 1.0
		var start := float(r) * run
		if not _run_present(r - 1, side, frac):
			k *= smoothstep(start, start + def.ramp_m, s)
		if not _run_present(r + 1, side, frac):
			k *= 1.0 - smoothstep(start + run - def.ramp_m, start + run, s)
	for f in _all_tunnels:
		var out := maxf(f.s_start - s, s - f.s_end)
		k = maxf(k, 1.0 - smoothstep(def.tunnel_frame_m, def.tunnel_frame_m + def.ramp_m, out))
	if k <= 0.0:
		return 0.0
	for c in _checkpoints:
		k *= smoothstep(def.checkpoint_clear_m, def.checkpoint_clear_m + def.ramp_m, absf(s - c))
	if side == 0:
		for g in _cp_signs:
			k *= smoothstep(def.sign_clear_m, def.sign_clear_m + def.ramp_m, absf(s - g))
	return k


func _run_present(r: int, side: int, frac: float) -> bool:
	return _hash01(TraceHash.mix_int(TraceHash.mix_int(cliff_seed, r), side)) < frac


## Seeded value noise in [-1, 1] along s for profile point `j` on `side`.
func _cliff_noise(def: CliffDef, s: float, j: int, side: int) -> float:
	var f := s / maxf(def.noise_cell_m, ROW_EPS_M)
	var c := floori(f)
	var u := smoothstep(0.0, 1.0, f - float(c))
	var key := TraceHash.mix_int(TraceHash.mix_int(cliff_seed, j), side + 2)
	var a := _hash01(TraceHash.mix_int(key, c))
	var b := _hash01(TraceHash.mix_int(key, c + 1))
	return lerpf(a, b, u) * 2.0 - 1.0


static func _hash01(h: int) -> float:
	return float(h & 0xFFFFFF) / float(0x1000000)


## The walls of interval i: per side with a wall at either row, the profile's faces
## between the two rows (point j at foot + x_j + jitter, height lerped from the foot's
## to the jittered h_j by the row's factor), in band colours.
func _emit_cliff_interval(i: int) -> void:
	var def := _iv_cliff_def[i]
	var a := i
	var b := i + 1
	var pa := _row_p[a]
	var pb := _row_p[b]
	var ra := _row_right[a]
	var rb := _row_right[b]
	var ua := _row_up[a]
	var ub := _row_up[b]
	var uv := Vector2(EMISSIVE_NONE, TINT_NONE)
	var n := def.face_count()
	var foot_a := _row_guard[a] + tuning.prop_clearance_m + def.setback_m
	var foot_b := _row_guard[b] + tuning.prop_clearance_m + def.setback_m
	var h0 := def.profile_h_m[0]
	for side in 2:
		var sg := 1.0 if side == 0 else -1.0
		if (_iv_cliff_sides[i] & (1 << side)) == 0:
			continue
		var ka := _row_cliff_r[a] if side == 0 else _row_cliff_l[a]
		var kb := _row_cliff_r[b] if side == 0 else _row_cliff_l[b]
		# One lateral wobble per row for the whole profile (keeps the points in order;
		# CliffDef keeps it within the setback), heights jittered per pair of points (a
		# face and the ledge behind it move together).
		var wa := def.offset_jitter_m * _cliff_noise(def, _row_s[a], CLIFF_NOISE_LATERAL, side)
		var wb := def.offset_jitter_m * _cliff_noise(def, _row_s[b], CLIFF_NOISE_LATERAL, side)
		var da := sg * (foot_a + wa)
		var db := sg * (foot_b + wb)
		var ya := h0
		var yb := h0
		for j in n:
			var x := def.profile_x_m[j + 1]
			var h := def.profile_h_m[j + 1]
			var na := _cliff_noise(def, _row_s[a], (j + 2) >> 1, side)
			var nb := _cliff_noise(def, _row_s[b], (j + 2) >> 1, side)
			var d1a := sg * (foot_a + x + wa)
			var d1b := sg * (foot_b + x + wb)
			var y1a := lerpf(h0, h * (1.0 + def.height_jitter_frac * na), ka)
			var y1b := lerpf(h0, h * (1.0 + def.height_jitter_frac * nb), kb)
			_profile_panel(pa, ra, ua, pb, rb, ub, da, ya, db, yb, d1a, y1a, d1b, y1b, sg, def.band_color(j), uv)
			da = d1a
			db = d1b
			ya = y1a
			yb = y1b


## One panel of a cross-section profile swept from row a to row b. The profile runs
## from (d0, h0) to (d1, h1) in (d, height) coordinates; the face normal points to
## the left of that direction in the (d, h) plane, times `orient` (-1 for a profile
## mirrored to the opposite carriageway).
func _profile_panel(pa: Vector3, ra: Vector3, ua: Vector3, pb: Vector3, rb: Vector3, ub: Vector3,
		d0a: float, h0a: float, d0b: float, h0b: float, d1a: float, h1a: float, d1b: float, h1b: float,
		orient: float, col: Color, uv: Vector2) -> void:
	_profile_panel_c(pa, ra, ua, pb, rb, ub, d0a, h0a, d0b, h0b, d1a, h1a, d1b, h1b, orient, col, col, uv)


## _profile_panel with row a's vertices in `col_a` and row b's in `col_b`.
func _profile_panel_c(pa: Vector3, ra: Vector3, ua: Vector3, pb: Vector3, rb: Vector3, ub: Vector3,
		d0a: float, h0a: float, d0b: float, h0b: float, d1a: float, h1a: float, d1b: float, h1b: float,
		orient: float, col_a: Color, col_b: Color, uv: Vector2) -> void:
	var v0 := pa + ra * d0a + ua * h0a
	var v1 := pa + ra * d1a + ua * h1a
	var v2 := pb + rb * d1b + ub * h1b
	var v3 := pb + rb * d0b + ub * h0b
	var hint := (ra * -(h1a - h0a) + ua * (d1a - d0a)) * orient
	_world_quad_c(v0, v1, v2, v3, hint, col_a, col_a, col_b, col_b, uv)


# ---------------------------------------------------------------- Quads

## Appends the quad v0-v1-v2-v3 (a loop, either direction) to the road surface,
## wound so its front face (Godot: clockwise) faces `hint`. Flat face normal.
func _road_quad(v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3, hint: Vector3,
		col: Color, uv: Vector2) -> void:
	var fn := (v2 - v0).cross(v1 - v0)
	if fn.dot(hint) < 0.0:
		var tmp := v1
		v1 = v3
		v3 = tmp
		fn = -fn
	var n := fn.normalized() if fn.length_squared() > 0.0 else hint.normalized()
	var o := _rv
	road_vertices[o] = v0
	road_vertices[o + 1] = v1
	road_vertices[o + 2] = v2
	road_vertices[o + 3] = v3
	for q in 4:
		road_normals[o + q] = n
		road_colors[o + q] = col
		road_uv2[o + q] = uv
	var x := _ri
	road_indices[x] = o
	road_indices[x + 1] = o + 1
	road_indices[x + 2] = o + 2
	road_indices[x + 3] = o
	road_indices[x + 4] = o + 2
	road_indices[x + 5] = o + 3
	_rv += 4
	_ri += 6


func _world_quad(v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3, hint: Vector3,
		col: Color, uv: Vector2) -> void:
	_world_quad_c(v0, v1, v2, v3, hint, col, col, col, col, uv)


## _world_quad with a colour per vertex (c0 for v0 ... c3 for v3).
func _world_quad_c(v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3, hint: Vector3,
		c0: Color, c1: Color, c2: Color, c3: Color, uv: Vector2) -> void:
	var fn := (v2 - v0).cross(v1 - v0)
	if fn.dot(hint) < 0.0:
		var tmp := v1
		v1 = v3
		v3 = tmp
		var tc := c1
		c1 = c3
		c3 = tc
		fn = -fn
	var n := fn.normalized() if fn.length_squared() > 0.0 else hint.normalized()
	var o := _wv
	world_vertices[o] = v0
	world_vertices[o + 1] = v1
	world_vertices[o + 2] = v2
	world_vertices[o + 3] = v3
	world_colors[o] = c0
	world_colors[o + 1] = c1
	world_colors[o + 2] = c2
	world_colors[o + 3] = c3
	for q in 4:
		world_normals[o + q] = n
		world_uv2[o + q] = uv
	var x := _wi
	var b := o + _world_index_base
	world_indices[x] = b
	world_indices[x + 1] = b + 1
	world_indices[x + 2] = b + 2
	world_indices[x + 3] = b
	world_indices[x + 4] = b + 2
	world_indices[x + 5] = b + 3
	_wv += 4
	_wi += 6


func _size_road(quads: int) -> void:
	road_vertices.resize(quads * 4)
	road_normals.resize(quads * 4)
	road_colors.resize(quads * 4)
	road_uv2.resize(quads * 4)
	road_indices.resize(quads * 6)


func _size_world(quads: int) -> void:
	world_vertices.resize(quads * 4)
	world_normals.resize(quads * 4)
	world_colors.resize(quads * 4)
	world_uv2.resize(quads * 4)
	world_indices.resize(quads * 6)
