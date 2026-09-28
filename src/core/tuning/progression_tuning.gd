class_name ProgressionTuning
extends Resource
## Daily Drive ghosts, roster and progression, asset budgets.
## Spec: Modes at launch (ghost), Garage and progression, Modular car convention
## (triangle budgets), Art pipeline, Traffic roster. Saved as data/tuning/progression.tres.

@export_group("Daily Drive")
@export var ghost_sample_hz: int = 20

@export_group("Roster and progression")
@export var roster_size: int = 8
@export var cars_unlocked_at_start: int = 1
@export var unlock_leg_milestone: int = 4
@export var unlock_daily_streak_days: int = 7
@export var unlock_lifetime_threads: int = 100
@export var achievement_count: int = 25

@export_group("Asset budgets (tests/check_car_assets.gd)")
@export var player_body_tris_lod0: int = 15000
@export var player_body_tris_lod1: int = 5000
@export var player_interior_tris: int = 5000
@export var traffic_tris_lod0: int = 3000
@export var traffic_tris_lod1: int = 1000
@export var rim_tris: int = 800
@export var palette_atlas_px: int = 256
@export var palette_color_count: int = 30
@export var traffic_model_count: int = 14
