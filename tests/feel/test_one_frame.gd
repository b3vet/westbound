extends "res://tests/integration/run_harness.gd"
## WP7.5 One-frame check. Spec: Audio, haptics and game feel ("Every scoring event gets
## sound, haptics and a visual response within one frame"); plan WP7.5, Gate M7, D19
## (a cut plays the pass tick). docs/FEEL.md → One-frame check.
##
## How a frame is defined here (and in the game): one rendered frame is the physics
## ticks due, then Run._process → Run.frame(). frame() calls RunEvents.drain(), which
## emits every buffered record on `Events`; Godot runs every connected listener
## synchronously inside emit(), so GameAudio starts its voice, Haptics sends its pulse
## and the HUD / CameraRig / TimeScale change state before drain() returns. Nothing
## here depends on the order in which nodes' _process run: the Run is ticked by hand
## (manual_ticks), and the HUD, camera, haptics and audio are never advanced between
## the snapshot and the check.
##
## Each row of ROWS is one scoring event kind. Its producer drives a real Run until the
## record sits in the run's ScoreEventBuffer (the sim wrote it; the drain has not run),
## then the check settles every transient (so a response can't hide behind an earlier
## one), snapshots the listeners, calls frame() once and asserts, for that one call:
##   (a) the table's voices started (VoicePool's log; night: the music filter target),
##   (b) exactly the table's haptic patterns were sent (docs/FEEL.md table + D19),
##   (c) every listed visual changed (event stack, chain pulse, glitter, leg toast,
##       bank flyer, lives, boost meter, camera shake, slow motion).
## test_every_signal_is_classified fails when Events grows a signal nobody placed in
## the table or the not-a-scoring-event list, and test_every_score_kind_... pushes each
## ScoreEvents kind through the drain, so a new kind without a response fails loudly.

const HapticsScript := preload("res://src/platform/haptics.gd")
const SCORE_EVENTS_PATH := "res://src/scoring/score_events.gd"

const FAST_MPS := 45.0
const SLOW_MPS := 30.0
## Long enough for every transient (chain pulse, stack lines, toast, flyer, shake,
## punch, slow motion, the double tick's second pulse, the chime count-up) to end.
const SETTLE_S := 12.0
## The room clock's start for the loop row (test_run_loop.gd's: a day).
const LOOP_CLOCK_START := 1_789_998_720.0
## Glitter needs a high multiplier (hud.glitter_min_multiplier); the forced rows use this.
const HIGH_MULTIPLIER := 24.0
## The drain timing: this many events in one frame, repeated.
const BURST_EVENTS := 20
const BURST_REPEATS := 20
## A 60 fps frame is 16.7 ms. The listeners (audio aside) for 20 events stay far below it.
const DRAIN_BUDGET_MS := 4.0
## The same drain with audio (32 one-shot voices), mean over the repeats. One-shots are
## QOA WAVs (WP7.6): about 2 ms mean alone, 3 ms in the loaded full suite (OGG Vorbis
## one-shots took ~20 ms). The mean, not the worst: single repeats spike to ~6 ms under
## a loaded suite. 2x the loaded mean, still far below the OGG cost.
const AUDIO_DRAIN_MEAN_BUDGET_MS := 6.0
## Audio's share per started voice (OGG Vorbis: 0.55-0.65 ms; QOA WAV: ~0.06 ms).
const AUDIO_PER_VOICE_BUDGET_MS := 0.25

# Visual channels.
const V_STACK := &"stack"
const V_CHAIN := &"chain_pulse"
const V_GLITTER := &"glitter"
const V_TOAST := &"toast"
const V_FLYER := &"flyer"
const V_LIVES := &"lives"
const V_BOOST := &"boost"
const V_SHAKE := &"shake"
const V_SLOWMO := &"slowmo"
## The audio response of night: the Music bus low-pass and reverb fade in (no voice).
const A_MUSIC_NIGHT := &"music_night"

## Where the event is published: the drain in frame() (the normal path), or the tick
## (CrashSequence emits crash_started when the cinematic starts, in the fatal tick; the
## window is then that tick plus the frame() after it: still one rendered frame).
const IN_DRAIN := &"drain"
const IN_TICK := &"tick"

## Every Events signal that is not a scoring event, with why. A new signal must be put
## here or in ROWS (test_every_signal_is_classified).
const NOT_SCORING := {
	&"game_state_changed": "flow", &"paused_changed": "flow", &"run_started": "flow",
	&"countdown_tick": "flow (countdown screen)", &"run_over": "flow (results screen)",
	&"multiplier_changed": "a readout (HUD feed)", &"chain_changed": "a readout (HUD feed)",
	&"chain_lost": "part of a hit or HESITATED (their rows)",
	&"too_slow_changed": "a state readout (HUD TOO SLOW strip from the feed)",
	&"shoulder_penalty_changed": "a penalty state (HUD SHOULDER line)",
	&"boost_meter_changed": "a readout (HUD feed)", &"boost_ended": "the end of boost",
	&"ghost_started": "part of the first hit", &"ghost_ended": "a state",
	&"life_restored": "part of a clean crossing (its row)",
	&"barrier_scrape": "part of a barrier hit", &"crash_finished": "flow",
	&"dawn_started": "sky", &"morning_reached": "sky", &"sun_lifted": "sky",
	&"leg_started": "part of a crossing (its row)", &"checkpoint_warning": "a sign",
	&"objective_completed": "paid as bonus_awarded (bonus row)",
	&"fork_announced": "route", &"fork_taken": "route", &"coast_reached": "route",
	&"journey_complete": "route (banner)",
	&"set_piece_warning": "traffic", &"set_piece_started": "traffic", &"set_piece_ended": "traffic",
	&"traffic_horn": "traffic", &"traffic_brake_tap": "traffic", &"traffic_hazards": "traffic",
	&"gear_shifted": "car", &"hard_braking_changed": "car", &"high_beam_changed": "car",
	&"origin_shifted": "world", &"biome_changed": "world",
	&"slowmo_requested": "a feel request", &"camera_shake_requested": "a feel request",
	&"settings_changed": "platform", &"camera_mode_changed": "platform",
	&"quality_changed": "platform", &"governor_changed": "platform",
	&"thermal_state_changed": "platform",
}

var _haptics_setting: bool
var _hap: HapticsScript


## The table: one row per scoring event kind. audio = voice ids (or A_MUSIC_NIGHT),
## haptic = the exact patterns (HapticsScript.Pattern), visual = channels that must
## change, make = the producer, also_haptic = pulses another event of the same frame may
## add (a thread is paid in the frame of its second pass), flag = a spec gap flagged in the handoff (the row's
## audio / visual are then reported, not asserted).
static func rows() -> Array[Dictionary]:
	return [
		{id = &"pass", signals = [&"scored"], make = &"_make_pass", at = IN_DRAIN,
			audio = [AudioBank.STING_PASS, AudioBank.WHOOSH], haptic = [HapticsScript.Pattern.PASS], visual = [V_STACK, V_CHAIN]},
		{id = &"close_pass", signals = [&"scored"], make = &"_make_close_pass", at = IN_DRAIN,
			audio = [AudioBank.STING_CLOSE, AudioBank.WHOOSH, AudioBank.ZIP], haptic = [HapticsScript.Pattern.CLOSE],
			visual = [V_STACK, V_CHAIN, V_SHAKE]},
		{id = &"close_pass_high", signals = [&"scored"], make = &"_make_close_pass_high", at = IN_DRAIN,
			audio = [AudioBank.STING_CLOSE, AudioBank.WHOOSH, AudioBank.ZIP], haptic = [HapticsScript.Pattern.CLOSE],
			visual = [V_STACK, V_CHAIN, V_SHAKE, V_GLITTER]},
		{id = &"cut", signals = [&"scored"], make = &"_make_cut", at = IN_DRAIN,
			audio = [AudioBank.STING_CUT], haptic = [HapticsScript.Pattern.PASS], visual = [V_STACK, V_CHAIN]},
		{id = &"thread", signals = [&"scored"], make = &"_make_thread", at = IN_DRAIN,
			audio = [AudioBank.STING_THREAD, AudioBank.THUMP], haptic = [HapticsScript.Pattern.THREAD],
			visual = [V_STACK, V_CHAIN, V_SLOWMO], also_haptic = [HapticsScript.Pattern.PASS]},
		{id = &"slipstream", signals = [&"slipstream_changed"], make = &"_make_slipstream", at = IN_DRAIN,
			audio = [], haptic = [], visual = [],
			flag = "slipstream is in the spec's scoring-event table (no points, boost +20%/s) but nothing listens to slipstream_changed: no sound, no discrete visual (only the boost meter filling from the feed); it toggles with no hysteresis. Needs an orchestrator decision."},
		{id = &"bank_cash_out", signals = [&"chain_banked"], make = &"_make_cash_out", at = IN_DRAIN,
			audio = [AudioBank.CHIME_TICK], haptic = [HapticsScript.Pattern.BANK], visual = [V_STACK, V_FLYER]},
		{id = &"checkpoint", signals = [&"checkpoint_crossed", &"chain_banked", &"bonus_awarded"],
			make = &"_make_checkpoint", at = IN_DRAIN,
			audio = [AudioBank.CHIME_TICK, AudioBank.CHIME_BANK], haptic = [HapticsScript.Pattern.BANK], visual = [V_TOAST, V_FLYER]},
		{id = &"sector", signals = [&"checkpoint_crossed", &"chain_banked", &"bonus_awarded"],
			make = &"_make_sector", at = IN_DRAIN,
			audio = [AudioBank.CHIME_TICK, AudioBank.CHIME_BANK], haptic = [HapticsScript.Pattern.BANK], visual = [V_TOAST, V_FLYER]},
		{id = &"bonus", signals = [&"bonus_awarded"], make = &"_make_bonus", at = IN_DRAIN,
			audio = [AudioBank.CHIME_BANK], haptic = [], visual = [V_STACK]},
		{id = &"hesitated", signals = [&"hesitated"], make = &"_make_hesitated", at = IN_DRAIN,
			audio = [AudioBank.STING_HESITATED], haptic = [], visual = [V_STACK]},
		{id = &"hit", signals = [&"hit"], make = &"_make_hit", at = IN_DRAIN,
			audio = [AudioBank.HIT_IMPACT, AudioBank.STING_HIT], haptic = [HapticsScript.Pattern.HIT],
			visual = [V_LIVES, V_SHAKE, V_SLOWMO]},
		{id = &"crash", signals = [&"crash_started", &"hit"], make = &"_make_crash", at = IN_DRAIN,
			audio = [AudioBank.CRASH_METAL, AudioBank.CRASH_GLASS, AudioBank.HIT_IMPACT, AudioBank.STING_HIT],
			haptic = [HapticsScript.Pattern.CRASH], visual = [V_LIVES, V_SHAKE, V_SLOWMO]},
		{id = &"crash_cinematic", signals = [&"crash_started", &"hit"], make = &"_make_crash_cinematic", at = IN_TICK,
			audio = [AudioBank.CRASH_METAL, AudioBank.CRASH_GLASS, AudioBank.HIT_IMPACT, AudioBank.STING_HIT],
			haptic = [HapticsScript.Pattern.CRASH], visual = [V_LIVES, V_SHAKE, V_SLOWMO]},
		{id = &"boost", signals = [&"boost_started"], make = &"_make_boost", at = IN_DRAIN,
			audio = [AudioBank.BOOST], haptic = [], visual = [V_BOOST]},
		{id = &"night", signals = [&"night_started"], make = &"_make_night", at = IN_DRAIN,
			audio = [A_MUSIC_NIGHT], haptic = [], visual = [V_STACK]},
	]


## The haptics table (docs/FEEL.md, spec + D19): the only rows that pulse, and how.
const HAPTIC_TABLE := {
	&"pass": "light tick", &"close_pass": "medium tick", &"close_pass_high": "medium tick",
	&"cut": "light tick (D19)", &"thread": "heavy thump", &"bank_cash_out": "double light tick",
	&"checkpoint": "double light tick", &"sector": "double light tick", &"hit": "strong burst",
	&"crash": "long rumble", &"crash_cinematic": "long rumble",
}


func before_each() -> void:
	super.before_each()
	_haptics_setting = bool(Settings.get_value(&"haptics"))
	Settings.set_value(&"haptics", true)
	_hap = tree.root.get_node(^"Haptics") as HapticsScript
	_hap.reset()


func after_each() -> void:
	_hap.reset()
	Settings.set_value(&"haptics", _haptics_setting)
	await super.after_each()


# ---------------------------------------------------------------- The table

func test_every_signal_is_classified() -> void:
	var in_rows := {}
	for row in rows():
		for s: StringName in row.signals:
			in_rows[s] = true
	for sig: Dictionary in Events.get_script().get_script_signal_list():
		var n := StringName(sig.name)
		check(in_rows.has(n) or NOT_SCORING.has(n),
			"Events.%s is new: add a one-frame row (tests/feel/test_one_frame.gd ROWS) or list it in NOT_SCORING" % n)


func test_every_row_has_a_producer_and_a_response() -> void:
	for row in rows():
		check(has_method(row.make), "%s: producer %s" % [row.id, row.make])
		eq(not (row.haptic as Array).is_empty(), HAPTIC_TABLE.has(row.id),
			"%s: pulses exactly when the haptics table (docs/FEEL.md, D19) lists it" % row.id)
		if row.has("flag"):
			continue
		check(not (row.audio as Array).is_empty(), "%s: a sound" % row.id)
		check(not (row.visual as Array).is_empty(), "%s: a visual response" % row.id)


## Every ScoreEvents kind (a new one included) through the adapter's drain: a sound, a
## haptic (D19: every scored kind pulses) and an event-stack line in the same frame().
func test_every_score_kind_responds_in_the_drain() -> void:
	var r := _make()
	_go_quiet(r, FAST_MPS)
	_run_ticks(r, TICKS_PER_FRAME)
	for k: StringName in _score_kinds():
		_settle(r)
		var before := Snap.take(r, _hap)
		r.events.push(k, 100, HIGH_MULTIPLIER, 0.4)
		r.frame(FRAME_S)
		var after := Snap.take(r, _hap)
		gt(after.voices - before.voices, 0, "%s: a voice started in the frame" % k)
		gt(after.pulses - before.pulses, 0, "%s: a haptic pulse in the frame" % k)
		gt(after.pushes - before.pushes, 0, "%s: an event-stack line in the frame" % k)
		gt(after.chain - before.chain, 0, "%s: the chain pulses in the frame" % k)


# ---------------------------------------------------------------- One test per row

func test_pass() -> void:
	_check_row(&"pass")


func test_close_pass() -> void:
	_check_row(&"close_pass")


func test_close_pass_high_multiplier() -> void:
	_check_row(&"close_pass_high")


func test_cut() -> void:
	_check_row(&"cut")


func test_thread() -> void:
	_check_row(&"thread")


func test_slipstream() -> void:
	_check_row(&"slipstream")


func test_bank_cash_out() -> void:
	_check_row(&"bank_cash_out")


func test_checkpoint_crossing() -> void:
	_check_row(&"checkpoint")


func test_sector_crossing() -> void:
	_check_row(&"sector")


func test_bonus() -> void:
	_check_row(&"bonus")


func test_hesitated() -> void:
	_check_row(&"hesitated")


func test_hit() -> void:
	_check_row(&"hit")


func test_crash() -> void:
	_check_row(&"crash")


func test_crash_cinematic() -> void:
	_check_row(&"crash_cinematic")


func test_boost() -> void:
	_check_row(&"boost")


func test_night() -> void:
	_check_row(&"night")


## 20 scoring events drained in one frame: the one-frame guarantee must not hitch.
## Times the drain with every listener, then without GameAudio (taken out of the tree:
## its listeners disconnect), and the whole frame(). Prints the numbers. Budgets: the
## listeners without audio (worst), the drain with audio (mean) and audio's cost per
## voice. One-shots are WAV (QOA) since WP7.6: an OGG Vorbis one-shot built a decoder
## per play() (about 0.6 ms each here), a 20-event burst took ~20 ms (docs/FEEL.md →
## One-frame check → Cost, docs/AUDIO.md → Assets).
func test_drain_of_twenty_events_timing() -> void:
	var r := _make()
	_go_quiet(r, FAST_MPS)
	_run_ticks(r, TICKS_PER_FRAME * 4)
	var a := _audio(r)
	var with_audio := _time_bursts(r, a)
	var worst_frame := 0
	for rep in BURST_REPEATS:
		_settle(r)
		_push_burst(r)
		var t0 := Time.get_ticks_usec()
		r.frame(FRAME_S)
		worst_frame = maxi(worst_frame, Time.get_ticks_usec() - t0)
	r.remove_child(a)
	var no_audio := _time_bursts(r, null)
	r.add_child(a)
	var ms := 1.0 / 1000.0
	var voices := with_audio.z / float(BURST_REPEATS)
	var per_voice := (with_audio.y - no_audio.y) / float(BURST_REPEATS) / maxf(voices, 1.0)
	print(("    one-frame drain of %d events: worst %.2f ms (mean %.2f ms, %.0f voices started); " +
		"without audio worst %.3f ms (mean %.3f ms); audio %.2f ms per voice; whole frame() worst %.2f ms") % [
		BURST_EVENTS, with_audio.x * ms, with_audio.y * ms / BURST_REPEATS, voices,
		no_audio.x * ms, no_audio.y * ms / BURST_REPEATS, per_voice * ms, worst_frame * ms])
	lt(no_audio.x * ms, DRAIN_BUDGET_MS, "HUD, haptics, camera, slow motion: 20 events far inside a frame")
	lt(with_audio.y * ms / BURST_REPEATS, AUDIO_DRAIN_MEAN_BUDGET_MS, "with audio: 20 events inside a frame (mean)")
	lt(per_voice * ms, AUDIO_PER_VOICE_BUDGET_MS, "a one-shot voice starts without a decoder hitch")


## Drains BURST_REPEATS bursts: (worst us, total us, voices started in total).
func _time_bursts(r: Run, a: GameAudio) -> Vector3:
	var worst := 0
	var total := 0
	var voices := 0
	_settle(r)
	_push_burst(r)
	r.adapter.drain()   # warm-up (first-use costs: string tables, the sparks' first burst)
	for rep in BURST_REPEATS:
		_settle(r)
		_push_burst(r)
		var v0 := a.pool.played if a != null else 0
		var t0 := Time.get_ticks_usec()
		r.adapter.drain()
		var us := Time.get_ticks_usec() - t0
		ge(r.adapter.emitted_last, BURST_EVENTS, "all 20 published in one drain")
		if a != null:
			voices += a.pool.played - v0
		worst = maxi(worst, us)
		total += us
	if a != null:
		ge(voices, BURST_EVENTS * BURST_REPEATS, "every event sounded")
	return Vector3(worst, total, voices)


# ---------------------------------------------------------------- The check

func _row(id: StringName) -> Dictionary:
	for row in rows():
		if row.id == id:
			return row
	fail("no row %s" % id)
	return {}


func _check_row(id: StringName) -> void:
	var row := _row(id)
	if row.is_empty():
		return
	var r: Run = call(row.make)
	if r == null:
		return   # the producer reported why
	var sigs := {}
	for s: StringName in row.signals:
		sigs[s] = 0
		var sg: Signal = Events.get(s)
		_listen(sg, _counter(sigs, s))
	var pending := {}
	var drain_frame: bool = row.at == IN_DRAIN
	_settle(r)
	var before := Snap.take(r, _hap)
	if not drain_frame:
		r.tick()   # the fatal tick: the cinematic starts and emits crash_started here
	r.frame(FRAME_S)
	var after := Snap.take(r, _hap)
	for s: StringName in row.signals:
		if sigs[s] == 0:
			pending[s] = true
	check(pending.is_empty(), "%s: published in this frame: %s missing" % [id, pending.keys()])
	var started := after.voice_ids(before)
	var patterns := after.patterns(before)
	var changed := after.visuals(before)
	var note := "%s: voices %s, haptics %s, visuals %s" % [id, started, patterns, changed]
	# (b) exactly the defined haptic set (the order and repeats of pulses aside).
	var want_h: Array = row.haptic
	var also_h: Array = row.get("also_haptic", [])
	for p: int in want_h:
		check(patterns.has(p), "%s: haptic %s sent in the frame (%s)" % [id, p, note])
	for p: int in patterns:
		check(want_h.has(p) or also_h.has(p), "%s: no haptic %s outside the table (%s)" % [id, p, note])
	if row.has("flag"):
		print("    FLAG %s: %s (%s)" % [id, row.flag, note])
		return
	# (a) the sounds.
	for a: StringName in row.audio:
		if a == A_MUSIC_NIGHT:
			check(after.night > before.night, "%s: the music night filter started (%s)" % [id, note])
		else:
			check(started.has(a), "%s: voice %s started in the frame (%s)" % [id, a, note])
	# (c) the visuals.
	for v: StringName in row.visual:
		check(changed.has(v), "%s: visual %s changed in the frame (%s)" % [id, v, note])


func _counter(sigs: Dictionary, s: StringName) -> Callable:
	# Signals of any arity: count the emission.
	var argc := 0
	for sig: Dictionary in Events.get_script().get_script_signal_list():
		if StringName(sig.name) == s:
			argc = (sig.args as Array).size()
	var bump := func() -> void: sigs[s] = int(sigs[s]) + 1
	match argc:
		0:
			return bump
		1:
			return func(_a: Variant) -> void: bump.call()
		2:
			return func(_a: Variant, _b: Variant) -> void: bump.call()
		3:
			return func(_a: Variant, _b: Variant, _c: Variant) -> void: bump.call()
	return func(_a: Variant, _b: Variant, _c: Variant, _d: Variant) -> void: bump.call()


## Ends every transient so each response of the next frame shows as a change: HUD
## animations, the camera's shake and punch, a pending double tick and a playing pulse,
## the chime count-up and the playing voices, slow motion.
func _settle(r: Run) -> void:
	(r.hud as Hud).advance(SETTLE_S)
	r.rig.advance(SETTLE_S)
	_hap.advance_real(SETTLE_S)
	var a := r.get_node_or_null(^"GameAudio") as GameAudio
	if a != null:
		a.step(SETTLE_S)
		a.pool.stop_all()
	r.time_scale.restore()


static func _audio(r: Run) -> GameAudio:
	return r.get_node(^"GameAudio") as GameAudio


## The score kinds: ScoreEvents' constants that are not bank / loss reasons.
static func _score_kinds() -> Array[StringName]:
	var out: Array[StringName] = []
	var consts: Dictionary = (load(SCORE_EVENTS_PATH) as Script).get_script_constant_map()
	for k: String in consts:
		if not k.begins_with("REASON_"):
			out.append(consts[k] as StringName)
	return out


## What the listeners show at one moment.
class Snap:
	var voices: int
	var night: float
	var pulses: int
	var pushes: int
	var chain: int
	var glitter: int
	var toast: bool
	var flyer: bool
	var breaking: bool
	var burning: bool
	var shake: float
	var slowmo: int
	var _pool: VoicePool
	var _hap: HapticsScript

	static func take(r: Run, hap: HapticsScript) -> Snap:
		var s := Snap.new()
		var a := r.get_node(^"GameAudio") as GameAudio
		var hud := r.hud as Hud
		s._pool = a.pool
		s._hap = hap
		s.voices = a.pool.log_count
		s.night = a.music.night_target
		s.pulses = hap.sent_count
		s.pushes = hud.event_pushes()
		s.chain = hud.chain_pulses()
		s.glitter = hud.glitter_alive()
		s.toast = hud.toast_visible()
		s.flyer = hud.bank_flying()
		s.breaking = hud.life_breaking()
		s.burning = hud.boost_burning()
		s.shake = r.rig.shake_amplitude()
		s.slowmo = r.time_scale.applied_count
		return s

	## Voice ids started since `b`.
	func voice_ids(b: Snap) -> Array[StringName]:
		var out: Array[StringName] = []
		for back in mini(voices - b.voices, VoicePool.LOG_SIZE):
			out.append(_pool.last_id(back))
		return out

	## Haptic patterns sent since `b`.
	func patterns(b: Snap) -> Array[int]:
		var out: Array[int] = []
		for back in mini(pulses - b.pulses, HapticsScript.LOG_CAPACITY):
			out.append(_hap.pulse_pattern(back))
		return out

	func visuals(b: Snap) -> Array[StringName]:
		var out: Array[StringName] = []
		if pushes > b.pushes:
			out.append(V_STACK)
		if chain > b.chain:
			out.append(V_CHAIN)
		if glitter > b.glitter:
			out.append(V_GLITTER)
		if toast and not b.toast:
			out.append(V_TOAST)
		if flyer and not b.flyer:
			out.append(V_FLYER)
		if breaking and not b.breaking:
			out.append(V_LIVES)
		if burning and not b.burning:
			out.append(V_BOOST)
		if shake > b.shake:
			out.append(V_SHAKE)
		if slowmo > b.slowmo:
			out.append(V_SLOWMO)
		return out


# ---------------------------------------------------------------- Producers
# Each drives a real run until the event's record is in the run's buffer (written by
# the sim this tick, not yet drained), or (IN_TICK) until the next tick produces it.
# Returns the run, or null after a failed check.

## Ticks until one of `kinds` is in the run's event buffer (frames in between, as the
## game renders them). The tick that wrote it gets no frame yet.
func _tick_until_buffered(r: Run, kinds: Array[StringName], max_s: float, what: String) -> Run:
	for i in _ticks_for(max_s):
		r.tick()
		for j in r.events.size():
			if kinds.has(r.events.kind[j]):
				return r
		if r.tick_count % TICKS_PER_FRAME == 0:
			r.frame(FRAME_S)
	fail("%s: never buffered within %s s" % [what, max_s])
	return null


func _make_pass() -> Run:
	var r := _make()
	var drv := _go_quiet(r)
	drv.v_target = FAST_MPS
	drv.target_d = _lane_d(r, 1)
	_spawn(r, 40.0, 0, SLOW_MPS)
	return _tick_until_buffered(r, [ScoreEvents.PASS], 6.0, "pass")


func _make_close_pass() -> Run:
	var r := _make()
	var drv := _go_quiet(r)
	drv.v_target = FAST_MPS
	drv.target_d = _d_for_clearance(r, _lane_d(r, 0), 0.6, 1.0)
	_spawn(r, 60.0, 0, SLOW_MPS)
	return _tick_until_buffered(r, [ScoreEvents.CLOSE_PASS], 6.0, "close pass")


## The sim's own close pass, its record then raised to a multiplier over the glitter
## threshold (a run needs minutes of chaining to get there).
func _make_close_pass_high() -> Run:
	var r := _make_close_pass()
	if r == null:
		return null
	for j in r.events.size():
		if r.events.kind[j] == ScoreEvents.CLOSE_PASS:
			r.events.multiplier[j] = HIGH_MULTIPLIER
	ge(HIGH_MULTIPLIER, t.hud.glitter_min_multiplier, "over the glitter threshold")
	return r


func _make_cut() -> Run:
	var r := _make()
	var v := Units.kmh_to_mps(155.0)
	var drv := _go_quiet(r, v)
	_spawn(r, 13.0, 1, v)
	_run_ticks(r, TICKS_PER_FRAME * 10)
	drv.target_d = _lane_d(r, 2)
	return _tick_until_buffered(r, [ScoreEvents.CUT], 3.0, "cut")


func _make_thread() -> Run:
	var r := _make()
	var drv := _go_quiet(r)
	drv.v_target = FAST_MPS
	drv.target_d = _lane_d(r, 1)
	var left_d := _d_for_clearance(r, _lane_d(r, 1), 1.2, -1.0) - _lane_d(r, 0)
	var right_d := _d_for_clearance(r, _lane_d(r, 1), 1.2, 1.0) - _lane_d(r, 2)
	_spawn(r, 60.0, 0, SLOW_MPS, left_d)
	_spawn(r, 60.0, 2, SLOW_MPS, right_d)
	return _tick_until_buffered(r, [ScoreEvents.THREAD], 6.0, "thread")


func _make_slipstream() -> Run:
	var r := _make()
	var v := Units.kmh_to_mps(135.0)
	_go_quiet(r, v)
	_spawn(r, 12.0, 1, v)
	return _tick_until_buffered(r, [ScoringRuleSet.KIND_SLIPSTREAM], 1.0, "slipstream")


func _make_cash_out() -> Run:
	var r := _make()
	var drv := _go_quiet(r)
	drv.v_target = FAST_MPS
	drv.target_d = _lane_d(r, 1)
	_spawn(r, 40.0, 0, SLOW_MPS)
	check(_run_until(r, func() -> bool: return r.scoring.chain() > 0, 6.0), "a chain")
	return _tick_until_buffered(r, [ScoringRuleSet.KIND_BANKED], 8.0, "cash-out bank")


## A chain, then to just before the checkpoint (test_scoring_loop's scenario).
func _make_checkpoint() -> Run:
	var r := _make()
	var v := Units.kmh_to_mps(220.0)
	_go_quiet(r, v)
	_spawn(r, 25.0, 0, SLOW_MPS)
	check(_run_until(r, func() -> bool: return r.scoring.chain() > 0, 3.0), "a chain")
	var cp := r.legs.distance_to_checkpoint(r.car.state.s)
	r.dev_teleport(r.car.state.s + cp - 15.0, v)
	return _tick_until_buffered(r, [LegTracker.KIND_CHECKPOINT_CROSSED], 2.0, "checkpoint")


## Loop mode (N3.2): a chain, then through a sector gantry.
func _make_sector() -> Run:
	var r := RUN_SCENE.instantiate() as Run
	r.run_seed = SEED
	r.manual_ticks = true
	r.crash_cinematic = false
	r.record_best = false
	r.mode = Run.MODE_LOOP
	r.loop = RunLoop.new()
	r.loop.clock_start_unix_s = LOOP_CLOCK_START
	_run = r
	tree.root.add_child(r)
	_runs.append(r)
	var v := Units.kmh_to_mps(220.0)
	var lr := r.road as LoopRoadPath
	var gantry := lr.length() + lr.layout.sector_s[1]
	r.dev_teleport(gantry - 600.0, v)
	r.legs.skip_to(gantry - 600.0)
	_go_quiet(r, v)
	_spawn(r, 25.0, 0, SLOW_MPS)
	check(_run_until(r, func() -> bool: return r.scoring.chain() > 0, 3.0), "a chain")
	r.dev_teleport(gantry - 15.0, v)
	return _tick_until_buffered(r, [LegTracker.KIND_CHECKPOINT_CROSSED], 8.0, "sector gantry")


## A leg bonus paid the way the run pays one (Scoring.award_bonus into the run's buffer).
func _make_bonus() -> Run:
	var r := _make()
	_go_quiet(r, FAST_MPS)
	_run_ticks(r, TICKS_PER_FRAME * 4)
	r.scoring.award_bonus(LegTracker.BONUS_CLEAN, t.legs.bonus_clean_points, r.events)
	return r


func _make_hesitated() -> Run:
	var r := _make()
	var drv := _go_quiet(r)
	drv.v_target = FAST_MPS
	drv.target_d = _lane_d(r, 1)
	_spawn(r, 30.0, 0, SLOW_MPS)
	check(_run_until(r, func() -> bool: return r.scoring.chain() > 0, 5.0), "a chain")
	drv.v_target = Units.kmh_to_mps(80.0)
	return _tick_until_buffered(r, [ScoringRuleSet.KIND_HESITATED], 9.0, "hesitated")


func _make_hit() -> Run:
	var r := _make()
	_go_quiet(r, FAST_MPS)
	_run_ticks(r, TICKS_PER_FRAME * 4)
	r.force_hit()
	return _tick_until_buffered(r, [Lives.KIND_HIT], 0.1, "first hit")


## The second hit without the cinematic: the fallback emits crash_started in frame().
func _make_crash() -> Run:
	var r := _make()
	_go_quiet(r, FAST_MPS)
	_run_ticks(r, TICKS_PER_FRAME * 4)
	r.force_hit()
	_run_ticks(r, TICKS_PER_FRAME)
	check(_run_until(r, func() -> bool: return not r.lives.is_ghost(), 4.0), "the ghost ended")
	r.force_hit()
	var out := _tick_until_buffered(r, [Lives.KIND_HIT], 0.1, "the fatal hit")
	if out != null:
		eq(r.state, Game.CRASH, "the run crashed")
	return out


## The second hit with the Jolt cinematic: the next tick starts it (crash_started).
func _make_crash_cinematic() -> Run:
	var r := _make(SEED, true)
	_go_quiet(r, FAST_MPS)
	_run_ticks(r, TICKS_PER_FRAME * 4)
	r.force_hit()
	_run_ticks(r, TICKS_PER_FRAME)
	check(_run_until(r, func() -> bool: return not r.lives.is_ghost(), 4.0), "the ghost ended")
	_run_ticks(r, TICKS_PER_FRAME)
	r.force_hit()
	return r


func _make_boost() -> Run:
	var r := _make()
	var drv := _go_quiet(r, FAST_MPS)
	_run_ticks(r, TICKS_PER_FRAME * 4)
	r.car.state.boost_meter = 1.0
	drv.request_boost()
	for i in TICKS_PER_FRAME * 4:
		r.tick()
		if r.car.state.boost_active:
			return r
	fail("boost never started")
	return null


func _make_night() -> Run:
	var r := _make()
	_go_quiet(r, FAST_MPS)
	_run_ticks(r, TICKS_PER_FRAME * 4)
	r.sun.sky_t = t.sun.sky_t_sunset - 1e-5
	return _tick_until_buffered(r, [SunClock.KIND_NIGHT_STARTED], 1.0, "night")


# ---------------------------------------------------------------- The burst

## 20 records in the buffer as the sims write them: 8 passes, 4 close passes, 2 cuts,
## 2 threads, a bank, a bonus, HESITATED and a hit with a life left.
func _push_burst(r: Run) -> void:
	var b := r.events
	for i in 8:
		b.push(ScoreEvents.PASS, 120, HIGH_MULTIPLIER, 2.0)
	for i in 4:
		b.push(ScoreEvents.CLOSE_PASS, 400, HIGH_MULTIPLIER, 0.5)
	for i in 2:
		b.push(ScoreEvents.CUT, 150, HIGH_MULTIPLIER, -1.0)
	for i in 2:
		b.push(ScoreEvents.THREAD, 900, HIGH_MULTIPLIER, 0.8)
	b.push(ScoringRuleSet.KIND_BANKED, 5000, 1.0, -1.0, -1, 5000.0, ScoreEvents.REASON_CASH_OUT)
	b.push(ScoringRuleSet.KIND_BONUS, 2000, 0.0, -1.0, -1, 7000.0, LegTracker.BONUS_CLEAN)
	b.push(ScoringRuleSet.KIND_HESITATED)
	b.push(Lives.KIND_HIT, 0, 0.0, -1.0, -1, 1.0, HitDetection.HIT_BARRIER)

