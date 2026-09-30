extends "res://tests/verifier/verifier_harness.gd"
## WP N8.1 / N8.2: the replay verifier (tools/verifier) on real headless runs. Spec:
## multiplayer handoff → Testing → Verifier ("100 % of honest replays accepted; tampered
## replays rejected: inflated score, edited path (teleport, impossible lateral speed),
## removed hit, wrong seed"). docs/REPLAY_FORMAT.md → Verification; docs/DETERMINISM.md.
##
## Fast tier: two runs recorded once for the suite (a weaving, boosting bot for 25 s; a
## driver that rams the traffic ahead until its crash), then each check plays a replay
## back. N8.2: a replay carries the car's exact inputs, and the verifier re-simulates the
## run from them: the re-simulation reproduces the recorded run tick for tick (every
## sample exactly, every event, the score); an edited path or edited inputs leave it
## (path_mismatch). The N8.1 kinematic playback (a replay without inputs) keeps its
## physics limits and its exact-state check.
## Soak tier: honest runs of 10 minutes and more on several seeds and cars, with the
## weaving, boosting bot and with PassabilityDriver (a reacting driver on Passability's
## path): 100 % accepted, every traffic fingerprint matched.

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
## N8.2: the long honest runs (the verifier replays the run's own lives, so each run ends
## at its crash or here).
const LONG_S := 660.0
const LONG_SEEDS: Array[int] = [20260929, 424242, 9001]
const STEER_EDIT := 20
const DAILY_S := 8.0

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
	check(_weave.replay.has_inputs(), "N8.2: the replay carries the car's inputs")
	var res := await verify(_weave.replay)
	eq(res.get("playback"), "resim", "re-simulated from the inputs")
	eq(res.get("recomputed_score"), _weave.score, "the client's score exactly")
	eq(res.get("traffic_matched"), res.get("traffic_checks"), "every traffic fingerprint matches")
	eq(res.get("resim_mismatches"), 0, "every sample exactly")
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


func _teleported() -> NetReplayFile:
	var r := _copy(_weave)
	for i in range(r.sample_count >> 1, r.sample_count):
		r.s_q[i] += roundi(TELEPORT_M * NetReplayFile.Q_POS)
	return r


## A lane's width in a tenth of a second, with the heading edited to match (so the path
## is consistent with its own velocities): far beyond what the car can do sideways.
func _lane_jumped() -> NetReplayFile:
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
	return r


func test_teleport_is_rejected() -> void:
	var res := await verify(_teleported())
	check(not bool(res.get("accepted", true)), describe(res))
	eq(res.get("reason"), ReplayVerifier.REASON_PATH, "the re-simulated car is not there")


func test_teleport_is_rejected_by_the_kinematic_playback() -> void:
	var kin := await verify(_teleported(), -1, -1, -1, false)
	check(not bool(kin.get("accepted", true)), describe(kin))
	eq(kin.get("reason"), ReplayVerifier.REASON_PHYSICS, "kinematic playback: the physics limits")
	check(_kinds(kin).has(ReplayVerifier.V_TELEPORT), "a teleport: %s" % describe(kin))


func test_impossible_lateral_speed_is_rejected() -> void:
	var res := await verify(_lane_jumped())
	check(not bool(res.get("accepted", true)), describe(res))
	eq(res.get("reason"), ReplayVerifier.REASON_PATH, "the re-simulated car is not there")


func test_impossible_lateral_speed_is_rejected_by_the_kinematic_playback() -> void:
	var kin := await verify(_lane_jumped(), -1, -1, -1, false)
	check(not bool(kin.get("accepted", true)), describe(kin))
	eq(kin.get("reason"), ReplayVerifier.REASON_PHYSICS, "kinematic playback: the physics limits")
	check(_kinds(kin).has(ReplayVerifier.V_LATERAL_SPEED), "lateral speed: %s" % describe(kin))


## N8.2: inputs edited (a steering bias from the middle on), the samples left as they
## were: the re-simulated car leaves the recorded path. An input out of range: malformed.
func test_edited_inputs_are_rejected() -> void:
	var r := _copy(_weave)
	var q := int(NetReplayFile.Q_INPUT)
	for i in range(r.input_count >> 1, r.input_count):
		r.in_steer[i] = clampi(r.in_steer[i] + STEER_EDIT, -q, q)
	var res := await verify(r)
	check(not bool(res.get("accepted", true)), describe(res))
	eq(res.get("reason"), ReplayVerifier.REASON_PATH)
	check(res.get("resim_mismatch_at_s") != null, "where it left the path")
	var bad := _copy(_weave)
	bad.in_throttle[0] = q * 2
	var res2 := await verify(bad)
	eq(res2.get("reason"), ReplayVerifier.REASON_MALFORMED, "an input out of range: %s" % describe(res2))


## N8.2: a Daily replay is verified on its own date's seed (not the verifier's today),
## and a date that does not give the run's seed is a seed mismatch.
func test_daily_replay_is_verified_on_its_date() -> void:
	var rec := await record_bot_run(0, 2, DAILY_S, RunContext.MODE_DAILY)
	eq(rec.replay.mode, NetReplayFile.MODE_DAILY)
	eq(rec.replay.seed_value, Run.daily_seed_for(REPLAY_DATE), "the date's seed")
	var res := await verify(rec.replay, rec.score, rec.hits, rec.replay.seed_value)
	check(bool(res.get("accepted", false)), describe(res))
	var r := _copy(rec)
	r.date = "2026-10-01"
	var res2 := await verify(r, rec.score, rec.hits, rec.replay.seed_value)
	eq(res2.get("reason"), ReplayVerifier.REASON_SEED, "another date: %s" % describe(res2))


## N8.2: a replay without inputs (an N8.1 client) is played back kinematically.
func test_a_replay_without_inputs_plays_kinematically() -> void:
	var r := _copy(_weave)
	r.input_count = 0
	var back := NetReplayFile.decode(r.encode())
	check(back != null and not back.has_inputs(), "no input section")
	var res := await verify(back)
	eq(res.get("playback"), "kinematic")
	check(bool(res.get("accepted", false)), describe(res))


## N8.3: the production sidecar passes --require-inputs=1: a replay without inputs is
## "cannot verify" (exit 3, set aside by the server's worker), never a kinematic verdict.
func test_require_inputs_refuses_a_replay_without_inputs() -> void:
	var main_script: GDScript = load("res://tools/verifier/verify_replay_main.gd")
	var r := _copy(_weave)
	r.input_count = 0
	var back := NetReplayFile.decode(r.encode())
	var on := {"require-inputs": "1"}
	var why := String(main_script.call(&"inputs_error", back, on))
	check(why.begins_with("no_inputs"), why)
	eq(main_script.call(&"inputs_error", back, {}), "", "off by default: the kinematic playback")
	eq(main_script.call(&"inputs_error", back, {"require-inputs": "0"}), "", "=0 is off")
	eq(main_script.call(&"inputs_error", _copy(_weave), on), "", "a replay with inputs is verified")
	for flag: String in ["--require-inputs=1", "--require-inputs"]:
		var parsed: Dictionary = main_script.call(&"parse_args", PackedStringArray([flag, "--out=/tmp/x"]))
		check(String(main_script.call(&"inputs_error", back, parsed)).begins_with("no_inputs"), flag)


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


## N8.2: honest runs of up to LONG_S (a run ends earlier at its crash: the verifier
## replays the run's own lives), the weaving, boosting bot and the reacting
## PassabilityDriver on three seeds: every one accepted, every sample re-simulated
## exactly, every traffic fingerprint matched, the score exactly the client's. Prints the
## replay size per 10 minutes.
func soak_long_honest_runs_are_all_accepted() -> void:
	var total := 0
	var accepted := 0
	for n in LONG_SEEDS.size():
		for driver in 2:
			var rec: Recorded
			if driver == 0:
				rec = await record_bot_run(LONG_SEEDS[n], n % Run.CAR_PATHS.size(), LONG_S,
					RunContext.MODE_JOURNEY, BOT_SEED + n)
			else:
				var sd := BOT_SEED + n
				var make := func(r: Run) -> VehicleController:
					return PassabilityDriver.new(r, sd, RUN_SPEED_MPS)
				rec = await record_run(LONG_SEEDS[n], (n + 1) % Run.CAR_PATHS.size(), LONG_S, make)
			var res := await verify(rec.replay, rec.score, rec.hits)
			var per_10_min := float(rec.bytes.size()) / 1024.0 * 600.0 / maxf(rec.seconds, 1.0)
			var line := "%s seed %d car %s: %.0f s, %d hits, crashed %s, %d input rows, %d bytes (%.1f KB per 10 min), %s, verify %d ms" % [
				"weave" if driver == 0 else "passability", LONG_SEEDS[n], rec.replay.car, rec.seconds, rec.hits,
				rec.crashed, rec.replay.input_count, rec.bytes.size(), per_10_min, describe(res),
				int(res.get("elapsed_ms", 0))]
			print("      " + line)
			total += 1
			if check(bool(res.get("accepted", false)), line):
				accepted += 1
			eq(res.get("recomputed_score"), rec.score, "the score exactly: " + line)
			eq(res.get("traffic_matched"), res.get("traffic_checks"), "every fingerprint: " + line)
			eq(res.get("resim_mismatches"), 0, "every sample: " + line)
	print("      honest replays accepted: %d / %d" % [accepted, total])


## The N8.1 measurement behind docs/REPLAY_FORMAT.md → Honest replays, kept for the
## kinematic playback (replays without inputs). Asserted: every honest path passes every
## physics limit, the replay stays within the size budget, a replay whose kinematic
## traffic never diverged is accepted, and re-simulated (the default) all five are.
func soak_five_honest_bot_runs() -> void:
	var accepted := 0
	for n in SOAK_RUNS:
		var rec := await record_bot_run(SOAK_SEEDS[n], n % Run.CAR_PATHS.size(), SOAK_MAX_S,
				RunContext.MODE_JOURNEY, BOT_SEED + n)
		var res := await verify(rec.replay, rec.score, rec.hits, -1, false)
		var per_10_min := float(rec.bytes.size()) / 1024.0 * 600.0 / maxf(rec.seconds, 1.0)
		var line := "seed %d car %s: %.0f s, %d bytes (%.1f KB per 10 min), kinematic %s, log match %.1f %%, verify %d ms" % [
			SOAK_SEEDS[n], rec.replay.car, rec.seconds, rec.bytes.size(), per_10_min, describe(res),
			float(res.get("log_match_pct", 0.0)), int(res.get("elapsed_ms", 0))]
		print("      " + line)
		eq(res.get("violation_count"), 0, "an honest path breaks no physics limit: " + line)
		lt(per_10_min, 100.0, "about 100 KB per 10 minutes at most")
		if res.get("traffic_diverged_at_s") == null:
			check(bool(res.get("accepted", false)), line)
		var re := await verify(rec.replay, rec.score, rec.hits)
		print("        re-simulated: %s" % describe(re))
		if check(bool(re.get("accepted", false)), "re-simulated: " + describe(re)):
			accepted += 1
	print("      honest replays accepted (re-simulated): %d / %d" % [accepted, SOAK_RUNS])


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
