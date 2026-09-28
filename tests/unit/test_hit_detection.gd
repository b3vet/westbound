extends WBTest
## HitDetection suite. Spec: Lives, hits and crashes -> What counts as a hit (oriented
## boxes in road space, inset 8 cm from the visual body, barrier scrapes count) and
## Tests ("Collision boxes: hull overlap detection agrees with the inset boxes at speeds
## up to 350 km/h, with no tunnelling between 120 Hz ticks").
##
## Every scenario moves the boxes kinematically at 120 Hz and calls step() once per
## tick. The reference is an independent overlap test of the inset boxes (Godot's
## polygon intersection) sampled finely along each tick.

const PLAYER_LEN := 4.5
const PLAYER_WID := 1.9
const SEDAN_LEN := 4.6
const SEDAN_WID := 1.8
## [length, width] of the traffic bodies used in the randomized agreement check.
const BODIES: Array[Vector2] = [Vector2(2.2, 0.8), Vector2(4.6, 1.8), Vector2(5.2, 2.0), Vector2(16.0, 2.55)]
const AGREE_SEED := 31337
const AGREE_SCENARIOS := 400
const AGREE_TICKS := 240
## Reference samples per tick.
const REF_SUBSTEPS := 48
## The reference's "grown" boxes (sandwich lower bound).
const REF_GROW_M := 0.001

var t: Tuning
var inset: float
var dt: float
var vmax: float
var road: StraightRoadPath
var hits: HitDetection
var traffic: TrafficState
var player: VehicleState
var contact: HitDetection.Contact


func before_all() -> void:
	t = Tuning.load_default()
	inset = t.lives.collision_inset_m
	dt = t.vehicle.physics_dt()
	vmax = Units.kmh_to_mps(t.lives.collision_test_max_speed_kmh)
	road = StraightRoadPath.new(3, t.road)


func before_each() -> void:
	traffic = TrafficState.new(8)
	hits = HitDetection.new(t.lives, traffic.capacity)
	hits.set_player_body(PLAYER_LEN, PLAYER_WID)
	player = VehicleState.new()
	contact = HitDetection.Contact.new()


func _car(s: float, d: float, v: float, v_lat: float = 0.0, length: float = SEDAN_LEN,
		width: float = SEDAN_WID) -> int:
	var i := traffic.allocate()
	traffic.s[i] = s
	traffic.d[i] = d
	traffic.v[i] = v
	traffic.v_lat[i] = v_lat
	traffic.length[i] = length
	traffic.width[i] = width
	return i


## Moves the player (road-space velocity, fixed yaw) and every car one tick.
func _move(p_vs: float, p_vd: float) -> void:
	player.s += p_vs * dt
	player.d += p_vd * dt
	for i in traffic.capacity:
		if traffic.active[i] == 1:
			traffic.s[i] += traffic.v[i] * dt
			traffic.d[i] += traffic.v_lat[i] * dt


## Runs up to `ticks`; returns the first contact tick (1-based) or -1.
func _run(p_vs: float, p_vd: float, ticks: int) -> int:
	hits.reset(player, traffic)
	for k in ticks:
		_move(p_vs, p_vd)
		if hits.step(dt, player, traffic, road, contact):
			return k + 1
	return -1


# ---------------------------------------------------------------- Reference

func _box(cs: float, cd: float, yaw: float, hl: float, hw: float, os: float, od: float) -> PackedVector2Array:
	var c := cos(yaw)
	var sn := sin(yaw)
	var pts := PackedVector2Array()
	for k in 4:
		var fx := 1.0 if k == 0 or k == 1 else -1.0
		var fy := 1.0 if k == 0 or k == 3 else -1.0
		pts.append(Vector2(cs - os + fx * hl * c - fy * hw * sn, cd - od + fx * hl * sn + fy * hw * c))
	return pts


## Reference overlap of two inset boxes (grown by `grow`) at one instant.
func _ref_overlap(a_s: float, a_d: float, a_yaw: float, a_len: float, a_wid: float,
		b_s: float, b_d: float, b_yaw: float, b_len: float, b_wid: float, grow: float) -> bool:
	var pa := _box(a_s, a_d, a_yaw, a_len * 0.5 - inset + grow, a_wid * 0.5 - inset + grow, a_s, a_d)
	var pb := _box(b_s, b_d, b_yaw, b_len * 0.5 - inset + grow, b_wid * 0.5 - inset + grow, a_s, a_d)
	return not Geometry2D.intersect_polygons(pa, pb).is_empty()


# ---------------------------------------------------------------- Scenarios

func test_sources_match_events() -> void:
	eq(HitDetection.HIT_TRAFFIC, Events.HIT_TRAFFIC)
	eq(HitDetection.HIT_BARRIER, Events.HIT_BARRIER)
	eq(HitDetection.HIT_PROP, Events.HIT_PROP)


func test_rear_end_at_350_kmh() -> void:
	var v_t := Units.kmh_to_mps(100.0)
	player.s = 0.0
	player.d = road.lane_center_d(1, 0.0)
	player.v = vmax
	var gap := 30.0   # between the inset boxes
	var slot := _car(PLAYER_LEN * 0.5 - inset + gap + SEDAN_LEN * 0.5 - inset, player.d, v_t)
	var k := _run(vmax, 0.0, 240)
	var expected := int(ceil(gap / ((vmax - v_t) * dt)))
	eq(k, expected, "contact on the tick the gap closes")
	eq(contact.source, Events.HIT_TRAFFIC)
	eq(contact.slot, slot)
	eq(contact.end, 1, "front of the player")
	eq(contact.side, 0)
	near(contact.rel_v_s, vmax - v_t, 1e-6, "closing speed")
	near(contact.rel_v_d, 0.0, 1e-9)
	near(contact.s - player.s, (PLAYER_LEN * 0.5 - inset) - (1.0 - contact.toi) * vmax * dt, 1e-6,
		"contact point on the player's inset nose at the time of impact")
	near(contact.d, player.d, 1e-6)
	ge(contact.toi, 0.0)
	le(contact.toi, 1.0)


func test_head_on_relative_speed() -> void:
	# Synthetic: a box moving toward -s (the opposite carriageway is beyond the median
	# barrier in play, but the check must hold at any closing speed).
	player.d = road.lane_center_d(0, 0.0)
	var gap := 50.0
	_car(PLAYER_LEN * 0.5 - inset + gap + SEDAN_LEN * 0.5 - inset, player.d, -vmax)
	var k := _run(vmax, 0.0, 240)
	eq(k, int(ceil(gap / (2.0 * vmax * dt))), "closing at 2 x 350 km/h")
	eq(contact.end, 1)
	near(contact.rel_v_s, 2.0 * vmax, 1e-6)


func test_same_direction_overtaking_car_from_behind() -> void:
	player.d = road.lane_center_d(1, 0.0)
	var v_p := Units.kmh_to_mps(120.0)
	_car(-20.0, player.d, vmax)
	var k := _run(v_p, 0.0, 240)
	gt(k, 0)
	eq(contact.end, -1, "rear of the player")


func test_lateral_swipe_into_the_next_lane() -> void:
	var v := Units.kmh_to_mps(250.0)
	var lane_w := road.lane_width(0.0)
	player.d = road.lane_center_d(1, 0.0)
	player.yaw = atan2(3.0, v)
	var slot := _car(0.0, road.lane_center_d(2, 0.0), v)
	var k := _run(v * cos(player.yaw), v * sin(player.yaw), 240)
	gt(k, 0)
	eq(contact.slot, slot)
	eq(contact.side, 1, "right side of the player")
	eq(contact.away_side, -1, "deflect left, away from the contact")
	gt(contact.rel_v_d, 0.0, "moving into the car")
	# The gap between inset boxes (lane width - widths) closes at ~3 m/s.
	var gap := lane_w - (PLAYER_WID - 2.0 * inset) * 0.5 - (SEDAN_WID - 2.0 * inset) * 0.5
	near(float(k) * dt, gap / 3.0, 0.1)


func test_near_misses_that_look_clean_are_clean() -> void:
	var v := Units.kmh_to_mps(200.0)
	var side_d := PLAYER_WID * 0.5 + SEDAN_WID * 0.5
	# Side by side, visual bodies overlapping by just under the two insets: clean.
	for overlap: float in [0.0, 0.05, 2.0 * inset - 0.005]:
		before_each()
		player.d = road.lane_center_d(1, 0.0)
		_car(0.0, player.d + side_d - overlap, v)
		eq(_run(v, 0.0, 120), -1, "visual overlap %.3f m looks clean and is clean" % overlap)
	# Just over the insets: a hit.
	before_each()
	player.d = road.lane_center_d(1, 0.0)
	_car(0.0, player.d + side_d - (2.0 * inset + 0.005), v)
	eq(_run(v, 0.0, 120), 1, "real overlap is a hit")
	# Passing alongside at 350 km/h relative with a 1 cm visual overlap: clean.
	before_each()
	player.d = road.lane_center_d(1, 0.0)
	_car(-30.0, player.d - side_d + 0.01, 0.0)
	eq(_run(vmax, 0.0, 120), -1, "fast pass, visual touch, clean")
	# Nose to tail at equal speed, visual overlap under the insets: clean.
	before_each()
	player.d = road.lane_center_d(1, 0.0)
	_car(PLAYER_LEN * 0.5 + SEDAN_LEN * 0.5 - (2.0 * inset - 0.01), player.d, v)
	eq(_run(v, 0.0, 120), -1, "tailgating within the inset is clean")


func test_corner_clip_between_ticks_is_not_tunnelled() -> void:
	# Both tick ends clear, the boxes' corners cross in between: 350 km/h past a
	# stopped car, drifting away at 6 m/s. Minkowski half-extents (inset boxes):
	var hs := (PLAYER_LEN + SEDAN_LEN) * 0.5 - 2.0 * inset
	var hd := (PLAYER_WID + SEDAN_WID) * 0.5 - 2.0 * inset
	var step_s := vmax * dt
	var vd := 6.0
	player.s = -hs - step_s * 0.125   # enters the s-overlap 1/8 into the tick
	player.d = hd - 0.02   # already 2 cm inside laterally, leaving at vd
	var slot := _car(0.0, 0.0, 0.0)
	# The tick ends leave the corner (sanity: the case is a real tunnel case).
	var end_s := player.s + step_s
	var end_d := player.d + vd * dt
	check(end_d > hd or end_s < -hs, "end of tick is clear")
	check(not _ref_overlap(end_s, end_d, 0.0, PLAYER_LEN, PLAYER_WID, 0.0, 0.0, 0.0, SEDAN_LEN, SEDAN_WID, 0.0),
		"a discrete end-of-tick check misses it")
	var k := _run(vmax, vd, 1)
	eq(k, 1, "swept check catches the corner clip")
	eq(contact.slot, slot)
	near(contact.toi, 0.125, 1e-6)


func test_slot_reuse_is_not_swept_across() -> void:
	player.d = road.lane_center_d(1, 0.0)
	var slot := _car(-100.0, player.d, 0.0)
	hits.reset(player, traffic)
	_move(0.0, 0.0)
	eq(hits.step(dt, player, traffic, road, contact), false)
	traffic.free_slot(slot)
	var again := _car(100.0, player.d, 0.0)
	eq(again, slot, "same slot, new vehicle")
	_move(0.0, 0.0)
	eq(hits.step(dt, player, traffic, road, contact), false, "no sweep from the old car's position")


func test_median_barrier_scrape() -> void:
	var v := Units.kmh_to_mps(250.0)
	var yaw := -0.02
	player.yaw = yaw
	player.d = road.lanes_left_edge_d(0.0) + 1.0
	var k := _run(v * cos(yaw), v * sin(yaw), 600)
	gt(k, 0)
	eq(contact.source, Events.HIT_BARRIER)
	eq(contact.slot, -1)
	eq(contact.side, -1, "left side")
	eq(contact.away_side, 1, "deflect right")
	near(contact.d, road.median_barrier_d(0.0), 1e-6, "contact on the barrier face")
	near(contact.rel_v_d, v * sin(yaw), 1e-6)
	# Timing: the front-left inset corner reaches the face.
	var hl := PLAYER_LEN * 0.5 - inset
	var hw := PLAYER_WID * 0.5 - inset
	var corner0 := road.lanes_left_edge_d(0.0) + 1.0 + hl * sin(yaw) - hw * cos(yaw)
	var ticks := (corner0 - road.median_barrier_d(0.0)) / (-v * sin(yaw) * dt)
	eq(k, int(ceil(ticks)))


func test_guardrail_scrape_and_clean_parallel_run() -> void:
	var v := Units.kmh_to_mps(180.0)
	var hw := PLAYER_WID * 0.5 - inset
	# Parallel 1 cm inside the guardrail (inset box): clean for 2 s.
	player.d = road.guardrail_d(0.0) - hw - 0.01
	eq(_run(v, 0.0, 240), -1, "1 cm clear of the rail")
	# Visual body 5 cm into the rail (inside the inset): still clean.
	before_each()
	player.d = road.guardrail_d(0.0) - PLAYER_WID * 0.5 + 0.05
	eq(_run(v, 0.0, 240), -1)
	# Drifting right into the rail: a hit on the right.
	before_each()
	player.d = road.guardrail_d(0.0) - hw - 0.5
	player.yaw = 0.01
	var k := _run(v * cos(player.yaw), v * sin(player.yaw), 600)
	gt(k, 0)
	eq(contact.source, Events.HIT_BARRIER)
	eq(contact.side, 1)
	eq(contact.away_side, -1)
	near(contact.d, road.guardrail_d(0.0), 1e-6)


class _WallAt:
	extends HitDetection.PropQuery
	var wall_s: float

	func _init(s: float) -> void:
		wall_s = s

	func query_into(s0: float, d0: float, s1: float, d1: float, yaw: float, half_len: float,
			_half_wid: float, out: HitDetection.Contact) -> bool:
		var f0 := s0 + half_len * cos(yaw)
		var f1 := s1 + half_len * cos(yaw)
		if f1 < wall_s:
			return false
		out.hit = true
		out.source = Events.HIT_PROP
		out.toi = 0.0 if f0 >= wall_s else (wall_s - f0) / (f1 - f0)
		out.s = wall_s
		out.d = d0 + (d1 - d0) * out.toi
		return true


func test_roadside_prop_query_hook() -> void:
	player.d = road.lane_center_d(1, 0.0)
	hits.set_prop_query(_WallAt.new(50.0))
	var k := _run(40.0, 0.0, 240)
	gt(k, 0)
	eq(contact.source, Events.HIT_PROP)
	near(contact.s, 50.0, 1e-9)
	# The earliest contact wins: a car before the wall.
	before_each()
	player.d = road.lane_center_d(1, 0.0)
	hits.set_prop_query(_WallAt.new(50.0))
	_car(30.0, player.d, 0.0)
	_run(40.0, 0.0, 240)
	eq(contact.source, Events.HIT_TRAFFIC)


# ---------------------------------------------------------------- Agreement with the reference

## One randomized scenario: returns [swept first tick, reference tick, grown reference tick]
## (-1 = none within AGREE_TICKS).
func _agree_scenario(rng: Rng) -> PackedInt32Array:
	before_each()
	var body := BODIES[rng.int_range(0, BODIES.size() - 1)]
	var yaw := rng.float_range(-0.08, 0.08)
	var v_p := rng.float_range(0.0, vmax)
	var v_t := rng.float_range(-vmax, vmax)
	var vl_t := rng.float_range(-3.0, 3.0)
	var vd_p := v_p * sin(yaw)
	var vs_p := v_p * cos(yaw)
	player.yaw = yaw
	player.s = 0.0
	player.d = road.lane_center_d(1, 0.0)
	# Start lateral offsets clustered around a graze of the inset boxes.
	var graze := (PLAYER_WID + body.y) * 0.5 - 2.0 * inset
	var dd := (graze + rng.float_range(-0.4, 0.4)) * (1.0 if rng.chance(0.5) else -1.0)
	var ds := rng.float_range(-60.0, 60.0)
	if rng.chance(0.3):
		dd = rng.float_range(-graze, graze)
	var slot := _car(ds, player.d + dd, v_t, vl_t, body.x, body.y)
	var b_yaw := atan2(vl_t, v_t)
	var swept := -1
	var ref := -1
	var grown := -1
	hits.reset(player, traffic)
	for k in AGREE_TICKS:
		var a0s := player.s
		var a0d := player.d
		var b0s := traffic.s[slot]
		var b0d := traffic.d[slot]
		_move(vs_p, vd_p)
		if swept < 0 and hits.step(dt, player, traffic, null, contact):   # traffic only
			swept = k + 1
		# Reference: skip ticks whose bounding circles never get close.
		var reach := Vector2(PLAYER_LEN, PLAYER_WID).length() * 0.5 + body.length() * 0.5 \
			+ (vmax * 2.0 + 10.0) * dt
		if absf(b0s - a0s) > reach or absf(b0d - a0d) > reach:
			continue
		for j in REF_SUBSTEPS + 1:
			var u := float(j) / float(REF_SUBSTEPS)
			var as_ := a0s + (player.s - a0s) * u
			var ad := a0d + (player.d - a0d) * u
			var bs := b0s + (traffic.s[slot] - b0s) * u
			var bd := b0d + (traffic.d[slot] - b0d) * u
			if grown < 0 and _ref_overlap(as_, ad, yaw, PLAYER_LEN, PLAYER_WID, bs, bd, b_yaw, body.x, body.y, REF_GROW_M):
				grown = k + 1
			if ref < 0 and _ref_overlap(as_, ad, yaw, PLAYER_LEN, PLAYER_WID, bs, bd, b_yaw, body.x, body.y, 0.0):
				ref = k + 1
		if swept > 0 and ref > 0 and grown > 0:
			break
	return PackedInt32Array([swept, ref, grown])


func test_agrees_with_reference_up_to_350_kmh() -> void:
	var rng := Rng.new(AGREE_SEED)
	var n_contact := 0
	var n_clear := 0
	for n in AGREE_SCENARIOS:
		var r := _agree_scenario(rng)
		var swept := r[0]
		var ref := r[1]
		var grown := r[2]
		# Sandwich: grown reference <= swept <= exact reference (a missed sample in the
		# reference can only make it later; swept is exact for the motion).
		if ref > 0:
			n_contact += 1
			if not (swept > 0 and swept <= ref):
				fail("scenario %d: reference contact at tick %d, swept %d (tunnelled)" % [n, ref, swept])
		else:
			n_clear += 1
		if swept > 0 and not (grown > 0 and grown <= swept):
			fail("scenario %d: swept contact at tick %d but the boxes never came within %.3f m (grown ref %d)"
				% [n, swept, REF_GROW_M, grown])
	gt(float(n_contact), AGREE_SCENARIOS * 0.2, "enough contact scenarios")
	gt(float(n_clear), AGREE_SCENARIOS * 0.2, "enough clean scenarios")


# ---------------------------------------------------------------- Budget

func test_broadphase_window_covers_the_largest_reach() -> void:
	# The widest reach along s (player + semi, box diagonals) plus the largest one-tick
	# relative move (head-on at 2 x 350 km/h) must fit in the window.
	var reach := (PLAYER_LEN + PLAYER_WID) * 0.5 + (BODIES[3].x + BODIES[3].y) * 0.5
	gt(t.lives.collision_broadphase_m, reach + 2.0 * vmax * dt)


func test_step_budget_sixty_cars() -> void:
	traffic = TrafficState.new(60)
	hits = HitDetection.new(t.lives, traffic.capacity)
	hits.set_player_body(PLAYER_LEN, PLAYER_WID)
	player.d = road.lane_center_d(1, 0.0)
	for i in 60:
		_car(-193.0 + float(i) * 20.0, road.lane_center_d(i % 3, 0.0), 30.0)
	hits.reset(player, traffic)
	var usec := WBBench.usec_per_call(hits.step.bind(dt, player, traffic, road, contact), 500)
	WBBench.report("hit detection step, 60 cars", usec, 60.0)
	le(usec, WBBench.budget(60.0))
