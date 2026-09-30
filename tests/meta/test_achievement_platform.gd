extends WBTest
## WP8.3: the platform mirror (src/platform/leaderboards.gd, PlatformLeaderboards) and the
## service over it. Without a plugin (web, desktop, headless) everything is a quiet no-op
## and achievements stay local; with Game Center's or Play Games' plugin API the unlock
## and the board scores reach the plugin's methods; a plugin missing a method never
## errors; an unlock made before sign-in is mirrored later, and once; the optional boards
## mirror is off by default (our server's boards replace the platform's) and never sends
## a warm-up run. Spec: Architecture → Platform services ("no-ops on web"); multiplayer
## handoff → Migration. docs/ACHIEVEMENTS.md → Platforms.

var svc: AchievementService
var cat: AchievementCatalog
var _saved: Dictionary
var _mirror_boards: bool


## Game Center's plugin API (godot-ios-plugins GameCenter).
class FakeGameCenter:
	extends RefCounted
	var authed: bool = true
	var awards: Array[Dictionary] = []
	var scores: Array[Dictionary] = []
	var auth_calls: int = 0

	func authenticate() -> int:
		auth_calls += 1
		return OK

	func is_authenticated() -> bool:
		return authed

	func award_achievement(d: Dictionary) -> int:
		awards.append(d)
		return OK

	func post_score(d: Dictionary) -> int:
		scores.append(d)
		return OK


## Play Games' plugin API (godot-play-game-services).
class FakePlayGames:
	extends RefCounted
	var unlocked: PackedStringArray = []
	var scores: PackedStringArray = []

	func unlockAchievement(id: String) -> void:
		unlocked.append(id)

	func submitScore(id: String, score: int) -> void:
		scores.append("%s=%d" % [id, score])


## The older Play Games plugin's score method.
class FakeOldPlayGames:
	extends RefCounted
	var scores: PackedStringArray = []

	func submitLeaderBoardScore(id: String, score: int) -> void:
		scores.append("%s=%d" % [id, score])


class NoMethods:
	extends RefCounted


func before_all() -> void:
	cat = AchievementCatalog.load_path(AchievementTuning.load_default().catalog_path)


func before_each() -> void:
	_saved = Save.data.duplicate(true)
	for k: String in [AchievementService.SECTION, Garage.SECTION_STATS, Garage.SECTION_UNLOCKS]:
		Save.data.erase(k)
	Save.section(Garage.SECTION_STATS)[MetaProfile.BACKFILLED] = true
	_mirror_boards = cat.mirror_boards


func after_each() -> void:
	if svc != null and is_instance_valid(svc):
		svc.free()
	svc = null
	cat.mirror_boards = _mirror_boards
	Save.data = _saved
	Save.dirty = false


func _service(p: PlatformLeaderboards) -> AchievementService:
	var s := AchievementService.new()
	s.run_under_tools = true
	s.show_toast = false
	s.haptic_tick = false
	s.platform = p
	tree.root.add_child(s)
	svc = s
	return s


func _platform(backend: PlatformLeaderboards.Backend, plugin: Object) -> PlatformLeaderboards:
	var p := PlatformLeaderboards.new()
	p.backend = backend
	p.plugin = plugin
	return p


func _first_thread() -> void:
	Events.run_started.emit(&"journey", 1)
	Events.scored.emit(Events.THREAD, 50, 5.0, 1.0)


func _over(extra: Dictionary) -> void:
	var r := {RunStats.MODE: &"journey", RunStats.SCORE: 1234, RunStats.DISTANCE_M: 5678.9, RunStats.TOP_SPEED_KMH: 0.0}
	r.merge(extra, true)
	Events.run_over.emit(r)


# ---------------------------------------------------------------- No platform

func test_no_platform_here_is_a_quiet_no_op() -> void:
	var p := PlatformLeaderboards.detect()
	eq(p.backend, PlatformLeaderboards.Backend.NONE, "headless / desktop: no platform services")
	check(not p.available(), "not available")
	p.sign_in()
	check(not p.is_signed_in(), "no player")
	check(not p.unlock_achievement(cat.find(&"first_thread")), "an unlock goes nowhere")
	check(not p.submit_score(AchievementCatalog.BOARD_JOURNEY, 1000, cat), "a score goes nowhere")


func test_achievements_stay_local_without_a_platform() -> void:
	_service(PlatformLeaderboards.detect())
	_first_thread()
	check(svc.is_unlocked(&"first_thread"), "unlocked locally")
	eq(svc.mirrored_count, 0, "nothing mirrored")
	check(not Save.section(AchievementService.SECTION).has(AchievementService.KEY_MIRRORED), "no mirror bookkeeping")


# ---------------------------------------------------------------- Plugin APIs

func test_game_center_calls() -> void:
	var gc := FakeGameCenter.new()
	var p := _platform(PlatformLeaderboards.Backend.GAME_CENTER, gc)
	p.sign_in()
	eq(gc.auth_calls, 1, "authenticate()")
	var def := cat.find(&"top_speed_300")
	check(p.unlock_achievement(def), "handed to Game Center")
	eq(gc.awards.size(), 1)
	if gc.awards.size() == 1:
		eq(gc.awards[0].get("name"), def.game_center_id, "its Game Center id")
		eq(gc.awards[0].get("progress"), 100.0, "complete")
	check(p.submit_score(AchievementCatalog.BOARD_DAILY, 4321, cat), "a board score")
	if gc.scores.size() == 1:
		eq(gc.scores[0].get("score"), 4321)
		eq(gc.scores[0].get("category"), cat.game_center_boards[AchievementCatalog.BOARD_DAILY])
	gc.authed = false
	check(not p.unlock_achievement(def), "not signed in: not sent")


func test_play_games_calls() -> void:
	var pg := FakePlayGames.new()
	var p := _platform(PlatformLeaderboards.Backend.PLAY_GAMES, pg)
	p.sign_in()   # the plugin has no signIn(): nothing, no error
	check(p.is_signed_in(), "no isAuthenticated(): the plugin decides")
	var def := cat.find(&"coast")
	check(p.unlock_achievement(def), "handed to Play Games")
	eq(pg.unlocked, PackedStringArray([def.play_games_id]), "its Play Games id")
	check(p.submit_score(AchievementCatalog.BOARD_JOURNEY, 99, cat), "a score")
	eq(pg.scores, PackedStringArray(["%s=99" % cat.play_games_boards[AchievementCatalog.BOARD_JOURNEY]]))
	var old := FakeOldPlayGames.new()
	var q := _platform(PlatformLeaderboards.Backend.PLAY_GAMES, old)
	check(q.submit_score(AchievementCatalog.BOARD_DISTANCE, 7, cat), "the older plugin's method")
	eq(old.scores.size(), 1)


func test_a_plugin_without_the_methods_never_errors() -> void:
	for backend: PlatformLeaderboards.Backend in [PlatformLeaderboards.Backend.GAME_CENTER, PlatformLeaderboards.Backend.PLAY_GAMES]:
		var p := _platform(backend, NoMethods.new())
		p.sign_in()
		check(not p.unlock_achievement(cat.find(&"coast")), "no method: false")
		check(not p.submit_score(AchievementCatalog.BOARD_JOURNEY, 5, cat), "no method: false")
	var none := _platform(PlatformLeaderboards.Backend.GAME_CENTER, null)
	check(not none.available(), "no plugin object: not available")
	check(not none.unlock_achievement(cat.find(&"coast")))


# ---------------------------------------------------------------- The service's mirror

func test_unlocks_are_mirrored_once() -> void:
	var p := PlatformLeaderboards.recorder()
	_service(p)
	_first_thread()
	Events.scored.emit(Events.THREAD, 50, 5.0, 1.0)
	eq(p.calls, PackedStringArray(["unlock %s" % cat.find(&"first_thread").game_center_id]), "mirrored in the frame of the unlock")
	svc.mirror_pending()
	eq(p.calls.size(), 1, "never twice")


func test_an_unlock_before_sign_in_is_mirrored_later() -> void:
	var p := PlatformLeaderboards.recorder()
	p.record_signed_in = false
	_service(p)
	_first_thread()
	check(svc.is_unlocked(&"first_thread"), "unlocked locally")
	eq(p.calls.size(), 0, "not signed in yet")
	p.record_signed_in = true
	Events.run_started.emit(&"journey", 2)   # the next run start retries
	eq(p.calls.size(), 1, "mirrored once signed in")


func test_boards_mirror_is_off_by_default() -> void:
	var p := PlatformLeaderboards.recorder()
	_service(p)
	Events.run_started.emit(&"journey", 1)
	_over({})
	for c in p.calls:
		check(not c.begins_with("score"), "no board scores: our server's boards replace the platform's (%s)" % c)


func test_boards_mirror_when_on() -> void:
	cat.mirror_boards = true
	var p := PlatformLeaderboards.recorder()
	_service(p)
	Events.run_started.emit(&"journey", 1)
	_over({})
	check(p.calls.has("score %s 1234" % cat.game_center_boards[AchievementCatalog.BOARD_JOURNEY]), "the Journey score")
	check(p.calls.has("score %s 5678" % cat.game_center_boards[AchievementCatalog.BOARD_DISTANCE]), "the distance")
	p.calls.clear()
	Events.run_started.emit(&"daily", 1)
	_over({RunStats.MODE: &"daily"})
	check(p.calls.has("score %s 1234" % cat.game_center_boards[AchievementCatalog.BOARD_DAILY]), "the Daily score")
	p.calls.clear()
	Events.run_started.emit(&"journey", 1)
	_over({RunWarmup.RESULT_KEY: true})
	eq(p.calls.size(), 0, "a warm-up run is not submitted (D24)")
	Events.run_started.emit(&"loop", 1)
	_over({RunStats.MODE: &"loop"})
	for c in p.calls:
		check(not c.begins_with("score"), "loop practice has no platform board")
