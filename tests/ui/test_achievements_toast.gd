extends WBTest
## WP8.3: the achievement unlock toast (HudAchievementLayer + HudAchievementToast). It
## appears in the frame of the unlock (inside the emit), with a light haptic tick when the
## haptics setting allows; it fades in, holds and hides after toast_s of real time (slow
## motion does not stretch it), then draws nothing and stops processing; unlocks in one
## frame queue; it sits clear of the thumb areas, the middle third, the safe edges and
## every HUD readout in every control layout, hand, text size and canvas; every title fits.
## Spec: Garage and progression (Achievements); UI → Screens (toasts never pause play);
## HUD layout (plan D14); Accessibility. docs/ACHIEVEMENTS.md → Toast.

const HapticsScript := preload("res://src/platform/haptics.gd")
const CANVASES: Array[Vector2] = [Vector2(1280.0, 720.0), Vector2(1560.0, 720.0)]
const NOTCH := Vector4(44.0, 0.0, 44.0, 21.0)
const TOL := 0.5

var svc: AchievementService
var at: AchievementTuning
var t: Tuning
var hap: HapticsScript
var probe := HudTextProbe.new()
var _saved: Dictionary
var _haptics_setting: bool
var _time_scale: float


func before_all() -> void:
	at = AchievementTuning.load_default()
	t = Tuning.load_default()


func before_each() -> void:
	Settings.reset_to_defaults()
	_saved = Save.data.duplicate(true)
	for k: String in [AchievementService.SECTION, Garage.SECTION_STATS, Garage.SECTION_UNLOCKS]:
		Save.data.erase(k)
	Save.section(Garage.SECTION_STATS)[MetaProfile.BACKFILLED] = true
	hap = tree.root.get_node(^"Haptics") as HapticsScript
	_haptics_setting = bool(Settings.get_value(&"haptics"))
	Settings.set_value(&"haptics", true)
	hap.reset()
	_time_scale = Engine.time_scale
	svc = _service()


func after_each() -> void:
	HudDraw.probe = null
	Engine.time_scale = _time_scale
	if svc != null and is_instance_valid(svc):
		svc.free()
	svc = null
	hap.reset()
	Settings.set_value(&"haptics", _haptics_setting)
	Save.data = _saved
	Save.dirty = false
	Settings.reset_to_defaults()


func _service() -> AchievementService:
	var s := AchievementService.new()
	s.run_under_tools = true
	s.platform = PlatformLeaderboards.recorder()
	tree.root.add_child(s)
	s.toast.set_screen(Rect2(Vector2.ZERO, CANVASES[0]), Rect2(Vector2.ZERO, CANVASES[0]))
	return s


func _coast() -> void:
	Events.run_started.emit(&"journey", 1)
	Events.coast_reached.emit()


# ---------------------------------------------------------------- Timing

func test_appears_in_the_frame_of_the_unlock() -> void:
	var layer := svc.toast
	eq(layer.visible_item_count(), 0, "nothing drawn before")
	check(not layer.is_processing(), "idle: not processing")
	Events.run_started.emit(&"journey", 1)
	var shown_at_unlock := [false]
	svc.unlocked.connect(func(_id: StringName) -> void: shown_at_unlock[0] = layer.showing(), CONNECT_ONE_SHOT)
	Events.scored.emit(Events.THREAD, 50, 5.0, 1.0)
	check(shown_at_unlock[0], "showing when the unlock is announced (same emit, same frame)")
	check(layer.widget.visible, "visible now")
	eq(layer.widget.title_text(), "NEEDLE", "the achievement's title")
	eq(layer.widget.header_text(), HudAchievementToast.HEADER, "the word says what happened")
	eq(layer.visible_item_count(), 1)
	check(layer.is_processing(), "animating")


func test_a_haptic_tick_if_the_setting_allows() -> void:
	var before := hap.pulse_count()
	_coast()
	eq(hap.pulse_count(), before + 1, "a tick with the unlock (coast_reached has no pulse of its own)")
	eq(hap.pulse_pattern(0), HapticsScript.Pattern.PASS, "the light tick")
	svc.free()
	for k: String in [AchievementService.SECTION]:
		Save.data.erase(k)
	Settings.set_value(&"haptics", false)
	hap.reset()
	svc = _service()
	_coast()
	check(svc.is_unlocked(&"coast"), "unlocked")
	eq(hap.pulse_count(), 0, "haptics off: no pulse")
	check(svc.toast.showing(), "the toast still shows")


func test_fades_then_hides_and_draws_nothing() -> void:
	var layer := svc.toast
	_coast()
	var w := layer.widget
	near(w.modulate.a, 0.0, 1e-6, "starts transparent")
	layer.advance(at.toast_in_s)
	near(w.modulate.a, 1.0, 1e-6, "in")
	layer.advance(at.toast_s - at.toast_in_s - at.toast_out_s * 0.5)
	check(w.modulate.a > 0.0 and w.modulate.a < 1.0, "fading out")
	check(layer.showing(), "still there")
	# The unlocks queued behind it (coast + clean journey arrive together).
	layer.advance(at.toast_out_s)
	check(layer.showing(), "the next one")
	eq(w.title_text(), "CLEAN JOURNEY")
	layer.advance(at.toast_s + 0.01)
	check(not layer.showing(), "gone")
	check(not w.visible, "hidden")
	eq(layer.visible_item_count(), 0, "draws nothing")
	check(not layer.is_processing(), "stops processing")
	var redraws := w.redraw_total()
	await tree.process_frame
	await tree.process_frame
	eq(w.redraw_total(), redraws, "no redraws while hidden")


func test_real_time_under_slow_motion() -> void:
	_coast()
	svc.toast.widget.dismiss()   # just the one
	svc.toast.show_unlock(svc.catalog.find(&"coast"))
	Engine.time_scale = 0.5
	svc.toast._process((at.toast_s + 0.01) * 0.5)   # the engine's scaled delta
	check(not svc.toast.showing(), "gone after toast_s of real time")


func test_a_burst_of_unlocks_queues_and_is_capped() -> void:
	var s := Save.section(Garage.SECTION_STATS)
	s[MetaProfile.THREADS] = 200
	s[MetaProfile.XP] = Progression.xp_to_reach(12, t.progression)
	s[MetaProfile.DAILY_BEST_STREAK] = 9
	Save.section(Garage.SECTION_UNLOCKS)["car/night_viper"] = 1
	Events.run_started.emit(&"daily", 1)   # quiet: the save had all that before
	check(not svc.toast.showing(), "quiet unlocks show no toast")
	Events.chain_banked.emit(60_000, Events.REASON_CHECKPOINT, 600_000)
	Events.multiplier_changed.emit(120.0)
	for i in 30:
		Events.scored.emit(Events.CLOSE_PASS, 30, 3.0, 0.1)
	var shown := 0
	var seen: Array[String] = []
	while svc.toast.showing() and shown < 20:
		seen.append(svc.toast.widget.title_text())
		shown += 1
		svc.toast.advance(at.toast_s + 0.01)
	eq(shown, 1 + at.toast_queue_max, "one on show and toast_queue_max waiting")
	check(seen.has("BIG BANK"), "in order of unlock: %s" % [seen])
	for id: StringName in [&"big_bank", &"half_million", &"multiplier_50", &"multiplier_100", &"close_passes_run", &"hairline"]:
		check(svc.is_unlocked(id), "%s is saved even if its toast was dropped" % id)


# ---------------------------------------------------------------- Place and fit

func _configs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for size in CANVASES:
		var full := Rect2(Vector2.ZERO, size)
		var safe := full
		if size.x > CANVASES[0].x:
			safe = Rect2(Vector2(NOTCH.x, NOTCH.y), size - Vector2(NOTCH.x + NOTCH.z, NOTCH.y + NOTCH.w))
		for ts in t.hud.text_scales:
			for left: bool in [false, true]:
				for throttle: StringName in [PlayerInput.AUTO, PlayerInput.MANUAL]:
					for cs in t.hud.settings_controls_scales:
						out.append({full = full, safe = safe, ts = ts, left = left, throttle = throttle, cs = cs,
								what = "%dx%d text %d%% %s %s controls %d%%" % [size.x, size.y, roundi(ts * 100.0),
								"left" if left else "right", throttle, roundi(cs * 100.0)]})
	return out


func test_clear_of_thumbs_middle_and_readouts() -> void:
	var layer := svc.toast
	var def := svc.catalog.find(&"hazards")
	for c in _configs():
		Settings.set_value(&"text_scale", float(c.ts))
		Settings.set_value(&"left_handed", bool(c.left))
		Settings.set_value(&"throttle_mode", c.throttle)
		Settings.set_value(&"controls_scale", float(c.cs))
		layer.widget.dismiss()
		layer.set_screen(c.full, c.safe)
		layer.show_unlock(def)
		var r := layer.toast_rect
		var lay := layer.layout
		var what: String = c.what
		check((c.safe as Rect2).grow(TOL).encloses(r), "%s: inside the safe area %s" % [what, r])
		check(not r.intersects(lay.middle_column()), "%s: out of the middle third" % what)
		check(HudAchievementLayer.clear_of_thumbs(lay, r, t.hud), "%s: clear of the thumb areas" % what)
		var names := HudLayout.names()
		var rects := lay.rects()
		for i in rects.size():
			check(not r.intersects(rects[i].grow(-TOL)), "%s: clear of the HUD's %s" % [what, names[i]])
		check(r.size.x >= t.hud.touch_target_px and r.size.y > 0.0, "%s: a real size %s" % [what, r.size])


func test_every_title_fits() -> void:
	var layer := svc.toast
	HudDraw.probe = probe
	for c in _configs():
		if c.left or c.throttle != PlayerInput.AUTO or c.cs != 1.0:
			continue
		Settings.set_value(&"text_scale", float(c.ts))
		layer.set_screen(c.full, c.safe)
		for def in svc.catalog.achievements:
			layer.widget.dismiss()
			layer.show_unlock(def)
			var w := layer.widget
			check(w.fits(), "%s: %s fits at full size in %s" % [c.what, def.title, w.size])
			probe.clear()
			w.queue_redraw()
			await tree.process_frame
			var drawn := 0
			for i in probe.size():
				if probe.items[i] != w:
					continue
				drawn += 1
				check(Rect2(Vector2.ZERO, w.size).grow(TOL).encloses(probe.rects[i]),
						"%s: '%s' inside the toast %s" % [c.what, probe.texts[i], probe.rects[i]])
			eq(drawn, 2, "%s: header and title drawn (%s)" % [c.what, def.title])
