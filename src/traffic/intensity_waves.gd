class_name IntensityWaves
extends RefCounted
## The traffic director's intensity waves and blind-window cap (WP6.2). Spec: Traffic →
## Traffic director ("Intensity waves. Tension and release in cycles of 45-90 s: build,
## peak (often a set piece), then a 10-15 s breather. Every leg ends with a short
## breather before the checkpoint."); Fairness rule 6 ("Within 150 m after a blind crest
## or bend, the director caps density at 60% and allows no set pieces"). Design and
## numbers: docs/SPAWNING.md "Intensity waves".
##
## Pure and headless. Two parts:
##
## 1. The curve: intensity (0 breather .. 1 peak) as a function of the PLAYER's road
##    position x. Each leg (checkpoint to checkpoint; LegsTuning's grid on a road without
##    checkpoint features) is filled with n whole cycles of wave_period_min_s ..
##    wave_period_max_s at wave_reference_pace_kmh, each build (rising from
##    wave_build_start_intensity to 1), peak (1), breather (0); the leg's last breather is
##    the checkpoint breather and ends exactly at the checkpoint. Everything is drawn from
##    one stream (run.rng_traffic.derive(&"waves")) in road order, so the curve depends
##    only on the seed and the checkpoints: the same for every player (Daily Drive). Each
##    peak also carries its set-piece draws (chance, kind), fixed by the seed.
##
## 2. The meeting map: which part of the curve a vehicle planned now belongs to. Traffic
##    is planned ~780 m ahead (beyond the fog) and the player meets a vehicle of a slower
##    lane at the closing speed, so a vehicle planned at s in a lane of speed v is met at
##        x_meet = player s + (s - player s) * pace / max(pace - v, closing floor)
##    (pace = the player's smoothed speed; clamped to wave_meet_lookahead_m). Planning at
##    wave_density_mult(intensity(x_meet)) makes the density the player MEETS follow the
##    curve in every lane, whatever its speed. The blind cap works in the same map: a
##    vehicle is within [p, crest end + blind_window_m] ahead of the player at some moment
##    p while the player drives a blind feature [a, b] exactly when
##        a <= x_meet <= a + (b - a + blind_window_m) * pace / closing speed
##    and then plans at no more than blind_density_cap_pct.
##
## Director rate (may allocate): reset, plan_to, forget_before. Tick rate
## (allocation-free): observe_player and every query.

enum Phase { BUILD, PEAK, BREATHER }

const STREAM := &"waves"

var tuning: DirectorTuning
var traffic_tuning: TrafficTuning
var leg_length_m: float

## The curve: contiguous segments along x (player road position), sorted.
var seg_x0 := PackedFloat64Array()
var seg_x1 := PackedFloat64Array()
var seg_phase := PackedInt32Array()
var seg_i0 := PackedFloat64Array()   ## intensity at x0
var seg_i1 := PackedFloat64Array()   ## intensity at x1
## Peaks only: the seed's set-piece draws in [0, 1) (chance, kind); -1 elsewhere.
var seg_u_chance := PackedFloat64Array()
var seg_u_kind := PackedFloat64Array()
## Serial number of each segment (stable across forget_before).
var seg_id := PackedInt32Array()

## Blind windows: [start, end] of every BLIND_CREST / BLIND_BEND feature scanned, by start.
var blind_s0 := PackedFloat64Array()
var blind_s1 := PackedFloat64Array()
## Checkpoint lines scanned (s), increasing.
var checkpoints := PackedFloat64Array()
## Road stretches a set piece must not drive through (lane-count changes, tunnels,
## forks), grown by set_piece_feature_clear_m.
var zone_s0 := PackedFloat64Array()
var zone_s1 := PackedFloat64Array()
## WP9.6: 1 where the zone is a widening (lanes added on the right: a rolling piece's lanes
## stay as they are, clear_of_zones(..., true) skips it).
var zone_widen := PackedByteArray()

## Where the curve starts, how far it is built and how far the road was scanned.
var origin_s: float = 0.0
var planned_to: float = 0.0
var scanned_to: float = 0.0

## The meeting map's inputs: the player's s, its smoothed speed (m/s), and the density
## (vehicles per km per lane) at multiplier 1 (the leg target x gain x the dev scale).
var player_s: float = 0.0
var pace: float = 0.0
var base_density: float = 0.0
## The multiplier the director's context density was set at (Flow reshapes relative to it).
var ref_mult: float = 1.0
var _rng: Rng
var _next_id: int = 0
var _scanned_any: bool = false
var _pace_ref: float
var _dv_floor: float
var _look: float
var _blind_w: float
var _blind_cap: float
var _tau: float


func _init(director_tuning: DirectorTuning, traffic: TrafficTuning, legs: LegsTuning, rng: Rng) -> void:
	tuning = director_tuning
	traffic_tuning = traffic
	leg_length_m = legs.leg_length_m()
	_rng = rng
	_pace_ref = Units.kmh_to_mps(tuning.wave_reference_pace_kmh)
	_dv_floor = Units.kmh_to_mps(tuning.wave_min_closing_kmh)
	_look = tuning.wave_meet_lookahead_m
	_blind_w = tuning.blind_window_m
	_blind_cap = Units.pct_to_frac(tuning.blind_density_cap_pct)
	_tau = tuning.wave_pace_smoothing_s


## Starts the curve at `s` (the run start) with the player at `speed` m/s. Keeps the
## stream position: a reset mid-run continues the same draws (director.reset).
func reset(s: float, speed: float) -> void:
	seg_x0.clear()
	seg_x1.clear()
	seg_phase.clear()
	seg_i0.clear()
	seg_i1.clear()
	seg_u_chance.clear()
	seg_u_kind.clear()
	seg_id.clear()
	blind_s0.clear()
	blind_s1.clear()
	checkpoints.clear()
	zone_s0.clear()
	zone_s1.clear()
	zone_widen.clear()
	_scanned_any = false
	origin_s = s
	planned_to = s
	scanned_to = s - _blind_w - tuning.set_piece_feature_clear_m
	player_s = s
	pace = speed


# ---------------------------------------------------------------- Tick rate (allocation-free)

## Per tick: the player's position and smoothed pace.
func observe_player(dt: float, s: float, v: float) -> void:
	player_s = s
	pace += (maxf(v, 0.0) - pace) * minf(dt / _tau, 1.0)


## Flow puts vehicles between live ones, and the director tops lanes up, only where the
## density multiplier is at least this (DirectorTuning.wave_fill_min_mult).
func fill_min_mult() -> float:
	return tuning.wave_fill_min_mult


## Index of the segment containing x (clamped to the built curve), -1 when none is built.
func segment_at(x: float) -> int:
	var n := seg_x0.size()
	if n == 0:
		return -1
	return clampi(seg_x0.bsearch(x, false) - 1, 0, n - 1)


## Intensity (0 breather .. 1 peak) at player position x. 1 before anything is built.
func intensity_at(x: float) -> float:
	var k := segment_at(x)
	if k < 0:
		return 1.0
	var a := seg_x0[k]
	var b := seg_x1[k]
	var u := clampf((x - a) / (b - a), 0.0, 1.0) if b > a else 0.0
	return lerpf(seg_i0[k], seg_i1[k], u)


func phase_at(x: float) -> Phase:
	var k := segment_at(x)
	return Phase.PEAK if k < 0 else seg_phase[k] as Phase


## Density multiplier of the curve at player position x (1 before anything is built).
func mult_at(x: float) -> float:
	if seg_x0.is_empty():
		return 1.0
	return tuning.wave_density_mult(intensity_at(x))


## The highest density multiplier the curve reaches (Flow's thinning bound).
func max_mult() -> float:
	return maxf(tuning.wave_density_mult(0.0), tuning.wave_density_mult(1.0))


## Where the player meets a vehicle planned now at `s` in a lane of speed `v_lane`.
func meet_x(v_lane: float, s: float) -> float:
	var dv := maxf(pace - v_lane, _dv_floor)
	return clampf(player_s + (s - player_s) * pace / dv, player_s - _look, player_s + _look)


## True when a vehicle planned now at `s` at `v_lane` would be hidden just beyond a blind
## crest or bend while the player drives it (fairness rule 6).
func is_blind(v_lane: float, s: float) -> bool:
	var dv := maxf(pace - v_lane, _dv_floor)
	var x := meet_x(v_lane, s)
	var k := pace / dv
	for j in blind_s0.size():
		var a := blind_s0[j]
		if x < a:
			return false
		if x <= a + (blind_s1[j] - a + _blind_w) * k:
			return true
	return false


## Density multiplier for a vehicle planned now at `s` at `v_lane`: the curve where the
## player meets it, capped in blind windows.
func density_mult(v_lane: float, s: float) -> float:
	var m := mult_at(meet_x(v_lane, s))
	if is_blind(v_lane, s):
		m = minf(m, _blind_cap)
	return m


## Planning density (vehicles per km per lane) for a vehicle at `s` at `v_lane`.
func density_at(v_lane: float, s: float) -> float:
	return base_density * density_mult(v_lane, s)


## The wave-shaped multiplier expected in the density window around the player: the
## mean over `lanes` lanes at their flow speeds of what the window's traffic was planned
## at. A lane the player catches (closing speed above the floor): density_mult over the
## window [player s - behind_m, player s + ahead_m]. A lane it does not catch: its
## ahead batches never reach the window and its traffic there arrives from behind,
## planned at the wave where the player is (mult_at(player s)).
func window_mult(lanes: int, behind_m: float, ahead_m: float) -> float:
	var n := maxi(tuning.wave_window_samples, 1)
	var sum := 0.0
	for l in lanes:
		var v := traffic_tuning.lane_flow_speed_mps(l, lanes)
		if pace - v < _dv_floor:
			sum += mult_at(player_s) * float(n)
			continue
		for k in n:
			sum += density_mult(v, player_s + lerpf(-behind_m, ahead_m, (float(k) + 0.5) / float(n)))
	return sum / float(maxi(lanes * n, 1))


## True when [x0, x1] (player positions) keeps clear of every checkpoint's range.
func clear_of_checkpoints(x0: float, x1: float) -> bool:
	for c in checkpoints:
		if x1 >= c - tuning.set_piece_checkpoint_clear_before_m and x0 <= c + tuning.set_piece_checkpoint_clear_after_m:
			return false
	return true


## True when the road stretch [s0, s1] has no lane-count change, tunnel or fork zone
## (`rolling`, WP9.6: widenings do not count; the added lanes come on the right).
func clear_of_zones(s0: float, s1: float, rolling: bool = false) -> bool:
	for j in zone_s0.size():
		if s1 >= zone_s0[j] and s0 <= zone_s1[j] and not (rolling and zone_widen[j] == 1):
			return false
	return true


## The first peak segment ending after x whose id is above `after_id` (-1: none built).
func next_peak(x: float, after_id: int) -> int:
	for k in seg_x0.size():
		if seg_phase[k] == Phase.PEAK and seg_x1[k] > x and seg_id[k] > after_id:
			return k
	return -1


# ---------------------------------------------------------------- Director rate

## Builds the curve and scans the road's features up to `x_to` (generating the road that
## far). Director rate: allocates.
func plan_to(road: RoadPath, x_to: float) -> void:
	_scan(road, x_to + leg_length_m)
	while planned_to < x_to:
		_build_leg(planned_to, _next_checkpoint(planned_to))


## Drops curve segments, blind windows and zones entirely behind `s`. Director rate.
func forget_before(s: float) -> void:
	var k := 0
	while k < seg_x1.size() - 1 and seg_x1[k] < s:
		k += 1
	if k > 0:
		seg_x0 = seg_x0.slice(k)
		seg_x1 = seg_x1.slice(k)
		seg_phase = seg_phase.slice(k)
		seg_i0 = seg_i0.slice(k)
		seg_i1 = seg_i1.slice(k)
		seg_u_chance = seg_u_chance.slice(k)
		seg_u_kind = seg_u_kind.slice(k)
		seg_id = seg_id.slice(k)
	var b := 0
	while b < blind_s0.size() and blind_s1[b] + _blind_w < s:
		b += 1
	if b > 0:
		blind_s0 = blind_s0.slice(b)
		blind_s1 = blind_s1.slice(b)
	var z := 0
	while z < zone_s0.size() and zone_s1[z] < s:
		z += 1
	if z > 0:
		zone_s0 = zone_s0.slice(z)
		zone_s1 = zone_s1.slice(z)
		zone_widen = zone_widen.slice(z)
	var c := 0
	while c < checkpoints.size() and checkpoints[c] + tuning.set_piece_checkpoint_clear_after_m < s:
		c += 1
	if c > 0:
		checkpoints = checkpoints.slice(c)


func _scan(road: RoadPath, s_to: float) -> void:
	if s_to <= scanned_to:
		return
	road.ensure_generated_to(s_to)
	var hi := minf(s_to, road.length_generated())
	if hi <= scanned_to:
		return
	var found: Array[RoadFeature] = []
	road.features_in(scanned_to, hi, found)
	var grow := tuning.set_piece_feature_clear_m
	for f in found:
		if f.s_start < scanned_to and _scanned_any:
			continue   # an extended feature already seen by the last scan
		match f.kind:
			RoadFeature.Kind.BLIND_CREST, RoadFeature.Kind.BLIND_BEND:
				_insert_sorted(blind_s0, blind_s1, f.s_start, f.s_end)
			RoadFeature.Kind.CHECKPOINT:
				if checkpoints.is_empty() or f.s_start > checkpoints[checkpoints.size() - 1]:
					checkpoints.append(f.s_start)
			RoadFeature.Kind.LANE_COUNT_CHANGE:
				_insert_zone(f.s_start - grow, f.s_end + grow, int(f.value) > road.lane_count(f.s_start - 1.0))
			RoadFeature.Kind.TUNNEL:
				_insert_zone(f.s_start - grow, f.s_end + grow, false)
			RoadFeature.Kind.FORK:
				# WP9.6: up to set_piece_fork_clear_after_m past the split (f.value).
				_insert_zone(f.s_start - grow, minf(f.s_end, f.value + tuning.set_piece_fork_clear_after_m) + grow, false)
	scanned_to = hi
	_scanned_any = true


func _insert_zone(s0: float, s1: float, widen: bool) -> void:
	var at := zone_s0.bsearch(s0, false)
	zone_s0.insert(at, s0)
	zone_s1.insert(at, s1)
	zone_widen.insert(at, 1 if widen else 0)


static func _insert_sorted(a0: PackedFloat64Array, a1: PackedFloat64Array, s0: float, s1: float) -> void:
	var at := a0.bsearch(s0, false)
	a0.insert(at, s0)
	a1.insert(at, s1)


## The first checkpoint beyond x (+ a small minimum leg): a scanned CHECKPOINT feature,
## else LegsTuning's grid (the procedural road puts them at k x leg length).
func _next_checkpoint(x: float) -> float:
	var min_leg := _pace_ref * tuning.checkpoint_breather_min_s
	for c in checkpoints:
		if c > x + min_leg:
			return c
	var k := floorf((x + min_leg) / leg_length_m) + 1.0
	return k * leg_length_m


## Fills [xa, xb] (one leg) with whole cycles; the last breather ends at xb.
func _build_leg(xa: float, xb: float) -> void:
	var t := tuning
	var total := (xb - xa) / _pace_ref
	var cp_breather := _rng.float_range(t.checkpoint_breather_min_s, t.checkpoint_breather_max_s)
	if total <= cp_breather:
		_add(xa, xb, Phase.BREATHER, 0.0, 0.0)
		planned_to = xb
		return
	var n_lo := maxi(1, ceili(total / t.wave_period_max_s))
	var n_hi := maxi(n_lo, floori(total / t.wave_period_min_s))
	var n := _rng.int_range(n_lo, n_hi)
	var w := PackedFloat64Array()
	var sum := 0.0
	for i in n:
		w.append(_rng.float_range(t.wave_period_min_s, t.wave_period_max_s))
		sum += w[i]
	var x := xa
	for i in n:
		var dur := w[i] * total / sum
		var br := cp_breather if i == n - 1 else _rng.float_range(t.breather_min_s, t.breather_max_s)
		br = minf(br, dur * 0.5)
		var active := dur - br
		var peak := active * Units.pct_to_frac(_rng.float_range(t.wave_peak_min_pct, t.wave_peak_max_pct))
		var x_build := x + (active - peak) * _pace_ref
		var x_peak := x + active * _pace_ref
		var x_end := xb if i == n - 1 else x + dur * _pace_ref
		_add(x, x_build, Phase.BUILD, t.wave_build_start_intensity, 1.0)
		_add(x_build, x_peak, Phase.PEAK, 1.0, 1.0)
		seg_u_chance[seg_u_chance.size() - 1] = _rng.unit()
		seg_u_kind[seg_u_kind.size() - 1] = _rng.unit()
		_add(x_peak, x_end, Phase.BREATHER, 0.0, 0.0)
		x = x_end
	planned_to = xb


func _add(x0: float, x1: float, phase: Phase, i0: float, i1: float) -> void:
	seg_x0.append(x0)
	seg_x1.append(x1)
	seg_phase.append(phase)
	seg_i0.append(i0)
	seg_i1.append(i1)
	seg_u_chance.append(-1.0)
	seg_u_kind.append(-1.0)
	seg_id.append(_next_id)
	_next_id += 1
