extends WBTest
## Checkpoint landmark styles per biome (WP5.5): BiomeDef.landmark_styles cycled by leg
## from a seeded start, the biome director filling the CHECKPOINT feature tag
## (CONTRACTS §3), and the landmarks building the tagged style. Spec: Biomes ("Biome
## data: ... checkpoint landmark style"), Core loop → Legs and checkpoints (express toll
## gantry, suspension bridge, big sign gantry or tunnel portal), Architecture rule 2.

const SEED := 5507
const VIEW_M := 700.0

var _t: Tuning
var _lt: LandmarkTuning
var _nodes: Array[Node] = []


func before_each() -> void:
	_t = Tuning.load_default()
	_lt = LandmarkTuning.load_default()


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


func _director(seed_value: int, road: RoadPath, origin: FloatingOrigin) -> BiomeDirector:
	var d := BiomeDirector.new()
	tree.root.add_child(d)
	_nodes.append(d)
	d.setup(RunContext.new(seed_value, RunContext.MODE_JOURNEY, _t), road, origin)
	return d


func _farmland() -> BiomeDef:
	return load(BiomeDirector.DEFAULT_BIOME_PATH) as BiomeDef


func test_farmland_mixes_all_four_styles() -> void:
	var b := _farmland()
	eq(b.landmark_styles.size(), 4, "farmland: toll gantry, sign gantry, bridge, tunnel")
	for kind in LandmarkBuilds.kinds():
		check(b.landmark_styles.has(kind), "farmland has %s" % kind)
	eq(b.landmark_style, BiomeDef.LANDMARK_TOLL_GANTRY, "the single style is kept (backward compatible)")


func test_styles_cycle_through_the_list() -> void:
	var b := _farmland()
	var n := b.landmark_styles.size()
	for style_seed: int in [0, 1, 99, 123456789]:
		var first := b.landmark_styles.find(b.checkpoint_style(1, style_seed))
		check(first >= 0, "a listed style")
		for leg in range(1, 13):
			eq(b.checkpoint_style(leg, style_seed), b.landmark_styles[(first + leg - 1) % n],
				"seed %d leg %d: the next in the list" % [style_seed, leg])
		var seen := {}
		for leg in range(5, 5 + n):
			seen[b.checkpoint_style(leg, style_seed)] = true
		eq(seen.size(), n, "any %d consecutive legs show every style" % n)
	# The start depends on the seed.
	var starts := {}
	for style_seed in 16:
		starts[b.checkpoint_style(1, style_seed)] = true
	gt(starts.size(), 1, "different seeds start the cycle at different styles")


func test_single_style_biome_is_unchanged() -> void:
	var b := BiomeDef.new()
	b.id = &"desert"
	b.landmark_style = BiomeDef.LANDMARK_TUNNEL_PORTAL
	for leg in range(1, 6):
		eq(b.checkpoint_style(leg, SEED), BiomeDef.LANDMARK_TUNNEL_PORTAL)


## The director tags the real road's checkpoint features with the style of the biome
## whose leg ends there: deterministic by seed, all four seen in four legs.
func test_director_fills_the_checkpoint_tag_deterministically() -> void:
	var legs := 8
	var tags: Array[PackedStringArray] = []
	for run in 3:
		var seed_value := SEED if run < 2 else SEED + 1
		var ctx := RunContext.new(seed_value, RunContext.MODE_JOURNEY, _t)
		var road := ProceduralRoadPath.new(ctx)
		var director := _director(seed_value, road, null)
		var end := _t.legs.leg_length_m() * float(legs) + 1.0
		road.ensure_generated_to(end)
		var found: Array[RoadFeature] = []
		road.features_in(0.0, end, found)
		director.tag_checkpoints(found)
		var out := PackedStringArray()
		for f in found:
			if f.kind == RoadFeature.Kind.CHECKPOINT:
				eq(f.tag, director.checkpoint_style(int(f.value), f.s_start), "leg %d tagged" % int(f.value))
				out.append(String(f.tag))
			elif f.kind == RoadFeature.Kind.SIGN and f.value > 0.0 and f.s_start + f.value < end:
				check(f.tag != &"" and not LandmarkBuilds.kinds().has(f.tag), "signs keep their own tag")
		eq(out.size(), legs, "one checkpoint per leg")
		var seen := {}
		for i in 4:
			seen[out[i]] = true
		eq(seen.size(), 4, "the first four legs show all four styles")
		tags.append(out)
	eq(tags[0], tags[1], "same seed, same styles")
	var road2 := StraightRoadPath.new(3, _t.road)
	var tagged := RoadFeature.make(RoadFeature.Kind.CHECKPOINT, 3500.0, 3500.0, 1.0, BiomeDef.LANDMARK_SIGN_GANTRY)
	var d2 := _director(SEED, road2, null)
	var list: Array[RoadFeature] = [tagged]
	d2.tag_checkpoints(list)
	eq(tagged.tag, BiomeDef.LANDMARK_SIGN_GANTRY, "an explicit tag is kept")


## Driving four legs of the real road: each checkpoint's landmark is the director's
## style, and every kind appears once.
func test_landmarks_use_the_tag() -> void:
	var ctx := RunContext.new(SEED, RunContext.MODE_JOURNEY, _t)
	var road := ProceduralRoadPath.new(ctx)
	var origin := _origin()
	var director := _director(SEED, road, origin)
	var lm := Landmarks.new()
	lm.view_distance_override_m = VIEW_M
	lm.biome_director = director
	tree.root.add_child(lm)
	_nodes.append(lm)
	lm.setup(ctx, road, origin)
	var leg_m := _t.legs.leg_length_m()
	var seen := {}
	var s := 60.0
	while s < leg_m * 4.0 + 200.0:
		road.ensure_generated_to(s + VIEW_M + 2.0 * leg_m)
		var smp := road.sample(s)
		origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
		lm.update_view(s)
		for slot in lm.live_slots():
			if slot.kind != Landmarks.KIND_SIGN:
				seen[slot.leg] = slot.kind
		s += _lt.update_step_m * 4.0
	eq(seen.size(), 4, "four checkpoints")
	var kinds := {}
	for leg: int in seen:
		eq(seen[leg], director.checkpoint_style(leg, float(leg) * leg_m), "leg %d uses its tag" % leg)
		kinds[seen[leg]] = true
	eq(kinds.size(), 4, "all four landmark kinds in four legs")
	# The roadside's clearance resolves the same styles.
	var c := LandmarkClearance.new()
	c.setup(road, _lt, director)
	for leg: int in seen:
		var f := RoadFeature.make(RoadFeature.Kind.CHECKPOINT, float(leg) * leg_m, float(leg) * leg_m, float(leg))
		eq(c.style_for(f), seen[leg], "clearance style of leg %d" % leg)
