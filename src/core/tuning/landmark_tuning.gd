class_name LandmarkTuning
extends Resource
# lint: not-sim tuning resource for the landmark world system (render-side)
## Checkpoint landmarks and warning signs (WP5.3). Spec: Core loop → Legs and
## checkpoints ("ending at a checkpoint landmark: express toll gantry, suspension
## bridge, big sign gantry, or tunnel portal"; "warning signs announce each checkpoint
## at 1 km and 500 m"), World → Checkpoint landmarks, Night lighting (retro-reflective
## signs), Performance budget. Saved as data/tuning/landmarks.tres. Visual only: the
## checkpoint line and the warning distances themselves come from the road features
## (LegsTuning), nothing here feeds back into the simulation.
##
## Until the orchestrator adds `Tuning.landmarks`, load it with LandmarkTuning.load_default().
## Lateral positions are measured outward from the road's own edges (guardrail_d,
## median_barrier_d), so the builds follow the lane count at the checkpoint.

const PATH := "res://data/tuning/landmarks.tres"

@export_group("Placement and pools")
## Features are re-queried each time the focus moves this far.
@export var update_step_m: float = 25.0   # not in spec
## A landmark or sign is recycled once all of it is this far behind the focus.
@export var keep_behind_m: float = 60.0   # not in spec: the chase camera sits 7 m back
## Placed this far beyond the view distance, so it never pops in inside the fog.
@export var place_margin_m: float = 100.0   # not in spec
## Pooled builds per landmark kind (legs are 3.5 km apart: one is ever in view).
@export var landmarks_per_kind_count: int = 2   # not in spec
## Pooled warning signs (two per checkpoint).
@export var sign_pool_count: int = 4   # not in spec
## Nothing but a landmark's overhead parts may stand between the median barrier and a
## guardrail, and those only above this height.
@export var overhead_clearance_m: float = 5.5   # not in spec: common motorway clearance
## Long builds bend along the road through stations this far apart (chord error
## < 1 cm at R 1,200 m); geometry along s is split at this length.
@export var bend_station_step_m: float = 8.0   # not in spec

@export_group("Warning signs (right side, 1 km and 500 m)")
## Inner edge of the panel beyond the guardrail.
@export var sign_setback_m: float = 1.0   # not in spec
@export var sign_panel_width_m: float = 8.5   # not in spec: reads at 200 km/h
@export var sign_panel_height_m: float = 3.6   # not in spec
@export var sign_panel_bottom_m: float = 2.2   # not in spec

@export_group("Express toll gantry")
## Top of the gantry beam over both carriageways.
@export var toll_beam_top_m: float = 7.8   # not in spec
@export var toll_beam_height_m: float = 1.3   # not in spec
## Outer columns stand this far beyond each guardrail.
@export var toll_column_offset_m: float = 1.2   # not in spec
@export var toll_lane_panel_width_m: float = 2.8   # not in spec
@export var toll_lane_panel_height_m: float = 1.05   # not in spec
## The header panel on top of the beam (CHECKPOINT and the next leg).
@export var toll_header_height_m: float = 2.4   # not in spec
## Booths and their canopies sit beyond each guardrail.
@export var toll_booth_width_m: float = 3.2   # not in spec
@export var toll_booth_length_m: float = 5.0   # not in spec
@export var toll_booth_height_m: float = 2.8   # not in spec
@export var toll_canopy_height_m: float = 5.0   # not in spec
@export var toll_canopy_width_m: float = 9.0   # not in spec
@export var toll_canopy_length_m: float = 16.0   # not in spec

@export_group("Suspension bridge")
## Tower to tower, centred on the checkpoint line.
@export var bridge_span_m: float = 360.0   # not in spec
@export var bridge_tower_height_m: float = 54.0   # not in spec
## Inner face of each tower leg beyond the guardrail.
@export var bridge_tower_offset_m: float = 2.0   # not in spec
@export var bridge_tower_leg_width_m: float = 2.6   # not in spec
## The lowest crossbeam (the top one sits just under the saddles).
@export var bridge_crossbeam_low_m: float = 18.0   # not in spec
## Height of the main cables at mid-span (they sag from the tower tops).
@export var bridge_cable_low_m: float = 6.0   # not in spec
@export var bridge_suspender_spacing_m: float = 12.0   # not in spec
## Backstays run from each tower top down to an anchorage this far outside the span.
@export var bridge_backstay_m: float = 90.0   # not in spec

@export_group("Big sign gantry")
@export var sign_gantry_top_m: float = 8.6   # not in spec
@export var sign_gantry_upright_offset_m: float = 1.5   # not in spec
## Panels hang from the truss; their bottoms stay above the clearance.
@export var sign_gantry_panel_height_m: float = 3.8   # not in spec

@export_group("Tunnel portal")
## The portal is at the checkpoint line; the shell runs this far past it.
@export var tunnel_length_m: float = 120.0   # not in spec
## Underside of the roof slab.
@export var tunnel_clearance_m: float = 7.2   # not in spec
## Inner face of the walls beyond each guardrail.
@export var tunnel_wall_offset_m: float = 0.6   # not in spec
## Top of the earth over the shell. Above the median light poles (10.35 m) so they
## never poke out of the hill (the roadside does not skip landmark ranges yet).
@export var tunnel_cover_top_m: float = 11.6   # not in spec
## The hill falls from the cover top to the ground over this width beyond the walls.
@export var tunnel_hill_width_m: float = 26.0   # not in spec
## Lamp strips along the inside walls, one lamp every this many metres.
@export var tunnel_lamp_spacing_m: float = 8.0   # not in spec

@export_group("Sign text (baked atlas)")
@export var text_atlas_width_px: int = 1024   # not in spec
@export var text_atlas_height_px: int = 1024   # not in spec
## Atlas pixels per text line (the glyphs are rasterised to fit).
@export var text_row_px: int = 48   # not in spec
## Empty pixels around every text region (keeps mipmaps from bleeding).
@export var text_gutter_px: int = 6   # not in spec
## Capital height as a share of the line strip on the sign.
@export var text_cap_height_frac: float = 0.62   # not in spec
## Horizontal margin inside a line strip, as a share of its height.
@export var text_side_margin_frac: float = 0.4   # not in spec

@export_group("Night (retro-reflective faces)")
## Reflector faces glow this much more than the color script's reflector ramp.
@export var retro_emissive_factor: float = 1.6   # not in spec
## ...and the player's fake headlight brightens them this much more than other surfaces.
@export var retro_light_factor: float = 2.5   # not in spec
## By day, a reflective face gets this share of full sunlight whichever way it faces
## (sign sheeting is sky-lit; driving into the sun puts every sign face in shadow).
@export var retro_day_fill_frac: float = 0.55   # not in spec: readability


static func load_default() -> LandmarkTuning:
	return load(PATH) as LandmarkTuning
