class_name SetPieceLook
extends Resource
## The look of the set pieces' props (WP6.3): signs, cones, barriers, the arrow board,
## the on-ramp and its gore, the toll lane legends. Spec: Traffic → set-piece table
## (signs, cones and a barrier, flashing arrow board, on-ramp); World → Night lighting
## ("reflectors and signs: retro-reflective material"); Art pipeline (palette, flat
## shading). Data: data/set_pieces/look.tres. Colors are WBPalette names. Where the
## props stand (their s and d) is gameplay and lives in the SetPieceDefs.

const PATH := "res://data/set_pieces/look.tres"

@export_group("Signs")
## Panel size (m), the panel's bottom above the road, the setback beyond the guardrail.
@export var sign_width_m: float = 3.2
@export var sign_height_m: float = 1.8
@export var sign_bottom_m: float = 1.4
@export var sign_setback_m: float = 1.2
@export var sign_post_width_m: float = 0.12
@export var sign_depth_m: float = 0.08
## Border band around the face (m); text lines: the big line's share of the face height.
@export var sign_border_m: float = 0.08
@export var sign_big_line_frac: float = 0.52
## Face and border colors per kind (road works, merge zone), lettering.
@export var works_sign_color: StringName = &"brand_orange"
@export var merge_sign_color: StringName = &"hazard_yellow"
@export var sign_border_color: StringName = &"ink"
@export var sign_ink_color: StringName = &"ink"
@export var post_color: StringName = &"steel"

@export_group("Cones")
@export var cone_height_m: float = 0.75
@export var cone_base_m: float = 0.42
@export var cone_top_m: float = 0.08
## The retro-reflective collar: from / to (share of the height).
@export var cone_band_lo_frac: float = 0.45
@export var cone_band_hi_frac: float = 0.7
@export var cone_sides: int = 6
@export var cone_color: StringName = &"brand_orange"
@export var cone_band_color: StringName = &"white"
## Cones drawn at most (one MultiMesh).
@export var max_cones: int = 160

@export_group("Barrier and arrow board")
@export var barrier_height_m: float = 0.9
@export var barrier_segment_m: float = 3.8
@export var barrier_gap_m: float = 0.2
@export var barrier_color: StringName = &"white"
@export var barrier_stripe_color: StringName = &"reflector_red"
@export var trailer_height_m: float = 0.9
@export var board_bottom_m: float = 1.6
@export var board_height_m: float = 1.5
@export var board_depth_m: float = 0.15
@export var board_color: StringName = &"ink"
@export var board_frame_color: StringName = &"hazard_yellow"
@export var trailer_color: StringName = &"brand_orange"
@export var arrow_color: StringName = &"reflector_amber"
## The arrow's lamp brightness when on / off (x its albedo, whatever the time of day).
@export var arrow_on_gain: float = 2.4
@export var arrow_off_gain: float = 0.12

@export_group("On-ramp and gore")
## The ramp's paved width (a lane + its edge strips), edge line width, its rail.
@export var ramp_width_m: float = 4.6
@export var ramp_line_width_m: float = 0.15
@export var ramp_segment_m: float = 6.0
@export var rail_height_m: float = 0.75
@export var rail_depth_m: float = 0.3
@export var gore_stripe_every_m: float = 6.0
@export var gore_stripe_width_m: float = 0.5
@export var attenuator_length_m: float = 3.0
@export var attenuator_width_m: float = 0.9
@export var attenuator_height_m: float = 0.9
@export var attenuator_color: StringName = &"hazard_yellow"
@export var attenuator_stripe_color: StringName = &"ink"

@export_group("Toll legends")
## Painted words in the booth and express lanes, this far before the checkpoint.
@export var legend_before_m: float = 110.0
@export var legend_length_m: float = 9.0
@export var legend_width_frac: float = 0.7

@export_group("Text atlas")
@export var atlas_width_px: int = 1024
@export var atlas_height_px: int = 256
## Surfaces are lifted this far off the road and the verge (no z-fighting with the road
## mesh at a distance), and their paint (lines, gore stripes, legends) as far again.
@export var lift_m: float = 0.08


static func load_default() -> SetPieceLook:
	return load(PATH) as SetPieceLook
