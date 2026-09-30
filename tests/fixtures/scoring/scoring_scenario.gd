class_name ScoringScenario
extends RefCounted
## A scripted scoring scenario for tests (not a test suite): a straight 3-lane road
## fixture, a TrafficState whose cars move at constant speed along fixed lines (no
## traffic model), a scripted player (speed set directly, lateral moves at a constant
## rate) and the real Scoring rule set. Every event is logged with its tick time.
##
##   var sc := ScoringScenario.new()
##   sc.place_player(1, 150.0)
##   sc.add_car(20.0, sc.lane_d(1) + 2.7, 100.0)     # 20 m ahead, 2.7 m to the right
##   sc.run(2.5)
##   eq(sc.count(ScoreEvents.CLOSE_PASS), 1)

const DT := 1.0 / 120.0
## Default traffic car body (m).
const CAR_LENGTH := 4.5
const CAR_WIDTH := 1.8

var tuning: Tuning
var ctx: RunContext
var road: StraightRoadPath
var traffic: TrafficState
var player := VehicleState.new()
var rules: Scoring
var buf: ScoreEventBuffer
var time := 0.0
## Collect take_boost_fill() every tick into boost_total.
var auto_take_boost := true
var boost_total := 0.0

# Scripted lateral move of the player.
var _target_d := NAN
var _lat_speed := 0.0

# Event log (tests may allocate).
var log_kind: Array[StringName] = []
var log_tag: Array[StringName] = []
var log_points: Array[int] = []
var log_mult: Array[float] = []
var log_clear: Array[float] = []
var log_slot: Array[int] = []
var log_value: Array[float] = []
var log_time: Array[float] = []
## rules.multiplier() when the event was drained (end of its tick: the gain applied,
## minus one tick of decay).
var log_mult_after: Array[float] = []


func _init(t: Tuning = null, lanes: int = 3, capacity: int = 16) -> void:
	tuning = t if t != null else Tuning.load_default()
	ctx = RunContext.new(1, RunContext.MODE_JOURNEY, tuning)
	road = StraightRoadPath.new(lanes, tuning.road)
	traffic = TrafficState.new(capacity)
	rules = Scoring.new(ctx)
	rules.set_player_body(tuning.traffic.player_length_m, tuning.traffic.player_width_m)
	buf = ScoreEventBuffer.new(tuning.scoring.event_buffer_capacity)


static func kmh(x: float) -> float:
	return Units.kmh_to_mps(x)


func lane_d(lane: int) -> float:
	return road.lane_center_d(lane, player.s)


## Player hull half-width + a car's hull half-width + `clearance`: the center offset
## that leaves exactly `clearance` between the hulls side by side.
func side_offset(clearance: float, car_width: float = CAR_WIDTH) -> float:
	var inset := tuning.lives.collision_inset_m
	return tuning.traffic.player_width_m * 0.5 - inset + car_width * 0.5 - inset + clearance


## Hull half-length sum for a car of `car_length` (the longitudinal overlap limit).
func half_lengths(car_length: float = CAR_LENGTH) -> float:
	var inset := tuning.lives.collision_inset_m
	return tuning.traffic.player_length_m * 0.5 - inset + car_length * 0.5 - inset


## s offset (car center - player center) that leaves `gap` between the hulls.
func gap_ahead(gap: float, car_length: float = CAR_LENGTH) -> float:
	return gap + half_lengths(car_length)


func place_player(lane: int, v_kmh: float, s: float = 0.0) -> void:
	player.s = s
	player.d = road.lane_center_d(lane, s)
	player.v = kmh(v_kmh)
	player.yaw = 0.0


func place_player_d(d: float, v_kmh: float, s: float = 0.0) -> void:
	player.s = s
	player.d = d
	player.v = kmh(v_kmh)


func set_speed(v_kmh: float) -> void:
	player.v = kmh(v_kmh)


## Adds a car `ds` ahead of the player (negative = behind) at lateral position `d`.
func add_car(ds: float, d: float, v_kmh: float, length: float = CAR_LENGTH, width: float = CAR_WIDTH) -> int:
	var i := traffic.allocate()
	assert(i >= 0, "ScoringScenario: traffic capacity exceeded")
	traffic.s[i] = player.s + ds
	traffic.d[i] = d
	traffic.v[i] = kmh(v_kmh)
	traffic.v0[i] = traffic.v[i]
	traffic.length[i] = length
	traffic.width[i] = width
	var ln := road.lane_index_at(d, traffic.s[i])
	traffic.lane[i] = ln if ln >= 0 else (0 if d < road.lanes_left_edge_d(traffic.s[i]) else road.lane_count(0.0) - 1)
	traffic.target_lane[i] = traffic.lane[i]
	return i


func add_car_in_lane(ds: float, lane: int, v_kmh: float, length: float = CAR_LENGTH) -> int:
	return add_car(ds, road.lane_center_d(lane, player.s + ds), v_kmh, length)


func remove_car(i: int) -> void:
	traffic.free_slot(i)


## Moves the player's center laterally to `d` at `speed_mps` (constant rate).
func steer_to(d: float, speed_mps: float) -> void:
	_target_d = d
	_lat_speed = speed_mps


func steer_to_lane(lane: int, speed_mps: float) -> void:
	steer_to(road.lane_center_d(lane, player.s), speed_mps)


func is_steering() -> bool:
	return not is_nan(_target_d)


func run(seconds: float) -> void:
	var n := roundi(seconds / DT)
	for k in n:
		tick()


## Runs until the scripted lateral move is done (at most `max_s`).
func run_until_steered(max_s: float = 5.0) -> void:
	var n := roundi(max_s / DT)
	for k in n:
		if not is_steering():
			return
		tick()


func tick() -> void:
	player.s += player.v * DT
	if not is_nan(_target_d):
		var step := _lat_speed * DT
		if absf(_target_d - player.d) <= step:
			player.d = _target_d
			_target_d = NAN
		else:
			player.d += signf(_target_d - player.d) * step
	for i in traffic.capacity:
		if traffic.active[i] == 1:
			traffic.s[i] += traffic.v[i] * DT
	time += DT
	rules.step(DT, player, traffic, road, buf)
	drain()
	if auto_take_boost:
		boost_total += rules.take_boost_fill()


## Moves the buffered events into the log (also after notify_* calls).
func drain() -> void:
	for e in buf.size():
		log_kind.append(buf.kind[e])
		log_tag.append(buf.tag[e])
		log_points.append(buf.points[e])
		log_mult.append(buf.multiplier[e])
		log_clear.append(buf.clearance_m[e])
		log_slot.append(buf.slot[e])
		log_value.append(buf.value[e])
		log_time.append(time)
		log_mult_after.append(rules.multiplier())
	buf.clear()


func hit() -> void:
	rules.notify_hit(buf)
	drain()


func checkpoint() -> void:
	rules.notify_checkpoint(buf)
	drain()


func run_end() -> void:
	rules.notify_run_end(buf)
	drain()


func bonus(kind: StringName, base: int) -> void:
	rules.award_bonus(kind, base, buf)
	drain()


func clear_log() -> void:
	log_kind.clear()
	log_tag.clear()
	log_points.clear()
	log_mult.clear()
	log_clear.clear()
	log_slot.clear()
	log_value.clear()
	log_time.clear()
	log_mult_after.clear()


func count(kind: StringName) -> int:
	return log_kind.count(kind)


## Index of the last logged event of `kind`, or -1.
func last(kind: StringName) -> int:
	for e in range(log_kind.size() - 1, -1, -1):
		if log_kind[e] == kind:
			return e
	return -1


func first(kind: StringName) -> int:
	return log_kind.find(kind)


func points_of(kind: StringName) -> int:
	var total := 0
	for e in log_kind.size():
		if log_kind[e] == kind:
			total += log_points[e]
	return total


## Sum of the points of every scoring event (pass, close pass, cut, thread).
func scored_points() -> int:
	return points_of(ScoreEvents.PASS) + points_of(ScoreEvents.CLOSE_PASS) \
		+ points_of(ScoreEvents.CUT) + points_of(ScoreEvents.THREAD)


func scored_count() -> int:
	return count(ScoreEvents.PASS) + count(ScoreEvents.CLOSE_PASS) + count(ScoreEvents.CUT) \
		+ count(ScoreEvents.THREAD)


## Events of `kind` with value 1 / 0 (on/off kinds), in order, as a string like "10".
func toggles(kind: StringName) -> String:
	var out := ""
	for e in log_kind.size():
		if log_kind[e] == kind:
			out += "1" if log_value[e] > 0.5 else "0"
	return out
