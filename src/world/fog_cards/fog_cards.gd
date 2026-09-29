class_name FogCards
extends BiomeFeature
## Low fog layers beside the road (valley fog biome). Spec: World → Biomes ("Valley
## fog: low fog layers in valleys (cards), forests, dawn-friendly palette"), Color
## script, Performance budget (one draw call, alpha-blended, no depth writes).
## Data: BiomeDef.fog_cards (FogCardsDef). Shader: assets/shaders/fog_card.gdshader.
##
##   fog.biome_director = director
##   fog.setup(ctx, road, origin); fog.update_view(player_s)
##
## Banks are placed per (cell, side) from the props seed only; each is `layer_count`
## stacked strips following the road (rows every row_step_m) from its near edge
## (>= scenery line + setback_min_m: never over the carriageway or the clear zone)
## outward, plus `curtain_count` vertical curtains standing in the bank. Vertex
## channels for fog_card.gdshader: UV = (across 0..1, along 0..1), COLOR.a = the
## opacity (layer alpha x valley factor). Curtains use UV.x = 0.5 at the foot .. 1 at
## the top, so only their top edge fades.

const MATERIAL_PATH := "res://assets/shaders/materials/fog_card.tres"
const SALT_RIGHT := 1
const SALT_LEFT := 2
const _MASK31 := 0x7FFFFFFF
## Floats per bank in _banks: s start, s end, side, setback, depth, opacity.
const BANK_FIELDS := 6

var _smp := RoadSample.new()
var _focus_def: FogCardsDef
var _material_instance: ShaderMaterial
var _uniform_def: FogCardsDef
var _rng := Rng.new(0)
## Banks placed by the last build (tests, dev HUD).
var bank_count: int = 0
# Build state (one build at a time: see BiomeFeature).
var _banks := PackedFloat64Array()
var _bank_defs: Array[FogCardsDef] = []
var _b_lo: float = 0.0
var _b_hi: float = 0.0


func feature_id() -> StringName:
	return &"fog_cards"


func step_m() -> float:
	return _focus_def.rebuild_step_m if _focus_def != null else last_step_m()


func units_per_frame() -> int:
	return _focus_def.build_units_per_frame if _focus_def != null else super()


func _material() -> Material:
	if _material_instance == null:
		_material_instance = (load(MATERIAL_PATH) as ShaderMaterial).duplicate() as ShaderMaterial
	return _material_instance


func def_at(s: float) -> FogCardsDef:
	var b := biome_at(s)
	return b.fog_cards if b != null else null


## Banks reach a cell and length_factor_max cells back; their valley factor probes
## valley_probe_m further.
func _reach_behind_for(b: BiomeDef) -> float:
	var d := b.fog_cards
	if d == null:
		return 0.0
	return d.rebuild_step_m + d.cell_length_m * (d.length_factor_max + 1.0) + d.valley_probe_m


func update_view(focus_s: float) -> void:
	if road == null:
		return
	_focus_def = def_at(focus_s)
	_apply_uniforms(_focus_def)
	super(focus_s)
	if _material_instance != null and origin != null:
		_material_instance.set_shader_parameter(&"origin_xz", Vector2(origin.origin_x, origin.origin_z))


func _apply_uniforms(def: FogCardsDef) -> void:
	if def == null or def == _uniform_def or _material_instance == null:
		return
	_uniform_def = def
	var m := _material_instance
	m.set_shader_parameter(&"softness", def.edge_softness_frac)
	m.set_shader_parameter(&"brightness", def.brightness_factor)
	m.set_shader_parameter(&"noise_scale_m", def.noise_scale_m)
	m.set_shader_parameter(&"noise_depth", def.noise_depth_frac)
	m.set_shader_parameter(&"near_clear_m", def.near_clear_m)
	m.set_shader_parameter(&"near_fade_m", def.near_fade_m)
	m.set_shader_parameter(&"midday_factor", def.midday_factor)
	m.set_shader_parameter(&"midday_sun_y", def.midday_sun_y)


## Opacity factor for a bank centered at s: ridge_factor .. 1 with the dip depth.
func valley_factor(s: float, def: FogCardsDef) -> float:
	var e := _elev(s)
	var mean := (_elev(maxf(s - def.valley_probe_m, 0.0)) + _elev(s + def.valley_probe_m)) * 0.5
	var t := clampf((mean - e) / maxf(def.valley_depth_m, 0.001), 0.0, 1.0)
	return lerpf(def.ridge_factor, 1.0, t)


## Road elevation at s. The road is generated to s first (director rate; the table does
## not depend on how far it goes), so a bank's opacity never depends on how far the
## road happened to be generated; behind, the run keeps the road to reach_behind_m().
func _elev(s: float) -> float:
	if s > road.length_generated():
		road.ensure_generated_to(s)
	var s_min := 0.0
	if road is ProceduralRoadPath:
		s_min = (road as ProceduralRoadPath).first_retained_s()
	road.sample_into(clampf(s, s_min, road.length_generated()), _smp)
	return _smp.pos_y


# ---------------------------------------------------------------- Build

## Units: one bank each. The bank list is drawn up front (cheap: a few draws per
## cell and side); geometry is emitted per unit.
func _begin(s_lo: float, s_hi: float) -> int:
	bank_count = 0
	_banks.clear()
	_bank_defs.clear()
	var def := _focus_def
	var s := s_lo
	while def == null and s <= s_hi:
		def = def_at(s)
		s += road_tuning.roadside_update_step_m
	if def == null:
		return 0
	_b_lo = s_lo
	_b_hi = s_hi
	var reach := def.cell_length_m * def.length_factor_max
	var c0 := int(floor((s_lo - reach) / def.cell_length_m))
	var c1 := int(ceil(s_hi / def.cell_length_m))
	var layer_seed := TraceHash.mix_int(TraceHash.SEED, props_seed)
	for c in range(maxi(c0, 0), c1 + 1):
		var mid := (float(c) + 0.5) * def.cell_length_m
		var cd := def_at(mid)
		if cd == null:
			continue
		for salt: int in [SALT_RIGHT, SALT_LEFT]:
			_seed(layer_seed, c, salt)
			var present := _rng.unit()
			var length := cd.cell_length_m * _rng.float_range(cd.length_factor_min, cd.length_factor_max)
			var setback := _rng.float_range(cd.setback_min_m, cd.setback_max_m)
			var depth := _rng.float_range(cd.depth_min_m, cd.depth_max_m)
			var shift := _rng.float_range(-0.5, 0.5) * cd.cell_length_m
			var vf := valley_factor(mid, cd)
			if present >= cd.chance_frac * vf:
				continue
			var a := mid + shift - length * 0.5
			var b := a + length
			if b < s_lo or a > s_hi:
				continue
			var side := 1.0 if salt == SALT_RIGHT else -1.0
			_banks.append_array(PackedFloat64Array([maxf(a, 0.0), b, side, setback, depth, cd.alpha * vf]))
			_bank_defs.append(cd)
	bank_count = _bank_defs.size()
	return bank_count


func _emit(i: int, out: FeatureMesh) -> void:
	var k := i * BANK_FIELDS
	_bank(out, _bank_defs[i], _banks[k], _banks[k + 1], _banks[k + 2], _banks[k + 3], _banks[k + 4],
		_banks[k + 5], _b_lo, _b_hi)


func _seed(layer_seed: int, c: int, salt: int) -> void:
	var h := TraceHash.mix_int(TraceHash.mix_int(layer_seed, c), salt)
	_rng.set_state(((h & _MASK31) << 32) | TraceHash.mix_int(h, c))


## One bank: layer_count strips from s a to b (clipped to the window, UV kept),
## rows every row_step_m.
func _bank(out: FeatureMesh, def: FogCardsDef, a: float, b: float, side: float, setback: float, depth: float,
		opacity: float, s_lo: float, s_hi: float) -> void:
	var sa := maxf(a, s_lo)
	var sb := minf(b, s_hi)
	if sb <= sa:
		return
	var n := maxi(int(ceil((sb - sa) / def.row_step_m)), 1)
	var col := Color(1.0, 1.0, 1.0, opacity)
	var s_gen := road.length_generated()
	for layer in def.layer_count:
		var h := def.base_height_m + float(layer) * def.layer_spacing_m
		var prev_near := -1
		var prev_far := -1
		for i in n + 1:
			var s := minf(lerpf(sa, sb, float(i) / float(n)), s_gen)
			road.sample_into(s, _smp)
			var line := road.guardrail_d(s) + road_tuning.prop_clearance_m
			var v := (s - a) / maxf(b - a, 0.001)
			var up := _smp.up * h
			var near := out.vertex(local(_smp, side * (line + setback)) + up, _smp.up, col,
				Vector2(0.0, v))
			var far := out.vertex(local(_smp, side * (line + setback + depth)) + up, _smp.up, col,
				Vector2(1.0, v))
			if prev_near >= 0:
				out.quad_idx(prev_near, prev_far, far, near, Vector3.UP)
			prev_near = near
			prev_far = far
	var curtain_col := Color(1.0, 1.0, 1.0, def.curtain_alpha * opacity / maxf(def.alpha, 0.001))
	for k in def.curtain_count:
		var at := setback + depth * float(k + 1) / float(def.curtain_count)
		var prev_lo := -1
		var prev_hi := -1
		for i in n + 1:
			var s := minf(lerpf(sa, sb, float(i) / float(n)), s_gen)
			road.sample_into(s, _smp)
			var line := road.guardrail_d(s) + road_tuning.prop_clearance_m
			var v := (s - a) / maxf(b - a, 0.001)
			var foot := local(_smp, side * (line + at)) - _smp.up * def.base_height_m
			var lo := out.vertex(foot, _smp.up, curtain_col, Vector2(0.5, v))
			var hi := out.vertex(foot + _smp.up * (def.curtain_height_m + def.base_height_m), _smp.up, curtain_col,
				Vector2(1.0, v))
			if prev_lo >= 0:
				out.quad_idx(prev_lo, prev_hi, hi, lo, -_smp.right * side)
			prev_lo = lo
			prev_hi = hi
