class_name ReplayVerifier
extends RefCounted
## The replay verifier's core: rebuilds a run from its seed and plays the recorded path
## back kinematically, so traffic reacts to the recorded path, while the real TrafficSim,
## HitDetection, Lives, Scoring, legs and sun recompute every event. Spec: multiplayer
## handoff → Leaderboards (single-player runs, step 4: "loads the seed, regenerates road
## and traffic, and plays the recorded path back kinematically ... recomputes every
## scoring event and hit, and checks the path against the car's physics limits. Accept if
## the recomputed score is within 3 % and no unreported hits are found"), Testing →
## Verifier. WP N8.1; docs/REPLAY_FORMAT.md → Verification.
##
##   var v := ReplayVerifier.new(NetReplayFile.decode(bytes))
##   v.claimed_score = 183200    # the submission's (the server passes the run row's)
##   var result := v.verify(tree.root)   # {accepted, recomputed_score, ..., violations}
##
## Playback: the real Run scene (src/run/run.tscn) with manual ticks, the replay's seed,
## mode and car, infinite lives (the run goes on past the recorded crash so every hit is
## counted; the last one ends the path) and GO at once. Each RUNNING tick k, in Run.tick's
## order: the road ahead; the car's state set from the samples (linear between the 30 Hz
## samples; exact on a sample tick; a fork-swap tick gets its shift back, since the fork
## code moves the car again; the boost from the exact edges; the brake from the window's
## largest) instead of VehiclePhysics; then Run._sim_tick (forks, traffic with the player
## as participant, director, lives and hits, scoring, sun, legs, stats); the run's event
## buffer is read and cleared (the adapter never drains: nothing renders). No frame() is
## played: views, HUD and sky only listen (Architecture rule 8).
##
## **Re-simulation (N8.2).** A replay with an input stream (every replay the N8.2 client
## records) is not interpolated: the car is driven from GO by its recorded inputs through
## the real Run.tick (controller → VehiclePhysics → the whole simulation), with the
## run's real lives, and the result must land on every 30 Hz sample exactly (the quantized
## state equal to the recorded one): `path_mismatch` otherwise. The simulation is
## bit-identical on every platform (DetMath, fixed tick, tier-independent horizon), so an
## honest replay reproduces the client's run tick for tick: every event, hit and the score
## (docs/DETERMINISM.md). The physics limits are still checked on the samples.
## A replay without inputs (an N8.1 client) is played back kinematically as before: an
## approximation (the path is quantized and interpolated between samples).

const RUN_SCENE_PATH := "res://src/run/run.tscn"
const MAX_LISTED_VIOLATIONS := 20

## Verdict reasons.
const REASON_ACCEPTED := "accepted"
const REASON_SCORE := "score_mismatch"
const REASON_HITS := "unreported_hits"
const REASON_PHYSICS := "physics"
const REASON_SEED := "seed_mismatch"
const REASON_LOG := "log_mismatch"
const REASON_MALFORMED := "malformed"
## N8.2: the re-simulated car left the recorded path (edited inputs or samples, or a
## determinism bug: the result says where).
const REASON_PATH := "path_mismatch"

## Violation kinds.
const V_SPEED := "speed"
const V_TELEPORT := "teleport"
const V_LATERAL_PATH := "lateral_path"
const V_LATERAL_SPEED := "lateral_speed"
const V_LATERAL_ACCEL := "lateral_accel"
const V_YAW_RATE := "yaw_rate"
const V_ACCEL := "accel"
const V_BOOST := "boost_meter"
const V_RESET := "reset"
const V_FORK := "fork_swap"
const V_SAMPLES := "samples"
const V_SEED := "seed"
const V_RESIM := "resim"
const V_INPUTS := "inputs"

var replay: NetReplayFile
var tuning: NetTuning
## The claims to hold the playback against (-1: the replay header's). The server passes
## the submitted run's score and hits.
var claimed_score: int = -1
var claimed_hits: int = -1
## The run's seed on the server (-1: the header's). A different header seed is a violation.
var expected_seed: int = -1
## A different tuning hash cannot be verified here (another build): `verify` reports it
## as an error instead of a verdict.
var check_tuning_hash: bool = true
## (k: int, run: Run) -> void after every playback tick (tests, divergence hunts).
var on_tick: Callable
## (k: int, state: VehicleState) -> void right after the recorded state is set, before
## the tick's simulation (tests: feed the original's exact states).
var on_state: Callable

## Filled by verify().
var result: Dictionary = {}
var playback_hits := PackedInt64Array()
var elapsed_ms: int = 0

var _run: Run
var _limits: VerifierLimits
var _hz: float
var _dt: float
var _violations: Array[Dictionary] = []
var _violation_count: int = 0
var _shift_at: Dictionary[int, float] = {}
var _boost_edges := PackedInt64Array()   # tick × 2 + (1 on / 0 off), in order
var _logged_hits := PackedInt64Array()
var _fingerprints: Dictionary[int, int] = {}
var _fp_checked: int = 0
var _fp_matched: int = 0
## The first tick whose traffic fingerprint differs from the client's (-1: none).
var diverged_at: int = -1
## N8.2: re-simulate from the input stream when the replay has one (off: always the
## kinematic playback; tests compare the two).
var resim: bool = true
## The first sample tick the re-simulated state missed (-1: none) and how many missed.
var resim_mismatch_at: int = -1
var resim_mismatches: int = 0
var _resim_edges := PackedInt64Array()
var _hit_grace_ticks: int = 0
var _meter: float = 0.0
var _k: int = 0
var _ghost_s: float = 0.0
var _recomputed_kinds: Dictionary[String, int] = {}
## Playback scoring events: tick × 8 + kind code (KIND_CODES), in order.
var _scored := PackedInt64Array()
## The positions between two samples (index j = tick − start tick), rebuilt per segment.
var _seg_a: int = -1
var _seg_s := PackedFloat64Array()
var _seg_d := PackedFloat64Array()

## Scored kinds as small codes for the log match.
const KIND_CODES: Array[StringName] = [ScoreEvents.PASS, ScoreEvents.CLOSE_PASS, ScoreEvents.CUT,
		ScoreEvents.THREAD]
const CODE_BITS := 3


func _init(r: NetReplayFile, net_tuning: NetTuning = null) -> void:
	replay = r
	tuning = net_tuning if net_tuning != null else NetTuning.load_default()


## Plays the replay back under `host` and returns the result (also kept in `result`).
## `error` set (and no `accepted`) when it cannot be verified here.
func verify(host: Node) -> Dictionary:
	var started := Time.get_ticks_msec()
	result = _base_result()
	var why := _check_header()
	if not why.is_empty():
		result["error"] = why
		return result
	_run = _make_run(host)
	if _run == null:
		result["error"] = "the run could not be built for car `%s`" % replay.car
		return result
	if check_tuning_hash and NetReplayFile.tuning_hash_of(_run.ctx.tuning) != replay.tuning_hash:
		result["error"] = "tuning_mismatch: this verifier's simulation tuning differs from the replay's (build parity)"
		_free_run()
		return result
	_limits = VerifierLimits.new(_run.car.params, tuning, _dt)
	_index_events()
	if _resimulating():
		_play_resim()
	else:
		_play()
	_run.scoring.notify_run_end(_run.events)
	_scan_events(0)
	_run.events.clear()
	var recomputed := _run.scoring.banked()
	_free_run()
	_verdict(recomputed)
	elapsed_ms = Time.get_ticks_msec() - started
	result["elapsed_ms"] = elapsed_ms
	return result


func _base_result() -> Dictionary:
	return {
		"run_id": str(replay.run_id), "seed": str(replay.seed_value), "mode": String(replay.mode_name()),
		"date": replay.date, "car": replay.car, "build": replay.client_build,
		"ticks": replay.ticks, "samples": replay.sample_count,
		"claimed_score": claimed_score if claimed_score >= 0 else replay.score,
		"claimed_hits": claimed_hits if claimed_hits >= 0 else replay.hits,
	}


func _check_header() -> String:
	if replay == null:
		return "unreadable replay"
	if replay.sample_count < 2:
		return "a replay needs at least two samples"
	return ""


func _make_run(host: Node) -> Run:
	var car_index := -1
	for i in Run.CAR_PATHS.size():
		var def := load(Run.CAR_PATHS[i]) as CarDef
		if def != null and String(def.id) == replay.car:
			car_index = i
	if car_index < 0:
		return null
	var scene := load(RUN_SCENE_PATH) as PackedScene
	var r := scene.instantiate() as Run
	var run_seed := expected_seed if expected_seed >= 0 else replay.seed_value
	r.run_seed = run_seed if run_seed != 0 else 1
	r.mode = replay.mode_name()
	r.manual_ticks = true
	r.crash_cinematic = false
	r.record_best = false
	r.car_index = car_index
	host.add_child(r)
	# Kinematic playback: infinite lives (the path goes on past the recorded crash, every
	# hit counts). Re-simulation: the run's own lives, so it ends where the client's did.
	r.infinite_lives = not _resimulating()
	_hz = float(r.tuning.vehicle.physics_tick_hz)
	_dt = r.tuning.vehicle.physics_dt()
	_hit_grace_ticks = roundi(tuning.verify_hit_grace_s * _hz)
	_ghost_s = r.tuning.lives.ghost_period_s
	r.go()
	return r


func _resimulating() -> bool:
	return resim and replay.has_inputs()


func _free_run() -> void:
	if _run != null and is_instance_valid(_run):
		_run.queue_free()   # the next idle frame (deferred layout calls still find the tree)
	_run = null


func _index_events() -> void:
	_shift_at.clear()
	_boost_edges.clear()
	_logged_hits.clear()
	for i in replay.event_count:
		var k := int(replay.ev_tick[i])
		match int(replay.ev_kind[i]):
			NetReplayFile.Kind.FORK_SWAP:
				_shift_at[k] = float(replay.ev_value[i]) / NetReplayFile.Q_POS
			NetReplayFile.Kind.BOOST_ON:
				_boost_edges.append(k * 2 + 1)
			NetReplayFile.Kind.BOOST_OFF:
				_boost_edges.append(k * 2)
			NetReplayFile.Kind.HIT:
				_logged_hits.append(k)
			NetReplayFile.Kind.TRAFFIC:
				_fingerprints[k] = int(replay.ev_value[i])


# ---------------------------------------------------------------- Playback

func _play() -> void:
	var r := replay
	if r.tick[0] != 1:
		_violate(V_SAMPLES, 0, "the first sample is tick %d, not 1" % r.tick[0])
	for i in range(1, r.sample_count):
		if r.tick[i] <= r.tick[i - 1]:
			_violate(V_SAMPLES, int(r.tick[i]), "sample ticks go backwards")
			return
	if expected_seed >= 0 and expected_seed != r.seed_value:
		_violate(V_SEED, 0, "the replay's seed %d is not the run's %d" % [r.seed_value, expected_seed])
	var st := _run.car.state
	var inp := _run.car.input
	var last := int(r.tick[r.sample_count - 1])
	var b := 0   # the sample at or after tick k
	var edge := 0
	var boost_on := false
	var right_before := _run.forks.right_count
	for k in range(1, last + 1):
		_k = k
		while int(r.tick[b]) < k:
			b += 1
		var a := maxi(b - 1, 0)
		var on_sample := int(r.tick[b]) == k
		var flags := int(r.flags[b]) if on_sample else 0
		var boost_request := false
		var was_on := boost_on
		while edge < _boost_edges.size() and (_boost_edges[edge] >> 1) <= k:
			var turning_on := (_boost_edges[edge] & 1) == 1
			if turning_on and (_boost_edges[edge] >> 1) == k:
				boost_request = true
				if _meter < _limits.params.boost_start_min_frac - tuning.verify_boost_meter_slack:
					_violate(V_BOOST, k, "boost started with the meter at %.2f" % _meter)
			boost_on = turning_on
			edge += 1
		_run._road_ahead()
		_set_state(st, inp, a, b, k, flags)
		if on_state.is_valid():
			on_state.call(k, st)
		# Boost drain (VehiclePhysics.step: while it ran during the tick), then the scoring
		# fill comes in _sim_tick.
		st.boost_active = boost_on
		if boost_on or was_on:
			_meter -= _limits.params.boost_drain_per_s * _dt
			if _meter < -tuning.verify_boost_meter_slack:
				_violate(V_BOOST, k, "boost running on an empty meter")
				_meter = 0.0
		st.boost_meter = clampf(_meter, 0.0, 1.0)
		inp.boost = boost_request
		if (flags & NetReplayFile.FLAG_RESET) != 0:
			_check_reset(a, b, k)
			_run.hits.reset(st, _run.sim.state)
		var from := _run.events.size()
		_run._sim_tick(_dt)
		_meter = st.boost_meter
		var swapped := _run.forks.right_count != right_before
		right_before = _run.forks.right_count
		if swapped != ((flags & NetReplayFile.FLAG_FORK_SWAP) != 0):
			_violate(V_FORK, k, "the recorded path and the playback disagree on a fork swap")
		_scan_events(from)
		_run.events.clear()
		if _fingerprints.has(k):
			_fp_checked += 1
			if NetReplayFile.traffic_fingerprint(_run.sim.state) == _fingerprints[k]:
				_fp_matched += 1
			elif diverged_at < 0:
				diverged_at = k
		if on_sample and b > 0 and (flags & (NetReplayFile.FLAG_RESET | NetReplayFile.FLAG_FORK_SWAP)) == 0:
			_check_segment(a, b)
		_run.tick_count += 1
		if on_tick.is_valid():
			on_tick.call(k, _run)
		var smp := _run.car.road_sample()
		_run.origin.update_focus(smp.pos_x, smp.pos_y, smp.pos_z)
		if _run.state != Game.RUNNING:
			break


## N8.2: drives the run from GO with the recorded inputs (the real Run.tick), then checks
## each sample against the re-simulated state (exact, in wire units), the boost edges, the
## fork swaps and resets, and the physics limits on the samples.
func _play_resim() -> void:
	var r := replay
	if r.tick[0] != 1:
		_violate(V_SAMPLES, 0, "the first sample is tick %d, not 1" % r.tick[0])
	for i in range(1, r.sample_count):
		if r.tick[i] <= r.tick[i - 1]:
			_violate(V_SAMPLES, int(r.tick[i]), "sample ticks go backwards")
			return
	if expected_seed >= 0 and expected_seed != r.seed_value:
		_violate(V_SEED, 0, "the replay's seed %d is not the run's %d" % [r.seed_value, expected_seed])
	if not _inputs_valid():
		return
	var ctrl := ReplayInputs.new(r)
	_run.drive_controller = ctrl
	var st := _run.car.state
	var last := int(r.tick[r.sample_count - 1])
	var b := 0
	var boost_was := st.boost_active
	var right_before := _run.forks.right_count
	var resets_before := _run._resets
	_resim_edges.clear()
	for k in range(1, last + 1):
		_k = k
		ctrl.k = k
		_run.tick()
		_scan_events(0)
		_run.events.clear()
		if st.boost_active != boost_was:
			boost_was = st.boost_active
			_resim_edges.append(k * 2 + (1 if boost_was else 0))
		var swapped := _run.forks.right_count != right_before
		right_before = _run.forks.right_count
		var reset := _run._resets != resets_before
		resets_before = _run._resets
		if _fingerprints.has(k):
			_fp_checked += 1
			if NetReplayFile.traffic_fingerprint(_run.sim.state) == _fingerprints[k]:
				_fp_matched += 1
			elif diverged_at < 0:
				diverged_at = k
		if b < r.sample_count and int(r.tick[b]) == k:
			var fl := int(r.flags[b])
			if swapped != ((fl & NetReplayFile.FLAG_FORK_SWAP) != 0):
				_violate(V_FORK, k, "the recorded path and the re-simulation disagree on a fork swap")
			if reset != ((fl & NetReplayFile.FLAG_RESET) != 0):
				_violate(V_RESET, k, "the recorded path and the re-simulation disagree on a reset")
			_compare_sample(b, k)
			if b > 0 and (fl & (NetReplayFile.FLAG_RESET | NetReplayFile.FLAG_FORK_SWAP)) == 0:
				_check_segment(b - 1, b)
			b += 1
		elif swapped or reset:
			_violate(V_RESIM, k, "the re-simulation swapped a fork or reset the car where the replay has no sample")
		if on_tick.is_valid():
			on_tick.call(k, _run)
		if _run.state != Game.RUNNING:
			break
	if b < r.sample_count:
		_violate(V_RESIM, _k, "the re-simulated run ended at tick %d, the replay goes on to %d" % [_k, last])
	if _resim_edges != _boost_edges:
		_violate(V_RESIM, 0, "the re-simulated boost edges differ from the recorded ones")


## The input stream's shape: rows from tick 1, strictly increasing ticks, values in range.
func _inputs_valid() -> bool:
	var r := replay
	var q := int(NetReplayFile.Q_INPUT)
	if r.in_tick[0] != 1:
		_violate(V_INPUTS, 0, "the inputs start at tick %d, not 1" % r.in_tick[0])
		return false
	for i in r.input_count:
		if i > 0 and r.in_tick[i] <= r.in_tick[i - 1]:
			_violate(V_INPUTS, int(r.in_tick[i]), "input ticks go backwards")
			return false
		if absi(r.in_steer[i]) > q or r.in_throttle[i] < 0 or r.in_throttle[i] > q or r.in_brake[i] < 0 \
				or r.in_brake[i] > q or r.in_boost[i] < 0 or r.in_boost[i] > 1:
			_violate(V_INPUTS, int(r.in_tick[i]), "an input out of range")
			return false
	return true


## The re-simulated state after tick k against sample b, in wire units (exact).
func _compare_sample(b: int, k: int) -> void:
	var r := replay
	var st := _run.car.state
	var ds := roundi(st.s * NetReplayFile.Q_POS) - r.s_q[b]
	var dd := roundi(st.d * NetReplayFile.Q_POS) - r.d_q[b]
	var dy := roundi(st.yaw * NetReplayFile.Q_YAW) - r.yaw_q[b]
	var dv := roundi(st.v * NetReplayFile.Q_SPEED) - r.v_q[b]
	var dl := roundi(st.v_lat * NetReplayFile.Q_SPEED) - r.vlat_q[b]
	var boost_ok := st.boost_active == ((int(r.flags[b]) & NetReplayFile.FLAG_BOOST_ACTIVE) != 0)
	if ds == 0 and dd == 0 and dy == 0 and dv == 0 and dl == 0 and boost_ok:
		return
	resim_mismatches += 1
	if resim_mismatch_at < 0:
		resim_mismatch_at = k
		_violate(V_RESIM, k, "the re-simulated car is off the recorded sample: s %+d, d %+d (10 um), yaw %+d (1e-6 rad), v %+d, v_lat %+d (0.1 mm/s)%s" % [
			ds, dd, dy, dv, dl, "" if boost_ok else ", boost"])


## The car's state for tick k: sample b exactly, or between samples a and b.
func _set_state(st: VehicleState, inp: VehicleInput, a: int, b: int, k: int, flags: int) -> void:
	var r := replay
	var tb := int(r.tick[b])
	if tb == k or a == b:
		st.s = r.s_at(b)
		st.d = r.d_at(b)
		st.yaw = r.yaw_at(b)
		st.v = r.v_at(b)
		st.v_lat = r.vlat_at(b)
		inp.steer = r.steer_at(b)
		inp.throttle = r.throttle_at(b)
		if (flags & NetReplayFile.FLAG_FORK_SWAP) != 0:
			st.d += _shift_at.get(k, 0.0)   # the fork code moves it again this tick
	else:
		var ta := int(r.tick[a])
		var f := float(k - ta) / float(tb - ta)
		if _seg_a != a:
			_build_segment(a, b)
		st.s = _seg_s[k - ta]
		st.d = _seg_d[k - ta]
		st.yaw = lerpf(r.yaw_at(a), r.yaw_at(b), f)
		st.v = lerpf(r.v_at(a), r.v_at(b), f)
		st.v_lat = lerpf(r.vlat_at(a), r.vlat_at(b), f)
		inp.steer = lerpf(r.steer_at(a), r.steer_at(b), f)
		inp.throttle = lerpf(r.throttle_at(a), r.throttle_at(b), f)
	inp.brake = r.brake_at(b)
	_run.car._place()


## The ticks between samples a and b, integrated like VehiclePhysics.step does (s and d
## move by the speed before the tick along the heading after it) from velocities
## interpolated between the samples, then corrected linearly so the end lands exactly on
## sample b. Plain linear positions are off by tenths of a millimetre mid-segment; this is
## off by micrometres.
func _build_segment(a: int, b: int) -> void:
	var r := replay
	var n := int(r.tick[b] - r.tick[a])
	_seg_a = a
	_seg_s.resize(n + 1)
	_seg_d.resize(n + 1)
	var s := r.s_at(a)
	var d := r.d_at(a)
	_seg_s[0] = s
	_seg_d[0] = d
	var va := r.v_at(a)
	var vb := r.v_at(b)
	for j in range(1, n + 1):
		var f := float(j) / float(n)
		var v_prev := lerpf(va, vb, float(j - 1) / float(n))
		var yaw := lerpf(r.yaw_at(a), r.yaw_at(b), f)
		var vlat := lerpf(r.vlat_at(a), r.vlat_at(b), f)
		var sy := DetMath.sin_cos(yaw)
		var cy := DetMath.cos_out
		var kappa := _run.road.curvature_at(s)
		s += (v_prev * cy - vlat * sy) / (1.0 - kappa * d) * _dt
		d += (v_prev * sy + vlat * cy) * _dt
		_seg_s[j] = s
		_seg_d[j] = d
	var err_s := r.s_at(b) - _seg_s[n]
	var err_d := r.d_at(b) - _seg_d[n]
	for j in range(1, n + 1):
		var f := float(j) / float(n)
		_seg_s[j] += err_s * f
		_seg_d[j] += err_d * f


## Reads the run's event buffer from `from`: playback hits and scored kinds.
func _scan_events(from: int) -> void:
	var ev := _run.events
	for i in range(from, ev.size()):
		var kind := ev.kind[i]
		if kind == RunStats.KIND_HIT:
			playback_hits.append(_k)
		elif kind == ScoreEvents.PASS or kind == ScoreEvents.CLOSE_PASS or kind == ScoreEvents.CUT \
				or kind == ScoreEvents.THREAD:
			var key := String(kind)
			_recomputed_kinds[key] = _recomputed_kinds.get(key, 0) + 1
			_scored.append((_k << CODE_BITS) | KIND_CODES.find(kind))


# ---------------------------------------------------------------- Physics limits

## Path checks between samples a and b (b > a): speed, s and d against the recorded
## velocities (teleports, edited paths), lateral speed and acceleration, yaw rate and
## longitudinal acceleration against the car's capability × verify_limit_factor.
func _check_segment(a: int, b: int) -> void:
	var r := replay
	var k := int(r.tick[b])
	var span := float(k - int(r.tick[a])) / _hz
	var factor := tuning.verify_limit_factor
	var va := r.v_at(a)
	var vb := r.v_at(b)
	var top := _limits.params.boost_top_speed_mps * (1.0 + tuning.verify_speed_margin_pct / 100.0)
	if vb > top:
		_violate(V_SPEED, k, "%.2f m/s above the car's boosted top speed %.2f" % [vb, top])
	var kappa_a := _run.road.curvature_at(r.s_at(a))
	var kappa_b := _run.road.curvature_at(r.s_at(b))
	var ya := r.yaw_at(a)
	var yb := r.yaw_at(b)
	var sa := DetMath.sin_cos(ya)
	var ca := DetMath.cos_out
	var sb := DetMath.sin_cos(yb)
	var cb := DetMath.cos_out
	var sdot_a := (va * ca - r.vlat_at(a) * sa) / (1.0 - kappa_a * r.d_at(a))
	var sdot_b := (vb * cb - r.vlat_at(b) * sb) / (1.0 - kappa_b * r.d_at(b))
	var ddot_a := va * sa + r.vlat_at(a) * ca
	var ddot_b := vb * sb + r.vlat_at(b) * cb
	var ds := r.s_at(b) - r.s_at(a)
	var dd := r.d_at(b) - r.d_at(a)
	var tol := tuning.verify_path_tolerance_m
	if absf(ds - (sdot_a + sdot_b) * 0.5 * span) > tol:
		_violate(V_TELEPORT, k, "s moved %.2f m where the speeds give %.2f m" % [ds, (sdot_a + sdot_b) * 0.5 * span])
	if absf(dd - (ddot_a + ddot_b) * 0.5 * span) > tol:
		_violate(V_LATERAL_PATH, k, "d moved %.2f m where the speeds give %.2f m" % [dd, (ddot_a + ddot_b) * 0.5 * span])
	if _near_hit(k):
		return   # a hit's deflection and speed loss are the run's, not the driver's
	var v_ref := maxf(va, vb)
	var q_speed := 2.0 / NetReplayFile.Q_POS / span
	var lat_speed := absf(dd) / span
	var lat_cap := _limits.max_lat_speed(v_ref) * factor + q_speed
	if lat_speed > lat_cap:
		_violate(V_LATERAL_SPEED, k, "lateral speed %.2f m/s above the car's %.2f" % [lat_speed, lat_cap])
	var q_accel := 2.0 / NetReplayFile.Q_SPEED / span
	var lat_acc := absf(ddot_b - ddot_a) / span
	var acc_cap := _limits.max_lat_accel(v_ref) * factor + q_accel
	if lat_acc > acc_cap:
		_violate(V_LATERAL_ACCEL, k, "lateral acceleration %.1f m/s^2 above the car's %.1f" % [lat_acc, acc_cap])
	var road_turn := maxf(absf(kappa_a), absf(kappa_b)) * v_ref
	var yr := absf(yb - ya) / span
	var yr_cap := (_limits.max_yaw_rate(v_ref) + road_turn) * factor + 2.0 / NetReplayFile.Q_YAW / span
	if yr > yr_cap:
		_violate(V_YAW_RATE, k, "yaw rate %.2f rad/s above the car's %.2f" % [yr, yr_cap])
	var acc := (vb - va) / span
	var up := maxf(_limits.max_accel(va), _limits.max_accel(vb)) * factor + q_accel
	var down := maxf(_limits.max_decel(va), _limits.max_decel(vb)) * factor + q_accel
	if acc > up or -acc > down:
		_violate(V_ACCEL, k, "speed changes at %.1f m/s^2 (the car: +%.1f / -%.1f)" % [acc, up, down])


## The safety net (Run.dev_reset_car) only fires after the car went through a barrier,
## which only the ghost allows, and puts it on a lane centre at half speed.
func _check_reset(a: int, b: int, k: int) -> void:
	var r := replay
	var d := r.d_at(b)
	var s := r.s_at(b)
	var lane := clampi(_run.road.lane_index_at(d, s), 0, _run.road.lane_count(s) - 1)
	var centred := absf(d - _run.road.lane_center_d(lane, s)) <= tuning.verify_path_tolerance_m
	var halved := r.v_at(b) <= r.v_at(a) * 0.5 + tuning.verify_path_tolerance_m
	if not _run.lives.is_ghost() or not centred or not halved:
		_violate(V_RESET, k, "a reset outside the ghost, off a lane centre or without the speed loss")


func _near_hit(k: int) -> bool:
	for h in playback_hits:
		if k >= h and k - h <= _hit_grace_ticks:
			return true
	for h in _logged_hits:
		if absf(k - h) <= _hit_grace_ticks:
			return true
	return false


func _violate(kind: String, k: int, detail: String) -> void:
	_violation_count += 1
	if _violations.size() < MAX_LISTED_VIOLATIONS:
		_violations.append({"kind": kind, "tick": k, "detail": detail})


# ---------------------------------------------------------------- Verdict

func _verdict(recomputed: int) -> void:
	var claimed: int = result["claimed_score"]
	var claimed_h: int = result["claimed_hits"]
	var diff_pct := absf(float(recomputed - claimed)) * 100.0 / maxf(float(claimed), 1.0)
	var unexplained := _unexplained_hits()
	var unreported := maxi(unexplained, playback_hits.size() - claimed_h)
	result["recomputed_score"] = recomputed
	result["diff_pct"] = snappedf(diff_pct, 0.001)
	result["recomputed_hits"] = playback_hits.size()
	result["logged_hits"] = _logged_hits.size()
	result["unreported_hits"] = maxi(unreported, 0)
	result["violations"] = _violations
	result["violation_count"] = _violation_count
	result["events"] = _event_counts()
	# Diagnostics (not part of the verdict): where the playback's traffic stopped being the
	# client's. Until the determinism audit (N8.2) an honest replay can diverge; what comes
	# after that point is compared against another traffic.
	result["traffic_checks"] = _fp_checked
	result["traffic_matched"] = _fp_matched
	result["traffic_diverged_at_s"] = null
	if diverged_at >= 0:
		result["traffic_diverged_at_s"] = snappedf(float(diverged_at) / _hz, 0.01)
	var log_match := _log_match_pct()
	result["log_match_pct"] = snappedf(log_match, 0.01)
	var missing := _missing_hits()
	result["missing_hits"] = missing
	result["playback"] = "resim" if _resimulating() else "kinematic"
	result["resim_mismatch_at_s"] = null
	if resim_mismatch_at >= 0:
		result["resim_mismatch_at_s"] = snappedf(float(resim_mismatch_at) / _hz, 0.01)
	result["resim_mismatches"] = resim_mismatches
	var reason := REASON_ACCEPTED
	if _has(V_SEED):
		reason = REASON_SEED
	elif _has(V_SAMPLES) or _has(V_INPUTS):
		reason = REASON_MALFORMED
	elif _has(V_RESIM):
		reason = REASON_PATH
	elif _violation_count > 0:
		reason = REASON_PHYSICS
	elif unreported > 0:
		reason = REASON_HITS
	elif diff_pct > tuning.verify_score_pct:
		reason = REASON_SCORE
	elif log_match < tuning.verify_log_match_pct or missing > 0:
		reason = REASON_LOG
	result["reason"] = reason
	result["accepted"] = reason == REASON_ACCEPTED


## Playback hits that no logged hit explains: none within verify_hit_match_s, and not in
## the ghost that followed a logged hit (a missed first hit shifts the ghost).
func _unexplained_hits() -> int:
	var window := roundi(tuning.verify_hit_match_s * _hz)
	var ghost := roundi(_ghost_s * _hz)
	var used := PackedByteArray()
	used.resize(_logged_hits.size())
	var n := 0
	for h in playback_hits:
		var found := false
		for j in _logged_hits.size():
			if used[j] == 0 and absf(h - _logged_hits[j]) <= window:
				used[j] = 1
				found = true
				break
		if not found:
			for lh in _logged_hits:
				if h >= lh and h - lh <= ghost + window:
					found = true
					break
		if not found:
			n += 1
	return n


## How much of the client's scoring log the playback reproduces: scored events matched
## one to one (same kind, within verify_hit_match_s), over the larger of the two counts.
## 100 when neither side has at least verify_log_min_events.
## Logged hits the playback does not find (within verify_hit_match_s, or in the ghost of
## a playback hit): an honest replay finds every hit again, so these say the replay is
## not of this world (another seed, a made-up log).
func _missing_hits() -> int:
	var window := roundi(tuning.verify_hit_match_s * _hz)
	var ghost := roundi(_ghost_s * _hz)
	var n := 0
	for lh in _logged_hits:
		var found := false
		for h in playback_hits:
			if absf(h - lh) <= window or (lh >= h and lh - h <= ghost + window):
				found = true
				break
		if not found:
			n += 1
	return n


func _log_match_pct() -> float:
	var logged := PackedInt64Array()
	for i in replay.event_count:
		if int(replay.ev_kind[i]) == NetReplayFile.Kind.SCORED:
			var code := KIND_CODES.find(StringName(replay.tag_of(i)))
			if code >= 0:
				logged.append((int(replay.ev_tick[i]) << CODE_BITS) | code)
	var total := maxi(logged.size(), _scored.size())
	if total < tuning.verify_log_min_events:
		return 100.0
	var window := roundi(tuning.verify_hit_match_s * _hz)
	var mask := (1 << CODE_BITS) - 1
	var used := PackedByteArray()
	used.resize(_scored.size())
	var matched := 0
	var start := 0
	for e in logged:
		var t := e >> CODE_BITS
		var code := e & mask
		while start < _scored.size() and (_scored[start] >> CODE_BITS) < t - window:
			start += 1
		for j in range(start, _scored.size()):
			var tj := _scored[j] >> CODE_BITS
			if tj > t + window:
				break
			if used[j] == 0 and (_scored[j] & mask) == code:
				used[j] = 1
				matched += 1
				break
	return float(matched) * 100.0 / float(total)


func _has(kind: String) -> bool:
	for v in _violations:
		if v["kind"] == kind:
			return true
	return false


func _event_counts() -> Dictionary:
	var logged: Dictionary[String, int] = {}
	for i in replay.event_count:
		if int(replay.ev_kind[i]) == NetReplayFile.Kind.SCORED:
			var t := replay.tag_of(i)
			logged[t] = logged.get(t, 0) + 1
	var out := {}
	for k: String in [String(ScoreEvents.PASS), String(ScoreEvents.CLOSE_PASS), String(ScoreEvents.CUT),
			String(ScoreEvents.THREAD)]:
		out[k] = {"logged": logged.get(k, 0), "recomputed": _recomputed_kinds.get(k, 0)}
	return out


## N8.2: the recorded inputs as a controller (piecewise constant: a row holds from its tick
## until the next row's). The verifier sets `k` before each tick.
class ReplayInputs:
	extends VehicleController

	var r: NetReplayFile
	var k: int = 0
	var _row: int = 0

	func _init(replay_file: NetReplayFile) -> void:
		r = replay_file

	func update(_dt: float, _state: VehicleState, out_input: VehicleInput) -> void:
		while _row + 1 < r.input_count and r.in_tick[_row + 1] <= k:
			_row += 1
		out_input.steer = float(r.in_steer[_row]) / NetReplayFile.Q_INPUT
		out_input.throttle = float(r.in_throttle[_row]) / NetReplayFile.Q_INPUT
		out_input.brake = float(r.in_brake[_row]) / NetReplayFile.Q_INPUT
		out_input.boost = r.in_boost[_row] == 1
