class_name AchievementCatalog
extends Resource
## Every achievement and the platform mirror's ids (WP8.3). Spec: Garage and progression
## (About 25 achievements, mirrored to Game Center and Google Play Games); Architecture →
## Platform services (a thin `platform/leaderboards.gd` wrapper that no-ops on web);
## multiplayer handoff → Migration ("Their leaderboards are retired; achievements stay on
## the platform services"). Data: data/achievements/catalog.tres
## (AchievementTuning.catalog_path). docs/ACHIEVEMENTS.md.

## The platform boards the optional mirror submits to (PlatformLeaderboards).
const BOARD_JOURNEY := &"journey"
const BOARD_DAILY := &"daily"
const BOARD_DISTANCE := &"distance"

@export var achievements: Array[AchievementDef] = []
## The screen's tabs, in order, and their titles.
@export var groups: Array[StringName] = [&"driving", &"road", &"career"]
@export var group_titles: PackedStringArray = PackedStringArray(["DRIVING", "THE ROAD", "CAREER"])

@export_group("Rules")
## A close pass at or under this hull-to-hull clearance counts as a hairline pass (m).
@export var hairline_clearance_m: float = 0.25

@export_group("Platform mirror")
## Unlocks are mirrored to Game Center / Play Games when a plugin is present.
@export var mirror_achievements: bool = true
## The game's boards live on our server (N7); the platform boards are retired by the
## multiplayer handoff. On, the mirror also submits Journey / Daily / distance bests there.
@export var mirror_boards: bool = false
## Board ids per platform (placeholders).
@export var game_center_boards: Dictionary[StringName, String] = {}
@export var play_games_boards: Dictionary[StringName, String] = {}


static func load_path(path: String) -> AchievementCatalog:
	return load(path) as AchievementCatalog


func find(achievement_id: StringName) -> AchievementDef:
	for a in achievements:
		if a.id == achievement_id:
			return a
	return null


func index_of(achievement_id: StringName) -> int:
	for i in achievements.size():
		if achievements[i].id == achievement_id:
			return i
	return -1


## The achievements of tab `group`, in catalog order.
func in_group(group: StringName) -> Array[AchievementDef]:
	var out: Array[AchievementDef] = []
	for a in achievements:
		if a.group == group:
			out.append(a)
	return out


func group_title(group: StringName) -> String:
	var i := groups.find(group)
	return group_titles[i] if i >= 0 and i < group_titles.size() else String(group).to_upper()


## `def`'s threshold in the tracker's units (speed: m/s).
static func internal_threshold(def: AchievementDef) -> float:
	if def.unit == AchievementDef.Unit.SPEED:
		return Units.kmh_to_mps(def.threshold)
	return def.threshold
