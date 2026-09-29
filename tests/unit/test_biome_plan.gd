extends WBTest
## BiomePlan (WP6.4a): the journey's leg -> biome plan, forks, look blending at the
## checkpoints. Spec: World → Biomes ("Each leg is one biome. Default order below;
## forks swap the next biome"), The journey goal (the coast after 8 legs, then an
## endless coastal highway), Legs and checkpoints. docs/BIOMES.md.

const L := 3500.0

var _t: Tuning
var _a: BiomeDef
var _b: BiomeDef
var _c: BiomeDef


func before_each() -> void:
	_t = Tuning.load_default()
	_a = _biome(&"a", Color(0.2, 0.4, 0.2))
	_b = _biome(&"b", Color(0.8, 0.5, 0.3))
	_c = _biome(&"c", Color(0.5, 0.3, 0.2))


func _biome(id: StringName, ground: Color) -> BiomeDef:
	var d := BiomeDef.new()
	d.id = id
	d.ground_color = ground
	d.verge_color = ground
	return d


func _plan() -> BiomePlan:
	var legs: Array[BiomeDef] = [_a, _b, _b, _c]
	return BiomePlan.new(L, legs, _c)


func test_legs_and_endless() -> void:
	var p := _plan()
	eq(p.leg_at(0.0), 1)
	eq(p.leg_at(L - 0.001), 1)
	eq(p.leg_at(L), 2, "the next leg from the checkpoint line")
	eq(p.leg_at(-10.0), 1)
	eq(p.leg_start_s(3), 2.0 * L)
	eq(p.biome_for_leg(1), _a)
	eq(p.biome_for_leg(2), _b)
	eq(p.biome_for_leg(4), _c)
	eq(p.biome_for_leg(5), _c, "endless")
	eq(p.biome_for_leg(500), _c)
	eq(p.biome_at(L * 1.5), _b)
	eq(p.legs_planned(), 4)
	eq(p.catalog(), [_a, _b, _c] as Array[BiomeDef])


## The default journey (LegsTuning): legs_to_coast legs, farmland first; every id in
## the plan has a data file or falls back to the leg before it.
func test_default_journey_from_tuning() -> void:
	var legs := _t.legs
	eq(legs.leg_biome_ids.size(), legs.legs_to_coast, "one biome per leg to the coast")
	eq(legs.leg_biome_ids[0], &"farmland")
	eq(legs.leg_biome_ids[1], &"desert")
	check(legs.leg_biome_ids.has(&"canyon"))
	eq(legs.endless_biome_id, &"coast", "the endless coastal highway")
	check(not legs.leg_biome_ids.has(&"coast"), "the coast is the destination, after the last leg")
	var p := BiomePlan.from_tuning(legs)
	eq(p.leg_length_m, legs.leg_length_m())
	var prev: BiomeDef = null
	for leg in range(1, legs.legs_to_coast + 2):
		var b := p.biome_for_leg(leg)
		if not check(b != null, "leg %d has a biome" % leg):
			return
		var id := legs.biome_id_for_leg(leg)
		if BiomePlan.load_biome(id) != null:
			eq(b.id, id, "leg %d" % leg)
		else:
			eq(b, prev, "leg %d: %s is not authored yet, the leg before continues" % [leg, id])
			check(p.missing_ids.has(id), "%s reported missing" % id)
		prev = b
	for id in p.missing_ids:
		check(not ResourceLoader.exists(BiomePlan.PATH_FORMAT % id), "%s really missing" % id)


func test_missing_first_leg_falls_back_to_farmland() -> void:
	var legs := _t.legs.duplicate() as LegsTuning
	legs.leg_biome_ids = [&"no_such_biome", &"desert"] as Array[StringName]
	legs.endless_biome_id = &"nope"
	var p := BiomePlan.from_tuning(legs)
	eq(p.biome_for_leg(1).id, &"farmland")
	eq(p.biome_for_leg(2).id, &"desert")
	eq(p.biome_for_leg(3).id, &"desert", "missing endless: the last leg continues")
	eq(p.missing_ids, [&"no_such_biome", &"nope"] as Array[StringName])


func test_forks_swap_one_leg() -> void:
	var p := _plan()
	var v := p.version
	var fork := _biome(&"fork", Color.WHITE)
	p.plan_next(3, fork)
	gt(p.version, v)
	eq(p.biome_for_leg(2), _b)
	eq(p.biome_for_leg(3), fork)
	eq(p.biome_for_leg(4), _c)
	check(p.catalog().has(fork))
	v = p.version
	p.plan_next(3, fork)
	eq(p.version, v, "no change, no new version")
	# Past the planned legs: the list grows with the endless biome in between.
	p.plan_next(7, _a)
	eq(p.biome_for_leg(5), _c)
	eq(p.biome_for_leg(7), _a)
	eq(p.biome_for_leg(8), _c)
	p.set_biome_from_leg(2, fork)
	for leg in range(2, 12):
		eq(p.biome_for_leg(leg), fork, "leg %d after set_biome_from_leg" % leg)
	eq(p.biome_for_leg(1), _a)
	var cand := _biome(&"cand", Color.BLACK)
	p.add_candidate(cand)
	check(p.catalog().has(cand), "fork candidates are in the catalog")


## Blend: from -> to over [line - before, line + after], smoothstep, 0.5 at the centre,
## continuous and monotonic; nothing where the biome does not change.
func test_blend_around_a_checkpoint() -> void:
	var p := _plan()
	var bl := BiomePlan.Blend.new()
	var before := 250.0
	var after := 350.0
	p.blend_into(L * 0.5, before, after, bl)
	eq(bl.from, _a)
	eq(bl.to, _a)
	eq(bl.t, 0.0)
	p.blend_into(L - before - 1.0, before, after, bl)
	eq(bl.t, 0.0, "before the blend")
	eq(bl.from, _a)
	p.blend_into(L - before + 0.5 * (before + after), before, after, bl)
	eq(bl.from, _a)
	eq(bl.to, _b)
	near(bl.t, 0.5, 1e-9, "half-way at the centre")
	p.blend_into(L + after + 1.0, before, after, bl)
	eq(bl.from, _b)
	eq(bl.t, 0.0, "after the blend: all the new biome")
	var last := 0.0
	var s := L - before
	while s <= L + after:
		p.blend_into(s, before, after, bl)
		ge(bl.t, last, "monotonic at %s" % s)
		le(bl.t - last, 0.02, "continuous at %s" % s)
		last = bl.t
		s += 2.0
	near(last, 1.0, 1e-3)
	# Legs 2 -> 3 share a biome: no blend there.
	p.blend_into(2.0 * L, before, after, bl)
	eq(bl.from, _b)
	eq(bl.to, _b)
	eq(bl.t, 0.0)


func test_blend_allocates_nothing() -> void:
	var p := _plan()
	var bl := BiomePlan.Blend.new()
	for i in 10:
		p.blend_into(L - 100.0 + float(i), 250.0, 350.0, bl)
	var before := Performance.get_monitor(Performance.OBJECT_COUNT)
	for i in 1000:
		p.blend_into(L - 100.0 + float(i) * 0.3, 250.0, 350.0, bl)
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), before, "no objects created")


func test_uniform_plan() -> void:
	var p := BiomePlan.uniform(_a, L)
	for leg: int in [1, 2, 9, 100]:
		eq(p.biome_for_leg(leg), _a)
	eq(p.catalog(), [_a] as Array[BiomeDef])
	var bl := BiomePlan.Blend.new()
	p.blend_into(L, 250.0, 350.0, bl)
	eq(bl.t, 0.0)
	p.set_biome_from_leg(3, _b)
	eq(p.biome_for_leg(1), _a, "legs before the switch keep the old biome")
	eq(p.biome_for_leg(2), _a)
	eq(p.biome_for_leg(3), _b)
	eq(p.biome_for_leg(30), _b)


## Road rules are latched per leg: a later plan change does not reach legs the road
## has already asked about (so generated geometry never changes under the player).
func test_road_rules_latch_per_leg() -> void:
	_a.lane_count = 3
	_b.lane_count = 4
	_c.lane_count = 2
	_b.curve_frequency_scale = 0.5
	var p := _plan()
	var r := BiomeRoadRules.new(p, _t.road)
	eq(r.lanes_for_leg(1), 3)
	eq(r.lanes_for_leg(2), 4)
	eq(r.latched_legs(), 2)
	near(r.curve_scale_at(L + 1.0), 0.5, 1e-12)
	p.plan_next(2, _c)
	eq(r.lanes_for_leg(2), 4, "leg 2 latched before the fork")
	p.plan_next(4, _a)
	eq(r.lanes_for_leg(4), 3, "leg 4 not latched yet: follows the fork")
	var tiny := _biome(&"tiny", Color.WHITE)
	tiny.lane_count = 9
	p.plan_next(6, tiny)
	eq(r.lanes_for_leg(6), _t.road.lanes_max, "clamped to the road's range")
	near(r.bend_sight_clearance_at(0.0, 15.0), 15.0, 1e-12, "no biome clearance: the road's")
