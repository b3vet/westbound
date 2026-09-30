class_name SetPieceDef
extends Resource
# lint: not-sim data schema; defaults are placeholders overwritten by data/set_pieces/*.tres
## A traffic set piece. Spec: Traffic director → set-piece table; fairness rules 4
## and 6. Files: data/set_pieces/<id>.tres (WP6.2: truck_wall, rolling_roadblock;
## WP6.3: merge_zone, road_works, slalom, convoy, tunnel_squeeze, toll_gantry). The
## framework: SetPieceSource, docs/SET_PIECES.md. Spec values:
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
## What puts a piece on the road (WP6.3): a wave peak (the director's pick), or a road
## feature it belongs to (a road tunnel; a checkpoint of `checkpoint_style`).
enum Trigger { PEAK, TUNNEL, CHECKPOINT }

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

@export_group("Zone (WP6.3)")
## Road-anchored pieces (merge zone, road works, tunnel squeeze, toll gantry) have a
## zone fixed on the road: [zone start, zone end]. Warnings count down to the zone start
## (plus warning_anchor_m: the toll gantry's signs count to its checkpoint), it starts
## when the player is start_distance_m from it and ends when the player is end_margin_m
## past its end (never by time, approach or an empty formation). It may have no
## vehicles; vehicles it has are planned by the meeting map to be met zone_meet_m into
## the zone, in the batch where that falls.
@export var anchored: bool = false
@export var trigger: Trigger = Trigger.PEAK
## Its road hooks (lane counts, rail gaps, signs, cones) must be decided beyond the view,
## the road chunks and the signs: the zone start is placed at least this far ahead of the
## player, and waited for until it is no further than schedule_lead_max_m.
@export var schedule_lead_min_m: float = 1400.0
@export var schedule_lead_max_m: float = 2200.0
## Trigger TUNNEL / CHECKPOINT: the chance a matching feature gets the piece (seeded per
## feature), and the checkpoint landmark style that triggers it.
@export var feature_chance_pct: float = 100.0
@export var checkpoint_style: StringName = &""
## Fewest meters of road tunnel for a tunnel-triggered piece.
@export var tunnel_min_length_m: float = 300.0
## Most lanes the piece is laid out on (0 = any): the merge zone adds one.
@export var max_lanes: int = 0
## Where the player should meet the piece's vehicles, into the zone (m).
@export var zone_meet_m: float = 100.0
## The warnings count down to the zone start + this (the toll gantry: its checkpoint).
@export var warning_anchor_m: float = 0.0
## Piece vehicles (anchored pieces, slalom rows, convoy line): how many, and the free
## gap kept between consecutive ones of a line beyond IDM's s* (m).
@export var vehicles_min: int = 0
@export var vehicles_max: int = 0
@export var vehicle_extra_gap_m: float = 0.0
## Formation keeping (slalom, convoy, tunnel squeeze): each vehicle's desired speed is
## the piece's speed + gain x its lag behind its formation slot, within +- the limit.
@export var formation_gain_per_s: float = 0.2
@export var formation_limit_kmh: float = 8.0

@export_group("Merge zone (WP6.3)")
## "On-ramp adds traffic from the right, then the right lane ends": at the ramp nose
## (the zone start) the road gains a lane on the right (ramp_join_taper_m), the
## acceleration lane, which ends accel_lane_m later (lane_end_taper_m). The on-ramp
## ribbon comes in from the right over ramp_length_m before the nose, ramp_gap_m beyond
## the guardrail at the nose, curving away (ramp_slope, ramp_curve_per_m: d = slope x +
## curve x^2 at x before the nose); the mainline rail is open over the join taper.
@export var ramp_length_m: float = 220.0
@export var ramp_gap_m: float = 0.6
@export var ramp_slope: float = 0.06
@export var ramp_curve_per_m: float = 0.0003
@export var ramp_join_taper_m: float = 40.0
@export var accel_lane_m: float = 420.0
@export var lane_end_taper_m: float = 120.0
## Ramp traffic: cars in the acceleration lane between ramp_min_speed_kmh and
## ramp_speed_kmh (below the minimum speed: they come off the ramp), paced to be
## ramp_goal_frac into the lane when the player is ramp_go_s from reaching them, held
## out of the mandatory merge until then; then they speed up to the piece's speed and merge.
@export var ramp_speed_kmh: float = 60.0
@export var ramp_min_speed_kmh: float = 10.0
@export var ramp_goal_frac: float = 0.3
@export var ramp_go_s: float = 7.0

@export_group("Road works (WP6.3)")
## "One or two lanes closed by cones and a barrier; traffic merges": lanes_closed_min ..
## lanes_closed_max lanes on one side (the right on right_side_pct of pieces, else the
## left), never more than lanes - works_min_open_lanes. From the zone start the cones
## taper across the closed lanes over works_taper_m per lane, run works_length_min_m ..
## works_length_max_m along the open lanes' edge, then taper back over works_end_taper_m.
@export var right_side_pct: float = 70.0
@export var works_min_open_lanes: int = 1
@export var works_taper_m: float = 70.0
@export var works_length_min_m: float = 220.0
@export var works_length_max_m: float = 360.0
@export var works_end_taper_m: float = 40.0
@export var cone_spacing_taper_m: float = 5.0
@export var cone_spacing_m: float = 10.0
## The cone line stands this far inside the closed lane from the lane line (m).
@export var cone_line_inset_m: float = 0.3
## A cone's square footprint (hit box) and the barrier: a line of barrier segments down
## the middle of the closed lanes from barrier_start_m after the taper, barrier_length_m
## long, barrier_width_m wide (hit box). The arrow board stands in the outermost closed
## lane arrow_board_after_m after the zone start.
@export var cone_size_m: float = 0.4
@export var barrier_start_m: float = 25.0
@export var barrier_length_m: float = 90.0
@export var barrier_width_m: float = 0.6
@export var arrow_board_after_m: float = 12.0
@export var arrow_board_width_m: float = 2.2
@export var arrow_board_length_m: float = 3.6
## The arrow board flashes: this many flashes per second (the view; not simulation).
@export var arrow_flash_hz: float = 1.0

@export_group("Slalom (WP6.3)")
## "Staggered cars across lanes forming an S-line of gaps": rows of cars across all lanes
## but one, the open lane moving one lane per row and turning at the road's edges, rows
## row_gap_m apart bumper to bumper (never under IDM's s*).
@export var row_gap_m: float = 45.0

@export_group("Convoy (WP6.3)")
## "A slow line of same-color vehicles with hazards on, honking": one line in the right
## lane (or the next one, next_lane_pct of the time on next_lane_min_lanes+ lanes), one drawn vehicle
## repeated (type, model, color), hazards on. While the player is within honk_range_m,
## one of them honks every honk_interval_min_s .. honk_interval_max_s.
@export var next_lane_pct: float = 30.0
@export var next_lane_min_lanes: int = 3
@export var honk_range_m: float = 120.0
@export var honk_interval_min_s: float = 2.0
@export var honk_interval_max_s: float = 5.0

@export_group("Tunnel squeeze (WP6.3)")
## "Two lanes, tighter traffic, light change at entry and exit": in a road tunnel (its
## two lanes), every vehicle's IDM headway x headway_scale inside, and a platoon of the
## piece's cars staggered over both lanes (row_gap_m apart) met zone_meet_m in.
@export var headway_scale: float = 0.7
## The light change (every road tunnel, TunnelLight): ambient and sun light x (1 -
## tunnel_dark_frac) inside, the lamp strips' street-lamp ramp at least tunnel_lamp_on,
## ramped over tunnel_light_ramp_m at the portals.
@export var tunnel_dark_frac: float = 0.55
@export var tunnel_lamp_on: float = 1.0
@export var tunnel_light_ramp_m: float = 60.0

@export_group("Toll gantry (WP6.3)")
## "Booth lanes on the sides, open express lanes in the middle": the outermost lane on
## each side is a booth lane (only the right one under left_booth_min_lanes); over [checkpoint -
## booth_before_m, checkpoint + booth_after_m] every vehicle in a booth lane slows to
## booth_speed_kmh (smoothly, at its comfortable deceleration, before it). The piece's
## booth cars (vehicles_min .. vehicles_max per booth lane) are met at the booths.
@export var booth_before_m: float = 180.0
@export var booth_after_m: float = 60.0
@export var booth_speed_kmh: float = 50.0
## A left booth lane (lane 0) only from this many lanes on (else only the right one).
@export var left_booth_min_lanes: int = 3
## Booth traffic keeps its booth lane (no discretionary lane change) while slower than
## booth_exit_kmh, from the approach to booth_keep_after_m past the booths: it does not
## pull out into the express lanes at booth speed (they stay open at speed).
@export var booth_keep_after_m: float = 400.0
@export var booth_exit_kmh: float = 110.0


## The piece's matched speed (m/s), floored at `min_speed_mps`.
func speed_mps(min_speed_mps: float) -> float:
	return maxf(Units.kmh_to_mps(speed_kmh), min_speed_mps)
