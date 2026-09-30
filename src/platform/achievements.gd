class_name AchievementService
extends Node
## Achievements (WP8.3; requested autoload `Achievements`). Spec: Garage and progression
## ("Achievements. About 25 achievements, mirrored to Game Center and Google Play
## Games"); Architecture → Platform services; multiplayer handoff → Migration
## ("achievements stay on the platform services"); Save data. docs/ACHIEVEMENTS.md.
##
## A listener only (Architecture rule 8): the Events bus and the run's results feed the
## AchievementTracker; nothing here reaches gameplay. An unlock is recorded in the save
## (section `achievements`, additive: no new save version), shows the unlock toast
## (HudAchievementLayer) and a light haptic tick (Haptics, which honours the setting), all
## in the frame of the unlock, and is mirrored to Game Center / Play Games when a plugin is
## there (PlatformLeaderboards; web and desktop: local only). Each achievement unlocks
## once. Unlocks already earned by an older save (lifetime threads, driver level, cars,
## Daily streak) are recorded quietly at start.
##
##   AchievementService.ensure(host)   # the one service (the autoload, else a child of host)
##   AchievementService.current        # null when none runs
##   service.unlocked                  # (id) after it was recorded
##
## Until the autoload exists, TitleScreens makes one under itself (the run always builds
## the title). Under a `--script` main loop (the test runner, soaks, snaps, tools) none is
## made and an autoload stays dormant, so other suites never see unlocks, toasts or
## pulses; a test that wants it sets `run_under_tools` (or attach_under_tools).
##
## Save section:
##   achievements { unlocked: {id: utc day}, progress: {metric: value}, mirrored: {id: true} }

signal unlocked(achievement_id: StringName)

const SECTION := "achievements"
const KEY_MIRRORED := "mirrored"
const HapticsScript := preload("res://src/platform/haptics.gd")
const HAPTICS_PATH := ^"/root/Haptics"
const AUTOLOAD_NAME := "Achievements"

## The running service (null: none).
static var current: AchievementService
## ensure() makes a service under a --script main loop too (tests of the real path).
static var attach_under_tools: bool = false

## Track under a --script main loop (tests that add a service themselves).
@export var run_under_tools: bool = false
@export var show_toast: bool = true
@export var haptic_tick: bool = true

var tuning: AchievementTuning
var catalog: AchievementCatalog
var tracker: AchievementTracker
var platform: PlatformLeaderboards
var toast: HudAchievementLayer
## Ids unlocked while this service ran, in order (tests, the dev HUD).
var session_unlocks: Array[StringName] = []
## Platform calls made (unlocks mirrored, scores submitted).
var mirrored_count: int = 0

var _listening: bool = false


## The one service: the running one, else a new one under `host` (null under a --script
## main loop unless attach_under_tools).
static func ensure(host: Node) -> AchievementService:
	if current != null and is_instance_valid(current):
		return current
	if host == null or (script_main_loop() and not attach_under_tools):
		return null
	var s := AchievementService.new()
	s.run_under_tools = attach_under_tools
	host.add_child(s)
	return s


static func script_main_loop() -> bool:
	var ml := Engine.get_main_loop()
	return ml != null and ml.get_script() != null


func _init() -> void:
	name = AUTOLOAD_NAME
	process_mode = Node.PROCESS_MODE_ALWAYS


func _enter_tree() -> void:
	if script_main_loop() and not run_under_tools:
		return   # dormant (tests and tools)
	if current != null and is_instance_valid(current) and current != self:
		return   # one service at a time
	current = self
	setup()
	_connect(true)


func _exit_tree() -> void:
	_connect(false)
	if current == self:
		current = null


## Loads the catalog and the save, finds the platform (idempotent). `p`: a platform to use
## instead of detecting one (tests).
func setup(t: AchievementTuning = null, p: PlatformLeaderboards = null) -> void:
	if tracker != null:
		return
	tuning = t if t != null else AchievementTuning.load_default()
	catalog = AchievementCatalog.load_path(tuning.catalog_path)
	tracker = AchievementTracker.new(catalog)
	platform = p if p != null else (platform if platform != null else PlatformLeaderboards.detect())
	if show_toast and toast == null:
		toast = HudAchievementLayer.new()
		toast.tuning = tuning
		add_child(toast)
	if platform.available():
		platform.sign_in()
	bind_save()


## Reads the save again (a load, a reset): the unlocked ids and the saved progress, the
## garage's numbers; unlocks already earned are recorded quietly; pending mirrors go out.
func bind_save() -> void:
	if tracker == null:
		return
	tracker.bind(section())
	_refresh_profile()
	tracker.evaluate_all()
	_flush(true)
	mirror_pending()


func section() -> Dictionary:
	return Save.section(SECTION)


## Whether achievement `id` is recorded as unlocked in the save.
func is_unlocked(achievement_id: StringName) -> bool:
	var u: Variant = section().get(AchievementTracker.KEY_UNLOCKED)
	return u is Dictionary and (u as Dictionary).has(String(achievement_id))


## Recorded unlocks in the save.
func unlocked_count() -> int:
	var u: Variant = section().get(AchievementTracker.KEY_UNLOCKED)
	return (u as Dictionary).size() if u is Dictionary else 0


# ---------------------------------------------------------------- Events

func _connect(on: bool) -> void:
	if on == _listening:
		return
	_listening = on
	var pairs: Array = [
		[Events.run_started, _on_run_started], [Events.run_over, _on_run_over],
		[Events.game_state_changed, _on_game_state_changed],
		[Events.scored, _on_scored], [Events.multiplier_changed, _on_multiplier_changed],
		[Events.chain_banked, _on_chain_banked], [Events.bonus_awarded, _on_bonus_awarded],
		[Events.hit, _on_hit], [Events.checkpoint_crossed, _on_checkpoint_crossed],
		[Events.coast_reached, _on_coast_reached], [Events.night_started, _on_night_started],
		[Events.dawn_started, _on_dawn_started], [Events.morning_reached, _on_morning_reached],
		[Events.set_piece_started, _on_set_piece_started], [Events.set_piece_ended, _on_set_piece_ended],
		[Events.objective_completed, _on_objective_completed], [Save.loaded, bind_save],
	]
	for pair: Array in pairs:
		var sig: Signal = pair[0]
		var cb: Callable = pair[1]
		if on and not sig.is_connected(cb):
			sig.connect(cb)
		elif not on and sig.is_connected(cb):
			sig.disconnect(cb)


func _on_run_started(run_mode: StringName, _seed: int) -> void:
	tracker.bind(section())
	_refresh_profile()
	tracker.evaluate_all()
	_flush(true)
	var prog := Garage.tuning()
	tracker.begin_run(run_mode, Progression.counts_for_milestones(run_mode, prog),
			Progression.counts_for_xp(run_mode, prog))
	mirror_pending()


func _on_run_over(results: Dictionary) -> void:
	if not tracker.active:
		return
	tracker.end_run(results)
	_refresh_profile()   # after Garage.award_run: the level, cars and streak this run earned
	tracker.write_progress(section())
	_flush(false)
	Save.request_save()
	if catalog.mirror_boards:
		_submit_boards(results)
	mirror_pending()


func _on_game_state_changed(_from: StringName, to: StringName) -> void:
	if to == Game.MENU and tracker.active:
		tracker.abort_run()


func _on_scored(kind: StringName, points: int, multiplier: float, clearance_m: float) -> void:
	tracker.on_scored(kind, points, multiplier, clearance_m)
	if tracker.pending_count > 0:
		_flush(false)


func _on_multiplier_changed(value: float) -> void:
	tracker.on_multiplier_changed(value)
	if tracker.pending_count > 0:
		_flush(false)


func _on_chain_banked(amount: int, _reason: StringName, banked_total: int) -> void:
	tracker.on_chain_banked(amount, banked_total)
	if tracker.pending_count > 0:
		_flush(false)


func _on_bonus_awarded(_kind: StringName, _points: int, banked_total: int) -> void:
	tracker.on_bonus_awarded(banked_total)
	if tracker.pending_count > 0:
		_flush(false)


func _on_hit(_source: StringName, _lives_left: int) -> void:
	tracker.on_hit()


func _on_checkpoint_crossed(_leg_index: int, summary: Dictionary) -> void:
	tracker.on_checkpoint_crossed(summary)
	if tracker.pending_count > 0:
		_flush(false)


func _on_coast_reached() -> void:
	tracker.on_coast_reached()
	if tracker.pending_count > 0:
		_flush(false)


func _on_night_started() -> void:
	tracker.on_night_started()


func _on_dawn_started(_duration_s: float) -> void:
	tracker.on_dawn_started()
	if tracker.pending_count > 0:
		_flush(false)


func _on_morning_reached() -> void:
	tracker.on_morning_reached()


func _on_set_piece_started(_kind: StringName) -> void:
	tracker.on_set_piece_started()


func _on_set_piece_ended(_kind: StringName) -> void:
	tracker.on_set_piece_ended()
	if tracker.pending_count > 0:
		_flush(false)


func _on_objective_completed(_objective: StringName, _points: int) -> void:
	tracker.on_objective_completed()
	if tracker.pending_count > 0:
		_flush(false)


# ---------------------------------------------------------------- Unlocks

## The garage's numbers: driver level, real cars unlocked, best Daily streak, threads.
func _refresh_profile() -> void:
	var p := Garage.profile()
	var cars := 0
	for s in p.catalog.slots:
		if s.has_car() and p.car_unlocked(s):
			cars += 1
	tracker.set_profile(p.level(), cars, p.daily_best_streak(), p.threads())


## Records every pending unlock: the save, the mirror, and unless `quiet` (an unlock an
## older save had already earned) its toast and one haptic tick for the batch.
func _flush(quiet: bool) -> void:
	var n := tracker.pending_count
	if n == 0:
		return
	var sec := section()
	var u: Variant = sec.get(AchievementTracker.KEY_UNLOCKED)
	if not (u is Dictionary):
		u = {}
		sec[AchievementTracker.KEY_UNLOCKED] = u
	var unlocked_ids: Dictionary = u
	var day := Garage.today()
	var fresh := 0
	for k in n:
		var def := catalog.achievements[tracker.pending[k]]
		var key := String(def.id)
		if unlocked_ids.has(key):
			continue
		unlocked_ids[key] = day
		session_unlocks.append(def.id)
		fresh += 1
		if not quiet and show_toast and toast != null:
			toast.show_unlock(def)
		_mirror(def)
		unlocked.emit(def.id)
	tracker.clear_pending()
	if fresh > 0 and not quiet:
		_tick()   # one tick however many unlocked together
	Save.request_save()


func _tick() -> void:
	if haptic_tick and is_inside_tree():
		var h := get_node_or_null(HAPTICS_PATH) as HapticsScript
		if h != null:
			h.play(HapticsScript.Pattern.PASS)


## Mirrors every recorded unlock the platform has not taken yet (it may not have been
## signed in before).
func mirror_pending() -> void:
	if platform == null or not platform.available() or not catalog.mirror_achievements:
		return
	var u: Variant = section().get(AchievementTracker.KEY_UNLOCKED)
	if not (u is Dictionary):
		return
	for key: Variant in (u as Dictionary):
		var def := catalog.find(StringName(str(key)))
		if def != null:
			_mirror(def)


func _mirror(def: AchievementDef) -> void:
	if platform == null or not platform.available() or not catalog.mirror_achievements:
		return
	var sec := section()
	var m: Variant = sec.get(KEY_MIRRORED)
	if not (m is Dictionary):
		m = {}
		sec[KEY_MIRRORED] = m
	var done: Dictionary = m
	var key := String(def.id)
	if done.has(key):
		return
	if platform.unlock_achievement(def):
		done[key] = true
		mirrored_count += 1
		Save.request_save()


## The optional platform boards mirror (catalog.mirror_boards): Journey or Daily score and
## the distance, for runs the leaderboards would take (not a warm-up run).
func _submit_boards(results: Dictionary) -> void:
	if platform == null or not platform.available() or bool(results.get(RunWarmup.RESULT_KEY, false)):
		return
	var run_mode := StringName(str(results.get(RunStats.MODE, &"")))
	var score := int(results.get(RunStats.SCORE, 0))
	var board := &""
	if run_mode == AchievementTracker.MODE_DAILY:
		board = AchievementCatalog.BOARD_DAILY
	elif run_mode == RunContext.MODE_JOURNEY:
		board = AchievementCatalog.BOARD_JOURNEY
	if board == &"":
		return
	if platform.submit_score(board, score, catalog):
		mirrored_count += 1
	if run_mode == RunContext.MODE_JOURNEY and platform.submit_score(AchievementCatalog.BOARD_DISTANCE,
			floori(float(results.get(RunStats.DISTANCE_M, 0.0))), catalog):
		mirrored_count += 1


# ---------------------------------------------------------------- Dev

## Shows `id`'s toast without unlocking anything (previews, snaps).
func preview_toast(achievement_id: StringName) -> void:
	var def := catalog.find(achievement_id) if catalog != null else null
	if def != null and toast != null:
		toast.show_unlock(def)
