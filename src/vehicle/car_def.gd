class_name CarDef
extends Resource
## A player car. Spec: Car physics and feel → Car stats; Garage and progression.
## Files: data/cars/<id>.tres. Stats stay within about +-10% across the roster
## (VehicleTuning.car_stat_spread_pct); top speed within VehicleTuning's 240-300 km/h.
## Physics coefficients (drag, rolling resistance, cornering stiffness...) that WP1.5
## derives or needs are added here by WP1.5.
## Defaults below are neutral placeholders (not in spec); every data file sets its own values.

@export var id: StringName = &""
@export var display_name: String = ""
## Modular-convention scene (Car_<name> root, see spec "Modular car convention").
@export var model_scene_path: String = ""

@export_group("Stats")
@export var top_speed_kmh: float = 260.0
## Acceleration stat: 0-200 km/h time. The physics test holds each car to it within 2%.
@export var zero_to_200_s: float = 8.0
@export var braking_mps2: float = 9.0
## Scales the lane-change time targets (0.9-1.1; lower = quicker).
@export var handling_scale: float = 1.0
## Scales the boost meter's full duration (1 = ScoringTuning.boost_full_s).
@export var boost_capacity_scale: float = 1.0

@export_group("Body")
@export var length_m: float = 4.5
@export var width_m: float = 1.9
@export var height_m: float = 1.3
@export var mass_kg: float = 1500.0
@export var gear_count: int = 6

@export_group("Cosmetics")
@export var default_paint: Color = Color(0.9, 0.2, 0.15)
@export var paint_options: PackedColorArray = []
@export var default_rim: StringName = &""
@export var rim_options: Array[StringName] = []


func top_speed_mps() -> float:
	return Units.kmh_to_mps(top_speed_kmh)
