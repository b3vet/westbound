class_name SetPieceDef
extends Resource
# lint: not-sim data schema; defaults are placeholders overwritten by data/set_pieces/*.tres
## A traffic set piece. Spec: Traffic director → set-piece table; fairness rules 4
## and 6. Files: data/set_pieces/<id>.tres (WP6.2: truck_wall, rolling_roadblock;
## WP6.3 the rest). The framework: SetPieceSource, docs/SET_PIECES.md. Spec values:
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
## Events.set_piece_warning(id, distance) fires as the player's distance to the piece's
## rear (a rolling piece moves) comes down to each; a piece first seen closer than the
## first distance warns at once. Visible pieces (silhouettes, brake ripple) use one
## distance: where the warning reads.
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
## Fewest lanes the piece is laid out on (the truck wall needs two: one open).
@export var min_lanes: int = 2

@export_group("Vehicles (WP6.2)")
## Driver profiles the piece's vehicles are drawn from (parallel weights).
@export var profile_ids: Array[StringName] = []
@export var profile_weights: PackedFloat64Array = []
## The matched speed of the piece's vehicles. Never below the minimum speed plus
## DirectorTuning.set_piece_min_speed_margin_kmh (following a piece is always a path).
@export var speed_kmh: float = 110.0
## Rows of vehicles side by side, and the random stagger of each vehicle in its row.
@export var rows: int = 1
@export var row_stagger_m: float = 0.0

@export_group("Lifetime (WP6.2)")
## The piece has started (Events.set_piece_started) when the player is this close to its rear.
@export var start_distance_m: float = 50.0
## The piece ends (its vehicles become ordinary traffic) when the player is this far past
## its front, or this long after it started, whichever is first ...
@export var end_margin_m: float = 30.0
@export var duration_max_s: float = 60.0
## ... or when the player has not reached it this long after it spawned (too slow).
@export var approach_max_s: float = 150.0
## Flow plans nothing within this distance behind the piece's rear and ahead of its
## front in the piece's batch; ahead, lanes slower than the piece are also kept clear as
## far as the piece gains on them in duration_max_s (so the formation holds).
@export var clear_behind_m: float = 60.0
@export var clear_ahead_m: float = 60.0

@export_group("Truck wall (WP6.2)")
## "The open lane shifts slowly": one lane every this often, only while the player is at
## least shift_min_player_gap_m behind the wall (or when no player is near).
@export var shift_interval_s: float = 8.0
@export var shift_min_player_gap_m: float = 60.0
## A shift refused (traffic in the open lane, the player near) is tried again this soon.
@export var shift_retry_s: float = 1.0

@export_group("Rolling roadblock (WP6.2)")
## "A gap opens every few seconds": this long after the last gap closed, one car (never
## the last one's lane) taps its brakes and drops back gap_speed_delta_kmh until it is
## gap_distance_m behind the row, then closes up at the same delta.
@export var gap_interval_s: float = 4.0
@export var gap_distance_m: float = 25.0
@export var gap_speed_delta_kmh: float = 12.0
## A drop or a close-up held up by traffic longer than this ends (the car rejoins the row).
@export var gap_phase_max_s: float = 10.0
## "Brake lights ripple as it forms": lane by lane from the median, one brake tap every
## ripple_step_s, at the first warning.
@export var ripple_step_s: float = 0.25


## The piece's matched speed (m/s), floored at `min_speed_mps`.
func speed_mps(min_speed_mps: float) -> float:
	return maxf(Units.kmh_to_mps(speed_kmh), min_speed_mps)
