extends WBTest
## Haptics (src/platform/haptics.gd). Spec: Audio, haptics and game feel → Haptics:
## pass light tick, close pass medium tick, thread heavy thump, banking double light
## tick, hit strong burst 150 ms, crash long rumble 400 ms; toggle in settings.
## The record backend stands in for the device (no real vibration headless).

const HapticsScript := preload("res://src/platform/haptics.gd")

var _h: HapticsScript
var _feel: FeelTuning
var _haptics_setting: bool


func before_each() -> void:
	_haptics_setting = bool(Settings.get_value(&"haptics"))
	Settings.set_value(&"haptics", true)
	_feel = Tuning.load_default().feel
	_h = HapticsScript.new()
	_h.backend = HapticsScript.Backend.RECORD
	tree.root.add_child(_h)


func after_each() -> void:
	_h.queue_free()
	await tree.process_frame
	Settings.set_value(&"haptics", _haptics_setting)


## Lets any stronger pulse finish so the next one is not dropped.
func _idle() -> void:
	_h.advance_real(1.0)


func _last(pattern: int, ms: float, amp: float, message: String) -> void:
	eq(_h.pulse_pattern(), pattern, message + ": pattern")
	eq(_h.pulse_ms(), roundi(ms), message + ": duration")
	near(_h.pulse_amp(), amp, 1e-6, message + ": amplitude")


func test_spec_durations() -> void:
	near(_feel.haptic_hit_ms, 150.0, 1e-9, "hit: strong burst, 150 ms")
	near(_feel.haptic_crash_ms, 400.0, 1e-9, "crash: long rumble, 400 ms")
	lt(_feel.haptic_pass_ms, _feel.haptic_close_ms, "light tick shorter than the medium tick")
	lt(_feel.haptic_close_ms, _feel.haptic_thread_ms, "medium tick shorter than the heavy thump")
	lt(_feel.haptic_pass_amp, _feel.haptic_close_amp, "light < medium")
	le(_feel.haptic_close_amp, _feel.haptic_thread_amp, "medium <= heavy")
	lt(_feel.haptic_thread_ms, _feel.haptic_hit_ms, "a thump is shorter than a hit burst")
	lt(_feel.haptic_hit_ms, _feel.haptic_crash_ms)


func test_every_pattern_fires_for_its_event() -> void:
	var f := _feel
	Events.scored.emit(Events.PASS, 10, 1.0, 1.5)
	_last(HapticsScript.Pattern.PASS, f.haptic_pass_ms, f.haptic_pass_amp, "pass")
	_idle()
	Events.scored.emit(Events.CLOSE_PASS, 30, 2.0, 0.4)
	_last(HapticsScript.Pattern.CLOSE, f.haptic_close_ms, f.haptic_close_amp, "close pass")
	_idle()
	Events.scored.emit(Events.THREAD, 60, 3.0, 0.3)
	_last(HapticsScript.Pattern.THREAD, f.haptic_thread_ms, f.haptic_thread_amp, "thread")
	_idle()
	Events.scored.emit(Events.CUT, 20, 3.0, 0.8)
	_last(HapticsScript.Pattern.PASS, f.haptic_pass_ms, f.haptic_pass_amp, "cut: the pass tick (every scoring event)")
	_idle()
	Events.hit.emit(Events.HIT_TRAFFIC, 1)
	_last(HapticsScript.Pattern.HIT, 150.0, f.haptic_hit_amp, "hit")
	_idle()
	Events.crash_started.emit()
	_last(HapticsScript.Pattern.CRASH, 400.0, f.haptic_crash_amp, "crash")
	eq(_h.pulse_count(), 6)


func test_banking_is_a_double_light_tick() -> void:
	var f := _feel
	Events.chain_banked.emit(1200, Events.REASON_CHECKPOINT, 5000)
	eq(_h.pulse_count(), 1, "first tick now")
	_last(HapticsScript.Pattern.BANK, f.haptic_bank_ms, f.haptic_bank_amp, "bank tick 1")
	check(_h.is_second_pending())
	_h.advance_real((f.haptic_bank_gap_ms - 1.0) / 1000.0)
	eq(_h.pulse_count(), 1, "second tick waits for the gap")
	_h.advance_real(2.0 / 1000.0)
	eq(_h.pulse_count(), 2, "second tick after the gap")
	_last(HapticsScript.Pattern.BANK, f.haptic_bank_ms, f.haptic_bank_amp, "bank tick 2")
	check(not _h.is_second_pending())
	le(f.haptic_bank_ms, f.haptic_pass_ms, "light ticks")
	gt(f.haptic_bank_gap_ms, f.haptic_bank_ms, "two distinct pulses")
	_idle()
	Events.chain_banked.emit(0, Events.REASON_CHECKPOINT, 5000)
	eq(_h.pulse_count(), 2, "nothing banked: no tick")


func test_run_ending_hit_is_the_crash_rumble_only() -> void:
	Events.hit.emit(Events.HIT_BARRIER, 0)
	eq(_h.pulse_count(), 0, "the second hit leaves it to the crash")
	Events.crash_started.emit()
	eq(_h.pulse_count(), 1)
	eq(_h.pulse_pattern(), HapticsScript.Pattern.CRASH)


func test_setting_disables_every_pattern() -> void:
	Settings.set_value(&"haptics", false)
	Events.scored.emit(Events.PASS, 10, 1.0, 1.5)
	Events.scored.emit(Events.CLOSE_PASS, 30, 2.0, 0.4)
	Events.scored.emit(Events.THREAD, 60, 3.0, 0.3)
	Events.chain_banked.emit(1200, Events.REASON_CASH_OUT, 5000)
	Events.hit.emit(Events.HIT_TRAFFIC, 1)
	Events.crash_started.emit()
	_h.advance_real(1.0)
	eq(_h.pulse_count(), 0, "haptics off: nothing sent")
	eq(_h.dropped_count, 6)
	Settings.set_value(&"haptics", true)
	Events.scored.emit(Events.PASS, 10, 1.0, 1.5)
	eq(_h.pulse_count(), 1, "back on")


func test_turning_off_cancels_a_pending_second_tick() -> void:
	Events.chain_banked.emit(500, Events.REASON_CASH_OUT, 500)
	check(_h.is_second_pending())
	Settings.set_value(&"haptics", false)
	_h.advance_real(1.0)
	eq(_h.pulse_count(), 1)


func test_a_tick_never_cuts_a_stronger_pulse() -> void:
	Events.hit.emit(Events.HIT_TRAFFIC, 1)
	Events.scored.emit(Events.PASS, 10, 1.0, 1.5)
	eq(_h.pulse_count(), 1, "a pass during the hit burst is dropped")
	eq(_h.pulse_pattern(), HapticsScript.Pattern.HIT)
	_h.advance_real((_feel.haptic_hit_ms + 1.0) / 1000.0)
	Events.scored.emit(Events.PASS, 10, 1.0, 1.5)
	eq(_h.pulse_count(), 2, "after the burst it plays")
	Events.crash_started.emit()
	eq(_h.pulse_pattern(), HapticsScript.Pattern.CRASH, "a stronger one cuts in")


func test_a_hit_cancels_the_pending_bank_tick() -> void:
	Events.chain_banked.emit(500, Events.REASON_CASH_OUT, 500)
	Events.hit.emit(Events.HIT_TRAFFIC, 1)
	check(not _h.is_second_pending())
	_h.advance_real(1.0)
	eq(_h.pulse_count(), 2)
	eq(_h.pulse_pattern(), HapticsScript.Pattern.HIT)


func test_minimum_pulse_length() -> void:
	var f := _feel.duplicate() as FeelTuning
	f.haptic_pass_ms = 2.0
	_h.feel = f
	Events.scored.emit(Events.PASS, 10, 1.0, 1.5)
	eq(_h.pulse_ms(), roundi(f.haptic_min_ms), "clamped up to the device minimum")


func test_no_allocation_per_event() -> void:
	# Warm up every path once, then count objects over many events.
	for k: StringName in [Events.PASS, Events.CLOSE_PASS, Events.THREAD]:
		Events.scored.emit(k, 10, 1.0, 1.0)
		_idle()
	Events.chain_banked.emit(10, Events.REASON_CASH_OUT, 10)
	_idle()
	var before := Performance.get_monitor(Performance.OBJECT_COUNT)
	for i in 200:
		Events.scored.emit(Events.PASS, 10, 1.0, 1.0)
		Events.chain_banked.emit(10, Events.REASON_CASH_OUT, 10)
		_h.advance_real(0.2)
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), before, "no objects (timers) per event")
	gt(_h.pulse_count(), 200)


func test_desktop_and_headless_send_nothing_to_a_device() -> void:
	var h := HapticsScript.new()
	eq(h.backend, HapticsScript.Backend.NONE, "headless: no device backend")
	h.free()
