class_name ConvoyPiece
extends SetPieceSource.Controller
## Convoy (WP6.3). Spec: Traffic → Traffic director, set-piece table: "Convoy | A slow
## line of same-color vehicles with hazards on, honking | Visible"; Traffic → Visuals
## (hazards); Audio (horns: TrafficSim.KIND_HORN). docs/SET_PIECES.md.
##
## A rolling formation: one line of vehicles_min .. vehicles_max vehicles in the right
## lane (the next one to the left on next_lane_pct of pieces on next_lane_min_lanes+
## lanes), all the same
## drawn vehicle (profile, type, model and color), IDM's s* + vehicle_extra_gap_m apart,
## hazards on (FLAG_HAZARD from the spawn), at the piece's slow speed (still above the
## minimum speed, so following it is a valid path). They keep their slots
## (keep_formation) and never change lanes (scripted: no MOBIL). While the player is
## within honk_range_m of the line, one of them honks every honk_interval_min_s ..
## honk_interval_max_s (seeded). Released at the end: hazards off, own speed back.

var line_lane: int = 0
var honk_t: float = 0.0
## Horns sounded (tests, dev).
var honks: int = 0


func plan(src: SetPieceSource, ctx: SpawnSource.Context, inst: SetPieceSource.Instance) -> void:
	var d := inst.def
	var lanes := inst.lanes
	line_lane = lanes - 1
	if lanes >= d.next_lane_min_lanes and src.rng.chance(Units.pct_to_frac(d.next_lane_pct)):
		line_lane = lanes - 2
	var n := src.rng.int_range(d.vehicles_min, d.vehicles_max)
	var first := SpawnSource.Record.new()
	if not src.draw_vehicle(ctx, inst, line_lane, first):
		return
	var ln := src.flow.length_of(first.type_id)
	var step_m := src.flow.min_spacing(first.profile_id, inst.speed, ln, inst.speed, ln) + d.vehicle_extra_gap_m
	var line: Array[SpawnSource.Record] = [first]
	for k in range(1, n):
		line.append(_copy(first))
	for k in line.size():
		var rec := line[k]
		rec.s = inst.s_rear + ln * 0.5 + step_m * float(k)
		rec.flags |= TrafficState.FLAG_HAZARD
		src.add_record(inst, rec, k)


static func _copy(r: SpawnSource.Record) -> SpawnSource.Record:
	var c := SpawnSource.Record.new()
	c.lane = r.lane
	c.d = r.d
	c.v = r.v
	c.v0 = r.v0
	c.type_id = r.type_id
	c.profile_id = r.profile_id
	c.model_variant = r.model_variant
	c.color_index = r.color_index
	c.flags = r.flags
	c.set_piece = r.set_piece
	return c


func on_bound(src: SetPieceSource, inst: SetPieceSource.Instance) -> void:
	mark_formation(src, inst)
	honk_t = src.rng.float_range(inst.def.honk_interval_min_s, inst.def.honk_interval_max_s)


func step(src: SetPieceSource, inst: SetPieceSource.Instance, dt: float, player: VehicleState) -> void:
	keep_formation(src, inst, dt)
	var d := inst.def
	if player.s < inst.s_rear - d.honk_range_m or player.s > inst.s_front + d.honk_range_m:
		return
	honk_t -= dt
	if honk_t > 0.0:
		return
	honk_t = src.rng.float_range(d.honk_interval_min_s, d.honk_interval_max_s)
	var k := src.rng.int_range(0, inst.n - 1)
	if src.alive(inst, k):
		src.honk(inst, k)
		honks += 1


func on_end(src: SetPieceSource, inst: SetPieceSource.Instance) -> void:
	for k in inst.n:
		src.hazards(inst, k, false)
	super(src, inst)
