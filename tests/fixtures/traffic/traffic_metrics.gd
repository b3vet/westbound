class_name TrafficMetrics
extends RefCounted
## Logged traffic metrics per build (spec: Traffic → Tests (headless): "gaps per km, lane
## changes per vehicle per minute, mean speed per lane, set pieces per leg. A regression
## beyond ±15% on any of them fails the test"). Test observer: reads only the published
## TrafficState, the player and the sim's lane-change counter. See docs/SOAK.md.
##
##   var m := TrafficMetrics.new(tuning)
##   m.sample(dt, sim.state, player, road)     # every tick (cheap) ...
##   m.add_lane_changes(n)                     # completed lane moves since the last call
##   m.add_legs(1)                             # per leg driven
##   var d := m.to_dict()                      # {"gaps_per_km", "lane_changes_per_vehicle_min", ...}
##   var bad := TrafficMetrics.compare(d, baseline, 15.0)   # regressions, empty = ok
##
## Definitions:
## - gaps_per_km: bumper-to-bumper gaps of at least metrics_gap_min_m between
##   consecutive vehicles in the same lane (a gap the player can enter), per km of lane,
##   over [player s, player s + spawn_ahead_m], sampled every metrics_sample_interval_s.
## - lane_changes_per_vehicle_min: completed lane moves / vehicle-minutes simulated.
## - mean_speed_kmh_lane_<i>: time-sampled mean speed of vehicles in lane i (0 = next to
##   the median), counting vehicles not changing lanes.
## - set_pieces_per_leg: set pieces spawned / legs driven (0 until WP6.3).
## - density_per_km_lane (context, also compared): vehicles per km per lane in the window.

var gap_min: float
var window: float
var interval: float

var vehicle_seconds := 0.0
var lane_changes := 0
var legs := 0
var set_pieces := 0
var gap_count := 0
var gap_lane_km := 0.0
var density_vehicles := 0
var lane_speed_sum := PackedFloat64Array()
var lane_speed_n := PackedInt64Array()

var _clock := 0.0
var _lane_s: Array[PackedFloat64Array] = []
var _lane_len: Array[PackedFloat64Array] = []


func _init(t: Tuning) -> void:
	gap_min = t.traffic.metrics_gap_min_m
	window = t.traffic.spawn_ahead_m
	interval = t.traffic.metrics_sample_interval_s
	lane_speed_sum.resize(t.road.lanes_max)
	lane_speed_n.resize(t.road.lanes_max)
	for k in t.road.lanes_max:
		_lane_s.append(PackedFloat64Array())
		_lane_len.append(PackedFloat64Array())


## Call every tick with its dt: accumulates vehicle time, and samples the window every
## `interval` seconds.
func sample(dt: float, ts: TrafficState, player: VehicleState, road: RoadPath) -> void:
	vehicle_seconds += float(ts.count) * dt
	_clock += dt
	if _clock < interval:
		return
	_clock -= interval
	var lanes := mini(road.lane_count(player.s), _lane_s.size())
	for l in lanes:
		_lane_s[l].clear()
		_lane_len[l].clear()
	var lo := player.s
	var hi := player.s + window
	for i in ts.capacity:
		if ts.active[i] == 0:
			continue
		var l := ts.lane[i]
		if l < 0 or l >= lanes:
			continue
		if ts.lc_state[i] == TrafficState.LaneChange.NONE:
			lane_speed_sum[l] += ts.v[i]
			lane_speed_n[l] += 1
		if ts.s[i] >= lo and ts.s[i] < hi:
			density_vehicles += 1
			_lane_s[l].append(ts.s[i])
			_lane_len[l].append(ts.length[i])
	for l in lanes:
		var ss := _lane_s[l]
		var n := ss.size()
		if n >= 2:
			var idx := range(n)
			idx.sort_custom(func(a: int, b: int) -> bool: return ss[a] < ss[b])
			for q in range(1, n):
				var a: int = idx[q - 1]
				var b: int = idx[q]
				if ss[b] - ss[a] - (_lane_len[l][a] + _lane_len[l][b]) * 0.5 >= gap_min:
					gap_count += 1
		gap_lane_km += window / Units.M_PER_KM


func add_lane_changes(n: int) -> void:
	lane_changes += n


func add_legs(n: int, set_pieces_spawned: int = 0) -> void:
	legs += n
	set_pieces += set_pieces_spawned


## Adds another accumulator (shards, runs).
func merge(o: TrafficMetrics) -> void:
	vehicle_seconds += o.vehicle_seconds
	lane_changes += o.lane_changes
	legs += o.legs
	set_pieces += o.set_pieces
	gap_count += o.gap_count
	gap_lane_km += o.gap_lane_km
	density_vehicles += o.density_vehicles
	for l in lane_speed_sum.size():
		lane_speed_sum[l] += o.lane_speed_sum[l]
		lane_speed_n[l] += o.lane_speed_n[l]


func to_dict() -> Dictionary:
	var d := {}
	d["gaps_per_km"] = float(gap_count) / gap_lane_km if gap_lane_km > 0.0 else 0.0
	d["lane_changes_per_vehicle_min"] = float(lane_changes) / (vehicle_seconds / 60.0) if vehicle_seconds > 0.0 else 0.0
	d["set_pieces_per_leg"] = float(set_pieces) / float(legs) if legs > 0 else 0.0
	d["density_per_km_lane"] = float(density_vehicles) / gap_lane_km if gap_lane_km > 0.0 else 0.0
	for l in lane_speed_sum.size():
		if lane_speed_n[l] > 0:
			d["mean_speed_kmh_lane_%d" % l] = lane_speed_sum[l] / float(lane_speed_n[l]) / Units.kmh_to_mps(1.0)
	return d


## Every metric in `baseline` compared to `current`: a relative change beyond
## tolerance_pct (or any change from an exact 0) is a regression. A metric missing from
## `current` is one too. Returns one line per regression (empty = ok).
static func compare(current: Dictionary, baseline: Dictionary, tolerance_pct: float) -> PackedStringArray:
	var out := PackedStringArray()
	var tol := Units.pct_to_frac(tolerance_pct)
	for key: String in baseline.keys():
		var b := float(baseline[key])
		if not current.has(key):
			out.append("%s: missing (baseline %.4f)" % [key, b])
			continue
		var c := float(current[key])
		if b == 0.0:
			if c != 0.0:
				out.append("%s: %.4f, baseline 0" % [key, c])
			continue
		var rel := (c - b) / absf(b)
		if absf(rel) > tol:
			out.append("%s: %.4f vs baseline %.4f (%+.1f%%, limit ±%.0f%%)" % [key, c, b, rel * 100.0, tolerance_pct])
	return out
