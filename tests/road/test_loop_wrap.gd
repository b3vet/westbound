extends WBTest
## N3.2 wrap-around pieces of the loop: the periodic look plan, the unwrapped-s helpers
## and the loop's fixed elevated zone. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → The loop
## map ("s wraps modulo L. Every distance comparison uses the wrapped signed
## difference"); docs/LOOP_MAP.md → Loop test mode. The run across the seam:
## tests/run/test_run_loop.gd.

const SECTIONS: Array[StringName] = [&"desert", &"canyon", &"coast", &"city", &"farmland"]

var t: Tuning
var road: LoopRoadPath
var L: float


func before_all() -> void:
	t = Tuning.load_default()
	road = RunLoop.loop_road(t)
	L = road.length()


func test_periodic_biome_plan_repeats_forever() -> void:
	var plan := road.biome_plan(0)
	eq(plan.period_legs, SECTIONS.size())
	for lap: int in [0, 1, 7, 400]:
		for i in SECTIONS.size():
			var s := float(lap) * L + road.section_start(i) + 10.0
			eq(plan.biome_at(s).id, SECTIONS[i], "lap %d section %d" % [lap, i])
	eq(plan.biome_for_leg(6).id, &"desert", "leg 6 = lap 1's desert")
	eq(plan.biome_for_leg(5 * 1000 + 4).id, &"city")
	# The look blends across the seam like across any section line.
	var b := BiomePlan.Blend.new()
	plan.blend_into(2.0 * L, t.legs.biome_blend_before_m, t.legs.biome_blend_after_m, b)
	eq(b.from.id, &"farmland")
	eq(b.to.id, &"desert")
	# A finite plan (N3.1's) is unchanged: past its laps, the first section's biome.
	var once := road.biome_plan(1)
	eq(once.period_legs, 0)
	eq(once.biome_at(L + road.section_start(3) + 10.0).id, &"desert")


func test_journey_plan_is_not_periodic() -> void:
	var plan := BiomePlan.from_tuning(t.legs)
	eq(plan.period_legs, 0)
	eq(plan.biome_for_leg(100), plan.endless_biome(), "past the list: the endless biome")


func test_unwrap_near_and_period() -> void:
	eq(road.period_m(), L)
	eq(ProceduralRoadPath.new(RunContext.new(1)).period_m(), 0.0, "an open road has no period")
	near(road.unwrap_near(2.0 * L - 10.0, 5.0), 2.0 * L + 5.0, 1e-9, "a wrapped s just past the seam")
	near(road.unwrap_near(2.0 * L + 10.0, L - 5.0), 2.0 * L - 5.0, 1e-9, "just before it")
	near(road.unwrap_near(5.0 * L + 1000.0, 1200.0), 5.0 * L + 1200.0, 1e-9)
	near(road.unwrap_near(5.0 * L + 1000.0, 1200.0 + 3.0 * L), 5.0 * L + 1200.0, 1e-9, "any lap of the wrapped s")
	# Distances along the loop: the wrapped signed difference equals the unwrapped one
	# while both are within L/2.
	for a: float in [100.0, L - 50.0, 3.0 * L + 7.0]:
		for d: float in [-300.0, 0.0, 450.0, 12000.0]:
			near(road.signed_delta(a, a + d), d, 1e-6)


func test_elevated_zone_repeats_every_lap() -> void:
	var city := BiomePlan.load_biome(&"city")
	if not check(city != null and city.elevated != null, "the city has elevated sections"):
		return
	var o := road.layout
	var plan := ElevatedPlan.new(7, road.biome_plan(0).biome_at, city)
	plan.set_zones(o.elevated_s0, o.elevated_s1, L)
	var mid := (o.elevated_s0[0] + o.elevated_s1[0]) * 0.5
	for lap: int in [0, 1, 3, 250]:
		near(plan.drop_at(float(lap) * L + mid), city.elevated.height_m, 1e-9, "full height mid-zone, lap %d" % lap)
		eq(plan.drop_at(float(lap) * L + o.elevated_s0[0] - 1.0), 0.0, "not before the zone")
		eq(plan.drop_at(float(lap) * L + o.elevated_s1[0] + 1.0), 0.0, "not after it")
		eq(plan.drop_at(float(lap) * L + 2000.0), 0.0, "not in the desert")
	var ramp_mid := o.elevated_s0[0] + city.elevated.ramp_m * 0.5
	check(plan.drop_at(ramp_mid) > 0.0 and plan.drop_at(ramp_mid) < city.elevated.height_m, "ramps up")
	# Clearing the zones goes back to the seeded cells.
	plan.set_zones(PackedFloat64Array(), PackedFloat64Array(), 0.0)
	eq(plan.zone_s0.size(), 0)


func test_run_loop_start_and_places() -> void:
	var rl := RunLoop.new()
	rl.setup(rl.run_tuning(t))
	near(rl.start_s(), L + road.layout.spawn_s[0], 1e-9, "lap 1, the first spawn point")
	eq(road.lap_of(rl.start_s()), 1)
	for place: String in ["desert", "canyon", "tunnel", "coast", "bridge", "city", "ramp", "farmland", "seam"]:
		var s := rl.place_s(place)
		ge(s, L, "%s is on lap 1" % place)
		lt(s, 2.0 * L, place)
	eq(road.section_id(road.section_at(rl.place_s("city"))), &"city")
	eq(road.section_id(road.section_at(rl.place_s("farmland"))), &"farmland")
	near(rl.place_s("seam"), 2.0 * L - RunLoop.PLACE_LEAD_M, 1e-9)
	eq(rl.sector_at(L + road.layout.sector_s[3] + 1.0), 3)
	eq(rl.sector_at(2.0 * L - 1.0), road.layout.sector_s.size() - 1)
