class_name NetReplayRecorder
extends Node
## Records a single-player run's replay: the player's path and inputs at 30 Hz, the exact
## boost edges and discontinuities, and the client's event log. Spec: multiplayer handoff
## → Leaderboards (single-player runs, step 3), Client changes (`replay_recorder.gd`:
## path and input recording for single-player runs), Tuning reference (30 Hz). WP N8.1;
## format: docs/REPLAY_FORMAT.md; docs/NET_CLIENT.md → Replays.
##
## Listen-only (Architecture rule 8): it reads the Run's car and counters after each tick
## and listens to `Events`; it never writes gameplay state, and run.gd has no hook for it.
##
## - **Attaching:** on `Events.run_started` it finds the Run (the current scene, else the
##   parent of the tree's "PlayerCar") and starts a new replay for Journey and Daily
##   runs (never Loop practice). Tests call begin(run) themselves (`auto_attach` off).
## - **Ticks:** `_physics_process` runs at PHYSICS_PRIORITY, after the Run (50) in the
##   same physics frame, so it sees every 120 Hz tick (manual-tick tests call capture()
##   after each Run.tick()). The RUNNING tick index k (1 = the first tick after GO) is
##   `RunStats.duration_s` × tick rate: RunStats observes exactly the RUNNING ticks. The
##   run-ending tick (the second hit returns before RunStats) is k + 1, taken when the
##   state is first CRASH.
## - **Samples:** the state after ticks k = 1, 1 + n, 1 + 2n, ... (n =
##   NetTuning.replay_sample_ticks: 4 = 30 Hz): s, d, yaw (heading vs road), v, v_lat, and
##   the inputs: steer and throttle at that tick, the largest brake of the n ticks up to it
##   (a tap between samples still fails a "no braking" objective on playback), and whether
##   a boost was requested in them. A fork swap (the road moved to the right branch: d
##   jumps by the fork's shift), the safety net (car put back in a lane) and the last tick
##   are always sampled, together with the tick before them.
## - **Exact events** (from the per-tick state): boost on / off, fork swaps (with the
##   shift), resets, and once a second (NetTuning.replay_fingerprint_ticks) the traffic's
##   fingerprint (NetReplayFile.traffic_fingerprint), so the verifier can tell where its
##   traffic stopped being this one. **The event log** (from `Events`, stamped with the last tick seen):
##   scored, hit, chain banked / lost, bonus, checkpoint crossed.
## - **finish(results, date):** the header's claims (score, hits, distance, ticks) from the
##   run_over payload, then the encoded bytes. NetRunsClient stores them until uploaded.
## Per tick it allocates nothing (the columns are reserved for replay_reserve_s and grow
## by doubling).

const PHYSICS_PRIORITY := 60
const CAR_NODE := "PlayerCar"

## Attach to runs on Events.run_started (the game). Off: begin() by hand (tests).
var auto_attach: bool = true
var tuning: NetTuning
var client_build: int = 0
var run: Run
## A replay is being recorded (between begin() and finish()).
var recording: bool = false
var replay: NetReplayFile

var _hz: float = 120.0
var _every: int = 4
var _fingerprint_every: int = 120
var _last_k: int = 0
var _last_sample_k: int = 0
var _crash_done: bool = false
var _prev_boost: bool = false
var _win_brake: float = 0.0
var _win_boost: bool = false
var _last_right: int = 0
var _last_resets: int = 0
var _has_prev: bool = false
var _p_k: int = 0
var _p_s: float = 0.0
var _p_d: float = 0.0
var _p_yaw: float = 0.0
var _p_v: float = 0.0
var _p_vlat: float = 0.0
var _p_steer: float = 0.0
var _p_throttle: float = 0.0
var _p_boost: bool = false
var _hash_cache: Dictionary[int, int] = {}


func _init(net_tuning: NetTuning = null, build: int = 0) -> void:
	name = "ReplayRecorder"
	tuning = net_tuning
	client_build = build
	process_physics_priority = PHYSICS_PRIORITY


func _enter_tree() -> void:
	_connect(Events.run_started, _on_run_started)
	_connect(Events.scored, _on_scored)
	_connect(Events.hit, _on_hit)
	_connect(Events.chain_banked, _on_banked)
	_connect(Events.chain_lost, _on_lost)
	_connect(Events.bonus_awarded, _on_bonus)
	_connect(Events.checkpoint_crossed, _on_checkpoint)


func _exit_tree() -> void:
	for pair: Array in [[Events.run_started, _on_run_started], [Events.scored, _on_scored],
			[Events.hit, _on_hit], [Events.chain_banked, _on_banked], [Events.chain_lost, _on_lost],
			[Events.bonus_awarded, _on_bonus], [Events.checkpoint_crossed, _on_checkpoint]]:
		var sig: Signal = pair[0]
		if sig.is_connected(pair[1]):
			sig.disconnect(pair[1])


func _physics_process(_delta: float) -> void:
	if recording:
		capture()


## Starts a replay of `r`'s current run (Journey / Daily only). False when it will not
## record (Loop practice, no car yet).
func begin(r: Run) -> bool:
	recording = false
	run = r
	if r == null or r.car == null or r.ctx == null:
		return false
	if r.mode != RunContext.MODE_JOURNEY and r.mode != RunContext.MODE_DAILY:
		return false
	var t := tuning if tuning != null else NetTuning.load_default()
	_hz = float(r.tuning.vehicle.physics_tick_hz)
	_every = maxi(t.replay_sample_ticks, 1)
	_fingerprint_every = maxi(t.replay_fingerprint_ticks, 1)
	replay = NetReplayFile.new()
	replay.seed_value = r.current_seed
	replay.client_build = client_build
	replay.tuning_hash = _tuning_hash(r.ctx.tuning)
	replay.mode = NetReplayFile.mode_id(r.mode)
	replay.tick_hz = r.tuning.vehicle.physics_tick_hz
	replay.sample_ticks = _every
	replay.car = String(r.car.car.id)
	var reserve := ceili(t.replay_reserve_s * _hz / float(_every))
	replay.reserve(reserve, reserve >> 2)   # events: about one per four samples
	_last_k = 0
	_last_sample_k = 0
	_crash_done = false
	_prev_boost = false
	_win_brake = 0.0
	_win_boost = false
	_last_right = r.forks.right_count
	_last_resets = r._resets
	_has_prev = false
	recording = true
	return true


## After each Run tick: samples, exact events. Cheap and allocation-free when nothing is due.
func capture() -> void:
	if not recording or run == null or not is_instance_valid(run) or run.car == null:
		return
	if run.state == Game.RUNNING:
		var k := roundi(run.stats.duration_s * _hz)
		if k > _last_k:
			_tick(k, false)
	elif run.state == Game.CRASH and not _crash_done and _last_k > 0:
		_crash_done = true
		_tick(_last_k + 1, true)


## The replay bytes with the run_over claims (score, hits, distance) and `date`; stops
## recording. Empty when nothing was recorded.
func finish(results: Dictionary, date: String) -> PackedByteArray:
	if replay == null or not recording:
		recording = false
		return PackedByteArray()
	recording = false
	if replay.sample_count == 0:
		return PackedByteArray()
	replay.date = date
	replay.ticks = _last_k
	replay.score = int(results.get(RunStats.SCORE, 0))
	replay.hits = int(results.get(RunStats.HITS, 0))
	replay.distance_mm = roundi(float(results.get(RunStats.DISTANCE_M, 0.0)) * NetReplayFile.Q_CLEARANCE)
	return replay.encode()


## Stops without producing anything (a new run, a retry).
func cancel() -> void:
	recording = false


func _tick(k: int, final: bool) -> void:
	var cs := run.car.state
	var inp := run.car.input
	var fl := 0
	var swapped := run.forks.right_count != _last_right
	var reset := run._resets != _last_resets
	_last_right = run.forks.right_count
	_last_resets = run._resets
	if swapped or reset or final:
		# The tick before a discontinuity, so playback never interpolates across it.
		if _has_prev and _p_k > _last_sample_k and _p_k == k - 1:
			replay.add_sample(_p_k, _p_s, _p_d, _p_yaw, _p_v, _p_vlat, _p_steer, _p_throttle,
				_win_brake, NetReplayFile.FLAG_BOOST_ACTIVE if _p_boost else 0)
			_last_sample_k = _p_k
			_win_brake = 0.0
			_win_boost = false
		if swapped:
			fl |= NetReplayFile.FLAG_FORK_SWAP
			replay.add_event(k, NetReplayFile.Kind.FORK_SWAP, "", 0, roundi(_fork_shift() * NetReplayFile.Q_POS))
		if reset:
			fl |= NetReplayFile.FLAG_RESET
			replay.add_event(k, NetReplayFile.Kind.RESET, "", 0, 0)
		if final:
			fl |= NetReplayFile.FLAG_FINAL
	_win_brake = maxf(_win_brake, inp.brake)
	_win_boost = _win_boost or inp.boost
	if cs.boost_active != _prev_boost:
		_prev_boost = cs.boost_active
		replay.add_event(k, NetReplayFile.Kind.BOOST_ON if cs.boost_active else NetReplayFile.Kind.BOOST_OFF, "", 0, 0)
	if cs.boost_active:
		fl |= NetReplayFile.FLAG_BOOST_ACTIVE
	if swapped or reset or final or (k - 1) % _every == 0:
		if _win_boost:
			fl |= NetReplayFile.FLAG_BOOST_REQUEST
		replay.add_sample(k, cs.s, cs.d, cs.yaw, cs.v, cs.v_lat, inp.steer, inp.throttle, _win_brake, fl)
		_last_sample_k = k
		_win_brake = 0.0
		_win_boost = false
	if (k - 1) % _fingerprint_every == 0:
		replay.add_event(k, NetReplayFile.Kind.TRAFFIC, "", 0, NetReplayFile.traffic_fingerprint(run.sim.state))
	_has_prev = true
	_p_k = k
	_p_s = cs.s
	_p_d = cs.d
	_p_yaw = cs.yaw
	_p_v = cs.v
	_p_vlat = cs.v_lat
	_p_steer = inp.steer
	_p_throttle = inp.throttle
	_p_boost = cs.boost_active
	_last_k = k


## The lateral shift of the fork just resolved to the right (RunForks keeps it per fork).
func _fork_shift() -> float:
	var f := run.forks
	if f.active < 0 or f.active >= f._shifts.size():
		return 0.0
	return f._shifts[f.active]


func _tuning_hash(t: Tuning) -> int:
	var id := t.get_instance_id()
	if not _hash_cache.has(id):
		_hash_cache[id] = NetReplayFile.tuning_hash_of(t)
	return _hash_cache[id]


# ---------------------------------------------------------------- Events (listen-only)

func _on_run_started(_mode: StringName, _seed: int) -> void:
	if not auto_attach:
		return
	var r := _find_run()
	if r != null:
		begin(r)
	else:
		recording = false


func _find_run() -> Run:
	if not is_inside_tree():
		return null
	var scene := get_tree().current_scene
	if scene is Run:
		return scene as Run
	var car := get_tree().root.find_child(CAR_NODE, true, false)
	if car != null and car.get_parent() is Run:
		return car.get_parent() as Run
	return null


func _on_scored(kind: StringName, points: int, multiplier: float, clearance_m: float) -> void:
	if recording:
		replay.add_event(_last_k, NetReplayFile.Kind.SCORED, String(kind), points,
			roundi(multiplier * NetReplayFile.Q_MULTIPLIER), clearance_m)


func _on_hit(source: StringName, lives_left: int) -> void:
	if recording:
		replay.add_event(_last_k, NetReplayFile.Kind.HIT, String(source), 0, lives_left)


func _on_banked(amount: int, reason: StringName, banked_total: int) -> void:
	if recording:
		replay.add_event(_last_k, NetReplayFile.Kind.BANKED, String(reason), amount, banked_total)


func _on_lost(amount: int, reason: StringName) -> void:
	if recording:
		replay.add_event(_last_k, NetReplayFile.Kind.CHAIN_LOST, String(reason), amount, 0)


func _on_bonus(kind: StringName, points: int, banked_total: int) -> void:
	if recording:
		replay.add_event(_last_k, NetReplayFile.Kind.BONUS, String(kind), points, banked_total)


func _on_checkpoint(leg_index: int, _summary: Dictionary) -> void:
	if recording:
		replay.add_event(_last_k, NetReplayFile.Kind.CHECKPOINT, "", 0, leg_index)


static func _connect(sig: Signal, fn: Callable) -> void:
	if not sig.is_connected(fn):
		sig.connect(fn)
