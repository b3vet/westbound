class_name ResultsScreen
extends RunScreen
## The results after the crash. Spec: Run end ("Results screen: total score, distance,
## legs completed, whether the coast was reached, best chain, best multiplier, threads,
## close passes, top speed, time spent at night and hits. It compares against personal
## bests ... and offers Retry and Garage"; "Retry puts the player back on the road
## within 2 seconds"); UI → Screens; Design system (gold = records, speed tilt,
## left-anchored layout). docs/SCREENS.md → Results.
##
## show_results(payload) takes the Events.run_over payload (RunStats.results plus
## personal_best, new_best and previous_best). It fades in, counts the score up
## (tabular digits, no jitter), pops NEW BEST when the count passes the old best, and
## staggers the stat rows in. RETRY (primary, bottom-right thumb reach; mirrored when
## left-handed) emits `retry`; GARAGE (WP8.2) emits `garage`. Taps are ignored for
## results_input_delay_s, so the tap that skipped the crash never lands on RETRY.
## N7.2 (multiplayer handoff → Leaderboards): with an online session (NetRunsClient), the
## run's submission shows under the tiles (ResultsOnline: placements, NEW PB, VERIFYING,
## OFFLINE — WILL SUBMIT, UPDATE REQUIRED) and animates in when the server answers; the
## results never wait for it. LEADERBOARDS (on the side away from RETRY) opens the
## LeaderboardsScreen over this one.
## WP8.5: MENU (beside LEADERBOARDS, away from RETRY) emits `menu`: back to the title.
## RETRY keeps the run's mode (the run's retry()).
## WP8.2: the XP panel under the stats list (right column): the driver level, the XP the
## run earned (MetaProfile's payload keys, added by Garage.award_run), the bar to the next
## level, LEVEL UP in gold and what unlocked. Hidden when the payload has no XP keys.

signal retry()
signal garage()
signal menu()

const TILT_SHADER := preload("res://src/ui/theme/speed_tilt.gdshader")
const TEXT_HEADER := "RUN OVER"
const TEXT_NEW_BEST := "NEW BEST"
const TEXT_TO_BEAT := "BEST %s  ·  %s TO BEAT"
const TEXT_OVER := "+%s OVER YOUR BEST"
const TEXT_FIRST := "FIRST RECORD"
const TEXT_RETRY := "RETRY"
const TEXT_GARAGE := "GARAGE"
const TEXT_LEADERBOARDS := "LEADERBOARDS"
const TEXT_MENU := "MENU"
const TEXT_SOON := "SOON"
const TEXT_XP_LEVEL := "DRIVER LEVEL %d"
const TEXT_XP_GAINED := "+%s XP"
const TEXT_XP_NEXT := "%s XP TO LEVEL %d"
const TEXT_XP_MAX := "MAX LEVEL"
const TEXT_LEVEL_UP := "LEVEL UP"
const TEXT_UNLOCKED := "NEW: %s"
const TEXT_UNLOCKED_MANY := "%d NEW IN THE GARAGE"
const TEXT_SEP := " · "
const TEXT_COAST := "COAST REACHED"
const TEXT_TO_COAST := "OF %d TO THE COAST"
const TEXT_YES := "YES"
const TEXT_NO := "NO"
const UNIT_KM := "KM"
const UNIT_MI := "MI"
const UNIT_KMH := "KM/H"
const UNIT_MPH := "MPH"
const SEC_PER_MIN := 60

## Stat row keys (the list panel), in order. The tiles show distance, legs and top speed.
const LIST_KEYS: Array[StringName] = [&"best_chain", &"best_multiplier", &"threads", &"close_passes",
		&"night_time_s", &"hits", &"coast_reached"]
const LIST_LABELS := {
	&"best_chain": "BEST CHAIN",
	&"best_multiplier": "BEST MULTIPLIER",
	&"threads": "THREADS",
	&"close_passes": "CLOSE PASSES",
	&"night_time_s": "TIME AT NIGHT",
	&"hits": "HITS",
	&"coast_reached": "COAST REACHED",
}
const TILE_KEYS: Array[StringName] = [&"distance_m", &"legs_completed", &"top_speed_kmh"]
const TILE_LABELS := {
	&"distance_m": "DISTANCE",
	&"legs_completed": "LEGS",
	&"top_speed_kmh": "TOP SPEED",
}

var results: Dictionary = {}
var score: int = 0
var best_before: int = 0
var new_best: bool = false
var miles: bool = false
var legs_total: int = 8
## RETRY and GARAGE take taps (false during the input guard).
var accepting: bool = false

var dim: ColorRect
var header: ScreenText
var score_text: ScreenText
var badge: ScreenPanel
var badge_text: ScreenText
var compare: ScreenText
var retry_button: ScreenButton
var garage_button: ScreenButton
## WP8.5: back to the title.
var menu_button: ScreenButton
var stats_panel: ScreenPanel
## N7.2: the online line, LEADERBOARDS, and the runs client they follow.
var online: ResultsOnline
var boards_button: ScreenButton
## WP8.2: the XP panel.
var xp_panel: ScreenPanel
var xp_level: ScreenText
var xp_gained: ScreenText
var xp_bar: GarageXpBar
var xp_note: ScreenText
var runs: NetRunsClient
var leaderboards: LeaderboardsScreen
## This run's submission (null: not submitted, or no session).
var submission: NetRunSubmission

var _shown: int = 0
var _badge_popped: bool = false
var _tiles: Array[Tile] = []
var _rows: Array[StatRow] = []
var _guard_left: float = 0.0
var _shown_done: bool = false


## One hero tile: label, big value + unit, a sub-line.
class Tile:
	extends RefCounted
	var key: StringName
	var panel: ScreenPanel
	var label: ScreenText
	var value: ScreenText
	var unit: ScreenText
	var sub: ScreenText


## One list row: label left, value right.
class StatRow:
	extends RefCounted
	var key: StringName
	var label: ScreenText
	var value: ScreenText


func _init() -> void:
	super._init()
	name = "Results"
	modal = true
	dim = ColorRect.new()
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	header = ScreenText.make(TEXT_HEADER, ScreenText.Face.LABEL, 16, ScreenText.Ink.MUTED)
	add_child(header)
	score_text = ScreenText.make("0", ScreenText.Face.DISPLAY, 92, ScreenText.Ink.TEXT)
	score_text.tabular = true
	score_text.outline = true
	add_child(score_text)
	badge = ScreenPanel.new()
	badge.gold_fill = true
	badge.small_bevel = true
	badge.tab = false
	add_child(badge)
	badge_text = ScreenText.make(TEXT_NEW_BEST, ScreenText.Face.LABEL, 20, ScreenText.Ink.INK)
	badge.add_child(badge_text)
	compare = ScreenText.make("", ScreenText.Face.LABEL, 16, ScreenText.Ink.MUTED)
	add_child(compare)
	for key in TILE_KEYS:
		var t := Tile.new()
		t.key = key
		t.panel = ScreenPanel.new()
		add_child(t.panel)
		t.label = ScreenText.make(TILE_LABELS[key], ScreenText.Face.LABEL, 13, ScreenText.Ink.MUTED)
		t.panel.add_child(t.label)
		t.value = ScreenText.make("", ScreenText.Face.DISPLAY, 36, ScreenText.Ink.TEXT)
		t.value.tabular = true
		t.panel.add_child(t.value)
		t.unit = ScreenText.make("", ScreenText.Face.LABEL, 13, ScreenText.Ink.MUTED)
		t.panel.add_child(t.unit)
		t.sub = ScreenText.make("", ScreenText.Face.LABEL, 13, ScreenText.Ink.MUTED)
		t.panel.add_child(t.sub)
		_tiles.append(t)
	stats_panel = ScreenPanel.new()
	add_child(stats_panel)
	for key in LIST_KEYS:
		var r := StatRow.new()
		r.key = key
		r.label = ScreenText.make(LIST_LABELS[key], ScreenText.Face.LABEL, 16, ScreenText.Ink.MUTED)
		stats_panel.add_child(r.label)
		r.value = ScreenText.make("", ScreenText.Face.BODY, 22, ScreenText.Ink.TEXT)
		r.value.tabular = true
		r.value.align = HORIZONTAL_ALIGNMENT_RIGHT
		stats_panel.add_child(r.value)
		_rows.append(r)
	xp_panel = ScreenPanel.new()
	xp_panel.name = "XpPanel"
	xp_panel.visible = false
	add_child(xp_panel)
	xp_level = ScreenText.make("", ScreenText.Face.LABEL, 16, ScreenText.Ink.TEXT)
	xp_panel.add_child(xp_level)
	xp_gained = ScreenText.make("", ScreenText.Face.LABEL, 16, ScreenText.Ink.ACCENT)
	xp_gained.tabular = true
	xp_gained.align = HORIZONTAL_ALIGNMENT_RIGHT
	xp_panel.add_child(xp_gained)
	xp_bar = GarageXpBar.new()
	xp_panel.add_child(xp_bar)
	xp_note = ScreenText.make("", ScreenText.Face.LABEL, 13, ScreenText.Ink.MUTED)
	xp_panel.add_child(xp_note)
	garage_button = ScreenButton.make(TEXT_GARAGE, ScreenButton.Kind.NORMAL, 24)
	garage_button.name = "Garage"
	garage_button.pressed.connect(_on_garage)
	add_child(garage_button)
	retry_button = ScreenButton.make(TEXT_RETRY, ScreenButton.Kind.PRIMARY, 24)
	retry_button.name = "Retry"
	retry_button.pressed.connect(_on_retry)
	add_child(retry_button)
	menu_button = ScreenButton.make(TEXT_MENU, ScreenButton.Kind.NORMAL, 24)
	menu_button.name = "Menu"
	menu_button.pressed.connect(_on_menu)
	add_child(menu_button)
	online = ResultsOnline.new()
	online.visible = false
	add_child(online)
	boards_button = ScreenButton.make(TEXT_LEADERBOARDS, ScreenButton.Kind.NORMAL, 24)
	boards_button.name = "Leaderboards"
	boards_button.visible = false
	boards_button.pressed.connect(open_leaderboards)
	add_child(boards_button)


func _ready() -> void:
	set_process(false)
	if runs == null:
		bind_runs(NetRunsClient.ensure())


## The runs client whose submissions show here (null: none, offline builds).
func bind_runs(client: NetRunsClient) -> void:
	if runs != null and is_instance_valid(runs) and runs.submission_changed.is_connected(_on_submission):
		runs.submission_changed.disconnect(_on_submission)
	runs = client
	if runs != null and not runs.submission_changed.is_connected(_on_submission):
		runs.submission_changed.connect(_on_submission)
	boards_button.visible = runs != null
	if leaderboards != null:
		leaderboards.bind(runs)
	_refresh_online()


func _exit_tree() -> void:
	if runs != null and is_instance_valid(runs) and runs.submission_changed.is_connected(_on_submission):
		runs.submission_changed.disconnect(_on_submission)


func _restyled() -> void:
	score_text.size_px = tuning.font_results_score_px
	score_text.use_tilt(TILT_SHADER, tuning.speed_tilt_rad())
	badge_text.use_tilt(TILT_SHADER, tuning.speed_tilt_rad())
	retry_button.size_px = tuning.font_screen_button_px
	garage_button.size_px = tuning.font_screen_button_px
	menu_button.size_px = tuning.font_screen_button_px
	boards_button.size_px = tuning.font_screen_button_px
	if leaderboards != null:
		leaderboards.setup(style, tuning)
	xp_bar.setup(style)
	dim.color = Color(style.ink, Units.pct_to_frac(tuning.screen_dim_pct))
	_layout()


## Fills the screen from the Events.run_over payload (does not open it).
func set_results(payload: Dictionary, legs_to_coast: int, in_miles: bool) -> void:
	results = payload
	legs_total = legs_to_coast
	miles = in_miles
	score = int(payload.get(RunStats.SCORE, 0))
	new_best = bool(payload.get(&"new_best", false))
	var pb := int(payload.get(&"personal_best", 0))
	best_before = int(payload.get(&"previous_best", pb if not new_best else 0))
	for t in _tiles:
		_fill_tile(t)
	for r in _rows:
		r.value.text = stat_text(r.key)
		r.value.set_ink(ScreenText.Ink.GOLD if r.key == &"coast_reached" and bool(payload.get(r.key, false))
				else ScreenText.Ink.TEXT)
	compare.text = compare_text()
	compare.set_ink(ScreenText.Ink.GOLD if new_best else ScreenText.Ink.MUTED)
	_fill_xp()
	if leaderboards != null:
		leaderboards.close(false)
	submission = runs.submission_for(payload) if runs != null else null
	_refresh_online()
	_set_shown(0.0)
	_layout()


## Opens with the fade, the count-up, the NEW BEST pop and the staggered rows.
func open() -> void:
	_badge_popped = false
	badge.visible = false
	accepting = false
	_guard_left = tuning.results_input_delay_s
	_apply_accepting()
	set_process(true)
	_layout()
	_open = true
	kill_tweens()
	_show()
	modulate.a = 0.0
	var tw := new_tween()
	tw.tween_property(self, ^"modulate:a", 1.0, tuning.results_fade_in_s)
	var count := new_tween()
	count.tween_method(_set_shown, 0.0, float(score), tuning.results_count_s) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT).set_delay(tuning.results_fade_in_s * 0.5)
	count.tween_callback(_count_done)
	var i := 0
	var dx := -tuning.screen_slide_px
	for t in _tiles:
		slide_in(t.panel, dx, tuning.results_fade_in_s, tuning.results_fade_in_s + float(i) * tuning.results_row_stagger_s)
		i += 1
	slide_in(stats_panel, -dx, tuning.results_fade_in_s, tuning.results_fade_in_s)
	if xp_panel.visible:
		slide_in(xp_panel, -dx, tuning.results_fade_in_s, tuning.results_fade_in_s + float(_rows.size()) * tuning.results_row_stagger_s)
	if online.visible:
		slide_in(online, dx, tuning.results_fade_in_s, tuning.results_fade_in_s + float(i) * tuning.results_row_stagger_s)
	for r in _rows:
		slide_in(r.label, -dx * 0.5, tuning.results_fade_in_s, tuning.results_fade_in_s + float(i) * tuning.results_row_stagger_s)
		slide_in(r.value, -dx * 0.5, tuning.results_fade_in_s, tuning.results_fade_in_s + float(i) * tuning.results_row_stagger_s)
		i += 1


func _process(delta: float) -> void:
	if _guard_left > 0.0:
		_guard_left -= delta
		if _guard_left <= 0.0:
			accepting = true
			_apply_accepting()
			set_process(false)


func finish_animations() -> void:
	super.finish_animations()
	if _guard_left > 0.0:
		_guard_left = 0.0
		accepting = true
		_apply_accepting()
		set_process(false)


## Ends the input guard now (tests, snaps).
func accept_input_now() -> void:
	_guard_left = 0.0
	accepting = true
	_apply_accepting()


func _apply_accepting() -> void:
	var f := Control.MOUSE_FILTER_STOP if accepting else Control.MOUSE_FILTER_IGNORE
	retry_button.mouse_filter = f
	garage_button.mouse_filter = f
	boards_button.mouse_filter = f
	menu_button.mouse_filter = f


func _on_retry() -> void:
	if accepting:
		retry.emit()


func _on_menu() -> void:
	if accepting:
		menu.emit()


func _on_garage() -> void:
	if accepting:
		garage.emit()


# ---------------------------------------------------------------- XP (WP8.2)

## The XP panel from the payload (hidden without MetaProfile's keys).
func _fill_xp() -> void:
	xp_panel.visible = results.has(MetaProfile.R_XP_GAINED)
	if not xp_panel.visible:
		return
	var t := Garage.tuning()
	var total := int(results.get(MetaProfile.R_XP_TOTAL, 0))
	var level := int(results.get(MetaProfile.R_LEVEL, 1))
	var up := level > int(results.get(MetaProfile.R_LEVEL_BEFORE, level))
	xp_level.text = TEXT_XP_LEVEL % level
	xp_gained.text = TEXT_XP_GAINED % HudFormat.thousands(int(results.get(MetaProfile.R_XP_GAINED, 0)))
	xp_bar.frac = Progression.level_progress(total, t)
	xp_bar.gold = up
	xp_note.set_ink(ScreenText.Ink.GOLD if up else ScreenText.Ink.MUTED)
	xp_note.text = xp_note_text(-1.0)


## The panel's last line: what unlocked ("LEVEL UP · NEW: SUNSET PAINT"), else the XP to
## the next level. Shortened to "n NEW IN THE GARAGE" when the names do not fit `max_w`
## (px; negative: no limit).
func xp_note_text(max_w: float) -> String:
	var fresh: Variant = results.get(MetaProfile.R_UNLOCKED, [])
	var ids: Array = fresh if fresh is Array else []
	var level := int(results.get(MetaProfile.R_LEVEL, 1))
	var up := level > int(results.get(MetaProfile.R_LEVEL_BEFORE, level))
	var head := TEXT_LEVEL_UP + TEXT_SEP if up else ""
	if ids.is_empty():
		if up:
			return TEXT_LEVEL_UP
		var t := Garage.tuning()
		if level >= t.max_level:
			return TEXT_XP_MAX
		return TEXT_XP_NEXT % [HudFormat.thousands(Progression.xp_to_next(int(results.get(MetaProfile.R_XP_TOTAL, 0)), t)),
				level + 1]
	var names := PackedStringArray()
	for id: Variant in ids:
		names.append(Garage.catalog().item_name(str(id)))
	var line := head + TEXT_UNLOCKED % ", ".join(names)
	if max_w < 0.0 or style == null or HudDraw.text_width(style.label, line, xp_note.font_px()) <= max_w:
		return line
	return head + TEXT_UNLOCKED_MANY % ids.size()


func _unhandled_input(event: InputEvent) -> void:
	if visible and accepting and event.is_action_pressed(&"ui_accept"):
		get_viewport().set_input_as_handled()
		retry.emit()


func _set_shown(v: float) -> void:
	var n := roundi(v)
	if n == _shown and not score_text.text.is_empty():
		return
	_shown = n
	score_text.text = HudFormat.thousands(n)
	if new_best and not _badge_popped and best_before > 0 and n > best_before:
		_pop_badge()


func _count_done() -> void:
	_set_shown(float(score))
	if new_best and not _badge_popped:
		_pop_badge()


func _pop_badge() -> void:
	_badge_popped = true
	badge.visible = true
	score_text.set_ink(ScreenText.Ink.GOLD)
	punch(badge, Units.pct_to_frac(tuning.countdown_punch_scale_pct), tuning.results_badge_pop_s)


## The score shown now (the count-up's current value).
func shown_score() -> int:
	return _shown


func badge_visible() -> bool:
	return badge.visible


# ---------------------------------------------------------------- Online (N7.2)

## A submission changed: this run's shows (and slides in when its placements arrive).
func _on_submission(sub: NetRunSubmission) -> void:
	var ours := sub == submission or (not results.is_empty() and is_same(sub.results, results))
	if not ours:
		return
	var was_done := submission == sub and _shown_done
	submission = sub
	_refresh_online()
	if _open and online.visible and sub.is_done() and not was_done and not leaderboards_open():
		slide_in(online, -tuning.screen_slide_px, runs.tuning.boards_reveal_s, 0.0)
		if online.pb_chip.visible:
			punch(online.pb_chip, Units.pct_to_frac(tuning.countdown_punch_scale_pct), tuning.results_badge_pop_s)


func _refresh_online() -> void:
	if online == null or leaderboards_open():
		return   # shown again when the leaderboards close
	online.show_submission(submission if runs != null else null, _today())
	_shown_done = submission != null and submission.is_done()
	_layout()


func _today() -> String:
	return NetRunPayload.utc_date(runs.now_unix() if runs != null else Time.get_unix_time_from_system())


## LEADERBOARDS: the boards over this screen, on the run's own board.
func open_leaderboards() -> void:
	if runs == null or not accepting:
		return
	var first := leaderboards == null
	leaderboards = LeaderboardsScreen.attach(self, leaderboards, runs)
	if first:
		leaderboards.closed_by_player.connect(_on_leaderboards_closed)
	var mode := String(results.get(RunStats.MODE, NetBoards.JOURNEY))
	leaderboards.open_over(self, mode if NetBoards.BOARDS.has(mode) else "")


func leaderboards_open() -> bool:
	return leaderboards != null and leaderboards.is_open()


func _on_leaderboards_closed() -> void:
	badge.visible = _badge_popped
	_refresh_online()


## "BEST 2,010,000  ·  725,500 TO BEAT" / "+336,900 OVER YOUR BEST" / "FIRST RECORD".
func compare_text() -> String:
	if new_best:
		if best_before <= 0:
			return TEXT_FIRST
		return TEXT_OVER % HudFormat.thousands(score - best_before)
	var pb := int(results.get(&"personal_best", best_before))
	if pb <= 0:
		return ""
	return TEXT_TO_BEAT % [HudFormat.thousands(pb), HudFormat.thousands(pb - score)]


## The shown text of a payload key (value and unit), for tests and the layout.
func stat_text(key: StringName) -> String:
	var v: Variant = results.get(key, 0)
	match key:
		&"best_chain":
			return HudFormat.thousands(int(v))
		&"best_multiplier":
			var hud := tuning if tuning != null else Tuning.load_default().hud
			return HudFormat.multiplier_text(HudFormat.multiplier_key(float(v), hud.multiplier_decimals_below,
					hud.multiplier_display_max), hud.multiplier_decimals_below)
		&"night_time_s":
			var s := roundi(float(v))
			@warning_ignore("integer_division")
			return "%d:%02d" % [s / SEC_PER_MIN, s % SEC_PER_MIN]
		&"coast_reached":
			return TEXT_YES if bool(v) else TEXT_NO
		&"distance_m":
			var km := float(v) / Units.M_PER_KM
			return HudFormat.tenths_text(roundi((Units.kmh_to_mph(km) if miles else km) * HudFormat.TENTHS))
		&"top_speed_kmh":
			return str(roundi(Units.kmh_to_mph(float(v)) if miles else float(v)))
		&"legs_completed":
			return str(int(v))
	return HudFormat.thousands(int(v))


func tile_text(key: StringName) -> String:
	for t in _tiles:
		if t.key == key:
			return "%s %s %s" % [t.value.text, t.unit.text, t.sub.text]
	return ""


func _fill_tile(t: Tile) -> void:
	t.value.text = stat_text(t.key)
	t.sub.set_ink(ScreenText.Ink.MUTED)
	match t.key:
		&"distance_m":
			t.unit.text = UNIT_MI if miles else UNIT_KM
			t.sub.text = ""
		&"top_speed_kmh":
			t.unit.text = UNIT_MPH if miles else UNIT_KMH
			t.sub.text = ""
		&"legs_completed":
			t.unit.text = ""
			if bool(results.get(&"coast_reached", false)):
				t.sub.text = TEXT_COAST
				t.sub.set_ink(ScreenText.Ink.GOLD)
			else:
				t.sub.text = TEXT_TO_COAST % legs_total


func _layout() -> void:
	if style == null:
		return
	var m := margin()
	var g := tuning.spacing_grid_px
	var a := safe.grow(-m)
	var ts := style.ts
	dim.position = Vector2.ZERO
	dim.size = full.size
	# Buttons: RETRY in the thumb corner, GARAGE beside it (mirrored when left-handed).
	var pb := tuning.primary_button_size_px
	var th := tuning.touch_target_px
	var gw := tuning.menu_button_width_px * GARAGE_WIDTH
	var ry := a.end.y - pb.y
	if mirrored:
		retry_button.position = Vector2(a.position.x, ry)
		garage_button.position = Vector2(a.position.x + pb.x + g * 2.0, a.end.y - th)
	else:
		retry_button.position = Vector2(a.end.x - pb.x, ry)
		garage_button.position = Vector2(a.end.x - pb.x - g * 2.0 - gw, a.end.y - th)
	retry_button.size = pb
	garage_button.size = Vector2(gw, th)
	# Stats list: right column, from the top.
	var sw := tuning.results_stats_width_px * lerpf(1.0, ts, STATS_GROW)
	var pad := tuning.panel_padding_px * ts
	var rh := tuning.results_stat_row_px * ts
	var sh := pad * 2.0 + rh * float(_rows.size())
	stats_panel.position = Vector2(a.end.x - sw, a.position.y)
	stats_panel.size = Vector2(sw, sh)
	var y := pad
	for r in _rows:
		var ls := r.label.get_combined_minimum_size()
		var vs := r.value.get_combined_minimum_size()
		r.label.position = Vector2(pad, y + (rh - ls.y) * 0.5)
		r.label.size = ls
		r.value.position = Vector2(sw - pad - maxf(vs.x, sw * VALUE_COL), y + (rh - vs.y) * 0.5)
		r.value.size = Vector2(maxf(vs.x, sw * VALUE_COL), vs.y)
		y += rh
	_layout_xp(Vector2(stats_panel.position.x, stats_panel.position.y + sh + g * 2.0), sw, pad, g)
	# Left block: header, score, badge + comparison, then the three tiles.
	var left := a.position.x
	var hs := header.get_combined_minimum_size()
	header.position = Vector2(left, a.position.y)
	header.size = hs
	var ss := score_text.get_combined_minimum_size()
	score_text.position = Vector2(left, a.position.y + hs.y)
	score_text.size = Vector2(maxf(ss.x, stats_panel.position.x - left - g), ss.y)
	score_text.pivot_offset = Vector2(0.0, ss.y * 0.5)
	var bs := badge_text.get_combined_minimum_size()
	var bpad := g * 1.5
	badge.size = Vector2(bs.x + bpad * 2.0, bs.y + g)
	var by := score_text.position.y + ss.y
	badge.position = Vector2(left, by)
	badge_text.position = Vector2(bpad, g * 0.5)
	badge_text.size = bs
	var cs := compare.get_combined_minimum_size()
	var cx := left + (badge.size.x + g * 2.0 if new_best else 0.0)
	compare.position = Vector2(cx, by + (badge.size.y - cs.y) * 0.5)
	compare.size = cs
	var tile_top := by + badge.size.y + g * 3.0
	var tile_w := (stats_panel.position.x - left - g * 2.0 * float(_tiles.size())) / float(_tiles.size())
	tile_w = minf(tile_w, tuning.results_stats_width_px * TILE_MAX)
	var tile_h := pad * 2.0
	for t in _tiles:
		tile_h = maxf(tile_h, pad * 2.0 + t.label.get_combined_minimum_size().y + t.value.get_combined_minimum_size().y
				+ t.sub.get_combined_minimum_size().y)
	var x := left
	for t in _tiles:
		t.panel.position = Vector2(x, tile_top)
		t.panel.size = Vector2(tile_w, tile_h)
		var lsz := t.label.get_combined_minimum_size()
		t.label.position = Vector2(pad, pad)
		t.label.size = lsz
		var vsz := t.value.get_combined_minimum_size()
		t.value.position = Vector2(pad, pad + lsz.y)
		t.value.size = vsz
		var usz := t.unit.get_combined_minimum_size()
		t.unit.position = Vector2(pad + vsz.x + g * 0.5, pad + lsz.y + vsz.y - usz.y - g * 0.5)
		t.unit.size = usz
		var subsz := t.sub.get_combined_minimum_size()
		t.sub.position = Vector2(pad, pad + lsz.y + vsz.y)
		t.sub.size = subsz
		x += tile_w + g * 2.0
	# N7.2: the online line under the tiles, LEADERBOARDS away from RETRY.
	online.layout_panel()
	online.position = Vector2(left, tile_top + tile_h + g * 2.0)
	var lbw := maxf(gw, HudDraw.text_width(style.label, boards_button.text, boards_button.font_px()) + g * 5.0)
	boards_button.size = Vector2(lbw, th)
	boards_button.position = Vector2(a.end.x - lbw if mirrored else left, a.end.y - th)
	# WP8.5: MENU next to LEADERBOARDS (in the corner itself when there are no boards).
	var mw := maxf(gw, HudDraw.text_width(style.label, menu_button.text, menu_button.font_px()) + g * 5.0)
	var inner := lbw + g * 2.0 if boards_button.visible else 0.0
	menu_button.size = Vector2(mw, th)
	menu_button.position = Vector2(a.end.x - inner - mw if mirrored else left + inner, a.end.y - th)


## WP8.2: the XP panel under the stats list: level and +XP, the bar, the note line.
func _layout_xp(at: Vector2, w: float, pad: float, g: float) -> void:
	var ls := xp_level.get_combined_minimum_size()
	var gs := xp_gained.get_combined_minimum_size()
	xp_level.position = Vector2(pad, pad)
	xp_level.size = ls
	xp_gained.position = Vector2(w - pad - gs.x, pad)
	xp_gained.size = gs
	var bar_h := Garage.tuning().garage_xp_bar_px
	var row := maxf(ls.y, gs.y)
	xp_bar.position = Vector2(pad, pad + row + g * 0.5)
	xp_bar.size = Vector2(w - pad * 2.0, bar_h)
	if xp_panel.visible:
		xp_note.text = xp_note_text(w - pad * 2.0)
	var ns := xp_note.get_combined_minimum_size()
	xp_note.position = Vector2(pad, xp_bar.position.y + bar_h + g * 0.5)
	xp_note.size = ns
	xp_panel.position = at
	xp_panel.size = Vector2(w, xp_note.position.y + ns.y + pad)


## GARAGE: a share of the menu width. Stats panel: how much it grows with the text
## size; value column share; tiles at most this share of the stats width.
const GARAGE_WIDTH := 0.62   # lint: allow-number layout proportion
const STATS_GROW := 0.6   # lint: allow-number layout proportion
const VALUE_COL := 0.35   # lint: allow-number layout proportion
const TILE_MAX := 0.5   # lint: allow-number layout proportion
