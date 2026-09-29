class_name CliffDef
extends Resource
## Rock walls along the road (canyon pass). Spec: World → Biomes ("Canyon pass:
## cliffs, tunnels, more curves and crests"), World → Road (flat-shaded low-poly,
## vertex colours; the roadside rhythm). docs/BIOMES.md.
##
## Built into the road chunks like the guardrails (RoadChunkMesher, one surface, no
## extra draw call), so the walls follow every curve and grade exactly. Per mesh row
## and side, the wall is a cross-section profile of faces from its foot outward
## (`profile_x_m`, `profile_h_m`), jittered by seeded noise along s so the faces are
## faceted, in horizontal colour bands (strata, `band_colors`, one per face).
##
## Runs: s is cut into runs of `run_length_m`; each run on each side is a wall with
## `presence_*_frac` (a seeded hash of the run: no scan, no order dependence). A wall
## rises from the ground over `ramp_m` where the run before it is open and falls where
## the run after is. Road tunnels are always framed by walls (`tunnel_frame_m`). Walls
## fall away `checkpoint_clear_m` around a checkpoint (its landmark) and, on the right,
## `sign_clear_m` around a checkpoint warning sign.

## Across the wall from its foot (m outward) and the height there (m); same size.
@export var profile_x_m: PackedFloat64Array = [0.0, 2.0, 5.0, 9.0, 16.0, 30.0, 48.0]
@export var profile_h_m: PackedFloat64Array = [-0.3, 9.0, 17.0, 25.0, 29.0, 32.0, 27.0]
## One colour (sRGB) per face (profile size - 1), foot to top.
@export var band_colors: PackedColorArray = []
## Scenery line (guardrail face + prop clearance) to the wall's foot.
@export var setback_m: float = 3.0
## Seeded noise along s: height jitter (share of each point's height) and lateral
## jitter (m) of the profile points past the foot, over noise cells this long.
@export var height_jitter_frac: float = 0.22
@export var offset_jitter_m: float = 1.6
@export var noise_cell_m: float = 16.0
## Runs along s, and the chance a run is a wall on each side.
@export var run_length_m: float = 300.0
@export var presence_right_frac: float = 0.65
@export var presence_left_frac: float = 0.55
## Length over which a wall rises from (or falls to) the ground.
@export var ramp_m: float = 70.0
## No wall within this of a checkpoint (its landmark) or of a checkpoint warning sign.
@export var checkpoint_clear_m: float = 330.0
@export var sign_clear_m: float = 30.0
## Walls always stand this far either side of a road tunnel (framing its portals).
@export var tunnel_frame_m: float = 160.0


func face_count() -> int:
	return maxi(mini(profile_x_m.size(), profile_h_m.size()) - 1, 0)


## The colour of face `i` (the last band repeats; grey without bands).
func band_color(i: int) -> Color:
	if band_colors.is_empty():
		return Color(0.5, 0.5, 0.5)
	return band_colors[mini(i, band_colors.size() - 1)]
