class_name VehicleType
extends Resource
## A kind of road vehicle, usable by AI or (Car Hopper) by the player.
## Spec: Driver types (vehicles, truck 16 m, bus 12 m, tall vans, narrow bikes);
## Traffic roster; Hooks to build in v1 ("per-type physics profiles: mass, grip,
## lane-change time, shove strength"). Files: data/vehicle_types/<id>.tres.
## TrafficState.type_id indexes the loaded list of these (order fixed by the registry).
## Defaults below are neutral placeholders (not in spec); every data file sets its own values.

@export var id: StringName = &""
@export var display_name: String = ""

@export_group("Dimensions (visual body; collision box is inset by LivesTuning.collision_inset_m)")
@export var length_m: float = 4.6
@export var width_m: float = 1.85
@export var height_m: float = 1.5
## Tall vehicles (trucks, buses, vans) block sightlines.
@export var blocks_sightlines: bool = false
@export var is_motorbike: bool = false

@export_group("Physics profile")
@export var mass_kg: float = 1500.0
@export var grip_scale: float = 1.0
## Scales lane-change move time (and, when player-driven, the lane-change curve).
@export var lane_change_time_scale: float = 1.0
## Car Hopper: how hard this vehicle shoves traffic aside (0 = none; a bus is high).
@export var shove_strength: float = 0.0
## Car Hopper: fragile vehicles degrade faster.
@export var durability: float = 1.0

@export_group("Traffic")
## DriverProfile ids that may drive this type (Hesitant: any car).
@export var allowed_profiles: Array[StringName] = []
## Model variants (pooled per model; color per instance).
@export var model_scene_paths: PackedStringArray = []
