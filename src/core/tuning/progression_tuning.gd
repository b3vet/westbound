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

@export_group("Driver level and XP (WP8.2, docs/GARAGE.md)")
## XP per banked point ("Lifetime banked score feeds a driver level").
@export var xp_per_point: float = 1.0
## Modes whose runs earn XP and count toward the lifetime threads.
@export var xp_modes: Array[StringName] = [&"journey", &"daily", &"loop"]
## Modes whose runs count for the road milestones (reach leg N, reach the coast): the
## procedural journey road (loop practice's sectors are not legs).
@export var milestone_modes: Array[StringName] = [&"journey", &"daily"]
## Total XP to reach level L: level_xp_base * (L - 1) ^ level_xp_exponent.
@export var level_xp_base: int = 5000
@export var level_xp_exponent: float = 1.8
@export var max_level: int = 50
## The garage's roster, paints and rims (GarageCatalog).
@export_file("*.tres") var garage_catalog_path: String = "res://data/cars/garage.tres"

@export_group("Garage turntable (WP8.2, visual only)")
## The turntable's idle spin (degrees per second) and where it starts (0 = nose to camera).
@export var turntable_spin_deg_s: float = 14.0
@export var turntable_start_yaw_deg: float = 215.0
## A drag on the turntable spins the car (degrees per canvas px).
@export var turntable_drag_deg_per_px: float = 0.45
## Camera: distance from the axis, height, look-at height, vertical field of view.
@export var turntable_camera_distance_m: float = 8.2
@export var turntable_camera_height_m: float = 2.3
@export var turntable_look_height_m: float = -0.35
@export var turntable_fov_deg: float = 30.0
## The disc: radius, thickness, and its colours (sRGB, lit by the sky's sun).
@export var turntable_disc_radius_m: float = 2.85
@export var turntable_disc_height_m: float = 0.14
@export var turntable_disc_segments: int = 48
@export var turntable_disc_color: Color = Color(0.16, 0.16, 0.19)
@export var turntable_ring_color: Color = Color(0.46, 0.44, 0.5)
@export var turntable_ring_frac: float = 0.93
## Render resolution cap (physical px per canvas px) for the turntable's viewport.
@export var turntable_max_pixel_scale: float = 2.0

@export_group("Garage screen (WP8.2)")
## The item list's width (canvas px at 100 % text; grows with the text size) and its columns.
@export var garage_list_width_px: float = 540.0
@export var garage_car_columns: int = 2
@export var garage_paint_columns: int = 3
@export var garage_rim_columns: int = 2
## Label sizes (px at 100 %): list items, the car name under the turntable.
@export var garage_item_font_px: int = 20
@export var garage_name_font_px: int = 40
## The XP bar's height (px) and the paint swatch chip's width share of an item.
@export var garage_xp_bar_px: float = 6.0
@export var garage_swatch_frac: float = 0.22
## The driver-level block in the garage's header (px at 100 %).
@export var garage_level_width_px: float = 250.0
## Paint names in the list (px at 100 %; three columns with the chip).
@export var garage_paint_font_px: int = 17
