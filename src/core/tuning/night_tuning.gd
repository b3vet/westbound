class_name NightTuning
extends Resource
# lint: not-sim render-side tuning resource for the night lighting (no simulation)
## Night lighting numbers (WP5.4). Spec: World → Night lighting (no real lights):
## traffic headlight cones, street-lamp light pools, the player's headlights (a cone
## decal plus the fake-light uniform) and retro-reflective reflectors and signs;
## Core loop → Night; Performance budget (emissive geometry, additive sprites and road
## decals only). Plan decision D8: the player gets a manual high-beam toggle, which
## changes only these visuals (never scoring or traffic). Saved as
## data/tuning/night.tres. Visual only: nothing here feeds back into the simulation.
##
## Light colors and decal looks live in the materials (assets/shaders/materials/
## light_cone.tres, traffic_cone.tres, lamp_pool.tres). Brightness always follows the
## color script's emissive ramps (headlight, street lamp), so every node here is
## hidden while its ramp is below `visible_min_ramp`.
##
## Until the orchestrator adds `Tuning.night`, load it with NightTuning.load_default().

const PATH := "res://data/tuning/night.tres"

## Night nodes are hidden (no draw call) while their color-script ramp is below this.
@export var visible_min_ramp: float = 0.05   # not in spec: ramps start at golden hour

@export_group("Player headlights: fake light")
## Fake-light strength (x the color script's headlight ramp) with low and high beams.
@export var low_beam_gain: float = 1.0   # not in spec
@export var high_beam_gain: float = 1.35   # not in spec: D8 manual high beams
## Reach of the fake light's distance falloff (1 = the shader's base falloff). The run
## passes it as the length of wb_player_light_dir (see world_common.gdshaderinc).
@export var low_beam_reach: float = 1.0   # not in spec
@export var high_beam_reach: float = 2.0   # not in spec
## The beam aims this far below the car's forward axis.
@export var beam_pitch_deg: float = 1.5   # not in spec
## Lamp height and setback used when the car model has no headlight nodes.
@export var fallback_lamp_height_m: float = 0.65   # not in spec: a sports car's lamps

@export_group("Player headlights: cone decal")
## The cone starts this far ahead of the lamps and reaches `*_length_m` ahead of them,
## widening from the near to the far width. It follows the road in `cone_segments`.
@export var cone_start_m: float = 0.4   # not in spec
@export var low_cone_length_m: float = 38.0   # not in spec
@export var high_cone_length_m: float = 85.0   # not in spec
@export var cone_near_width_m: float = 2.2   # not in spec: about the car's width
@export var low_cone_far_width_m: float = 14.0   # not in spec: ~3 lanes at the far end
@export var high_cone_far_width_m: float = 16.0   # not in spec
## Brightness of the cone decal with high beams (x the material's strength).
@export var high_cone_strength: float = 1.3   # not in spec
@export var cone_segments: int = 8   # not in spec: enough to follow grades and curves
## Height above the road surface (avoids z-fighting with the road and markings).
@export var cone_lift_m: float = 0.05   # not in spec

@export_group("Traffic headlight cones")
## Most cones drawn per quality tier (QualityTuning.tier_names order: low, medium,
## high): the nearest vehicles with headlights on, on either carriageway.
@export var traffic_cones_per_tier: PackedInt32Array = [6, 10, 16]   # not in spec: budget
## Only vehicles within this distance along the road (ahead or behind) get a cone.
@export var traffic_cone_range_m: float = 260.0   # not in spec: well inside the fog
## Cones fade out over the last part of the range (no pop at the edge).
@export var traffic_cone_fade_m: float = 60.0   # not in spec
@export var traffic_cone_start_m: float = 0.3   # not in spec
@export var traffic_cone_length_m: float = 26.0   # not in spec
@export var traffic_cone_near_width_m: float = 1.8   # not in spec
@export var traffic_cone_far_width_m: float = 7.5   # not in spec
@export var traffic_cone_lift_m: float = 0.04   # not in spec

@export_group("Street-lamp light pools")
## A pool lies under every lamp head (RoadTuning.light_pole_spacing_m, the median
## poles' twin heads at +-pool_d_m) from pool_behind_m behind the player to
## pool_ahead_m ahead.
@export var pool_ahead_m: float = 420.0   # not in spec: fades into the night fog
@export var pool_behind_m: float = 60.0   # not in spec: behind the far chase camera
## Lateral offset of the pool centers (the light pole's head, build_props.gd).
@export var pool_d_m: float = 4.0   # not in spec: head at 3.05 m, light thrown outward
## Pool size along the road and across it.
@export var pool_length_m: float = 22.0   # not in spec
@export var pool_width_m: float = 12.0   # not in spec
@export var pool_lift_m: float = 0.03   # not in spec


## Loads data/tuning/night.tres (until `Tuning.night` exists).
static func load_default() -> NightTuning:
	return load(PATH) as NightTuning


## The traffic cone cap for a quality tier index (clamped to the table).
func traffic_cones_for_tier(tier_index: int) -> int:
	if traffic_cones_per_tier.is_empty():
		return 0
	return traffic_cones_per_tier[clampi(tier_index, 0, traffic_cones_per_tier.size() - 1)]


## Fake-light strength gain for the beam.
func beam_gain(high: bool) -> float:
	return high_beam_gain if high else low_beam_gain


## Fake-light reach for the beam.
func beam_reach(high: bool) -> float:
	return high_beam_reach if high else low_beam_reach


func cone_length_m(high: bool) -> float:
	return high_cone_length_m if high else low_cone_length_m


func cone_far_width_m(high: bool) -> float:
	return high_cone_far_width_m if high else low_cone_far_width_m
