class_name AchievementDef
extends Resource
## One achievement (WP8.3). Spec: Garage and progression ("Achievements. About 25
## achievements, mirrored to Game Center and Google Play Games (for example: first thread,
## 50× multiplier, a clean journey, a full night survived, 300 km/h)"); multiplayer handoff
## → Migration ("achievements stay on the platform services"). Listed in
## data/achievements/catalog.tres. docs/ACHIEVEMENTS.md.
##
## It unlocks once its metric (AchievementTracker.METRIC_IDS) reaches `threshold`. Run
## metrics ("… in one run") count one run; total metrics add up across runs; profile
## metrics read the garage's driver level, cars and Daily streak.

## How `threshold` reads in text ({n} in the description, the progress line) and the
## unit it is written in here (converted once when the catalog loads).
enum Unit {
	COUNT,       ## a whole number (threads, legs, days, level)
	POINTS,      ## score points (thousands separators)
	MULTIPLIER,  ## "50×"
	SPEED,       ## km/h here; km/h or mph in text (the units setting); m/s in the tracker
}

## Stable id: the save's key (achievements.unlocked) and the platform mirror's.
@export var id: StringName = &""
## Short name, upper case ("300 CLUB").
@export var title: String = ""
## One short line, upper case. `{n}` is the threshold in its unit ("REACH {n}." →
## "REACH 300 KM/H."), `{clearance}` the catalog's hairline clearance ("25 CM").
@export var description: String = ""
## The achievements screen's tab (AchievementCatalog.groups).
@export var group: StringName = &""
## What is measured (AchievementTracker.METRIC_IDS).
@export var metric: StringName = &""
## Unlocks when the metric reaches this (in `unit`; speed in km/h).
@export var threshold: float = 1.0
@export var unit: Unit = Unit.COUNT
## The card shows "7 / 10" and a bar while locked (false: LOCKED only, for a one-off
## whose count says little, like the first checkpoint's "1 / 2" legs reached).
@export var show_progress: bool = true
## Hidden until unlocked: the screen shows HIDDEN and no progress.
@export var hidden: bool = false
## Platform ids (placeholders until the App Store Connect / Play Console entries exist;
## empty = not mirrored on that platform).
@export var game_center_id: String = ""
@export var play_games_id: String = ""
