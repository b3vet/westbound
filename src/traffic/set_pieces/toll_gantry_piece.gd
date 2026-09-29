class_name TollGantryPiece
extends SetPieceSource.Controller
## Toll gantry (WP6.3). Spec: Traffic → Traffic director, set-piece table: "Toll gantry |
## Checkpoint landmark: booth lanes on the sides, open express lanes in the middle |
## Signs 1 km and 500 m ahead"; World → Checkpoint landmarks (express toll gantry).
## docs/SET_PIECES.md.
##
## Triggered by a checkpoint whose landmark is the express toll gantry (SetPieceDef
## .trigger CHECKPOINT, checkpoint_style): not at a wave peak, and exempt from the
## scheduler's "clear of checkpoints" rule. The zone is [checkpoint - booth_before_m,
## checkpoint + booth_after_m]; the warnings are the landmark's own signs at 1 km and
## 500 m (warning_anchor_m counts them to the checkpoint). Booth lanes: the outermost lane
## on each side (only the right one on two lanes); the lanes between are the express
## lanes. setup_zone() puts a speed zone on every booth lane (TrafficSim.add_speed_zone,
## booth_speed_kmh, tag = the serial): all traffic there slows smoothly (its comfortable
## deceleration, never beyond the clamp) and pays at the booths; MOBIL sees the slow
## lane; booth traffic keeps its booth lane while slower than booth_exit_kmh, up to
## booth_keep_after_m past the booths (it never pulls out into the express lanes at
## booth speed). The express lanes are untouched: the path through at speed. The piece's booth
## cars (vehicles_min .. vehicles_max per booth lane) are planned by the meeting map to
## be met at the booths; scripted, they stay in their booth lanes.

var checkpoint_s: float = 0.0
var booth_left: int = -1
var booth_right: int = -1


func setup_zone(src: SetPieceSource, inst: SetPieceSource.Instance) -> bool:
	var d := inst.def
	if not src.can_zone or inst.lanes < d.min_lanes:
		return false
	checkpoint_s = inst.zone_s0 + d.booth_before_m
	inst.zone_s1 = checkpoint_s + d.booth_after_m
	booth_right = inst.lanes - 1
	booth_left = 0 if inst.lanes >= d.left_booth_min_lanes else -1
	var v := Units.kmh_to_mps(d.booth_speed_kmh)
	var v_exit := Units.kmh_to_mps(d.booth_exit_kmh)
	for lane: int in [booth_left, booth_right]:
		if lane >= 0 and not bool(src.sim.call(&"add_speed_zone", lane, inst.zone_s0, inst.zone_s1, v, inst.serial,
				d.booth_keep_after_m, v_exit)):
			return false
	return true


func is_booth_lane(lane: int) -> bool:
	return lane == booth_left or lane == booth_right


func plan(src: SetPieceSource, ctx: SpawnSource.Context, inst: SetPieceSource.Instance) -> void:
	var d := inst.def
	var row := 0
	for lane: int in [booth_left, booth_right]:
		if lane < 0:
			continue
		var n := src.rng.int_range(d.vehicles_min, d.vehicles_max)
		var s := inst.s_rear
		for k in n:
			var rec := SpawnSource.Record.new()
			if not src.draw_vehicle(ctx, inst, lane, rec):
				continue
			var ln := src.flow.length_of(rec.type_id)
			rec.s = s + ln * 0.5
			src.add_record(inst, rec, row)
			s += src.flow.min_spacing(rec.profile_id, inst.speed, ln, inst.speed, ln) + d.vehicle_extra_gap_m
			row += 1
