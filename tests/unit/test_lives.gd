extends WBTest
## Lives suite. Spec: Lives, hits and crashes (2 lives; first touch costs a life,
## 2.0 s ghost, deflect / -20% speed / 0.6 s wobble; second touch ends the run;
## clean-leg restore up to 2) and its Tests (first hit drivable and above minimum
## speed within 1 s; a second contact during the ghost does not count; a clean-leg
## restore never exceeds 2 lives).

const CAR_IDS: Array[StringName] = [&"falcon_gt", &"night_viper", &"brute_v8", &"kestrel_rs", &"coastliner",
	&"afterglow", &"daybreak", &"needle"]
const HIT_SPEEDS_KMH: Array[float] = [150.0, 200.0, 250.0]
## "Drivable": heading back within this of the lane direction by the 1 s mark...
const DRIVABLE_YAW_DEG := 1.0
## ...and a full steer for this long then moves the car at least this far sideways.
const STEER_PROBE_S := 0.5
const STEER_PROBE_MIN_M := 0.5

var t: Tuning
var lt_: LivesTuning
var dt: float
var buf: ScoreEventBuffer
var road: StraightRoadPath


func before_all() -> void:
	t = Tuning.load_default()
	lt_ = t.lives
	dt = t.vehicle.physics_dt()
	road = StraightRoadPath.new(3, t.road)


func before_each() -> void:
	buf = ScoreEventBuffer.new(64)


func _lives(tuning: LivesTuning = null) -> Lives:
	var l := Lives.new(tuning if tuning != null else lt_)
	l.reset()
	return l


func _contact(source: StringName = HitDetection.HIT_TRAFFIC, slot: int = 3, away: int = -1) -> HitDetection.Contact:
	var c := HitDetection.Contact.new()
	c.hit = true
	c.source = source
	c.slot = slot
	c.side = -away
	c.away_side = away
	return c


func _count(kind: StringName) -> int:
	var n := 0
	for i in buf.size():
		if buf.kind[i] == kind:
			n += 1
	return n


func _cruiser(v: float) -> VehicleState:
	var p := VehicleState.new()
	p.d = road.lane_center_d(1, 0.0)
	p.v = v
	return p


# ---------------------------------------------------------------- Lives and ghost

func test_start_with_two_lives() -> void:
	var l := _lives()
	eq(l.lives, lt_.lives)
	eq(l.lives, 2)
	check(not l.is_ghost())
	check(not l.is_run_over())


func test_first_hit_costs_a_life_and_starts_the_ghost() -> void:
	var l := _lives()
	var p := _cruiser(50.0)
	eq(l.on_contact(_contact(), p, buf), Lives.Outcome.FIRST_HIT)
	eq(l.lives, 1)
	check(l.is_ghost())
	check(not l.is_run_over())
	eq(_count(Lives.KIND_HIT), 1)
	eq(buf.tag[0], Events.HIT_TRAFFIC)
	eq(buf.slot[0], 3)
	near(buf.value[0], 1.0, 0.0, "hit(tag, lives_left)")
	eq(_count(Lives.KIND_GHOST_STARTED), 1)
	near(buf.value[1], lt_.ghost_period_s, 0.0)


func test_ghost_lasts_exactly_the_ghost_period() -> void:
	var l := _lives()
	var p := _cruiser(50.0)
	l.on_contact(_contact(), p, buf)
	var ticks := 0
	while l.is_ghost() and ticks < 100000:
		l.step(dt, p, buf)
		ticks += 1
	eq(ticks, int(round(lt_.ghost_period_s / dt)), "2.0 s at 120 Hz")
	eq(_count(Lives.KIND_GHOST_ENDED), 1)


func test_second_contact_during_ghost_does_not_count() -> void:
	var l := _lives()
	var p := _cruiser(50.0)
	l.on_contact(_contact(), p, buf)
	buf.clear()
	var ghost_ticks := int(round(lt_.ghost_period_s / dt))
	# Every tick of the ghost, touch something (traffic, barrier, prop).
	var sources: Array[StringName] = [HitDetection.HIT_TRAFFIC, HitDetection.HIT_BARRIER, HitDetection.HIT_PROP]
	for k in ghost_ticks - 1:
		l.step(dt, p, buf)
		eq(l.on_contact(_contact(sources[k % 3]), p, buf), Lives.Outcome.IGNORED)
		if l.lives != 1:
			fail("contact at tick %d of the ghost counted" % k)
			return
	eq(_count(Lives.KIND_HIT), 0, "no hit events in the ghost")
	check(not l.is_run_over())
	# The ghost ends on the next tick; a touch then ends the run.
	l.step(dt, p, buf)
	check(not l.is_ghost())
	eq(l.on_contact(_contact(HitDetection.HIT_BARRIER), p, buf), Lives.Outcome.RUN_OVER)
	eq(l.lives, 0)
	check(l.is_run_over())
	near(_last_value(Lives.KIND_HIT), 0.0, 0.0, "hit with 0 lives left")
	# Nothing counts after the run is over.
	eq(l.on_contact(_contact(), p, buf), Lives.Outcome.IGNORED)
	eq(l.lives, 0)


func _last_value(kind: StringName) -> float:
	var v := NAN
	for i in buf.size():
		if buf.kind[i] == kind:
			v = buf.value[i]
	return v


func test_no_contact_is_no_outcome() -> void:
	var l := _lives()
	var c := HitDetection.Contact.new()
	eq(l.on_contact(c, _cruiser(40.0), buf), Lives.Outcome.NONE)
	eq(l.lives, 2)
	eq(buf.size(), 0)


# ---------------------------------------------------------------- Life recovery

func test_clean_leg_restore_never_exceeds_two() -> void:
	var l := _lives()
	# Full: nothing to restore, however many clean legs.
	for i in 5:
		check(not l.restore_life(buf))
		eq(l.lives, 2)
	eq(_count(Lives.KIND_LIFE_RESTORED), 0)
	l.on_contact(_contact(), _cruiser(50.0), buf)
	eq(l.lives, 1)
	check(l.restore_life(buf))
	eq(l.lives, 2)
	eq(_count(Lives.KIND_LIFE_RESTORED), 1)
	near(_last_value(Lives.KIND_LIFE_RESTORED), 2.0, 0.0, "life_restored(lives)")
	for i in 5:
		check(not l.restore_life(buf))
		le(l.lives, lt_.lives, "never above the maximum")
	eq(l.lives, 2)
	# Many hit / restore cycles.
	var p := _cruiser(50.0)
	for cycle in 20:
		l.on_contact(_contact(), p, buf)
		for k in int(round(lt_.ghost_period_s / dt)):
			l.step(dt, p, buf)
		l.restore_life(buf)
		l.restore_life(buf)
		le(l.lives, 2)
		buf.clear()
	eq(l.lives, 2)


func test_restore_switch_off() -> void:
	var off := lt_.duplicate() as LivesTuning
	off.clean_leg_restore = false
	var l := _lives(off)
	l.on_contact(_contact(), _cruiser(50.0), buf)
	check(not l.restore_life(buf))
	eq(l.lives, 1)


func test_no_restore_after_run_over() -> void:
	var l := _lives()
	var p := _cruiser(50.0)
	l.on_contact(_contact(), p, buf)
	for k in int(round(lt_.ghost_period_s / dt)):
		l.step(dt, p, buf)
	l.on_contact(_contact(), p, buf)
	check(l.is_run_over())
	check(not l.restore_life(buf))
	eq(l.lives, 0)


# ---------------------------------------------------------------- First-hit response

func test_hit_response_speed_deflection_and_wobble() -> void:
	var l := _lives()
	var p := _cruiser(60.0)
	l.on_contact(_contact(HitDetection.HIT_TRAFFIC, 1, -1), p, buf)
	near(p.v, 60.0 * lt_.first_hit_speed_keep_frac(), 1e-9, "-20% speed")
	lt(p.yaw, 0.0, "heading kicked left, away from a right-side contact")
	check(l.is_wobbling())
	var ticks := 0
	while l.is_wobbling() and ticks < 10000:
		l.step(dt, p, buf)
		ticks += 1
	eq(ticks, int(round(lt_.first_hit_wobble_s / dt)), "0.6 s wobble")
	# Barrier on the left: deflect right.
	var l2 := _lives()
	var p2 := _cruiser(60.0)
	l2.on_contact(_contact(HitDetection.HIT_BARRIER, -1, 1), p2, buf)
	gt(p2.yaw, 0.0)


func test_first_hit_leaves_player_drivable_above_min_speed_within_1s() -> void:
	var min_v := t.scoring.min_speed_mps()
	var input := VehicleInput.new()
	for id in CAR_IDS:
		var params := VehicleParams.build(t, load("res://data/cars/%s.tres" % id) as CarDef)
		for kmh in HIT_SPEEDS_KMH:
			for away: int in [-1, 1]:
				var l := _lives()
				var p := _cruiser(Units.kmh_to_mps(kmh))
				input.clear()
				input.throttle = 1.0
				# Settle at speed first (gearbox, steady state).
				for k in 60:
					VehiclePhysics.step(p, input, dt, params, road)
					p.v = Units.kmh_to_mps(kmh)
				var d0 := p.d
				eq(l.on_contact(_contact(HitDetection.HIT_TRAFFIC, 0, away), p, buf), Lives.Outcome.FIRST_HIT)
				var recover := int(round(lt_.first_hit_recovery_max_s / dt))
				var max_off := 0.0
				for k in recover:
					VehiclePhysics.step(p, input, dt, params, road)
					l.step(dt, p, buf)
					max_off = maxf(max_off, (p.d - d0) * float(away))
					if not (finite(p.v) and finite(p.d) and finite(p.yaw)):
						return
				var tag := "%s at %d km/h, away %d" % [id, int(kmh), away]
				ge(p.v, min_v, tag + ": above minimum speed at 1 s")
				check(not l.is_wobbling(), tag + ": wobble over")
				lt(absf(p.yaw), deg_to_rad(DRIVABLE_YAW_DEG), tag + ": heading settled")
				gt(max_off, 0.0, tag + ": deflected away from the contact")
				# Drivable: full steer toward the contact side moves the car there.
				var d1 := p.d
				input.steer = -float(away)
				for k in int(round(STEER_PROBE_S / dt)):
					VehiclePhysics.step(p, input, dt, params, road)
					l.step(dt, p, buf)
				gt((p.d - d1) * -float(away), STEER_PROBE_MIN_M, tag + ": responds to steering")
				ge(p.v, min_v, tag + ": still above minimum speed")


func test_wobble_is_heading_neutral() -> void:
	var l := _lives()
	var p := _cruiser(50.0)
	l.on_contact(_contact(), p, buf)
	var yaw_after_kick := p.yaw
	for k in int(round(lt_.first_hit_wobble_s / dt)):
		l.step(dt, p, buf)
	near(p.yaw, yaw_after_kick, 1e-9, "wobble adds no net heading (without physics)")


func test_determinism() -> void:
	eq(_trace(), _trace())


func _trace() -> int:
	var l := _lives()
	var p := _cruiser(55.0)
	var b := ScoreEventBuffer.new(64)
	var h := TraceHash.SEED
	for k in 2000:
		if k % 300 == 17:
			l.on_contact(_contact(), p, b)
		if k % 900 == 5:
			l.restore_life(b)
		l.step(dt, p, b)
		p.s += p.v * dt
		if k % 60 == 0:
			h = l.hash_into(h)
			h = p.hash_into(h)
			h = b.hash_into(h)
			b.clear()
	return h


func test_step_budget() -> void:
	var l := _lives()
	var p := _cruiser(50.0)
	var usec := WBBench.usec_per_call(l.step.bind(dt, p, buf), 2000)
	WBBench.report("lives step", usec, 5.0)
	le(usec, WBBench.budget(5.0))
