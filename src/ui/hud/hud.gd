class_name Hud
extends CanvasLayer
## The gameplay HUD. Spec: UI, HUD and design system (layout, HUD elements, safe
## areas, update rule, accessibility text size); Scoring → Score feedback, Multiplier,
## Chain and banking, Boost; Sky timeline and sun clock → HUD; Core loop → Legs and
## checkpoints (warning signs, the leg summary toast, the leg objective), Night.
## CONTRACTS §14. docs/HUD.md.
##
##   hud.bind(feed)                  # the run's HudFeed; null = unbound (draws nothing new)
##   hud.bind_loop(loop_feed)        # N3.2 loop mode: the room clock and sectors (null = off)
##   hud.pause_pressed / camera_pressed / high_beam_pressed
##
## Reads the per-frame values from the HudFeed and listens to `Events` for the
## animations (event stack, banking fly-in and count-up, life icons, glitter). Never
## writes gameplay state. Labels change only when their shown value changes; idle,
## nothing redraws. Every piece but the buttons ignores touches.
##
## High beams (plan D8, WP5.5): a headlamp button under [CAM] emits high_beam_pressed
## (the run toggles PlayerInput.toggle_high_beam()); it lights gold while
## Events.high_beam_changed says the beams are on. It shows only while the headlights
## matter: the SkyRig's headlight ramp at or above hud.high_beam_min_ramp (where
## traffic turns its headlights on: late golden hour, dusk, night, dawn), fading in and
## out (modulate only), hidden (no draw call) by day. Its slot is always reserved, so
## the cluster never moves.
##
## Layout: HudLayout, from the canvas, the display safe area and the touch controls'
## rects (the PlayerInput hub's ControlsLayout when there is one, else one built from
## Settings), rebuilt when the controls layout, the viewport or a setting changes.
## Plan D14: speed, the minimum-speed strip and boost sit in a bottom-centre cluster
## under the car, and no readout goes into the thumb zones (the lower outer corners).

signal pause_pressed()
signal camera_pressed()
## The high-beam button (plan D8): the run toggles the hub's high beams.
signal high_beam_pressed()

const GROUP := &"wb_hud"
const TILT_SHADER := preload("res://src/ui/theme/speed_tilt.gdshader")

## Event words (Accessibility: every event has its own word).
const WORD_PASS := "PASS"
const WORD_CLOSE := "CLOSE!"
const WORD_CUT := "CUT"
const WORD_THREAD := "THREAD!"
const WORD_HESITATED := "HESITATED"
const WORD_BANKED := "BANKED"
const WORD_CHAIN_LOST := "CHAIN LOST"
const WORD_SHOULDER := "SHOULDER"
const WORD_NIGHT := "NIGHT"
const WORD_LIFE := "LIFE RESTORED"
const WORD_DAWN := "DAWN"
const WORD_MORNING := "MORNING"
const WORD_CHECKPOINT := "CHECKPOINT"
const WORD_OBJECTIVE := "OBJECTIVE"
## WP6.5: the JOURNEY COMPLETE banner's subtitle ("THE COAST · JOURNEY BONUS +50,000").
const JOURNEY_SUB := "%s  ·  JOURNEY BONUS +%s"
const JOURNEY_BIOME := &"coast"
const UNIT_KM := "KM"
const UNIT_M := "M"
const UNIT_MI := "MI"
const BIOME_PATH := "res://data/biomes/%s.tres"
const NIGHT_POINTS := "×2"
const PLUS := "+"
const MINUS := "-"

const SET_UNITS := &"units"
const SET_TEXT_SCALE := &"text_scale"
const UNITS_MPH := &"mph"
## Settings that move the touch controls (the HUD re-places around them).
const CONTROL_SETTINGS: Array[StringName] = [&"steering_mode", &"throttle_mode", &"left_handed",
		&"controls_scale"]

## false: the owner calls advance(dt) itself (tests).
@export var auto_process: bool = true

var feed: HudFeed
## N3.2: the loop test mode's values (null or inactive: the journey HUD). The sun bar
## becomes the room clock with the distance to the next sector, the leg toast names
## sectors and laps.
var loop_feed: HudLoopFeed
var tuning: HudTuning
var style := HudStyle.new()
var layout := HudLayout.new()

var _theme: Theme
var _boost_bonus: float = 0.0
var _hub: PlayerInput
var _sky: SkyRig
var _own_controls := ControlsLayout.new()
var _layout_version: int = -1
var _pinned: bool = false
var _pinned_full: Rect2 = Rect2()
var _pinned_safe: Rect2 = Rect2()
var _text_scale: float = 1.0
var _miles: bool = false
var _accent_rgba: int = 0
var _max_lives: int = 2
var _legs: LegsTuning

# High-beam button: the headlight ramp (from the SkyRig, or pinned) and the fade.
var _ramp_pinned: bool = false
var _pinned_ramp: float = 0.0
var _hb_alpha: float = 0.0

# Leg objective chip: its label is built only when the leg, id or units change.
var _obj_leg: int = -1
var _obj_id: StringName = &""
var _obj_miles: bool = false
var _obj_text: String = ""
# Leg toast: the crossing's events arrive in one frame after checkpoint_crossed; they
# fill the toast (not the stack) until the next advance().
var _toast_collect: bool = false
var _toast_objective_pts: int = 0
var _toast_life: bool = false

# Banking count-up.
var _counted: bool = false
var _banked_target: int = 0
var _count_from: float = 0.0
var _count_to: int = 0
var _count_t: float = -1.0
var _count_delay: float = 0.0

@onready var _root: Control = $Root
@onready var _score: HudScore = $Root/Score
@onready var _sun: HudSunBar = $Root/Sun
@onready var _chain: HudChain = $Root/Chain
@onready var _mult: HudMultiplier = $Root/Multiplier
@onready var _stack: HudEventStack = $Root/Stack
@onready var _lives: HudLives = $Root/Lives
@onready var _pause: HudButton = $Root/Pause
@onready var _camera: HudButton = $Root/Camera
@onready var _high_beam: HudButton = $Root/HighBeam
@onready var _min_speed: HudMinSpeed = $Root/MinSpeed
@onready var _speedo: HudSpeedo = $Root/Speedo
@onready var _boost: HudBoost = $Root/Boost
@onready var _flyer: HudFlyer = $Root/Flyer
@onready var _glitter: HudGlitter = $Root/Glitter
@onready var _objective: HudObjective = $Root/Objective
@onready var _toast: HudLegToast = $Root/LegToast
## WP6.5: made in _ready (no scene change needed).
var _journey := HudJourneyToast.new()
var _journey_bonus: int = 0
## N6.2 (rooms): points added to every banked total shown (the official score's eased
## correction, NetScoreClient.display_offset()); 0 outside rooms.
var _score_offset: int = 0
var _widgets: Array[HudWidget] = []


func _ready() -> void:
	add_to_group(GROUP)
	var t := Tuning.load_default()
	tuning = t.hud
	_boost_bonus = Units.pct_to_frac(t.vehicle.boost_top_speed_bonus_pct)
	_max_lives = t.lives.lives
	_legs = t.legs
	_theme = UiTheme.load_theme()
	_root.theme = _theme
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_journey.name = "JourneyToast"
	_journey.visible = false
	_root.add_child(_journey)
	_widgets = [_score, _sun, _chain, _mult, _stack, _lives, _min_speed, _speedo, _boost, _flyer, _glitter,
			_objective, _toast, _journey]
	for w: HudWidget in [_chain, _mult, _stack, _flyer]:
		w.use_tilt(TILT_SHADER, tuning.speed_tilt_rad())
	_pause.glyph = HudButton.Glyph.PAUSE
	_camera.glyph = HudButton.Glyph.CAMERA
	_high_beam.glyph = HudButton.Glyph.HIGH_BEAM
	_pause.pressed.connect(pause_pressed.emit)
	_camera.pressed.connect(camera_pressed.emit)
	_high_beam.pressed.connect(high_beam_pressed.emit)
	_high_beam.visible = false
	_read_settings()
	_restyle()
	_connect_events(true)
	get_viewport().size_changed.connect(_relayout)
	_flyer.visible = false
	_glitter.visible = false
	_stack.visible = false
	_min_speed.visible = false
	_objective.visible = false
	_toast.visible = false
	_set_chain_row_visible(false)
	_relayout()
	_poll_accent()
	if feed != null:
		_read_feed()


func _exit_tree() -> void:
	_connect_events(false)


func _process(delta: float) -> void:
	if auto_process:
		advance(delta)


# ---------------------------------------------------------------- Public API

## The run's feed (CONTRACTS §14). null unbinds: the HUD keeps what it shows.
func bind(f: HudFeed) -> void:
	feed = f
	_counted = false
	if f != null:
		_max_lives = f.max_lives
		if is_node_ready():
			_read_feed()


## N3.2: the loop mode's feed (null: the journey HUD again).
func bind_loop(f: HudLoopFeed) -> void:
	loop_feed = f
	if is_node_ready() and feed != null:
		_read_feed()


## Pins the canvas and safe rects (tests, previews); otherwise the viewport and the
## display safe area are used.
func set_screen(full: Rect2, safe: Rect2) -> void:
	_pinned = true
	_pinned_full = full
	_pinned_safe = safe
	if is_node_ready():
		_relayout()


## The design system's accent ("the sky's neon"). Redraws only on an 8-bit change.
func set_accent(color: Color) -> void:
	var rgba := color.to_rgba32()
	if rgba == _accent_rgba:
		return
	_accent_rgba = rgba
	style.accent = color
	for w in _widgets:
		w.accent_changed()
	_pause.queue_redraw()
	_camera.queue_redraw()
	_high_beam.queue_redraw()


## One frame: poll the layout inputs, read the feed, run the animations.
func advance(dt: float) -> void:
	_poll_layout()
	_poll_accent()
	if feed != null:
		_read_feed()
	_animate(dt)
	_animate_high_beam(dt)


## Pins the headlight ramp the high-beam button follows (previews, tests); otherwise it
## is read from the SkyRig. NAN unpins.
func set_headlight_ramp(ramp: float) -> void:
	_ramp_pinned = not is_nan(ramp)
	_pinned_ramp = ramp


## N6.2 (rooms): the official score's correction, added to the banked total shown. A
## lower value shows at once (the caller eases it down), a higher one counts up.
func set_score_offset(points: int) -> void:
	_score_offset = points


## N6.2 (rooms): a line on the event stack from outside the run's events (TRAIN ×n, an
## official sector bonus).
func push_event(word: String, value: String, role: HudEventStack.Role) -> void:
	_stack.push(word, value, role)


## The high-beam button is showing (fully or fading).
func high_beam_visible() -> bool:
	return _high_beam.visible


func high_beam_lit() -> bool:
	return _high_beam.lit


## Its opacity (0 hidden .. 1 shown).
func high_beam_alpha() -> float:
	return _hb_alpha


## Ends the high-beam button's fade at once (previews that freeze a state).
func settle_high_beam() -> void:
	_animate_high_beam(maxf(tuning.high_beam_fade_s, EPS))


## Shown-value changes across the HUD (tests: labels change only on change).
func change_count() -> int:
	var n := 0
	for w in _widgets:
		n += w.changes
	return n


## _draw calls across the HUD (tests: nothing redraws when idle).
func redraw_count() -> int:
	var n := 0
	for w in _widgets:
		n += w.redraw_total()
	return n


## Canvas items that draw this frame (visible widgets and buttons).
func visible_item_count() -> int:
	var n := 0
	for w in _widgets:
		if w.is_visible_in_tree():
			n += 1
	for b: HudButton in [_pause, _camera, _high_beam]:
		if b.is_visible_in_tree():
			n += 1
	return n


func displayed_banked() -> int:
	return _score.shown_banked()


func counting_up() -> bool:
	return _count_t >= 0.0


func multiplier_text() -> String:
	return _mult.multiplier_text()


func chain_text() -> String:
	return _chain.chain_text()


func speed_text() -> String:
	return _speedo.speed_text()


func event_line_count() -> int:
	return _stack.line_count()


func event_line(i: int) -> String:
	return _stack.line_text(i)


func min_speed_visible() -> bool:
	return _min_speed.visible


func too_slow_shown() -> bool:
	return _min_speed.too_slow_shown()


func lives_shown() -> int:
	return _lives.lives_shown()


func life_breaking() -> bool:
	return _lives.breaking()


func life_restoring() -> bool:
	return _lives.restoring()


func ghost_shown() -> bool:
	return _lives.ghost_shown()


func glitter_alive() -> int:
	return _glitter.alive()


func boost_lit() -> int:
	return _boost.lit_segments()


## WP7.5 one-frame check read-outs: the boost meter shows BOOSTING, the chain pulses
## started, the event stack's pushes, and the banked chain flying to the total.
func boost_burning() -> bool:
	return _boost.pulsing()


func chain_pulses() -> int:
	return _chain.pulses


func event_pushes() -> int:
	return _stack.changes


func bank_flying() -> bool:
	return _flyer.flying()


## N3.2: the top-centre plate shows the room clock (loop mode), and its countdown.
func clock_shown() -> bool:
	return _sun.is_clock()


func clock_text() -> String:
	return _sun.clock_text()


func checkpoint_text() -> String:
	return _sun.checkpoint_text()


## The leg objective chip (WP5.2): shown, its text ("5 CLOSE PASSES"), progress ("3/5"),
## caption ("LEG 2 OBJECTIVE") and state (HudObjective.State).
func objective_visible() -> bool:
	return _objective.visible


func objective_text() -> String:
	return _objective.objective_text() if _objective.visible else ""


func objective_progress_text() -> String:
	return _objective.progress_text()


func objective_caption() -> String:
	return _objective.caption_text()


func objective_state() -> HudObjective.State:
	return _objective.state()


## The chip's rect now (canvas) and whether its text is at full size (WP5.6).
func objective_rect() -> Rect2:
	return Rect2(_objective.position, _objective.size)


func objective_text_fits() -> bool:
	return _objective.fits_text()


## The leg toast (WP5.2): showing, and its lines (title, banked, items, next leg).
func toast_visible() -> bool:
	return _toast.visible


## WP6.5: the JOURNEY COMPLETE banner is showing, and its lines.
func journey_toast_visible() -> bool:
	return _journey.visible


func journey_toast_lines() -> PackedStringArray:
	return PackedStringArray([_journey.title_text(), _journey.subtitle_text()]) if _journey.visible \
		else PackedStringArray()


func journey_toast_rect() -> Rect2:
	return Rect2(_journey.position, _journey.size)


func toast_lines() -> PackedStringArray:
	return _toast.lines() if _toast.visible else PackedStringArray()


func toast_items_shown() -> int:
	return _toast.items_shown()


## The toast's footer as drawn: the next leg and its objective ("" if it did not fit).
func toast_footer() -> PackedStringArray:
	return _toast.footer() if _toast.visible else PackedStringArray()


## The rects the HUD occupies now (canvas), keyed like HudLayout.names().
func occupied_rects() -> Array[Rect2]:
	return layout.rects()


# ---------------------------------------------------------------- Feed

func _read_feed() -> void:
	var f := feed
	var t := tuning
	var top := maxf(f.top_speed_mps, EPS) * (1.0 + _boost_bonus)
	_speedo.set_units(_miles)
	_speedo.set_speed(HudFormat.speed_value(f.speed_mps, _miles), absf(f.speed_mps) / top,
			1.0 / (1.0 + _boost_bonus))
	_speedo.set_flags(f.too_slow, f.boosting)
	var show_bar := f.min_speed_mps > 0.0 and HudMinSpeed.should_show(t, Units.mps_to_kmh(absf(f.speed_mps)),
			f.too_slow, _min_speed.visible)
	if show_bar != _min_speed.visible:
		_min_speed.visible = show_bar
	if show_bar:
		_min_speed.set_state(absf(f.speed_mps) / maxf(f.min_speed_mps, EPS), f.too_slow,
				HudFormat.speed_value(f.min_speed_mps, _miles))
	_boost.set_fill(f.boost_fill, f.boosting)
	if loop_feed != null and loop_feed.active:
		var lf := loop_feed
		_toast.loop_sectors = lf.sectors
		_sun.set_clock(true, lf.cycle_frac, lf.day_frac, lf.flip_in_s)
		_sun.set_phase(lf.night, false)
		_sun.set_checkpoint(lf.sector_distance_m, _miles)
	else:
		_toast.loop_sectors = 0
		_sun.set_clock(false, 0.0, 1.0, 0.0)
		_sun.set_sun(f.sun_height)
		_sun.set_phase(f.night, f.dawning)
		_sun.set_checkpoint(f.checkpoint_distance_m, _miles)
	if not _lives.breaking() and not _lives.restoring():
		_lives.set_lives(f.lives, f.max_lives)
	_lives.set_ghost(f.ghost)
	_chain.set_chain(f.chain)
	_mult.set_multiplier(f.multiplier)
	_set_chain_row_visible(f.chain > 0 or f.multiplier >= 1.0 + MULT_SHOWN)
	_score.set_best(f.best)
	_feed_banked(f.banked + _score_offset)
	_read_objective(f)


func _read_objective(f: HudFeed) -> void:
	if f.objective != _obj_id or f.leg_index != _obj_leg or _miles != _obj_miles:
		_obj_id = f.objective
		_obj_leg = f.leg_index
		_obj_miles = _miles
		_obj_text = LegObjectives.label(f.objective, _legs, _miles) if f.objective != &"" else ""
	_objective.set_objective(f.leg_index, f.objective, _obj_text)
	if _objective.visible:
		_objective.set_progress(f.objective_progress, f.objective_target)
		_objective.set_state(f.objective_done, f.objective_failed)
		_fit_objective()


## The chip as wide as its content, inside its layout slot (WP5.6). Re-placed only when
## the width changes (a new objective, the progress appearing, FAILED).
func _fit_objective() -> void:
	var r := layout.objective_fit(_objective.content_width())
	if r.position != _objective.position or r.size != _objective.size:
		_place(_objective, r)


func _feed_banked(v: int) -> void:
	if not _counted or v < _banked_target:
		# First read after bind, or a new run: show it at once.
		_counted = true
		_banked_target = v
		_count_t = -1.0
		_score.set_banked(v)
		_score.set_counting(false)
	elif v > _banked_target:
		_start_count(v, _count_delay if _count_t >= 0.0 else 0.0)


func _start_count(target: int, delay: float) -> void:
	_counted = true
	_banked_target = target
	_count_from = float(_score.shown_banked()) if _score.shown_banked() >= 0 else 0.0
	_count_to = target
	_count_t = 0.0
	_count_delay = delay


func _set_chain_row_visible(on: bool) -> void:
	if _chain.visible != on:
		_chain.visible = on
		_mult.visible = on


# ---------------------------------------------------------------- Animation

func _animate(dt: float) -> void:
	_end_toast_collect()
	for w in _widgets:
		if w.visible:
			w.animate(dt)
	if _stack.muted:
		_stack.animate(dt)   # the toast holds its slot: lines age unseen
		if not _toast.showing() and not _journey.showing():
			_stack.muted = false
	if _count_t < 0.0:
		return
	if _count_delay > 0.0:
		_count_delay -= dt
		return
	_count_t += dt
	var k := clampf(_count_t / maxf(tuning.bank_count_s, EPS), 0.0, 1.0)
	var e := 1.0 - pow(1.0 - k, 3.0)
	_score.set_counting(k < 1.0)
	if k >= 1.0:
		_count_t = -1.0
		_score.set_banked(_count_to)
		return
	_score.set_banked(roundi(lerpf(_count_from, float(_count_to), e)))


# ---------------------------------------------------------------- Events

func _connect_events(on: bool) -> void:
	var pairs: Array[Array] = [
		[Events.scored, _on_scored],
		[Events.chain_banked, _on_chain_banked],
		[Events.chain_lost, _on_chain_lost],
		[Events.hesitated, _on_hesitated],
		[Events.bonus_awarded, _on_bonus],
		[Events.hit, _on_hit],
		[Events.life_restored, _on_life_restored],
		[Events.ghost_started, _on_ghost_started],
		[Events.ghost_ended, _on_ghost_ended],
		[Events.shoulder_penalty_changed, _on_shoulder],
		[Events.night_started, _on_night],
		[Events.gear_shifted, _on_gear],
		[Events.run_started, _on_run_started],
		[Events.checkpoint_warning, _on_checkpoint_warning],
		[Events.checkpoint_crossed, _on_checkpoint_crossed],
		[Events.leg_started, _on_leg_started],
		[Events.dawn_started, _on_dawn],
		[Events.morning_reached, _on_morning],
		[Events.settings_changed, _on_setting_changed],
		[Events.high_beam_changed, _on_high_beam_changed],
		[Events.journey_complete, _on_journey_complete],
		[Events.boost_started, _on_boost_started],
		[Events.boost_ended, _on_boost_ended],
	]
	for p in pairs:
		var sig: Signal = p[0]
		var cb: Callable = p[1]
		if on and not sig.is_connected(cb):
			sig.connect(cb)
		elif not on and sig.is_connected(cb):
			sig.disconnect(cb)


func _on_scored(kind: StringName, points: int, multiplier: float, _clearance_m: float) -> void:
	var word := WORD_PASS
	var role := HudEventStack.Role.TEXT
	match kind:
		Events.CLOSE_PASS:
			word = WORD_CLOSE
			role = HudEventStack.Role.ACCENT
		Events.CUT:
			word = WORD_CUT
		Events.THREAD:
			word = WORD_THREAD
			role = HudEventStack.Role.GOLD
	_stack.push(word, PLUS + HudFormat.thousands(points), role)
	_chain.pulse()
	if (kind == Events.CLOSE_PASS or kind == Events.THREAD) and multiplier >= tuning.glitter_min_multiplier:
		var c := _mult.global_position + Vector2(_mult.size.x * GLITTER_FROM_X, _mult.size.y * 0.5)
		_glitter.burst(c, tuning.glitter_count)


func _on_chain_banked(amount: int, reason: StringName, banked_total: int) -> void:
	var pts := PLUS + HudFormat.thousands(amount)
	if _toast_collect and reason == Events.REASON_CHECKPOINT:
		_toast.set_banked(pts)
	else:
		_stack.push(WORD_BANKED, pts, HudEventStack.Role.GOLD)
	_flyer.fly(pts, _chain.number_center(), _score.number_target() + Vector2(_flyer.size.x * 0.25, 0.0),
			tuning.bank_fly_s)
	if banked_total + _score_offset > _banked_target or not _counted:
		_start_count(banked_total + _score_offset, tuning.bank_fly_s)


func _on_chain_lost(amount: int, reason: StringName) -> void:
	if reason == Events.REASON_HESITATED or amount <= 0:
		return
	_stack.push(WORD_CHAIN_LOST, MINUS + HudFormat.thousands(amount), HudEventStack.Role.HOT)


func _on_hesitated() -> void:
	_stack.push(WORD_HESITATED, "", HudEventStack.Role.HOT)


func _on_bonus(kind: StringName, points: int, banked_total: int) -> void:
	if kind == Run.BONUS_JOURNEY:
		_journey_bonus = points
	var word := String(kind).to_upper().replace("_", " ")
	# The crossing's bonuses go to the toast (an objective bonus only if the summary says
	# this leg's objective was done: a new leg's one completing in the same frame is not).
	if _toast_collect and (kind != LegTracker.BONUS_OBJECTIVE or _toast_objective_pts > 0):
		if not _toast.has_item(word):
			_toast.add_item(word, PLUS + HudFormat.thousands(points), HudLegToast.Role.GOLD)
	else:
		_stack.push(word, PLUS + HudFormat.thousands(points), HudEventStack.Role.GOLD)
	if banked_total + _score_offset > _banked_target:
		_start_count(banked_total + _score_offset, 0.0)


func _on_hit(_source: StringName, lives_left: int) -> void:
	_lives.hit(lives_left)


func _on_life_restored(lives: int) -> void:
	_lives.restore(lives)
	if _toast_collect:
		_toast_life = true
	else:
		_stack.push(WORD_LIFE, "", HudEventStack.Role.GOLD)


func _on_ghost_started(_duration_s: float) -> void:
	_lives.set_ghost(true)


func _on_ghost_ended() -> void:
	_lives.set_ghost(false)


func _on_shoulder(active: bool) -> void:
	if active:
		_stack.push(WORD_SHOULDER, "", HudEventStack.Role.HOT)


func _on_night() -> void:
	_stack.push(WORD_NIGHT, NIGHT_POINTS, HudEventStack.Role.ACCENT)


func _on_dawn(_duration_s: float) -> void:
	_stack.push(WORD_DAWN, "", HudEventStack.Role.GOLD)


func _on_morning() -> void:
	_stack.push(WORD_MORNING, "", HudEventStack.Role.GOLD)


func _on_checkpoint_warning(distance_m: float) -> void:
	_stack.push(WORD_CHECKPOINT, _distance_text(distance_m), HudEventStack.Role.ACCENT)


## Step 5 of the crossing: the leg toast. The rest of the crossing (banked chain, leg
## bonuses, the objective at the line, the life, the next leg) follows in this frame.
func _on_checkpoint_crossed(leg_index: int, summary: Dictionary) -> void:
	_toast_collect = true
	_toast_life = false
	_toast_objective_pts = int(summary.get(RunEvents.SUMMARY_OBJECTIVE_POINTS, 0)) \
			if bool(summary.get(RunEvents.SUMMARY_OBJECTIVE_DONE, false)) else 0
	_toast.begin(leg_index)
	if bool(summary.get(RunEvents.SUMMARY_AT_NIGHT, false)):
		_toast.add_item(WORD_NIGHT, NIGHT_POINTS, HudLegToast.Role.ACCENT)
	_stack.muted = true


func _on_leg_started(leg_index: int, biome: StringName, objective: StringName) -> void:
	if not _toast_collect:
		return
	var text := LegObjectives.label(objective, _legs, _miles) if objective != &"" else ""
	_toast.set_next(leg_index, biome_name(biome), text)


## The crossing's events are in: an objective paid before the line is listed too, then
## the life.
func _end_toast_collect() -> void:
	if not _toast_collect:
		return
	_toast_collect = false
	if _toast_objective_pts > 0 and not _toast.has_item(WORD_OBJECTIVE):
		_toast.add_item(WORD_OBJECTIVE, PLUS + HudFormat.thousands(_toast_objective_pts), HudLegToast.Role.GOLD)
	if _toast_life:
		_toast.add_item(WORD_LIFE, "", HudLegToast.Role.GOLD)


## "1 KM", "500 M" ("0.6 MI", "0.3 MI" in miles).
func _distance_text(metres: float) -> String:
	if _miles:
		return "%s %s" % [HudFormat.tenths_text(HudFormat.distance_key(metres, true)), UNIT_MI]
	if metres >= Units.M_PER_KM:
		var key := HudFormat.distance_key(metres, false)
		if key % HudFormat.TENTHS == 0:
			return "%d %s" % [floori(float(key) / HudFormat.TENTHS), UNIT_KM]
		return "%s %s" % [HudFormat.tenths_text(key), UNIT_KM]
	return "%d %s" % [roundi(metres), UNIT_M]


## The biome's display name ("FARMLAND PLAINS"), else its id in capitals.
static func biome_name(id: StringName) -> String:
	if id == &"":
		return ""
	var path := BIOME_PATH % id
	if ResourceLoader.exists(path):
		var b := load(path) as BiomeDef
		if b != null and not b.display_name.is_empty():
			return b.display_name.to_upper()
	return String(id).to_upper().replace("_", " ")


func _on_high_beam_changed(on: bool) -> void:
	_high_beam.set_lit(on)


## Fades the high-beam button toward shown while the headlights are on (the color
## script's headlight ramp at or above hud.high_beam_min_ramp), hidden otherwise.
## Modulate only; nothing changes when it is settled.
func _animate_high_beam(dt: float) -> void:
	var ramp := _pinned_ramp
	if not _ramp_pinned:
		ramp = _sky.current().emissive_headlight if _sky != null and is_instance_valid(_sky) else 0.0
	var want := 1.0 if is_finite(ramp) and ramp >= tuning.high_beam_min_ramp else 0.0
	if _hb_alpha == want:
		return
	var step := dt / maxf(tuning.high_beam_fade_s, EPS)
	_hb_alpha = minf(_hb_alpha + step, want) if want > _hb_alpha else maxf(_hb_alpha - step, want)
	_high_beam.modulate.a = _hb_alpha
	_high_beam.visible = _hb_alpha > 0.0


## The boost meter turns gold in the frame boost starts (WP7.5's one-frame rule), not
## when the HUD next reads the feed; the feed then keeps it in step.
func _on_boost_started() -> void:
	_boost.set_boosting(true)


func _on_boost_ended() -> void:
	_boost.set_boosting(false)


func _on_gear(gear: int) -> void:
	_speedo.set_gear(gear)


## WP6.5: the celebratory banner (non-blocking; the road goes on).
func _on_journey_complete() -> void:
	var place := biome_name(JOURNEY_BIOME)
	var sub := JOURNEY_SUB % [place.to_upper(), HudFormat.thousands(_journey_bonus)] if _journey_bonus > 0 \
		else place.to_upper()
	_journey.show_complete(sub)
	_stack.muted = true


func _on_run_started(_mode: StringName, _seed: int) -> void:
	_journey.dismiss()
	_journey_bonus = 0
	_stack.clear()
	_stack.muted = false
	_toast_collect = false
	_toast.dismiss()
	_counted = false
	_count_t = -1.0
	_speedo.set_gear(0)


func _on_setting_changed(key: StringName) -> void:
	if key == SET_UNITS or key == SET_TEXT_SCALE:
		var old_ts := _text_scale
		_read_settings()
		if _text_scale != old_ts:
			_restyle()
		_relayout()
		if feed != null:
			_read_feed()
	elif key in CONTROL_SETTINGS and _hub == null:
		_relayout()


# ---------------------------------------------------------------- Layout and style

func _read_settings() -> void:
	_miles = StringName(_setting(SET_UNITS, &"kmh")) == UNITS_MPH
	_text_scale = tuning.clamp_text_scale(float(_setting(SET_TEXT_SCALE, 1.0)))


func _restyle() -> void:
	style.setup(_theme, tuning, _text_scale)
	for w in _widgets:
		w.setup(style)
	_pause.setup(style)
	_camera.setup(style)
	_high_beam.setup(style)


func _poll_layout() -> void:
	if _hub == null or not is_instance_valid(_hub):
		_hub = get_tree().get_first_node_in_group(PlayerInput.GROUP) as PlayerInput
		if _hub != null:
			_layout_version = -1
			_high_beam.set_lit(_hub.high_beam)
	if _hub != null and _hub.layout_version != _layout_version:
		_relayout()


func _poll_accent() -> void:
	if _sky == null or not is_instance_valid(_sky):
		_sky = get_tree().get_first_node_in_group(SkyRig.GROUP) as SkyRig
		if _sky == null:
			if _accent_rgba == 0:
				set_accent(_theme.get_color(UiTheme.C_ACCENT, UiTheme.TYPE))
			return
		_sky.accent_changed.connect(set_accent)
		set_accent(_sky.get_accent())


func _relayout() -> void:
	var full := _pinned_full if _pinned else _root.get_viewport_rect()
	var safe := _pinned_safe if _pinned else HudLayout.canvas_safe_rect(full)
	var controls := _controls_layout(full, safe)
	if _hub != null:
		_layout_version = _hub.layout_version
	layout.build(tuning, full, safe, controls, _text_scale, _max_lives)
	_place(_score, layout.score)
	_place(_sun, layout.sun)
	var half := tuning.spacing_grid_px * 0.5
	var cx := layout.chain.get_center().x
	_place(_chain, Rect2(layout.chain.position, Vector2(cx - half - layout.chain.position.x, layout.chain.size.y)))
	_place(_mult, Rect2(Vector2(cx + half, layout.chain.position.y),
			Vector2(layout.chain.end.x - cx - half, layout.chain.size.y)))
	_place(_stack, layout.stack)
	_place(_lives, layout.lives)
	_place(_pause, layout.pause)
	_place(_camera, layout.camera)
	_place(_high_beam, layout.high_beam)
	_place(_min_speed, layout.min_speed)
	_place(_speedo, layout.speedo)
	_place(_boost, layout.boost)
	_fit_objective()
	_place(_toast, layout.toast)
	_place(_journey, layout.journey)
	_flyer.size = Vector2(layout.chain.size.x * 0.5, layout.chain.size.y)
	_place(_glitter, full)


func _controls_layout(full: Rect2, safe: Rect2) -> ControlsLayout:
	if _hub != null:
		return _hub.layout
	var c := Tuning.load_default().controls
	var px_per_cm := PlayerInput.canvas_px_per_cm(c, full.size, DisplayServer.window_get_size())
	var size_scale := clampf(float(_setting(&"controls_scale", 1.0)), c.controls_scale_min_factor,
			c.controls_scale_max_factor)
	_own_controls.build(c, full, safe, px_per_cm, StringName(_setting(&"steering_mode", PlayerInput.DRAG)),
			StringName(_setting(&"throttle_mode", PlayerInput.AUTO)), bool(_setting(&"left_handed", false)), size_scale)
	return _own_controls


static func _place(c: Control, r: Rect2) -> void:
	c.position = r.position
	c.size = r.size


static func _setting(key: StringName, fallback: Variant) -> Variant:
	if Settings.DEFAULTS.has(key):
		return Settings.get_value(key)
	return fallback


const EPS := 1e-6   # lint: allow-number divide guard
## The chain row shows once the multiplier reads above 1.0× (one tenth).
const MULT_SHOWN := 0.05   # lint: allow-number half a displayed tenth
## Glitter bursts from the multiplier readout's left third (where its digits are).
const GLITTER_FROM_X := 0.25   # lint: allow-number readout geometry
