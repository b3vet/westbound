class_name RoadFork
extends RefCounted
# lint: sim
## One fork as one ProceduralRoadPath sees it (WP6.5). Spec: Core loop → Legs and
## checkpoints → Forks ("split the road OutRun-style into two branches ... you pick by
## the side of the road you are on at the split"). docs/FORKS.md.
##
## The split is the fork checkpoint's line. Every path of a run shares the reference
## line up to it (same seed, same plan up to that leg, a forced straight approach); past
## it each path follows its own branch (`side`): the LEFT branch keeps the reference line
## and the left `lanes_left` lanes, the RIGHT branch's path is the same road translated
## `shift_m` to the right (its reference line then sits at the gore nose) with the other
## lanes. The main path is always the left branch until the player picks; the run adopts
## the right path's state when they pick right (ProceduralRoadPath.swap_state).
##
## Everything here is a pure function of s and the fork's numbers (tick-safe and
## allocation-free), except the ground limits, which read the sibling branch (director
## rate: the mesher).

var index: int = -1
## The fork checkpoint (the fork picks leg checkpoint + 1).
var checkpoint: int = 0
var split_s: float = 0.0
## This path's branch: ForkPlan.LEFT or ForkPlan.RIGHT.
var side: int = ForkPlan.LEFT
## The player has picked (main path: the generation hold is released).
var resolved: bool = false
var left_id: StringName = &""
var right_id: StringName = &""
## Lanes at the split (the trunk's) and how many go left.
var lanes_trunk: int = 0
var lanes_left: int = 0
## RIGHT paths: how far their reference line sits right of the trunk's (lanes_left lane
## widths). 0 on LEFT paths.
var shift_m: float = 0.0
## The other branch's path (ground limits; director rate). Null when not known.
var sibling: ProceduralRoadPath
## After the choice, the branch not taken narrows to nothing from here (INF = never).
var vanish_s: float = INF

## The trunk's pose at the split (for the branch's lateral deviation): position and the
## right vector, set when the table first covers the split.
var pose_known: bool = false
var split_x: float = 0.0
var split_z: float = 0.0
var right_x: float = 1.0
var right_z: float = 0.0

# Numbers from RoadTuning (read once).
var approach_m: float = 0.0
var veer_offset_m: float = 0.0
var veer_length_m: float = 0.0
var veer_lead_m: float = 0.0
var veer_fade_frac: float = 0.0
var rejoin_after_m: float = 0.0
var widen_after_m: float = 0.0
var widen_taper_m: float = 0.0
var gore_full_gap_m: float = 1.0
var draw_m: float = 0.0
var vanish_length_m: float = 1.0
var ground_blend_m: float = 1.0
var hold_margin_m: float = 0.0
var quiet_after_m: float = 0.0
var hide_m: float = 0.0
## Half the crash cushion's width: the gore faces start this far into each branch's lane.
var cushion_half_m: float = 0.0


func _init(t: RoadTuning = null) -> void:
	if t == null:
		return
	approach_m = t.fork_approach_straight_m
	veer_offset_m = t.fork_veer_offset_m
	veer_length_m = maxf(t.fork_veer_length_m, 1.0)
	veer_lead_m = t.fork_veer_lead_m
	veer_fade_frac = clampf(t.fork_veer_fade_frac, 0.0, 1.0)
	rejoin_after_m = t.fork_rejoin_after_m
	widen_after_m = t.fork_widen_after_m
	widen_taper_m = t.fork_widen_taper_m
	gore_full_gap_m = maxf(t.fork_gore_full_gap_m, 1.0)
	draw_m = t.fork_draw_m
	vanish_length_m = maxf(t.fork_vanish_length_m, 1.0)
	ground_blend_m = maxf(t.fork_ground_blend_m, 1.0)
	hold_margin_m = t.fork_hold_margin_m
	quiet_after_m = t.fork_quiet_after_m
	hide_m = t.fork_opposite_hide_m
	cushion_half_m = t.fork_cushion_width_m * 0.5


## A copy for another path (same fork, same numbers; the caller sets side, shift, sibling).
func copy() -> RoadFork:
	var f := RoadFork.new()
	f.index = index
	f.checkpoint = checkpoint
	f.split_s = split_s
	f.side = side
	f.resolved = resolved
	f.left_id = left_id
	f.right_id = right_id
	f.lanes_trunk = lanes_trunk
	f.lanes_left = lanes_left
	f.shift_m = shift_m
	f.vanish_s = vanish_s
	f.approach_m = approach_m
	f.veer_offset_m = veer_offset_m
	f.veer_length_m = veer_length_m
	f.veer_lead_m = veer_lead_m
	f.veer_fade_frac = veer_fade_frac
	f.rejoin_after_m = rejoin_after_m
	f.widen_after_m = widen_after_m
	f.widen_taper_m = widen_taper_m
	f.gore_full_gap_m = gore_full_gap_m
	f.draw_m = draw_m
	f.vanish_length_m = vanish_length_m
	f.ground_blend_m = ground_blend_m
	f.hold_margin_m = hold_margin_m
	f.quiet_after_m = quiet_after_m
	f.hide_m = hide_m
	f.cushion_half_m = cushion_half_m
	return f


## Lanes going right at the split.
func lanes_right() -> int:
	return lanes_trunk - lanes_left


## Where the veer of the opposite carriageway starts (before the split).
func veer_start_s() -> float:
	return split_s - veer_lead_m - veer_length_m


## Where the taken branch's opposite carriageway is back in place.
func rejoin_end_s() -> float:
	return split_s + rejoin_after_m + veer_length_m


## End of the gore (the other branch has vanished and handed its ground over).
func gore_end_s() -> float:
	return split_s + draw_m + vanish_length_m + ground_blend_m


## The span the fork shapes: the veer before the split to the rejoin after it.
func span_start_s() -> float:
	return minf(veer_start_s(), split_s - approach_m)


func span_end_s() -> float:
	return maxf(rejoin_end_s(), gore_end_s())


## True from the split to the end of the gore (this path is on its branch).
func in_branch(s: float) -> bool:
	return s >= split_s and s < gore_end_s()


## Opposite carriageway lateral offset (m, >= 0, away to the left) at s.
func opposite_offset(s: float) -> float:
	var a := veer_start_s()
	if s <= a:
		return 0.0
	if s < a + veer_length_m:
		return veer_offset_m * _quintic((s - a) / veer_length_m)
	var r := split_s + rejoin_after_m
	if s <= r:
		return veer_offset_m
	if s < r + veer_length_m:
		return veer_offset_m * (1.0 - _quintic((s - r) / veer_length_m))
	return 0.0


## How much of the opposite carriageway is drawn at s (1 = all, 0 = none).
func opposite_width(s: float) -> float:
	var a := veer_start_s()
	if s <= a:
		return 1.0
	var fade := veer_fade_frac
	if s < a + veer_length_m:
		var u := (s - a) / veer_length_m
		return 1.0 - smoothstep(1.0 - fade, 1.0, u)
	var r := split_s + rejoin_after_m
	if s <= r:
		return 0.0
	if s < r + veer_length_m:
		return smoothstep(0.0, fade, (s - r) / veer_length_m)
	return 1.0


## The branch's lateral deviation from the approach line at s (m, outward from the
## other branch: left for the LEFT branch), from this path's table position (x, z).
func deviation(x: float, z: float) -> float:
	if not pose_known:
		return 0.0
	var d := (x - split_x) * right_x + (z - split_z) * right_z
	return d if side == ForkPlan.RIGHT else -d


## 0 at the split .. 1 once the gap between the branches reaches gore_full_gap_m, from
## the deviation (the branches are mirror images: the gap is twice it).
func gore_open(dev: float) -> float:
	return clampf(2.0 * dev / gore_full_gap_m, 0.0, 1.0)


## After the choice (branch not taken): 1 .. 0 across the vanish.
func vanish_factor(s: float) -> float:
	if s <= vanish_s:
		return 1.0
	return 1.0 - smoothstep(vanish_s, vanish_s + vanish_length_m, s)


## True where the right branch's left side is a guardrail (the opposite carriageway is
## away): from the split until its opposite carriageway rejoins.
func rail_on_left(s: float) -> bool:
	return side == ForkPlan.RIGHT and s >= split_s and s < split_s + rejoin_after_m


## The ground on the gore side reaches full width again over the blend after the vanish
## point of the branch not taken: 0 .. 1.
func gore_ground_release(s: float) -> float:
	var v := split_s + draw_m + vanish_length_m
	return smoothstep(v, v + ground_blend_m, s)


static func _quintic(u: float) -> float:
	var t := clampf(u, 0.0, 1.0)
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)   # lint: allow-number quintic smoothstep coefficients
