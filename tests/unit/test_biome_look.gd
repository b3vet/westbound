extends WBTest
## The biome look across a checkpoint (WP6.4a): BiomeDirector blends the world and fog
## tint offsets, crossfades the horizon silhouette sets and sets the desert's heat
## shimmer on the SkyRig. Spec: World → Color script ("Biomes can add tint offsets
## (desert warmer, coast cooler)"), Sky (horizon silhouette cards), Biomes (desert:
## fake heat shimmer near the horizon; every biome across the whole color script).

const SKY_SCENE := "res://src/sun/sky.tscn"

var _t: Tuning
var _sky: SkyRig
var _director: BiomeDirector
var _log: Dictionary = {}


func _record(global_name: StringName, value: Variant) -> void:
	_log[global_name] = value


func before_each() -> void:
	_t = Tuning.load_default()
	_log.clear()
	_sky = (load(SKY_SCENE) as PackedScene).instantiate() as SkyRig
	_sky.push_sink = _record
	_sky.view_distance_override_m = 700.0
	_sky.set_process(false)
	tree.root.add_child(_sky)
	_director = BiomeDirector.new()
	_director.sky = _sky
	tree.root.add_child(_director)
	_director.setup(RunContext.new(3, RunContext.MODE_JOURNEY, _t), StraightRoadPath.new(3, _t.road), null)


func after_each() -> void:
	_director.free()
	_sky.free()


func _mat() -> ShaderMaterial:
	return (_sky.get_node("Horizon") as MeshInstance3D).material_override as ShaderMaterial


func _tint() -> Vector3:
	_sky.push_now()
	return _log[&"wb_biome_tint_offset"]


func test_tint_offsets_blend_across_the_checkpoint() -> void:
	var farm := _director.plan.biome_for_leg(1)
	var desert := _director.plan.biome_for_leg(2)
	var line := _t.legs.leg_length_m()
	var before := _t.legs.biome_blend_before_m
	var after := _t.legs.biome_blend_after_m
	_director.update_view(line * 0.5)
	var w := farm.world_tint_offset
	near((_tint() - Vector3(w.r, w.g, w.b)).length(), 0.0, 1e-6, "farmland's offset mid-leg")
	_director.update_view(line + after + 10.0)
	w = desert.world_tint_offset
	near((_tint() - Vector3(w.r, w.g, w.b)).length(), 0.0, 1e-6, "the desert's after the blend")
	_director.update_view(line - before + 0.5 * (before + after))
	var half := farm.world_tint_offset.lerp(desert.world_tint_offset, 0.5)
	near((_tint() - Vector3(half.r, half.g, half.b)).length(), 0.0, 1e-6, "half-way at the blend's centre")


func test_fog_tint_shifts_the_fog_colour() -> void:
	var line := _t.legs.leg_length_m()
	_director.update_view(line * 0.5)
	_sky.push_now()
	var farm_fog: Color = _log[&"wb_fog_color"]
	_director.update_view(line * 1.5)
	_sky.push_now()
	var desert_fog: Color = _log[&"wb_fog_color"]
	var desert := _director.plan.biome_for_leg(2)
	var farm := _director.plan.biome_for_leg(1)
	var dr := desert.fog_tint_offset.r - farm.fog_tint_offset.r
	var db := desert.fog_tint_offset.b - farm.fog_tint_offset.b
	check(signf(desert_fog.r - farm_fog.r) == signf(dr), "red follows the fog offset")
	check(signf(desert_fog.b - farm_fog.b) == signf(db), "blue follows the fog offset")
	# Horizon tints move with it (the cards are tinted toward the fog).
	var base := _sky.current().horizon_tint_0
	var pushed: Color = _log[&"wb_horizon_tint_0"]
	var want := Color(clampf(base.r + desert.fog_tint_offset.r, 0, 1), clampf(base.g + desert.fog_tint_offset.g, 0, 1),
		clampf(base.b + desert.fog_tint_offset.b, 0, 1)).srgb_to_linear()
	near(pushed.r, want.r, 1e-5)
	near(pushed.b, want.b, 1e-5)


func test_horizon_crossfades_and_desert_shimmers() -> void:
	var farm := _director.plan.biome_for_leg(1)
	var desert := _director.plan.biome_for_leg(2)
	var line := _t.legs.leg_length_m()
	_director.update_view(line * 0.5)
	var mat := _mat()
	eq(mat.get_shader_parameter(&"layer_style"), farm.horizon_layer_style)
	eq(mat.get_shader_parameter(&"layer_mix"), 0.0)
	eq(_sky.heat_shimmer(), farm.heat_shimmer)
	var hb := _t.legs.horizon_blend_before_m
	var ha := _t.legs.horizon_blend_after_m
	_director.update_view(line - hb + 0.5 * (hb + ha))
	eq(mat.get_shader_parameter(&"layer_style"), farm.horizon_layer_style, "from farmland's set")
	eq(mat.get_shader_parameter(&"layer_style_b"), desert.horizon_layer_style, "to the desert's")
	near(float(mat.get_shader_parameter(&"layer_mix")), 0.5, 1e-6, "half-way")
	near(_sky.heat_shimmer(), 0.5 * (farm.heat_shimmer + desert.heat_shimmer), 1e-6, "the shimmer fades in")
	_director.update_view(line + ha + 1.0)
	eq(mat.get_shader_parameter(&"layer_style"), desert.horizon_layer_style)
	eq(mat.get_shader_parameter(&"layer_height_m"), desert.horizon_layer_height_m)
	eq(mat.get_shader_parameter(&"layer_mix"), 0.0)
	gt(_sky.heat_shimmer(), 0.0, "heat shimmer over the desert")
	near(float(mat.get_shader_parameter(&"heat_shimmer")), desert.heat_shimmer, 1e-6)


## The director only pushes when the look changes (not every frame).
func test_pushes_only_on_change() -> void:
	var line := _t.legs.leg_length_m()
	_director.update_view(line * 0.5)
	_sky.push_now()
	_log.clear()
	_director.update_view(line * 0.5 + 10.0)
	eq(_sky.push_now(), 0, "nothing changed mid-leg")
