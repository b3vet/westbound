class_name LoopMapDef
extends Resource
## The multiplayer loop's design data (N3.1): the seed, the section templates, the
## feature rules and the hand edits. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → The loop
## map ("built once from the existing road generator with a fixed seed, hand-tuned in an
## editor tool, and frozen as map data"). docs/LOOP_MAP.md.
##
## This file (data/maps/loop_v1.tres) is also the client scene data: LoopGen regenerates
## the whole loop from it deterministically (centreline, lanes, tunnels, sectors, ramps,
## elevated zones), and the props stream is derived from `map_seed`. The road-space file
## (loop_v1.json) is exported from the generated loop (LoopExport).
##
## Edits (`edits`, written by the loop editor) override single generated values by key:
##   bend/<section>/<i>/radius_m, bend/<section>/<i>/deflection_deg, bend/<section>/<i>/transition_m
##   straight/<section>/<i>/weight
##   pvi/<i>/raise_m, pvi/<i>/radius_m            (crest heights, vertical curve radii)
##   tunnel/<i>/portal_m, tunnel/<i>/length_m     (portal relative to its section's start)
##   lanes/<section>/change_m                     (lane-count change relative to the section start)
##   sector/<k>/offset_m                          (from the even spacing; sector 3 is the bridge)
##   ramp/<p>/off_m                               (off-ramp start relative to its section)
##   closure/<section>/start_m                    (road works zone start relative to its section)
## The generator draws every random value first and then applies the edit, so an edit
## never shifts another value's draw.

const DEFAULT_PATH := "res://data/maps/loop_v1.tres"

@export var map_id: StringName = &"loop_v1"
## Road-space file format (loop_v1.json "format_version").
@export var format_version: int = 1
## LoopGen's algorithm version (bump when the same data would generate differently).
@export var generator_version: int = 1
@export var map_seed: int = 1

@export_group("Shape")
@export var section_length_m: float = 5000.0
## World heading at s = 0 (degrees, right-positive, 0 = due west, the sun's azimuth).
@export var start_heading_deg: float = 122.0
@export var sections: Array[LoopSectionDef] = []
## The two sections whose first and last straights trade length to close the loop.
@export var closure_sections: PackedInt32Array = [1, 4]
@export var straight_min_m: float = 100.0
@export var straight_weight_jitter_frac: float = 0.2
@export var closure_solve_tolerance_m: float = 1e-9
@export var closure_max_iterations: int = 8

@export_group("Profile")
@export var crest_grade_max_pct: float = 4.5
## A vertical curve takes at most this share of the tangents either side of its PVI.
@export var vertical_curve_fit_frac: float = 0.9

@export_group("Tunnels")
@export var tunnel_section: int = 1
## Per tunnel: portal window (relative to the section start), length range, and lanes
## inside (0 = the section's lanes; fewer = a narrowing with a taper before the portal).
@export var tunnel_portal_min_m: PackedFloat64Array = []
@export var tunnel_portal_max_m: PackedFloat64Array = []
@export var tunnel_length_min_m: PackedFloat64Array = []
@export var tunnel_length_max_m: PackedFloat64Array = []
@export var tunnel_lanes: PackedInt32Array = []

@export_group("Sectors")
@export var sector_count: int = 6
## s of the start/finish gantry (sector 0); the others follow every L / sector_count.
@export var start_finish_s_m: float = 0.0
## Landmark style per sector gantry (BiomeDef.LANDMARK_*).
@export var sector_styles: Array[StringName] = []
## The sector whose gantry is the suspension bridge (must be in the coast).
@export var bridge_sector: int = 3
@export var bridge_section: int = 2
@export var spawn_after_gantry_m: float = 150.0
## Tunnels, ramps, lane changes and road works keep this far from a sector gantry.
@export var gantry_clearance_m: float = 250.0

@export_group("Ramps")
## One on/off ramp pair per entry: its section and the window (relative to its start).
@export var ramp_sections: PackedInt32Array = []
@export var ramp_window_start_m: PackedFloat64Array = []
@export var ramp_window_end_m: PackedFloat64Array = []
@export var off_ramp_length_m: float = 250.0
@export var on_ramp_length_m: float = 300.0
## From the off-ramp's end to the on-ramp's start.
@export var ramp_pair_gap_m: float = 700.0
## "Straight-ish": the road's radius stays above this along both ramps.
@export var ramp_min_radius_m: float = 2000.0
@export var placement_step_m: float = 10.0
## Tunnels, lane changes and road works keep this far from a ramp.
@export var feature_margin_m: float = 60.0

@export_group("Road works")
## One toggleable closure zone per section (the server switches it on for a few laps).
@export var closure_length_m: float = 300.0
@export var closure_taper_m: float = 80.0
@export var closure_lanes: int = 1
@export var closure_window_start_m: float = 200.0
@export var closure_window_end_m: float = 4700.0

@export_group("Elevated")
@export var elevated_section: int = 3
@export var elevated_start_m: float = 700.0
@export var elevated_end_m: float = 4300.0

@export_group("Validation")
## The handoff's section length ("5 km" each) the sections are checked against.
@export var spec_section_length_m: float = 5000.0
@export var length_min_m: float = 24000.0
@export var length_max_m: float = 26000.0
@export var section_length_tolerance_frac: float = 0.1
@export var sector_spacing_tolerance_frac: float = 0.15
@export var closure_max_error_m: float = 0.001
@export var heading_max_error_rad: float = 1e-6

@export_group("Edits")
@export var edits: Dictionary[String, float] = {}


static func load_default() -> LoopMapDef:
	return load(DEFAULT_PATH) as LoopMapDef
