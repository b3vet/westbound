class_name PlatformLeaderboards
extends RefCounted
## The platform game services: Game Center (iOS) and Google Play Games (Android), through
## their Godot plugins when present; a no-op elsewhere (web, desktop, headless). Spec:
## Architecture → Platform services ("Game Center (iOS) and Google Play Games (Android)
## for leaderboards and achievements, through a thin `platform/leaderboards.gd` wrapper
## that no-ops on web"); multiplayer handoff → Migration ("Their leaderboards are retired;
## achievements stay on the platform services"). WP8.3, docs/ACHIEVEMENTS.md → Platforms.
##
##   var p := PlatformLeaderboards.detect()
##   p.sign_in()                                   # once, at start
##   p.unlock_achievement(def)                     # true when handed to the platform
##   p.submit_score(AchievementCatalog.BOARD_JOURNEY, 1_284_500, catalog)
##
## The plugins are optional and found at run time (Engine.has_singleton); a missing
## plugin or method is never an error: the call returns false and nothing happens. The
## game's own boards are on our server (N7, NetRunsClient); submitting here is an optional
## mirror (AchievementCatalog.mirror_boards, off by default).
##
## Game Center: the godot-ios-plugins `GameCenter` singleton (authenticate(),
## award_achievement({name, progress, show_completion_banner}), post_score({score,
## category})). Play Games: the godot-play-game-services `GodotPlayGameServices` singleton
## (unlockAchievement(id), submitScore(id, score)), or the older `GodotPlayGamesServices`
## (unlockAchievement(id), submitLeaderBoardScore(id, score)). Calls are fire and forget;
## the plugins report back through their own events, which nothing here needs.

enum Backend { NONE, GAME_CENTER, PLAY_GAMES, RECORD }

const GAME_CENTER := "GameCenter"
const PLAY_GAMES: Array[String] = ["GodotPlayGameServices", "GodotPlayGamesServices"]

const GC_AUTHENTICATE := &"authenticate"
const GC_IS_AUTHENTICATED := &"is_authenticated"
const GC_AWARD := &"award_achievement"
const GC_POST_SCORE := &"post_score"
const GC_NAME := "name"
const GC_PROGRESS := "progress"
const GC_BANNER := "show_completion_banner"
const GC_SCORE := "score"
const GC_CATEGORY := "category"
## Game Center's achievement progress is a percentage.
const GC_COMPLETE := 100.0   # lint: allow-number Game Center percent complete

const PG_SIGN_IN: Array[StringName] = [&"signIn"]
const PG_IS_AUTHENTICATED: Array[StringName] = [&"isAuthenticated"]
const PG_UNLOCK: Array[StringName] = [&"unlockAchievement"]
const PG_SUBMIT: Array[StringName] = [&"submitScore", &"submitLeaderBoardScore"]

## RECORD (tests): the calls made, "unlock <id>" / "score <board id> <value>".
var calls := PackedStringArray()
var backend: Backend = Backend.NONE
## The plugin singleton (null for NONE and RECORD).
var plugin: Object
## RECORD: what is_signed_in() answers.
var record_signed_in: bool = true


## The platform's services: Game Center on iOS, Play Games on Android when their plugin
## is in the build, else none (web, desktop, headless, a build without the plugin).
static func detect() -> PlatformLeaderboards:
	var p := PlatformLeaderboards.new()
	if OS.has_feature("web"):
		return p
	if OS.has_feature("ios") and Engine.has_singleton(GAME_CENTER):
		p.backend = Backend.GAME_CENTER
		p.plugin = Engine.get_singleton(GAME_CENTER)
	elif OS.has_feature("android"):
		for n in PLAY_GAMES:
			if Engine.has_singleton(n):
				p.backend = Backend.PLAY_GAMES
				p.plugin = Engine.get_singleton(n)
				break
	return p


## A recorder (tests): every call succeeds and is logged.
static func recorder() -> PlatformLeaderboards:
	var p := PlatformLeaderboards.new()
	p.backend = Backend.RECORD
	return p


func available() -> bool:
	return backend == Backend.RECORD or (backend != Backend.NONE and plugin != null)


## Asks the platform to sign the player in (Game Center shows its own sheet once).
func sign_in() -> void:
	match backend:
		Backend.GAME_CENTER:
			_call(plugin, [GC_AUTHENTICATE], [])
		Backend.PLAY_GAMES:
			_call(plugin, PG_SIGN_IN, [])


## Whether the platform reports a signed-in player (true when it cannot tell: the
## plugin then queues or drops the call itself).
func is_signed_in() -> bool:
	match backend:
		Backend.NONE:
			return false
		Backend.RECORD:
			return record_signed_in
		Backend.GAME_CENTER:
			return _ask(plugin, [GC_IS_AUTHENTICATED])
		Backend.PLAY_GAMES:
			return _ask(plugin, PG_IS_AUTHENTICATED)
	return false


## Unlocks `def` on the platform. True when it was handed to a plugin (or recorded);
## false without a platform, an id for it, or a signed-in player.
func unlock_achievement(def: AchievementDef) -> bool:
	if def == null or not available() or not is_signed_in():
		return false
	match backend:
		Backend.RECORD:
			var rid := def.game_center_id if not def.game_center_id.is_empty() else def.play_games_id
			if rid.is_empty():
				return false
			calls.append("unlock %s" % rid)
			return true
		Backend.GAME_CENTER:
			if def.game_center_id.is_empty():
				return false
			return _call(plugin, [GC_AWARD], [{GC_NAME: def.game_center_id, GC_PROGRESS: GC_COMPLETE, GC_BANNER: true}])
		Backend.PLAY_GAMES:
			if def.play_games_id.is_empty():
				return false
			return _call(plugin, PG_UNLOCK, [def.play_games_id])
	return false


## Submits `value` to `board` (AchievementCatalog.BOARD_*) on the platform. True when it
## was handed to a plugin (or recorded).
func submit_score(board: StringName, value: int, cat: AchievementCatalog) -> bool:
	if cat == null or value <= 0 or not available() or not is_signed_in():
		return false
	match backend:
		Backend.RECORD:
			var rid: String = cat.game_center_boards.get(board, "")
			if rid.is_empty():
				return false
			calls.append("score %s %d" % [rid, value])
			return true
		Backend.GAME_CENTER:
			var gid: String = cat.game_center_boards.get(board, "")
			if gid.is_empty():
				return false
			return _call(plugin, [GC_POST_SCORE], [{GC_SCORE: value, GC_CATEGORY: gid}])
		Backend.PLAY_GAMES:
			var pid: String = cat.play_games_boards.get(board, "")
			if pid.is_empty():
				return false
			return _call(plugin, PG_SUBMIT, [pid, value])
	return false


## Calls the first of `methods` the plugin has with `args`; false when it has none.
static func _call(obj: Object, methods: Array, args: Array) -> bool:
	if obj == null:
		return false
	for m: StringName in methods:
		if obj.has_method(m):
			obj.callv(m, args)
			return true
	return false


## The first of `methods` as a yes / no; true when the plugin has none of them.
static func _ask(obj: Object, methods: Array) -> bool:
	if obj == null:
		return false
	for m: StringName in methods:
		if obj.has_method(m):
			var v: Variant = obj.call(m)
			return (v is bool and v) or (v is int and v != 0)
	return true
