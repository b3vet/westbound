extends "res://tests/verifier/verifier_harness.gd"
## WP N8.1: the replay verifier (tools/verifier) on real headless runs. Spec: multiplayer
## handoff → Testing → Verifier ("100 % of honest replays accepted; tampered replays
## rejected: inflated score, edited path (teleport, impossible lateral speed), removed
## hit, wrong seed"). docs/REPLAY_FORMAT.md → Verification.
##
## Fast tier: two runs recorded once for the suite (a weaving, boosting bot for 25 s; a
## driver that rams the traffic ahead until its crash), then each check plays a replay
## back; the playback fed the original's exact car states reproduces the simulation hash
## of every tick (the tick order is the run's).
## Soak tier: five honest 4-minute bot runs on different seeds and cars: their paths
## break no physics limit, and the numbers (score diff, first traffic divergence) are
## printed for docs/REPLAY_FORMAT.md; with exact states two of them replay bit for bit.
## Today the quantized, interpolated path makes the traffic diverge after tens of seconds
## to minutes (the director's knife edges; docs/REPLAY_FORMAT.md → Honest replays today),
## so their acceptance is reported, not asserted, until the determinism audit (N8.2).

const SHORT_S := 25.0
const RAM_S := 90.0
const OTHER_SEED := 777001
const INFLATE := 1.1
const TELEPORT_M := 20.0
const LANE_JUMP_M := 3.5
const JUMP_SAMPLES := 3
const SOAK_RUNS := 5
const SOAK_MAX_S := 240.0
const SOAK_SEEDS: Array[int] = [20260929, 424242, 9001, 31337, 123456789]

const EXACT_RUNS := 2

var _weave: Recorded
var _ram: Recorded


func before_all() -> void:
	super.before_all()
	_weave = await record_bot_run(SEED, 0, SHORT_S, RunContext.MODE_JOURNEY, BOT_SEED, RUN_SPEED_MPS, true)
	_ram = await record_rammer_run(SEED + 1, 1, RAM_S)


func _copy(rec: Recorded) -> NetReplayFile:
	return NetReplayFile.decode(rec.bytes)


func test_honest_bot_replay_is_accepted() -> void:
	check(_weave.replay != null, "the replay decodes")
	var res := await verify(_weave.replay)
	print("      weave: %s (%.1f s driven, %d bytes, verify %d ms)" % [describe(res), _weave.seconds,
		_weave.bytes.size(), int(res.get("elapsed_ms", 0))])
	check(bool(res.get("accepted", false)), describe(res))
	eq(res.get("violation_count"), 0, "an honest path breaks no limit")
	gt(int(res.get("recomputed_score", 0)), 0, "the bot scored")


## The playback's tick is the run's: with the original's exact car state fed in, every
## tick's traffic, scoring, lives, legs, sun, forks and stats hash equal the original's.
func test_exact_states_reproduce_every_tick() -> void:
	var out := await verify_exact(_weave)
	var res: Dictionary = out[1]
	eq(out[0], -1, "first differing tick")
	eq(res.get("recomputed_score"), _weave.score, "the same score")
	eq(res.get("traffic_matched"), res.get("traffic_checks"), "every traffic fingerprint matches")


func test_honest_replay_with_hits_is_accepted() -> void:
	check(_ram.replay != null, "the replay decodes")
	gt(_ram.hits, 0, "the rammer hit the traffic")
	var res := await verify(_ram.replay, _ram.score, _ram.hits)
	print("      ram: %s (%.1f s, crashed %s)" % [describe(res), _ram.seconds, _ram.crashed])
	check(bool(res.get("accepted", false)), describe(res))
	eq(int(res.get("recomputed_hits", -1)), _ram.hits, "every hit found again")
	eq(res.get("unreported_hits"), 0)


func test_inflated_score_is_rejected() -> void:
	var res := await verify(_copy(_weave), roundi(_weave.score * INFLATE) + 10)
	check(not bool(res.get("accepted", true)), describe(res))
	eq(res.get("reason"), ReplayVerifier.REASON_SCORE)


func test_teleport_is_rejected() -> void:
	var r := _copy(_weave)
	for i in range(r.sample_count >> 1, r.sample_count):
		r.s_q[i] += roundi(TELEPORT_M * NetReplayFile.Q_POS)
	var res := await verify(r)
	check(not bool(res.get("accepted", true)), describe(res))
	eq(res.get("reason"), ReplayVerifier.REASON_PHYSICS)
	check(_kinds(res).has(ReplayVerifier.V_TELEPORT), "a teleport: %s" % describe(res))


## A lane's width in a tenth of a second, with the heading edited to match (so the path
## is consistent with its own velocities): far beyond what the car can do sideways.
func test_impossible_lateral_speed_is_rejected() -> void:
	var r := _copy(_weave)
	var from := r.sample_count >> 1
	var span := float(r.tick[from + JUMP_SAMPLES] - r.tick[from]) / float(r.tick_hz)
	var lat := LANE_JUMP_M / span
	for i in range(from + 1, r.sample_count):
		var f := minf(float(i - from) / float(JUMP_SAMPLES), 1.0)
		r.d_q[i] += roundi(LANE_JUMP_M * f * NetReplayFile.Q_POS)
		if i <= from + JUMP_SAMPLES:
			var v := r.v_at(i)
			r.yaw_q[i] = roundi(asin(clampf(lat / v, -1.0, 1.0)) * NetReplayFile.Q_YAW)
	var res := await verify(r)
	check(not bool(res.get("accepted", true)), describe(res))
	eq(res.get("reason"), ReplayVerifier.REASON_PHYSICS)
	check(_kinds(res).has(ReplayVerifier.V_LATERAL_SPEED), "lateral speed: %s" % describe(res))


## The path still runs into the traffic; the log and the claim say it never did.
func test_removed_hit_is_rejected() -> void:
	var r := _copy(_ram)
	var i := 0
	while i < r.event_count:
		if int(r.ev_kind[i]) == NetReplayFile.Kind.HIT:
			r.remove_event(i)
		else:
			i += 1
	r.hits = 0
	var res := await verify(r, _ram.score, 0)
	check(not bool(res.get("accepted", true)), describe(res))
	eq(res.get("reason"), ReplayVerifier.REASON_HITS)
	gt(int(res.get("unreported_hits", 0)), 0)


## Another seed in the header: the server passes the run's real seed (seed_mismatch);
## played in the other world without it, the path and log do not fit (rejected either way).
func test_wrong_seed_is_rejected() -> void:
	var r := _copy(_ram)
	r.seed_value = OTHER_SEED
	var res := await verify(r, _ram.score, _ram.hits, SEED + 1)
	check(not bool(res.get("accepted", true)), describe(res))
	eq(res.get("reason"), ReplayVerifier.REASON_SEED)
	var blind := await verify(_copy_with_seed(_ram, OTHER_SEED), _ram.score, _ram.hits)
	check(not bool(blind.get("accepted", true)), "played in the wrong world: %s" % describe(blind))
	var weave := await verify(_copy_with_seed(_weave, OTHER_SEED))
	check(not bool(weave.get("accepted", true)), "the weave in the wrong world: %s" % describe(weave))


func test_unreadable_replays_are_errors_not_verdicts() -> void:
	var bytes := _weave.bytes.duplicate()
	bytes[0] = 0
	var errs: Array[String] = []
	check(NetReplayFile.decode(bytes, errs) == null, "bad magic")
	eq(errs, ["bad magic"] as Array[String])
	var truncated := _weave.bytes.slice(0, _weave.bytes.size() - 5)
	check(NetReplayFile.decode(truncated) == null, "truncated")
	var r := _copy(_weave)
	r.tuning_hash ^= 1
	var res := await verify(r)
	check(res.has("error") and not res.has("accepted"), "another build's tuning: %s" % str(res.get("error")))


## The measurement behind docs/REPLAY_FORMAT.md → Honest replays today. Asserted: every
## honest path passes every physics limit, the replay stays within the size budget, and a
## replay whose traffic never diverged is accepted.
func soak_five_honest_bot_runs() -> void:
	var accepted := 0
	for n in SOAK_RUNS:
		var rec := await record_bot_run(SOAK_SEEDS[n], n % Run.CAR_PATHS.size(), SOAK_MAX_S,
				RunContext.MODE_JOURNEY, BOT_SEED + n)
		var res := await verify(rec.replay, rec.score, rec.hits)
		var per_10_min := float(rec.bytes.size()) / 1024.0 * 600.0 / maxf(rec.seconds, 1.0)
		var line := "seed %d car %s: %.0f s, %d bytes (%.1f KB per 10 min), %s, log match %.1f %%, verify %d ms" % [
			SOAK_SEEDS[n], rec.replay.car, rec.seconds, rec.bytes.size(), per_10_min, describe(res),
			float(res.get("log_match_pct", 0.0)), int(res.get("elapsed_ms", 0))]
		print("      " + line)
		eq(res.get("violation_count"), 0, "an honest path breaks no physics limit: " + line)
		lt(per_10_min, 100.0, "about 100 KB per 10 minutes at most")
		if res.get("traffic_diverged_at_s") == null:
			check(bool(res.get("accepted", false)), line)
		if bool(res.get("accepted", false)):
			accepted += 1
	print("      honest replays accepted today: %d / %d" % [accepted, SOAK_RUNS])


## With the original's exact car states the playback is the run, bit for bit, for minutes:
## the divergence above is the path's precision, not the playback.
func soak_exact_states_reproduce_long_runs() -> void:
	for n in EXACT_RUNS:
		var rec := await record_bot_run(SOAK_SEEDS[n], n % Run.CAR_PATHS.size(), SOAK_MAX_S,
				RunContext.MODE_JOURNEY, BOT_SEED + n, RUN_SPEED_MPS, true)
		var out := await verify_exact(rec)
		var res: Dictionary = out[1]
		print("      exact seed %d: first differing tick %d, %s" % [SOAK_SEEDS[n], out[0], describe(res)])
		eq(out[0], -1, "seed %d: every tick identical" % SOAK_SEEDS[n])
		check(bool(res.get("accepted", false)), describe(res))


func _copy_with_seed(rec: Recorded, s: int) -> NetReplayFile:
	var r := _copy(rec)
	r.seed_value = s
	return r


static func _kinds(res: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for v: Dictionary in res.get("violations", []):
		out.append(String(v.get("kind", "")))
	return out
