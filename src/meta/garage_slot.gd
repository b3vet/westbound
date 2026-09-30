class_name GarageSlot
extends Resource
## One of the garage's 8 roster slots (WP8.2). Spec: Garage and progression ("Roster. 8
## player cars at launch; 1 unlocked at start"; "Levels unlock cars"; "Milestone
## unlocks. Some cars unlock from milestones instead: reach leg 4, reach the coast, a
## 7-day Daily Drive streak, 100 lifetime threads"). Listed in data/cars/garage.tres.
##
## A slot with an empty `car_path` is a placeholder for a car the art pipeline has not
## made yet (spec open question: the final roster): it shows as COMING SOON with its
## unlock rule and can never be driven. Its unlock is still recorded, so the car is there
## when it arrives. docs/GARAGE.md.

## How the slot unlocks. The milestone thresholds are in ProgressionTuning
## (unlock_leg_milestone, unlock_daily_streak_days, unlock_lifetime_threads).
const UNLOCK_START := &"start"
const UNLOCK_LEVEL := &"level"
const UNLOCK_LEG := &"leg"
const UNLOCK_COAST := &"coast"
const UNLOCK_DAILY_STREAK := &"daily_streak"
const UNLOCK_THREADS := &"threads"
const UNLOCKS: Array[StringName] = [UNLOCK_START, UNLOCK_LEVEL, UNLOCK_LEG, UNLOCK_COAST,
		UNLOCK_DAILY_STREAK, UNLOCK_THREADS]

## Stable id (the save keys the unlock and the look by it). A real car's slot id is its
## CarDef.id.
@export var id: StringName = &""
## The CarDef (data/cars/<id>.tres); empty = a placeholder slot.
@export_file("*.tres") var car_path: String = ""
@export var unlock: StringName = UNLOCK_LEVEL
## The driver level that unlocks it (unlock == level).
@export var unlock_level: int = 1


## A real car (not a placeholder).
func has_car() -> bool:
	return not car_path.is_empty()


func car() -> CarDef:
	return load(car_path) as CarDef if has_car() else null
