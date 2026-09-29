class_name RoadWorksPiece
extends SetPieceSource.Controller
## Road works (WP6.3). Spec: Traffic → Traffic director, set-piece table: "Road works |
## One or two lanes closed by cones and a barrier; traffic merges | Signs 400 m ahead,
## flashing arrow board"; World → Road ("tunnels and road works drop to 2"); Lives →
## what counts as a hit (roadside objects). docs/SET_PIECES.md.
##
## Road-anchored, no vehicles of its own: ordinary traffic merges out of the closed
## lanes through the sim's lane closures (telegraphed, no-ambush, waiting at the end of
## the lane when there is no gap). setup_zone() draws (seeded) how many lanes close
## (lanes_closed_min .. lanes_closed_max, leaving works_min_open_lanes) and on which side,
## and the works length, closes those lanes in the sim over the whole zone (tag = the
## instance serial) and lays out, in road space:
##   - the cone line: from the closed side's outer lane edge at the zone start, tapering
##     over works_taper_m per closed lane to the open lanes' edge (cone_line_inset_m
##     inside the closed lanes), along it for the works length, and back out over
##     works_end_taper_m; a cone every cone_spacing_taper_m on the tapers,
##     cone_spacing_m along the works;
##   - a barrier line down the middle of the closed lanes (barrier_start_m after the
##     taper, barrier_length_m long);
##   - the flashing arrow board in the outermost closed lane arrow_board_after_m after
##     the taper, pointing to the open side.
## The layout (every cone's s and d, the barrier and the board) is read by the view
## (SetPieceView) and by WorksPropQuery (hits: the player's box against every cone, the
## barrier and the board). The 400 m sign is the view's, the warning event the source's.

## +1: the right lanes are closed (traffic merges left); -1: the left lanes.
var side: int = 1
var closed_lo: int = 0
var closed_hi: int = 0
var taper_end_s: float = 0.0
var works_end_s: float = 0.0
## Cone line d at the zone start (the closed side's outer lane edge, inset) and along
## the works (the open lanes' edge, inset into the closed lanes).
var line_start_d: float = 0.0
var line_works_d: float = 0.0
var cone_s := PackedFloat64Array()
var cone_d := PackedFloat64Array()
var barrier_s0: float = 0.0
var barrier_s1: float = 0.0
var barrier_d: float = 0.0
var arrow_s: float = 0.0
var arrow_d: float = 0.0


func setup_zone(src: SetPieceSource, inst: SetPieceSource.Instance) -> bool:
	var d := inst.def
	var lanes := inst.lanes
	var most := mini(d.lanes_closed_max, lanes - d.works_min_open_lanes)
	if most < 1 or src.road == null or not src.can_zone:
		return false
	var least := clampi(d.lanes_closed_min, 1, most)
	var n_closed := src.rng.int_range(least, most)
	side = 1 if src.rng.chance(Units.pct_to_frac(d.right_side_pct)) else -1
	var length := src.rng.float_range(d.works_length_min_m, d.works_length_max_m)
	closed_lo = lanes - n_closed if side > 0 else 0
	closed_hi = lanes - 1 if side > 0 else n_closed - 1
	var s0 := inst.zone_s0
	taper_end_s = s0 + d.works_taper_m * float(n_closed)
	works_end_s = taper_end_s + length
	inst.zone_s1 = works_end_s + d.works_end_taper_m
	for lane in range(closed_lo, closed_hi + 1):
		if not bool(src.sim.call(&"add_lane_closure", lane, s0, inst.zone_s1, inst.serial)):
			return false
	_layout(src, inst, n_closed)
	return true


## The cone line's d at s (NAN outside the zone). Allocation-free.
func line_d_at(inst: SetPieceSource.Instance, s: float) -> float:
	if s < inst.zone_s0 or s > inst.zone_s1:
		return NAN
	if s < taper_end_s:
		return lerpf(line_start_d, line_works_d, (s - inst.zone_s0) / (taper_end_s - inst.zone_s0))
	if s <= works_end_s:
		return line_works_d
	return lerpf(line_works_d, line_start_d, (s - works_end_s) / (inst.zone_s1 - works_end_s))


## True when a box spanning [d_lo, d_hi] at s reaches into the closed area (beyond the
## cone line on the closed side). Allocation-free.
func in_closed_area(inst: SetPieceSource.Instance, s: float, d_lo: float, d_hi: float) -> bool:
	var line := line_d_at(inst, s)
	if is_nan(line):
		return false
	return d_hi > line if side > 0 else d_lo < line


func _layout(src: SetPieceSource, inst: SetPieceSource.Instance, n_closed: int) -> void:
	var d := inst.def
	var road := src.road
	var s0 := inst.zone_s0
	var w := road.lane_width(s0)
	var inset := d.cone_line_inset_m
	if side > 0:
		line_start_d = road.lanes_right_edge_d(s0) - inset
		line_works_d = road.lane_center_d(closed_lo, s0) - w * 0.5 + inset
	else:
		line_start_d = road.lanes_left_edge_d(s0) + inset
		line_works_d = road.lane_center_d(closed_hi, s0) + w * 0.5 - inset
	cone_s.clear()
	cone_d.clear()
	_cones(inst, s0, taper_end_s, d.cone_spacing_taper_m)
	_cones(inst, taper_end_s, works_end_s, d.cone_spacing_m)
	_cones(inst, works_end_s, inst.zone_s1, d.cone_spacing_taper_m)
	cone_s.append(inst.zone_s1)
	cone_d.append(line_d_at(inst, inst.zone_s1))
	barrier_s0 = taper_end_s + d.barrier_start_m
	barrier_s1 = minf(barrier_s0 + d.barrier_length_m, works_end_s)
	barrier_d = (road.lane_center_d(closed_lo, s0) + road.lane_center_d(closed_hi, s0)) * 0.5
	arrow_s = taper_end_s + d.arrow_board_after_m
	arrow_d = road.lane_center_d(closed_hi if side > 0 else closed_lo, s0)
	if n_closed > 1:
		# Two lanes: the board stands in the lane next to the open ones, where it is seen.
		arrow_d = road.lane_center_d(closed_lo if side > 0 else closed_hi, s0)


func _cones(inst: SetPieceSource.Instance, a: float, b: float, spacing: float) -> void:
	var n := maxi(ceili((b - a) / spacing), 1)
	for k in n:
		var s := a + (b - a) * float(k) / float(n)
		cone_s.append(s)
		cone_d.append(line_d_at(inst, s))
