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
## Allocation: arrays are reused. They are resized to the exact size of each build
## (Godot keeps power-of-two capacity, so steady-state builds reuse the buffers).

const SURFACE_ROAD := 0
const SURFACE_WORLD := 1

## §13 vertex classes (UV2.x emissive, UV2.y tint).
const EMISSIVE_NONE := 0.0
const EMISSIVE_REFLECTOR := 1.0
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

var tuning: RoadTuning
var palette: RoadPalette

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


func _init(road_tuning: RoadTuning = null, road_palette: RoadPalette = null) -> void:
	tuning = road_tuning if road_tuning != null else Tuning.load_default().road
	palette = road_palette if road_palette != null else RoadPalette.new()
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
	# A feature starting exactly at s1 must count here too: the boundary row is shared.
	road.features_in(s0 - tuning.lane_taper_length_m, s1 + ROW_EPS_M, _features)
	for f in _features:
		if f.kind == RoadFeature.Kind.LANE_COUNT_CHANGE and f.s_end > f.s_start:
			_tapers.append(f)

	_compute_rows(s0, s1)
	var max_lanes := 0.0
	for r in row_count:
		_fill_row(r)
		max_lanes = maxf(max_lanes, _row_lanes[r])
	lane_slots = maxi(1, ceili(max_lanes - ROW_EPS_M))
	_compute_breakpoints()
	_compute_reflectors(s0, s1)

	var intervals := row_count - 1
	road_quads_per_interval = 2 * (2 * lane_slots + 3)
	_road_quads = intervals * road_quads_per_interval + reflector_count * REFLECTOR_QUADS
	_world_quads = intervals * WORLD_QUADS_PER_INTERVAL
	_size_road(_road_quads)
	_size_world(_world_quads)
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
	while true:
		var nxt := minf(_next_dash_boundary(s), s + tuning.mesh_max_step_m)
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


func _fill_row(r: int) -> void:
	var s := _row_s[r]
	_road.sample_into(s, _smp)
	_row_p[r] = _smp.local_point(0.0, anchor_x, anchor_y, anchor_z)
	_row_right[r] = _smp.right
	_row_up[r] = _smp.up
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
	for side in 2:
		var sg := 1.0 if side == 0 else -1.0
		for j in last + 1:
			var col := palette.asphalt
			var uv := road_uv
			if j == 0 or j == last:
				col = palette.shoulder
			elif j == 1 or j == last - 1:
				col = palette.line
				uv = line_uv
			elif j % 2 == 1:
				var k := (j - 1) >> 1
				if dash and _line_exists(k, _row_lanes[a], _row_width[a]) \
						and _line_exists(k, _row_lanes[b], _row_width[b]):
					col = palette.line
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
	_profile_panel(pa, ra, ua, pb, rb, ub, -ba, 0.0, -bb, 0.0, -kwa, kh, -kwb, kh, 1.0, palette.barrier, uv)
	_profile_panel(pa, ra, ua, pb, rb, ub, -kwa, kh, -kwb, kh, -twa, hh, -twb, hh, 1.0, palette.barrier, uv)
	_profile_panel(pa, ra, ua, pb, rb, ub, -twa, hh, -twb, hh, twa, hh, twb, hh, 1.0, palette.barrier, uv)
	_profile_panel(pa, ra, ua, pb, rb, ub, twa, hh, twb, hh, kwa, kh, kwb, kh, 1.0, palette.barrier, uv)
	_profile_panel(pa, ra, ua, pb, rb, ub, kwa, kh, kwb, kh, ba, 0.0, bb, 0.0, 1.0, palette.barrier, uv)

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
	var verge := t.ground_verge_width_m
	var far := t.ground_ribbon_width_m
	for side in 2:
		var sg := 1.0 if side == 0 else -1.0
		_profile_panel(pa, ra, ua, pb, rb, ub, sg * (ga + dep), bot, sg * (gb + dep), bot,
				sg * ga, mid, sg * gb, mid, sg, palette.guardrail, uv)
		_profile_panel(pa, ra, ua, pb, rb, ub, sg * ga, mid, sg * gb, mid,
				sg * (ga + dep), top, sg * (gb + dep), top, sg, palette.guardrail, uv)
		_profile_panel(pa, ra, ua, pb, rb, ub, sg * (ga + dep), top, sg * (gb + dep), top,
				sg * (ga + dep), bot, sg * (gb + dep), bot, sg, palette.guardrail, uv)
		var d0a := sg * outa
		var d0b := sg * outb
		var d1a := sg * (outa + verge)
		var d1b := sg * (outb + verge)
		var d2a := sg * (outa + far)
		var d2b := sg * (outb + far)
		_world_quad(pa + ra * d0a, pa + ra * d1a, pb + rb * d1b, pb + rb * d0b, ua, palette.ground_verge, uv)
		_world_quad(pa + ra * d1a, pa + ra * d2a, pb + rb * d2b, pb + rb * d1b, ua, palette.ground_field, uv)


## One panel of a cross-section profile swept from row a to row b. The profile runs
## from (d0, h0) to (d1, h1) in (d, height) coordinates; the face normal points to
## the left of that direction in the (d, h) plane, times `orient` (-1 for a profile
## mirrored to the opposite carriageway).
func _profile_panel(pa: Vector3, ra: Vector3, ua: Vector3, pb: Vector3, rb: Vector3, ub: Vector3,
		d0a: float, h0a: float, d0b: float, h0b: float, d1a: float, h1a: float, d1b: float, h1b: float,
		orient: float, col: Color, uv: Vector2) -> void:
	var v0 := pa + ra * d0a + ua * h0a
	var v1 := pa + ra * d1a + ua * h1a
	var v2 := pb + rb * d1b + ub * h1b
	var v3 := pb + rb * d0b + ub * h0b
	var hint := (ra * -(h1a - h0a) + ua * (d1a - d0a)) * orient
	_world_quad(v0, v1, v2, v3, hint, col, uv)


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
	var fn := (v2 - v0).cross(v1 - v0)
	if fn.dot(hint) < 0.0:
		var tmp := v1
		v1 = v3
		v3 = tmp
		fn = -fn
	var n := fn.normalized() if fn.length_squared() > 0.0 else hint.normalized()
	var o := _wv
	world_vertices[o] = v0
	world_vertices[o + 1] = v1
	world_vertices[o + 2] = v2
	world_vertices[o + 3] = v3
	for q in 4:
		world_normals[o + q] = n
		world_colors[o + q] = col
		world_uv2[o + q] = uv
	var x := _wi
	world_indices[x] = o
	world_indices[x + 1] = o + 1
	world_indices[x + 2] = o + 2
	world_indices[x + 3] = o
	world_indices[x + 4] = o + 2
	world_indices[x + 5] = o + 3
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
