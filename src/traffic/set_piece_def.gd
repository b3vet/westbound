class_name SetPieceDef
extends Resource
# lint: not-sim data schema; defaults are placeholders overwritten by data/set_pieces/*.tres
## A traffic set piece. Spec: Traffic director → set-piece table; fairness rules 4
## and 6. Files: data/set_pieces/<id>.tres (WP6.3). Spec values to author there:
##   truck_wall: all lanes but one blocked; warning = silhouettes
##   rolling_roadblock: matched speed across all lanes, a gap opens every few seconds; brake-light ripple
##   merge_zone: on-ramp from the right, then the right lane ends; signs at 500 m and 250 m
##   road_works: 1-2 lanes closed by cones and a barrier; signs at 400 m + flashing arrow board
##   slalom: staggered cars forming an S-line of gaps; no warning needed
##   convoy: slow same-color line, hazards on, honking; visible
##   tunnel_squeeze: two lanes, tighter traffic, light change; tunnel portal
##   toll_gantry: checkpoint landmark, booths at the sides, express lanes in the middle; signs 1 km and 500 m
## Director rules (DirectorTuning): never within blind_window_m after a blind crest or
## bend; decelerations above the 6 m/s^2 clamp only if warned >= set_piece_min_warning_m ahead.
## Defaults below are neutral placeholders (not in spec); every data file sets its own values.

enum Kind { TRUCK_WALL, ROLLING_ROADBLOCK, MERGE_ZONE, ROAD_WORKS, SLALOM, CONVOY, TUNNEL_SQUEEZE, TOLL_GANTRY }
enum Warning { NONE, VISIBLE, SILHOUETTES, BRAKE_RIPPLE, SIGNS, SIGNS_AND_ARROW_BOARD, TUNNEL_PORTAL }

@export var id: StringName = &""
@export var kind: Kind = Kind.SLALOM
@export var display_name: String = ""

@export_group("Warning")
@export var warning: Warning = Warning.NONE
## Distances ahead of the set piece's start where signs stand (m), farthest first.
@export var warning_sign_distances_m: PackedFloat64Array = []

@export_group("Layout")
## Length of the set piece along the road.
@export var length_m: float = 300.0
@export var lanes_closed_min: int = 0
@export var lanes_closed_max: int = 0
## Lanes left open (truck wall: 1). 0 = not constrained.
@export var open_lanes: int = 0
## Lane count forced through the section (tunnel squeeze: 2). 0 = unchanged.
@export var lane_count_override: int = 0
## Right lane ends at the end of the section (merge zone).
@export var drops_right_lane: bool = false
## Participating vehicles get hazards on (convoy).
@export var hazards: bool = false
## May use decelerations above the 6 m/s^2 clamp (requires the >= 300 m warning).
@export var allows_hard_decel: bool = false

@export_group("Director")
@export var min_leg: int = 1
@export var weight: float = 1.0
@export var is_checkpoint_landmark: bool = false
