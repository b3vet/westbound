class_name DailyTraceNode
extends Node
## The web build's side of the cross-platform determinism check (WP8.4; docs/DAILY.md →
## Determinism check): `?determinism=daily&date=YYYY-MM-DD&seconds=N[&detail=S][&view_m=M][&replay=1]`
## (Run._ready switches to this scene) runs DailyTrace's scripted Daily run a slice per
## frame and prints its lines to the console, ending with "DT done". The native side is
## tools/determinism/daily_trace.gd; tools/determinism/compare.sh runs both and diffs them.
## Also runs natively for a manual check: `--determinism=daily --date=... --seconds=...`
## after `--` on the command line, with this scene as the main scene.

var trace: DailyTrace
var finished: bool = false


func _ready() -> void:
	var t := DailyTuning.resolve()
	trace = DailyTrace.new(t)
	var kind := Run.boot_param(DailyTrace.BOOT_PARAM)
	if kind != "daily":
		print("%s error unknown determinism check '%s' (use daily)" % [DailyTrace.PREFIX, kind])
		finished = true
		return
	var date := Run.boot_param("date")
	if not DailyGhostStore.valid_date(date):
		date = DailyGhostStore.today_utc()
	var secs := Run.boot_param("seconds")
	var n := secs.to_int() if secs.is_valid_int() else roundi(t.check_seconds)
	var detail := Run.boot_param("detail")
	trace.detail_second = detail.to_int() if detail.is_valid_int() else 0
	var drv := Run.boot_param("driver")
	if not drv.is_empty():
		trace.driver_kind = StringName(drv)
	trace.record_replay = Run.boot_param("replay") == "1"
	var view := Run.boot_param("view_m")
	trace.start(self, date, n, view.to_float() if view.is_valid_float() else -1.0)
	_flush()


func _process(_delta: float) -> void:
	if finished:
		return
	finished = trace.step_ticks(trace.tuning.check_web_ticks_per_step)
	_flush()
	if finished:
		_show_done()


## The run is freed (the page stays light for the harness) and a note says it is done.
func _show_done() -> void:
	@warning_ignore("integer_division")
	var secs := trace.ticks_done / maxi(trace.tick_hz, 1)
	trace.finish()
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var label := Label.new()
	label.text = "DETERMINISM CHECK DONE\n%s · %d s · %s" % [trace.date, secs, trace.driver_kind]
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(label)


func _flush() -> void:
	for line in trace.take_lines():
		print(line)
