extends Node
## Haptics service (requested autoload `Haptics`). Spec: Audio, haptics and game feel →
## Haptics (`platform/haptics.gd`, toggle in settings):
##   pass: light tick; close pass: medium tick; thread: heavy thump; banking: double
##   light tick; hit: strong burst, 150 ms; crash: long rumble, 400 ms.
## A cut (a scoring event the table does not list) gets the pass tick, so every scoring
## event has a haptic (spec: "every scoring event gets sound, haptics and a visual
## response within one frame"; WP7.5).
##
## A listener only (Architecture rule 8): Events.scored (pass / close_pass / cut /
## thread), chain_banked, hit (lives left > 0; the run-ending hit is the crash's rumble)
## and crash_started. Settings `haptics` off: nothing is sent. Every duration and
## amplitude is in FeelTuning's Haptics group (data/tuning/feel.tres).
##
## Backends:
##   - native (Android, iOS): Input.vibrate_handheld(ms, amplitude). Android: a one-shot
##     VibrationEffect with the amplitude (API 26+; VIBRATE is in the export
##     permissions); iOS: Core Haptics, a continuous event of that intensity and length
##     (iPhone 8 and later; older devices play the fixed system buzz, so ticks would be
##     long there).
##   - web: navigator.vibrate(ms) through JavaScriptBridge (duration only). Browsers
##     without it (iOS Safari) are detected once and skipped silently; calls wait for the
##     page's first user activation so Chrome logs no "blocked" intervention.
##   - none (desktop, headless) and record (tests: pulses go to a fixed-size log).
##
## Overlap: a pulse never cuts a stronger one that is still playing (Android and the
## web cancel the running vibration on a new call). The double tick's second pulse is
## a countdown advanced in _process with real time: no timers or other objects per
## event.

enum Backend { NONE, NATIVE, WEB, RECORD }
enum Pattern { PASS, CLOSE, THREAD, BANK, HIT, CRASH }

## Priority per Pattern (a pulse is dropped while a higher one plays).
const PRIORITY: Array[int] = [0, 1, 2, 1, 3, 4]
## Recorded pulses kept for tests and the dev HUD (a ring).
const LOG_CAPACITY := 32
const MS_PER_S := 1000.0   # lint: allow-number unit conversion

var feel: FeelTuning
var backend: Backend = Backend.NONE
## Settings `haptics` (kept in sync on Events.settings_changed).
var enabled: bool = true

## Pulses sent (or recorded) and pulses dropped (setting off, a stronger one playing).
var sent_count: int = 0
var dropped_count: int = 0

var _log_pattern := PackedInt32Array()
var _log_ms := PackedInt32Array()
var _log_amp := PackedFloat32Array()
var _clock_ms: float = 0.0
var _busy_until_ms: float = 0.0
var _busy_priority: int = -1
## The double tick's second pulse: ms until it fires (< 0: none pending).
var _second_in_ms: float = -1.0
var _web_nav: JavaScriptObject
var _web_activation: JavaScriptObject
var _web_active: bool = false


func _init() -> void:
	_log_pattern.resize(LOG_CAPACITY)
	_log_ms.resize(LOG_CAPACITY)
	_log_amp.resize(LOG_CAPACITY)
	process_mode = Node.PROCESS_MODE_ALWAYS
	if OS.has_feature("web"):
		backend = Backend.WEB
	elif OS.has_feature("mobile"):
		backend = Backend.NATIVE


func _enter_tree() -> void:
	if feel == null:
		feel = Tuning.load_default().feel
	enabled = bool(Settings.get_value(&"haptics"))
	if backend == Backend.WEB:
		_init_web()
	_connect(Events.scored, _on_scored)
	_connect(Events.chain_banked, _on_chain_banked)
	_connect(Events.hit, _on_hit)
	_connect(Events.crash_started, _on_crash_started)
	_connect(Events.settings_changed, _on_settings_changed)


func _exit_tree() -> void:
	_disconnect(Events.scored, _on_scored)
	_disconnect(Events.chain_banked, _on_chain_banked)
	_disconnect(Events.hit, _on_hit)
	_disconnect(Events.crash_started, _on_crash_started)
	_disconnect(Events.settings_changed, _on_settings_changed)


func _process(delta: float) -> void:
	# The double tick counts real time, also in slow motion.
	advance_real(delta / Engine.time_scale if Engine.time_scale > 0.0 else delta)


## Advances the service's clock by `real_dt` seconds (tests call it directly).
func advance_real(real_dt: float) -> void:
	_clock_ms += real_dt * MS_PER_S
	if _second_in_ms >= 0.0:
		_second_in_ms -= real_dt * MS_PER_S
		if _second_in_ms <= 0.0:
			_second_in_ms = -1.0
			_pulse(Pattern.BANK, feel.haptic_bank_ms, feel.haptic_bank_amp)


## Plays `pattern` (the event handlers call this; the dev HUD may too).
func play(pattern: Pattern) -> void:
	if not enabled:
		dropped_count += 1
		return
	var f := feel
	match pattern:
		Pattern.PASS:
			_pulse(pattern, f.haptic_pass_ms, f.haptic_pass_amp)
		Pattern.CLOSE:
			_pulse(pattern, f.haptic_close_ms, f.haptic_close_amp)
		Pattern.THREAD:
			_pulse(pattern, f.haptic_thread_ms, f.haptic_thread_amp)
		Pattern.BANK:
			if _pulse(pattern, f.haptic_bank_ms, f.haptic_bank_amp):
				_second_in_ms = f.haptic_bank_gap_ms
		Pattern.HIT:
			_second_in_ms = -1.0
			_pulse(pattern, f.haptic_hit_ms, f.haptic_hit_amp)
		Pattern.CRASH:
			_second_in_ms = -1.0
			_pulse(pattern, f.haptic_crash_ms, f.haptic_crash_amp)


## Recorded pulses in the log (at most LOG_CAPACITY back).
func pulse_count() -> int:
	return sent_count


## The `back`-th most recent pulse (0 = the last): pattern, duration (ms), amplitude.
func pulse_pattern(back: int = 0) -> int:
	return _log_pattern[_log_index(back)]


func pulse_ms(back: int = 0) -> int:
	return _log_ms[_log_index(back)]


func pulse_amp(back: int = 0) -> float:
	return _log_amp[_log_index(back)]


## True while the double tick's second pulse is pending.
func is_second_pending() -> bool:
	return _second_in_ms >= 0.0


## Forgets the log, counters and any pending pulse (tests).
func reset() -> void:
	sent_count = 0
	dropped_count = 0
	_busy_until_ms = 0.0
	_busy_priority = -1
	_second_in_ms = -1.0


func _pulse(pattern: Pattern, duration_ms: float, amplitude: float) -> bool:
	var prio := PRIORITY[pattern]
	if _clock_ms < _busy_until_ms and prio < _busy_priority:
		dropped_count += 1
		return false
	var ms := roundi(maxf(duration_ms, feel.haptic_min_ms))
	var amp := clampf(amplitude, 0.0, 1.0)
	_busy_until_ms = _clock_ms + float(ms)
	_busy_priority = prio
	var i := sent_count % LOG_CAPACITY
	_log_pattern[i] = pattern
	_log_ms[i] = ms
	_log_amp[i] = amp
	sent_count += 1
	match backend:
		Backend.NATIVE:
			Input.vibrate_handheld(ms, amp)
		Backend.WEB:
			_web_vibrate(ms)
	return true


func _log_index(back: int) -> int:
	return posmod(sent_count - 1 - back, LOG_CAPACITY)


func _init_web() -> void:
	# typeof strings: they come back as Strings on every browser (booleans may not).
	if str(JavaScriptBridge.eval("typeof navigator.vibrate", true)) != "function":
		backend = Backend.NONE   # iOS Safari: no Vibration API, degrade silently
		return
	_web_nav = JavaScriptBridge.get_interface("navigator")
	if str(JavaScriptBridge.eval("typeof navigator.userActivation", true)) == "object":
		_web_activation = _web_nav.get(&"userActivation") as JavaScriptObject
	else:
		_web_active = true   # no way to ask: try, the browser ignores it before a tap


func _web_vibrate(ms: int) -> void:
	if _web_nav == null:
		return
	if not _web_active:
		# Sticky activation (the first tap): until then Chrome blocks and logs the call.
		if _web_activation == null or not bool(_web_activation.get(&"hasBeenActive")):
			return
		_web_active = true
	_web_nav.call(&"vibrate", ms)


func _on_scored(kind: StringName, _points: int, _multiplier: float, _clearance_m: float) -> void:
	match kind:
		Events.PASS, Events.CUT:
			play(Pattern.PASS)
		Events.CLOSE_PASS:
			play(Pattern.CLOSE)
		Events.THREAD:
			play(Pattern.THREAD)


func _on_chain_banked(amount: int, _reason: StringName, _banked_total: int) -> void:
	if amount > 0:
		play(Pattern.BANK)


func _on_hit(_source: StringName, lives_left: int) -> void:
	if lives_left > 0:
		play(Pattern.HIT)


func _on_crash_started() -> void:
	play(Pattern.CRASH)


func _on_settings_changed(key: StringName) -> void:
	if key == &"haptics":
		enabled = bool(Settings.get_value(&"haptics"))
		if not enabled:
			_second_in_ms = -1.0


static func _connect(sig: Signal, fn: Callable) -> void:
	if not sig.is_connected(fn):
		sig.connect(fn)


static func _disconnect(sig: Signal, fn: Callable) -> void:
	if sig.is_connected(fn):
		sig.disconnect(fn)
