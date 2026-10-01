extends WBTest
## Low fog layers (WP6.4b, valley fog): FogCards banks beside the road. Spec: World →
## Biomes ("Valley fog: low fog layers in valleys (cards)"), Color script, Performance
## budget (one alpha-blended draw call), Architecture rule 2 (deterministic by seed).

const SEED := 20260928
const VIEW_M := 700.0
const POS_EPS := 0.01

var _t: Tuning
var _valley: BiomeDef
var _nodes: Array[Node] = []


func before_each() -> void:
	_t = Tuning.load_default()
	_valley = load("res://data/biomes/valley_fog.tres") as BiomeDef


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()


func _origin() -> FloatingOrigin:
	var o := FloatingOrigin.new()
	o.setup(_t.road.floating_origin_shift_km)
	tree.root.add_child(o)
	_nodes.append(o)
	return o


func _fog(road: RoadPath, origin: FloatingOrigin, seed_value: int = SEED) -> FogCards:
	var f := FogCards.new()
	f.fallback_biome = _valley
	f.view_distance_override_m = VIEW_M
	tree.root.add_child(f)
	_nodes.append(f)
	f.setup(RunContext.new(seed_value, RunContext.MODE_JOURNEY, _t), road, origin)
	return f


func test_valley_has_fog_cards_that_clear_the_road() -> void:
	var def := _valley.fog_cards
	if not check(def != null, "the valley has fog cards"):
		return
	var road := StraightRoadPath.new(_t.road.lanes_default, _t.road)
	var origin := _origin()
	var f := _fog(road, origin)
	f.update_view(2000.0)
	gt(f.bank_count, 0, "banks placed")
	eq(f.draw_calls(), 1, "one draw call")
	var m := f.mesh()
	var verts: PackedVector3Array = m.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var p := f.mesh_instance().position
	var line := road.guardrail_d(0.0) + _t.road.prop_clearance_m
	var top := maxf(def.base_height_m + float(def.layer_count - 1) * def.layer_spacing_m, def.curtain_height_m)
	for v in verts:
		var ad := absf(origin.origin_x + p.x + v.x)
		var h := origin.origin_y + p.y + v.y
		if ad < line + def.setback_min_m - POS_EPS:
			fail("fog over the road or its clear zone at |d| = %.2f" % ad)
			return
		if h < -def.base_height_m - POS_EPS or h > top + POS_EPS:
			fail("fog card at height %.2f" % h)
			return
	# Opacity lives in COLOR.a, never above the def's layer / curtain alpha.
	var cols: PackedColorArray = m.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var amax := 0.0
	for c in cols:
		amax = maxf(amax, c.a)
	le(amax, maxf(def.alpha, def.curtain_alpha) + 1e-6, "opacity within the data")
	gt(amax, 0.0, "visible")


func test_material_is_a_late_transparent_layer_that_fades_near_the_camera() -> void:
	var f := _fog(StraightRoadPath.new(_t.road.lanes_default, _t.road), _origin())
	var mat := f.mesh_instance().material_override as ShaderMaterial
	if not check(mat != null, "shader material"):
		return
	gt(mat.render_priority, -97, "drawn after the sky parts (§13 priorities)")
	eq(mat.shader.resource_path, "res://assets/shaders/fog_card.gdshader")
	f.update_view(1000.0)
	eq(mat.get_shader_parameter(&"near_clear_m"), _valley.fog_cards.near_clear_m, "near fade from the data")
	gt(_valley.fog_cards.near_clear_m + _valley.fog_cards.near_fade_m, 20.0,
		"clear around the player's car and the chase camera")


func test_denser_in_dips() -> void:
	var def := _valley.fog_cards
	var ctx := RunContext.new(SEED, RunContext.MODE_JOURNEY, _t)
	var road := ProceduralRoadPath.new(ctx)
	road.ensure_generated_to(40000.0)
	var f := _fog(road, _origin())
	var lo := INF
	var hi := -INF
	var s := 1000.0
	while s < 38000.0:
		var vf := f.valley_factor(s, def)
		lo = minf(lo, vf)
		hi = maxf(hi, vf)
		s += 100.0
	ge(lo, def.ridge_factor - 1e-9, "valley factor >= ridge factor")
	le(hi, 1.0 + 1e-9, "valley factor <= 1")
	gt(hi, lo + 0.1, "dips make a difference")


func test_same_seed_same_banks() -> void:
	var sigs: Array[int] = []
	for seed_value: int in [SEED, SEED, SEED + 3]:
		var road := StraightRoadPath.new(_t.road.lanes_default, _t.road)
		var f := _fog(road, _origin(), seed_value)
		var h := TraceHash.SEED
		var s := 500.0
		while s < 6000.0:
			f.update_view(s)
			var m := f.mesh()
			if m.get_surface_count() > 0:
				var verts: PackedVector3Array = m.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
				h = TraceHash.mix_int(h, verts.size())
				for i in range(0, verts.size(), 11):
					h = TraceHash.mix_float(h, snappedf(verts[i].x, 0.001))
			s += 333.0
		sigs.append(h)
	eq(sigs[0], sigs[1], "same seed: same fog")
	ne(sigs[0], sigs[2], "another seed: other fog")


## Prefetching and swapping per step keep every frame cheap: the p99.5 update_view
## while driving at top speed stays well inside a frame. Load-robust (WBFrameBench,
## WP9.10): three drives on fresh fog cards, each frame's cost the minimum over them,
## re-measured once if over budget. A frame that really costs too much does so in
## every drive and still fails.
func test_frame_cost_while_driving() -> void:
	var usec := WBFrameBench.tail_within("fog cards p99.5 frame (prefetch + swap)", _drive_at_top_speed,
			WBFrameBench.P995, 1500.0)
	le(usec, WBBench.budget(1500.0), "p99.5 fog frame usec")


## One timed drive (fresh fog cards, warmed at s = 0): each frame's update_view usec.
func _drive_at_top_speed() -> PackedInt64Array:
	var road := StraightRoadPath.new(_t.road.lanes_default, _t.road)
	var f := _fog(road, _origin())
	var v := Units.kmh_to_mps(_t.vehicle.car_top_speed_max_kmh) * (1.0 + Units.pct_to_frac(_t.vehicle.boost_top_speed_bonus_pct))
	var per_frame_m := v / float(_t.quality.gameplay_fps)
	f.update_view(0.0)
	var samples := PackedInt64Array()
	var s := 0.0
	while s < 8000.0:
		s += per_frame_m
		var t0 := Time.get_ticks_usec()
		f.update_view(s)
		samples.append(Time.get_ticks_usec() - t0)
	return samples
