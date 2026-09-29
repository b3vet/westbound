extends WBTest
## WP N8.1: the replay file (NetReplayFile) and the recorder (NetReplayRecorder). Spec:
## multiplayer handoff → Leaderboards (single-player runs, step 3: path and inputs at
## 30 Hz, the event log, about 100 KB compressed for 10 minutes), Testing → Client
## ("Replay recorder: output matches the verifier's expected format").
## docs/REPLAY_FORMAT.md is the byte layout these tests pin.

const RUN_SCENE := preload("res://src/run/run.tscn")
const SEED := 20260929
const BIG_SEED := 9223372036854775807
const TEN_MINUTES_S := 600.0
const BUDGET_BYTES := 102400
const SYNTH_V := 55.0
const SYNTH_LANE_M := 3.6
const SYNTH_WEAVE_S := 4.0
const STEER_WOBBLE := 0.03
const EVENT_EVERY_S := 1.5
const TICKS_PER_FRAME := 2
const FRAME_S := 1.0 / 60.0
const DRIVE_S := 3.0

var net: NetTuning
var t: Tuning
var _nodes: Array[Node] = []


func before_all() -> void:
	net = NetTuning.load_default()
	t = Tuning.load_default()


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	await tree.process_frame


# ---------------------------------------------------------------- Format

func _sample_file() -> NetReplayFile:
	var r := NetReplayFile.new()
	r.run_id = 917
	r.seed_value = BIG_SEED
	r.client_build = 42
	r.tuning_hash = 0xDEADBEEF
	r.mode = NetReplayFile.MODE_DAILY
	r.date = "2026-09-29"
	r.car = "night_viper"
	r.ticks = 13
	r.score = 183_200
	r.hits = 1
	r.distance_mm = 24_018_400
	r.add_sample(1, 150.0, 7.1, 0.0, 33.3, 0.0, 0.0, 1.0, 0.0, 0)
	r.add_sample(5, 151.1, 7.05, -0.012345, 33.4, -0.25, -0.5, 0.75, 0.2, NetReplayFile.FLAG_BOOST_REQUEST)
	r.add_sample(9, 152.2, -3.5, 0.2, 34.0, 1.5, 1.0, 0.0, 1.0,
			NetReplayFile.FLAG_BOOST_ACTIVE | NetReplayFile.FLAG_FORK_SWAP)
	r.add_sample(13, 4_000_000.123456, 12.0, -3.14159, 99.9999, -2.0, -1.0, 1.0, 0.0, NetReplayFile.FLAG_FINAL)
	r.add_event(5, NetReplayFile.Kind.SCORED, "close_pass", 3450, 23500, 0.431)
	r.add_event(6, NetReplayFile.Kind.BOOST_ON, "", 0, 0)
	r.add_event(9, NetReplayFile.Kind.FORK_SWAP, "", 0, -1_234_567)
	r.add_event(12, NetReplayFile.Kind.HIT, "traffic", 0, 1)
	r.add_event(12, NetReplayFile.Kind.CHAIN_LOST, "hit", 9_007_199_254_740_991, 0)
	r.add_event(13, NetReplayFile.Kind.SCORED, "close_pass", 30, 1000, 0.0)
	return r


func test_round_trip_keeps_every_field() -> void:
	var a := _sample_file()
	var bytes := a.encode()
	var errs: Array[String] = []
	var b := NetReplayFile.decode(bytes, errs)
	if not check(b != null, "decodes: %s" % str(errs)):
		return
	for f: String in ["run_id", "seed_value", "client_build", "tuning_hash", "mode", "tick_hz", "sample_ticks",
			"date", "car", "ticks", "score", "hits", "distance_mm", "sample_count", "event_count"]:
		eq(b.get(f), a.get(f), f)
	for f: String in ["tick", "s_q", "d_q", "yaw_q", "v_q", "vlat_q", "steer_q", "throttle_q", "brake_q", "flags"]:
		eq((b.get(f) as PackedInt64Array).slice(0, b.sample_count), (a.get(f) as PackedInt64Array).slice(0, a.sample_count), f)
	for f: String in ["ev_tick", "ev_kind", "ev_points", "ev_clearance", "ev_value"]:
		eq((b.get(f) as PackedInt64Array).slice(0, b.event_count), (a.get(f) as PackedInt64Array).slice(0, a.event_count), f)
	for i in a.event_count:
		eq(b.tag_of(i), a.tag_of(i), "tag %d" % i)
	near(b.s_at(3), 4_000_000.123456, 1.0 / NetReplayFile.Q_POS, "s to 10 µm")
	near(b.yaw_at(1), -0.012345, 1.0 / NetReplayFile.Q_YAW, "yaw to 1e-6 rad")
	near(b.v_at(3), 99.9999, 1.0 / NetReplayFile.Q_SPEED, "speed to 0.1 mm/s")
	eq(b.ev_clearance[0], 431, "clearance in mm")
	eq(b.ev_clearance[1], -1, "no clearance")
	eq(b.encode(), bytes, "re-encoding is byte-identical")


func test_header_layout_is_the_documented_one() -> void:
	var bytes := _sample_file().encode()
	eq(bytes.slice(0, 4).get_string_from_ascii(), "WBR1", "magic")
	eq(bytes.decode_u16(4), NetReplayFile.VERSION, "version")
	eq(bytes.decode_u16(6), NetReplayFile.FIXED_HEADER + "night_viper".length(), "header length")
	eq(bytes.decode_s64(8), 917, "run id at 8")
	eq(bytes.decode_s64(16), BIG_SEED, "seed at 16")
	eq(bytes.decode_u32(24), 42, "build at 24")
	eq(bytes[32], NetReplayFile.MODE_DAILY, "mode at 32")
	eq(bytes[33], NetReplayFile.COMPRESSION_GZIP, "gzip")
	eq(bytes.slice(38, 48).get_string_from_ascii(), "2026-09-29", "date at 38")
	eq(bytes.decode_s64(52), 183_200, "score at 52")
	var header_len := bytes.decode_u16(6)
	eq(bytes.decode_u32(72), bytes.size() - header_len, "payload length")
	eq(bytes.slice(header_len, header_len + 2), PackedByteArray([0x1f, 0x8b]), "a gzip stream follows")
	check(NetReplayFile.patch_run_id(bytes, 1234), "patched")
	eq(NetReplayFile.read_run_id(bytes), 1234)
	eq(NetReplayFile.decode(bytes).run_id, 1234, "the patch keeps the file valid")


func test_bad_files_are_refused() -> void:
	var good := _sample_file().encode()
	var cases := {
		"too short": good.slice(0, 20),
		"truncated": good.slice(0, good.size() - 1),
	}
	var bad_magic := good.duplicate()
	bad_magic[1] = 0
	cases["bad magic"] = bad_magic
	var bad_version := good.duplicate()
	bad_version.encode_u16(4, 99)
	cases["version"] = bad_version
	var bad_mode := good.duplicate()
	bad_mode[32] = 7
	cases["mode"] = bad_mode
	for name: String in cases:
		var errs: Array[String] = []
		check(NetReplayFile.decode(cases[name] as PackedByteArray, errs) == null, name)
		check(not errs.is_empty(), "%s says why" % name)
	check(not NetReplayFile.patch_run_id(PackedByteArray([1, 2, 3]), 5), "not a replay: no patch")
	var corrupt := good.duplicate()
	corrupt[corrupt.size() - 12] ^= 0xFF
	expect_errors(1)   # Godot's gzip reports the bad stream
	check(NetReplayFile.decode(corrupt) == null, "corrupt payload")


## Ten minutes of a weaving, boosting drive (VehiclePhysics at 120 Hz, a steering
## controller that changes every tick) plus an event every 1.5 s and the traffic
## fingerprints: under the spec's ~100 KB.
func test_ten_minutes_fit_the_budget() -> void:
	var def := load(Run.CAR_PATHS[0]) as CarDef
	var params := VehicleParams.build(t, def)
	var st := VehicleState.new()
	var inp := VehicleInput.new()
	VehiclePhysics.place(st, params, 0.0, 0.0, SYNTH_V)
	var rng := Rng.new(SEED)
	var r := NetReplayFile.new()
	var hz := float(t.vehicle.physics_tick_hz)
	var dt := t.vehicle.physics_dt()
	var ticks := roundi(TEN_MINUTES_S * hz)
	var every := net.replay_sample_ticks
	var event_every := roundi(EVENT_EVERY_S * hz)
	for k in range(1, ticks + 1):
		var time_s := float(k) / hz
		var target := SYNTH_LANE_M * signf(sin(TAU * time_s / SYNTH_WEAVE_S))
		inp.steer = clampf(0.3 * (target - st.d) - 2.0 * st.yaw + STEER_WOBBLE * (rng.unit() - 0.5), -1.0, 1.0)
		inp.throttle = clampf(0.5 + 0.1 * (SYNTH_V - st.v), 0.0, 1.0)
		inp.brake = 0.0
		VehiclePhysics.step(st, inp, dt, params, null)
		if (k - 1) % every == 0:
			r.add_sample(k, st.s, st.d, st.yaw, st.v, st.v_lat, inp.steer, inp.throttle, inp.brake,
					NetReplayFile.FLAG_BOOST_ACTIVE if st.boost_active else 0)
		if k % event_every == 0:
			r.add_event(k, NetReplayFile.Kind.SCORED, "close_pass", 30 + k % 700, 1000 + k % 9000, rng.unit())
		if (k - 1) % net.replay_fingerprint_ticks == 0:
			r.add_event(k, NetReplayFile.Kind.TRAFFIC, "", 0, int(rng.unit() * float(0x7FFFFFFF)))
	var bytes := r.encode()
	print("      10 min: %d samples, %d events, %d bytes (%.1f KB)" % [r.sample_count, r.event_count,
		bytes.size(), float(bytes.size()) / 1024.0])
	lt(bytes.size(), BUDGET_BYTES, "about 100 KB per 10 minutes")
	eq(r.sample_count, ceili(float(ticks) / float(every)), "30 Hz")
	check(NetReplayFile.decode(bytes) != null, "and it reads back")


# ---------------------------------------------------------------- Recorder on a run

func _run(mode: StringName = RunContext.MODE_JOURNEY) -> Run:
	var r := RUN_SCENE.instantiate() as Run
	r.run_seed = SEED
	r.mode = mode
	r.manual_ticks = true
	r.crash_cinematic = false
	r.record_best = false
	return r


## A scripted input: brake taps between samples, one boost request.
class Tapper:
	extends VehicleController
	var ticks: int = 0

	func update(_dt: float, _state: VehicleState, out: VehicleInput) -> void:
		ticks += 1
		out.steer = 0.0
		out.throttle = 1.0
		out.brake = 0.4 if ticks % 8 == 3 else 0.0
		out.boost = ticks == 10


func test_recorder_attaches_to_a_run_and_samples_at_30_hz() -> void:
	var rec := NetReplayRecorder.new(net, 5)
	tree.root.add_child(rec)
	_nodes.append(rec)
	var r := _run()
	tree.root.add_child(r)   # run_started: the recorder finds it
	_nodes.append(r)
	if not check(rec.recording and rec.run == r, "attached on run_started"):
		return
	var tap := Tapper.new()
	r.drive_controller = tap
	r.car.state.boost_meter = 1.0
	r.go()
	var n := roundi(DRIVE_S * float(t.vehicle.physics_tick_hz))
	for i in n:
		r.tick()
		rec.capture()
		if r.tick_count % TICKS_PER_FRAME == 0:
			r.frame(FRAME_S)
	var results := {RunStats.SCORE: 1234, RunStats.HITS: 0, RunStats.DISTANCE_M: 100.5}
	var bytes := rec.finish(results, "2026-09-29")
	check(not rec.recording, "finish stops it")
	var f := NetReplayFile.decode(bytes)
	if not check(f != null, "a valid file"):
		return
	eq(f.seed_value, SEED)
	eq(f.mode, NetReplayFile.MODE_JOURNEY)
	eq(f.car, String(r.car.car.id))
	eq(f.client_build, 5)
	eq(f.tuning_hash, NetReplayFile.tuning_hash_of(r.ctx.tuning), "the simulation tuning's hash")
	eq(f.date, "2026-09-29")
	eq(f.score, 1234)
	eq(f.distance_mm, 100_500)
	eq(f.ticks, n, "every RUNNING tick counted")
	eq(f.sample_count, ceili(float(n) / float(net.replay_sample_ticks)), "every 4th tick")
	eq(f.tick[0], 1, "the first tick after GO")
	eq(f.tick[1], 1 + net.replay_sample_ticks)
	near(f.s_at(f.sample_count - 1), r.car.state.s - r.car.state.v * t.vehicle.physics_dt() * 3.0, 1.0,
		"the last sample is the car's path")
	var brakes := 0
	for i in f.sample_count:
		if f.brake_at(i) > 0.0:
			brakes += 1

	eq(brakes, f.sample_count >> 1, "a brake tap between samples still shows (the window's largest)")
	var on := -1
	var fps := 0
	for i in f.event_count:
		if int(f.ev_kind[i]) == NetReplayFile.Kind.BOOST_ON:
			on = int(f.ev_tick[i])
		elif int(f.ev_kind[i]) == NetReplayFile.Kind.TRAFFIC:
			fps += 1
	eq(on, 10, "the boost's exact tick")
	eq(fps, ceili(float(n) / float(net.replay_fingerprint_ticks)), "a traffic fingerprint a second")


func test_loop_practice_is_not_recorded() -> void:
	var rec := NetReplayRecorder.new(net, 5)
	rec.auto_attach = false
	tree.root.add_child(rec)
	_nodes.append(rec)
	var r := _run(Run.MODE_LOOP)
	tree.root.add_child(r)
	_nodes.append(r)
	check(not rec.begin(r), "loop mode: no replay")
	check(rec.finish({}, "2026-09-29").is_empty(), "nothing to finish")


func test_the_crash_tick_is_the_last_sample() -> void:
	var rec := NetReplayRecorder.new(net, 5)
	rec.auto_attach = false
	tree.root.add_child(rec)
	_nodes.append(rec)
	var r := _run()
	tree.root.add_child(r)
	_nodes.append(r)
	r.go()
	rec.begin(r)
	for i in 6:
		r.tick()
		rec.capture()
	r.force_hit(HitDetection.HIT_BARRIER, -1, 1)
	r.tick()
	rec.capture()
	for i in t.lives.ghost_period_s * float(t.vehicle.physics_tick_hz) + 2.0:
		r.tick()
		rec.capture()
		if r.tick_count % TICKS_PER_FRAME == 0:
			r.frame(FRAME_S)
	r.force_hit(HitDetection.HIT_BARRIER, -1, -1)
	r.tick()
	rec.capture()
	r.frame(FRAME_S)
	eq(r.state, Game.CRASH)
	r.tick()
	rec.capture()
	var f := NetReplayFile.decode(rec.finish({RunStats.SCORE: 0, RunStats.HITS: 2}, "2026-09-29"))
	if not check(f != null):
		return
	var last := f.sample_count - 1
	check((int(f.flags[last]) & NetReplayFile.FLAG_FINAL) != 0, "flagged final")
	eq(f.tick[last], f.ticks, "at the crash tick")
	eq(f.tick[last - 1], f.ticks - 1, "with the tick before it")
	var hits := 0
	for i in f.event_count:
		if int(f.ev_kind[i]) == NetReplayFile.Kind.HIT:
			hits += 1
	eq(hits, 2, "both hits in the log")
