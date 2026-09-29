class_name ElevatedSections
extends BiomeFeature
## Elevated highway stretches (city): where ElevatedPlan drops the ground below the
## road, this draws what holds the road up: a concrete deck edge beyond each
## guardrail, a parapet, the girder fascia, the deck's underside, a hammerhead pier
## under each carriageway every `pier_spacing_m`, and the ground strip under the road
## between the two lowered ground ribbons. Spec: World → Biomes ("City at night:
## skyline, elevated highway sections, neon billboards"), Performance budget (one
## draw call: everything is one world-material mesh, vertex-lit, flat-shaded).
##
##   elevated.biome_director = director
##   elevated.clearance = landmark_clearance      # optional: no stretch at a landmark
##   elevated.setup(ctx, road, origin); elevated.update_view(player_s)
##   elevated.plan.drop_at(s)                     # the ground ribbon's drop (road mesher)
##
## The road itself never moves (road space, traffic and scoring are untouched). The
## ground ribbon must follow `plan.drop_at(s)`: that is RoadChunkMesher's geometry
## (GroundDropMesher is the hook; see docs/BIOMES.md).

const MATERIAL_PATH := "res://assets/shaders/materials/world.tres"
## Deck-edge strip lift over the road plane (above the dropped verge's old level).
const DECK_LIFT_M := 0.02  # lint: allow-number z-fight lift, not tuning

var plan: ElevatedPlan
## Optional LandmarkClearance (set before setup): stretches avoid landmark zones.
var clearance: LandmarkClearance

var _smp := RoadSample.new()
var _smp_b := RoadSample.new()
var _focus_def: ElevatedDef
# Build state (one build at a time: see BiomeFeature).
var _b_def: ElevatedDef
var _b_lo: float = 0.0
var _b_hi: float = 0.0
var _r0: int = 0
var _n_rows: int = 0
var _k0: int = 0
var _n_piers: int = 0


func feature_id() -> StringName:
	return &"elevated"


func step_m() -> float:
	return _focus_def.rebuild_step_m if _focus_def != null else last_step_m()


func units_per_frame() -> int:
	return _focus_def.build_units_per_frame if _focus_def != null else super()


func _material() -> Material:
	return load(MATERIAL_PATH) as Material


func _on_setup() -> void:
	var lookup := Callable()
	if biome_director != null:
		lookup = biome_director.biome_at
	plan = ElevatedPlan.new(props_seed, lookup, fallback_biome)
	plan.clearance = clearance


func update_view(focus_s: float) -> void:
	if road == null:
		return
	_focus_def = plan.def_at(focus_s)
	super(focus_s)


# ---------------------------------------------------------------- Build

## Units: the row intervals of [s_lo, s_hi] (deck, parapets, fascia, underside,
## ground under the road where the ground drops), then one unit per pier position.
func _begin(s_lo: float, s_hi: float) -> int:
	if clearance != null:
		clearance.prepare(s_lo, s_hi)
	_b_lo = s_lo
	_b_hi = s_hi
	_b_def = _any_def(s_lo, s_hi)
	if _b_def == null:
		return 0
	_r0 = int(floor(s_lo / _b_def.row_step_m))
	_n_rows = maxi(int(ceil(s_hi / _b_def.row_step_m)) - _r0, 0)
	_k0 = int(ceil(s_lo / _b_def.pier_spacing_m)) if _b_def.pier_spacing_m > 0.0 else 0
	var k1 := int(floor(s_hi / _b_def.pier_spacing_m)) if _b_def.pier_spacing_m > 0.0 else -1
	_n_piers = maxi(k1 - _k0 + 1, 0)
	return _n_rows + _n_piers


func _emit(i: int, out: FeatureMesh) -> void:
	if i < _n_rows:
		var step := _b_def.row_step_m
		var sa := maxf(float(_r0 + i) * step, _b_lo)
		var sb := minf(float(_r0 + i + 1) * step, _b_hi)
		if sb <= sa:
			return
		var da := plan.drop_at(sa)
		var db := plan.drop_at(sb)
		if da > 0.0 or db > 0.0 or plan.drop_at((sa + sb) * 0.5) > 0.0:
			var dd := plan.def_at(sa)
			_interval(out, dd if dd != null else _b_def, sa, sb, da, db)
		return
	var s := float(_k0 + i - _n_rows) * _b_def.pier_spacing_m
	var drop := plan.drop_at(s)
	var d_def := plan.def_at(s)
	if d_def != null and drop - d_def.girder_depth_m - d_def.cap_depth_m >= d_def.pier_min_height_m:
		road.sample_into(s, _smp)
		for side: float in [1.0, -1.0]:
			_pier(out, d_def, s, side, drop)


## The first elevated def in the window (coarse probes), or null.
func _any_def(s_lo: float, s_hi: float) -> ElevatedDef:
	var s := s_lo
	var probe := road_tuning.roadside_update_step_m
	while s <= s_hi:
		var d := plan.def_at(s)
		if d != null:
			return d
		s += probe
	return null


func _interval(out: FeatureMesh, def: ElevatedDef, sa: float, sb: float, drop_a: float, drop_b: float) -> void:
	road.sample_into(sa, _smp)
	road.sample_into(sb, _smp_b)
	var up_a := _smp.up
	var up_b := _smp_b.up
	var girder_a := minf(def.girder_depth_m, drop_a)
	var girder_b := minf(def.girder_depth_m, drop_b)
	for side: float in [1.0, -1.0]:
		var outer_a := road.shoulder_outer_d(sa)
		var outer_b := road.shoulder_outer_d(sb)
		var edge_a := road.guardrail_d(sa) + def.deck_overhang_m
		var edge_b := road.guardrail_d(sb) + def.deck_overhang_m
		var lift_a := up_a * DECK_LIFT_M
		var lift_b := up_b * DECK_LIFT_M
		var out_dir := _smp.right * side
		# Deck edge strip (shoulder edge to the deck edge), at road level.
		out.flat_quad(_p(_smp, side * outer_a) + lift_a, _p(_smp, side * edge_a) + lift_a,
			_p(_smp_b, side * edge_b) + lift_b, _p(_smp_b, side * outer_b) + lift_b,
			up_a, def.concrete_color)
		# Parapet on the edge: inner face, top, outer face (down to the girder's bottom).
		var pin_a := edge_a - def.parapet_width_m
		var pin_b := edge_b - def.parapet_width_m
		var h_a := up_a * def.parapet_height_m
		var h_b := up_b * def.parapet_height_m
		out.flat_quad(_p(_smp, side * pin_a), _p(_smp, side * pin_a) + h_a,
			_p(_smp_b, side * pin_b) + h_b, _p(_smp_b, side * pin_b), -out_dir,
			def.concrete_color)
		out.flat_quad(_p(_smp, side * pin_a) + h_a, _p(_smp, side * edge_a) + h_a,
			_p(_smp_b, side * edge_b) + h_b, _p(_smp_b, side * pin_b) + h_b, up_a,
			def.concrete_color)
		out.flat_quad(_p(_smp, side * edge_a) + h_a, _p(_smp, side * edge_a) - up_a * girder_a,
			_p(_smp_b, side * edge_b) - up_b * girder_b, _p(_smp_b, side * edge_b) + h_b,
			out_dir, def.fascia_color)
		# Underside of the deck, from the edge to the median.
		out.flat_quad(_p(_smp, side * edge_a) - up_a * girder_a, _p(_smp, 0.0) - up_a * girder_a,
			_p(_smp_b, 0.0) - up_b * girder_b, _p(_smp_b, side * edge_b) - up_b * girder_b,
			-up_a, def.underside_color)
		# Ground under the road, between the lowered ground ribbons (their inner edge is
		# the paved shoulder's outer edge).
		out.flat_quad(_p(_smp, side * outer_a) - Vector3.UP * drop_a, _p(_smp, 0.0) - Vector3.UP * drop_a,
			_p(_smp_b, 0.0) - Vector3.UP * drop_b, _p(_smp_b, side * outer_b) - Vector3.UP * drop_b,
			Vector3.UP, def.under_ground_color)


func _pier(out: FeatureMesh, def: ElevatedDef, s: float, side: float, drop: float) -> void:
	var inner := road.median_barrier_d(s) + def.pier_width_m * 0.5
	var outer := road.guardrail_d(s) - def.pier_width_m * 0.5
	var mid := (inner + outer) * 0.5
	var f := Vector3(_smp.tangent.x, 0.0, _smp.tangent.z).normalized()
	var r := _smp.right
	var top := -def.girder_depth_m
	var cap_bot := top - def.cap_depth_m
	var base := _p(_smp, side * mid)
	# Column: from the ground (-drop) to the cap's bottom; four sides.
	_box(out, base, r, f, side * 0.0, def.pier_width_m, def.pier_width_m, -drop, cap_bot, def.pier_color, false)
	# Cap: spans the carriageway under the girder.
	var cap_center := _p(_smp, side * (inner + outer) * 0.5)
	_box(out, cap_center, r, f, 0.0, outer - inner + def.pier_width_m, def.cap_length_m, cap_bot, top,
		def.pier_color, true)


## A box centered at `center` (+ r * dx) in the frame (r, up, f), `w` across, `l`
## along, from height y0 to y1; the bottom face only with `bottom`, no top.
func _box(out: FeatureMesh, center: Vector3, r: Vector3, f: Vector3, dx: float, w: float, l: float, y0: float,
		y1: float, col: Color, bottom: bool) -> void:
	var c := center + r * dx
	var hw := r * (w * 0.5)
	var hl := f * (l * 0.5)
	var lo := Vector3.UP * y0
	var hi := Vector3.UP * y1
	var corners: Array[Vector3] = [c - hw - hl, c + hw - hl, c + hw + hl, c - hw + hl]
	for i in 4:
		var a := corners[i]
		var b := corners[(i + 1) % 4]
		var mid := (a + b) * 0.5 - c
		out.flat_quad(a + lo, b + lo, b + hi, a + hi, mid, col)
	if bottom:
		out.flat_quad(corners[0] + lo, corners[1] + lo, corners[2] + lo, corners[3] + lo, Vector3.DOWN, col)


func _p(smp: RoadSample, d: float) -> Vector3:
	return local(smp, d)
