@warning_ignore_start("integer_division")
class_name DailyTrace
extends RefCounted
## The cross-platform determinism check's scripted Daily run (M8 gate: "Daily Drive
## gives identical runs on two devices for the same date"). Spec: Architecture rule 2
## (deterministic by seed: "This powers Daily Drive, ghosts and reproducible bug
## reports"), Implementation milestones → M8; plan §8 risk "cross-platform determinism".
## WP8.4; docs/DAILY.md → Determinism check.
##
## The same code runs natively (tools/determinism/daily_trace.gd, headless) and in the
## web build (`?determinism=daily&date=YYYY-MM-DD&seconds=N`, DailyTraceNode), and prints
## the same lines, so tools/determinism/compare.mjs can diff them:
##   DT info date=... seed=... driver=... view_m=... tier=... platform=... hz=...
##   DT libm sin=... cos=... ...                  (the math library's bits on fixed inputs)
##   DT detmath sin=... cos=... ...               (the same on DetMath: identical everywhere)
##   DT sec=N all=h car=h input=h traffic=h opp=h scoring=h lives=h legs=h obj=h sun=h
##          forks=h stats=h  s=... v=... cars=n   (after every simulated second)
##   DTT k=... (per tick of --detail=<second>: the same hashes and the car's float bits)
##   DT replay seed=... score=... b64=...         (with record_replay: the run's .wbr, N8.2)
##   DT done seconds=N
##
## The run: the real Run scene (manual ticks, Daily mode on the given date, the car of
## CAR_PATHS[0], infinite lives so it lasts, no crash cinematic, nothing saved), GO at
## once, driven by DailyScriptDriver (open-loop inputs: the same on every platform) or,
## with driver "bot", the weaving SandboxBot (closed-loop, like a player: it reacts to the
## state, so any difference grows, and adds its own asin). Run.frame() every
## check_ticks_per_frame ticks (events drained, views updated) as the game does. The view
## distance is pinned to the default tier's (WP8.4: it set the director's spawn distance;
## since N8.2 the simulation reads RoadTuning.sim_horizon_m instead, so the pin only keeps
## the two sides' rendering alike: tests/run/test_sim_horizon.gd).

const BOOT_PARAM := "determinism"
const SCENE := "res://src/meta/daily/daily_trace.tscn"
const RUN_SCENE_PATH := "res://src/run/run.tscn"
const PREFIX := "DT"
const FRAME_S := 1.0 / 60.0
const HEX32 := "%08x"
## libm probe: inputs x_i = LIBM_FROM + i × LIBM_STEP.
const LIBM_COUNT := 4096
const LIBM_FROM := -40.0
const LIBM_STEP := 0.0195
const LIBM_POW := 1.7
const LIBM_ATAN_X := 1.3
const LIBM_EXP_SCALE := 0.125
const LIBM_LOG_BIAS := 0.1
const LIBM_MASK_BITS := 8
const LIBM_CHUNK := 64

var tuning: DailyTuning
var run: Run
## The driver: DailyScriptDriver (&"script") or SandboxBot (&"bot").
var driver: VehicleController
## &"script" or &"bot" (default: the tuning's check_driver).
var driver_kind: StringName = &""
var date: String = ""
var seconds: int = 0
## Print per-tick lines within this second (0: none).
var detail_second: int = 0
## N8.2: also record the run's replay (NetReplayRecorder) and print it at the end as
## "DT replay ... b64=<the .wbr bytes>", so the other platform's verifier can check it
## (compare.sh --replay). With it the run keeps its real lives (a verifier replays those),
## so it can end at its crash.
var record_replay: bool = false
var recorder: NetReplayRecorder
var ticks_done: int = 0
var tick_hz: int = 120
var view_m: float = 0.0
var view_m_before: float = 0.0
## Every line produced so far (the caller prints them as they come: take_lines()).
var lines := PackedStringArray()

var _bits := PackedByteArray()


func _init(daily_tuning: DailyTuning = null) -> void:
	tuning = daily_tuning if daily_tuning != null else DailyTuning.resolve()
	_bits.resize(8)


## Builds the run under `parent` and starts it. `pin_view_m` < 0 = the default tier's view
## distance; 0 = leave whatever the device's quality gives.
func start(parent: Node, run_date: String, run_seconds: int, pin_view_m: float = -1.0) -> void:
	date = run_date
	seconds = maxi(run_seconds, 1)
	var r := (load(RUN_SCENE_PATH) as PackedScene).instantiate() as Run
	r.mode = RunContext.MODE_DAILY
	r.daily_date = date
	r.manual_ticks = true
	r.crash_cinematic = false
	r.record_best = false
	r.car_index = 0
	parent.add_child(r)
	run = r
	run.infinite_lives = not record_replay
	tick_hz = run.tuning.vehicle.physics_tick_hz
	view_m_before = run.builder.view_distance_m()
	var pin := pin_view_m
	if pin < 0.0:
		var q := run.tuning.quality
		pin = q.view_distance_m[maxi(q.tier_index(q.default_tier), 0)]
	if pin > 0.0 and not is_equal_approx(pin, view_m_before):
		run.builder.view_distance_override_m = pin
		run.retry()   # Daily keeps the date's seed; the director takes the pinned fog end
	view_m = run.builder.view_distance_m()
	var car := run.car
	if driver_kind == &"":
		driver_kind = tuning.check_driver
	if driver_kind == &"bot":
		var bot := SandboxBot.new(run.road, run.sim.state, car.params, tuning.check_bot_seed)
		bot.mode = SandboxBot.Mode.WEAVE
		bot.v_target = tuning.check_bot_speed_mps()
		bot.length_m = car.car.length_m
		bot.width_m = car.car.width_m
		driver = bot
	else:
		driver_kind = &"script"
		driver = DailyScriptDriver.new(tuning, tick_hz)
	run.drive_controller = driver
	run.go()
	if record_replay:
		recorder = NetReplayRecorder.new(NetTuning.load_default(), NetTuning.load_default().client_build)
		recorder.auto_attach = false
		recorder.set_physics_process(false)   # captured after each of our ticks instead
		parent.add_child(recorder)
		recorder.begin(run)
	ticks_done = 0
	lines.append(info_line())
	lines.append(libm_line())
	lines.append(libm_line(true))
	lines.append(params_line())


## Runs up to `n` more ticks; a line per completed second. True when finished.
func step_ticks(n: int) -> bool:
	var total := seconds * tick_hz
	var every := maxi(tuning.check_ticks_per_frame, 1)
	for i in n:
		if ticks_done >= total:
			break
		run.tick()
		if recorder != null:
			recorder.capture()
		ticks_done += 1
		if ticks_done % every == 0:
			run.frame(FRAME_S)
		var sec := (ticks_done - 1) / tick_hz + 1
		if detail_second > 0 and sec == detail_second:
			lines.append(tick_line())
		if ticks_done % tick_hz == 0:
			lines.append(second_line(ticks_done / tick_hz))
	if ticks_done >= total and recorder != null and recorder.recording:
		lines.append(replay_line())
	if ticks_done >= total and (lines.is_empty() or not lines[lines.size() - 1].begins_with(PREFIX + " done")):
		lines.append("%s done seconds=%d" % [PREFIX, ticks_done / tick_hz])
		return true
	return ticks_done >= total


## The lines produced since the last call.
func take_lines() -> PackedStringArray:
	var out := lines
	lines = PackedStringArray()
	return out


## "DT replay seed=... score=... hits=... bytes=N b64=...": the recorded replay with the
## run's claims (the banked score: a run cut here loses its held chain, as at its end).
func replay_line() -> String:
	var results := {RunStats.SCORE: run.scoring.banked(), RunStats.HITS: run.stats.hits,
		RunStats.DISTANCE_M: run.stats.distance_m}
	var bytes := recorder.finish(results, date)
	return "%s replay seed=%d score=%d hits=%d crashed=%s bytes=%d b64=%s" % [PREFIX, run.current_seed,
		run.scoring.banked(), run.stats.hits, run.state == Game.CRASH, bytes.size(), Marshalls.raw_to_base64(bytes)]


func finish() -> void:
	if recorder != null and is_instance_valid(recorder):
		recorder.queue_free()
	recorder = null
	if run != null and is_instance_valid(run):
		run.queue_free()
	run = null


# ---------------------------------------------------------------- Lines

func info_line() -> String:
	var q := run.tuning.quality
	return "%s info date=%s seed=%d driver=%s view_m=%.1f view_m_device=%.1f tier=%s platform=%s hz=%d build=%s params=%s" % [
		PREFIX, date, run.current_seed, driver_kind, view_m, view_m_before, q.default_tier, OS.get_name(),
		tick_hz, "debug" if OS.is_debug_build() else "release", _h(params_hash(run.car.params))]


## Every number of the car's VehicleParams (built at load time, with tan / pow / atan in
## the calibration): a difference here means the physics runs on other constants.
static func params_hash(p: Object) -> int:
	var h := TraceHash.SEED
	for prop: Dictionary in p.get_property_list():
		if (int(prop.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		var n := String(prop.get("name", ""))
		if not n.begins_with("_"):
			h = _mix_value(h, p.get(n))
	return h


## "DT params name=hash ...": each VehicleParams value's hash (compare.mjs names the ones
## that differ).
func params_line() -> String:
	var parts := PackedStringArray()
	var p := run.car.params
	for prop: Dictionary in p.get_property_list():
		if (int(prop.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		var n := String(prop.get("name", ""))
		if n.begins_with("_"):
			continue   # build scratch, not a constant
		parts.append("%s=%s" % [n, _h(_mix_value(TraceHash.SEED, p.get(n)))])
	return "%s params %s" % [PREFIX, " ".join(parts)]


## The yaw the wobble adds on the next tick (0 when not wobbling), as Lives.step does.
func _wobble_next(dt: float) -> float:
	var l := run.lives
	if not l.is_wobbling():
		return 0.0
	var t1 := minf(l._wobble_t + dt, l._wobble_s)
	return l._wobble_offset(t1) - l._wobble_offset(l._wobble_t)


static func _mix_value(h: int, v: Variant) -> int:
	if v is float:
		return TraceHash.mix_float(h, v)
	if v is int or v is bool:
		return TraceHash.mix_int(h, int(v))
	if v is PackedFloat64Array:
		var a := v as PackedFloat64Array
		return TraceHash.mix_f64_array(h, a, a.size())
	if v is PackedFloat32Array:
		for x: float in v as PackedFloat32Array:
			h = TraceHash.mix_float(h, x)
	return h


func second_line(sec: int) -> String:
	var st := run.car.state
	return "%s sec=%d all=%s %s s=%.3f d=%.4f v=%.4f cars=%d score=%d hits=%d" % [PREFIX, sec,
		_h(run.trace_hash()), _components(), st.s, st.d, st.v, run.sim.state.count, run.scoring.banked(),
		run.stats.hits]


## Also the DetMath results the next VehiclePhysics.step takes from this state (lcos,
## lsin: the heading; lexp: the yaw lag blend; ltan: the steer angle) and the first-hit
## wobble's next yaw step (lwob, Lives: a sine): on the tick before the first divergence,
## the one that differs is its cause (N8.2: DetMath's, so they should never differ).
func tick_line() -> String:
	var st := run.car.state
	var p := run.car.params
	var dt := run.tuning.vehicle.physics_dt()
	return "DTT k=%d all=%s %s s=%s d=%s yaw=%s v=%s vlat=%s steer=%s lcos=%s lsin=%s lexp=%s ltan=%s lwob=%s" % [
		ticks_done, _h(run.trace_hash()), _components(), _f(st.s), _f(st.d), _f(st.yaw), _f(st.v),
		_f(st.v_lat), _f(run.car.input.steer), _f(DetMath.cos(st.yaw)), _f(DetMath.sin(st.yaw)),
		_f(DetMath.exp(-dt / p.yaw_lag_s(maxf(st.v, 0.0)))), _f(DetMath.tan(st.steer_angle)), _f(_wobble_next(dt))]


func _components() -> String:
	var s0 := TraceHash.SEED
	return "car=%s input=%s traffic=%s opp=%s scoring=%s lives=%s legs=%s obj=%s sun=%s forks=%s stats=%s" % [
		_h(run.car.state.hash_into(s0)), _h(run.car.input.hash_into(s0)), _h(run.sim.state.hash_into(s0)),
		_h(run.director.opposite.state.hash_into(s0)), _h(run.scoring.hash_into(s0)),
		_h(run.lives.hash_into(s0)), _h(run.legs.hash_into(s0)), _h(run.objectives.hash_into(s0)),
		_h(run.sun.hash_into(s0)), _h(run.forks.hash_into(s0)), _h(run.stats.hash_into(s0))]


## The platform's math library on fixed inputs (a hash per function): differences here
## are the usual cause of native vs wasm divergence (glibc vs emscripten's musl libm).
## `masked=` hashes the same results with the low LIBM_MASK_BITS mantissa bits cleared (equal
## there = the differences are last-bit rounding); `chunks=` has an 8-bit hash per block of
## LIBM_CHUNK inputs (compare.mjs counts the blocks that differ: the share of inputs hit).
## With `det` (N8.2): the same probe on DetMath ("DT detmath"), which must be identical
## on every platform.
static func libm_line(det: bool = false) -> String:
	var names: Array[String] = ["sin", "cos", "tan", "atan2", "exp", "log", "pow", "sqrt", "asin", "atan"]
	var hs: Array[int] = []
	var masked: Array[int] = []
	var chunk: Array[int] = []
	var chunks: Array[String] = []
	for j in names.size():
		hs.append(TraceHash.SEED)
		masked.append(TraceHash.SEED)
		chunk.append(TraceHash.SEED)
		chunks.append("")
	var bits := PackedByteArray()
	bits.resize(8)
	var mask := ~((1 << LIBM_MASK_BITS) - 1)
	for i in LIBM_COUNT:
		var x := LIBM_FROM + float(i) * LIBM_STEP
		var ax := absf(x)
		var vals: Array[float] = [sin(x), cos(x), tan(x), atan2(x, LIBM_ATAN_X), exp(x * LIBM_EXP_SCALE),
			log(ax + LIBM_LOG_BIAS), pow(ax + LIBM_LOG_BIAS, LIBM_POW), sqrt(ax),
			asin(clampf(x / absf(LIBM_FROM), -1.0, 1.0)), atan(x)]
		if det:
			vals = [DetMath.sin(x), DetMath.cos(x), DetMath.tan(x), DetMath.atan2(x, LIBM_ATAN_X),
				DetMath.exp(x * LIBM_EXP_SCALE), DetMath.log(ax + LIBM_LOG_BIAS),
				DetMath.pow(ax + LIBM_LOG_BIAS, LIBM_POW), sqrt(ax),
				DetMath.asin(clampf(x / absf(LIBM_FROM), -1.0, 1.0)), DetMath.atan(x)]
		for j in vals.size():
			hs[j] = TraceHash.mix_float(hs[j], vals[j])
			bits.encode_double(0, vals[j])
			masked[j] = TraceHash.mix_int(masked[j], bits.decode_s64(0) & mask)
			chunk[j] = TraceHash.mix_float(chunk[j], vals[j])
			if (i + 1) % LIBM_CHUNK == 0:
				chunks[j] += "%02x" % (chunk[j] & 0xFF)
				chunk[j] = TraceHash.SEED
	var parts := PackedStringArray()
	for j in names.size():
		parts.append("%s=%s" % [names[j], HEX32 % hs[j]])
	for j in names.size():
		parts.append("%s_masked=%s" % [names[j], HEX32 % masked[j]])
	for j in names.size():
		parts.append("%s_chunks=%s" % [names[j], chunks[j]])
	return "%s %s n=%d chunk=%d %s" % [PREFIX, "detmath" if det else "libm", LIBM_COUNT, LIBM_CHUNK, " ".join(parts)]


func _h(h: int) -> String:
	return HEX32 % (h & 0xFFFFFFFF)


## A float's exact bits (hex) and its value.
func _f(x: float) -> String:
	_bits.encode_double(0, x)
	var b := _bits.decode_s64(0)
	return "%s%s(%.9f)" % [HEX32 % ((b >> 32) & 0xFFFFFFFF), HEX32 % (b & 0xFFFFFFFF), x]
