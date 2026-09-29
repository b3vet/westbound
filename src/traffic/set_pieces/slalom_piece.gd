class_name SlalomPiece
extends SetPieceSource.Controller
## Slalom (WP6.3). Spec: Traffic → Traffic director, set-piece table: "Slalom |
## Staggered cars across lanes forming an S-line of gaps | None needed (all visible)".
## docs/SET_PIECES.md.
##
## A rolling formation: vehicles_min .. vehicles_max rows (seeded), each with a car in
## every lane but one. The open lane moves one lane per row, turning at the road's edges
## (0, 1, 2, 1, 0 ... on three lanes), so the gaps line up into an S the player threads
## one lane change per row. Rows are row_gap_m apart bumper to bumper, never closer than
## IDM's s* at the piece's speed, so every gap is a lane change long at any closing
## speed the player can hold; following the piece is always a valid path (its speed is
## above the minimum). The cars keep their slots (keep_formation) and never change
## lanes: the S holds until the player has passed.

## Open lane of every row (tests, the sandbox).
var open_lanes := PackedInt32Array()


func plan(src: SetPieceSource, ctx: SpawnSource.Context, inst: SetPieceSource.Instance) -> void:
	var d := inst.def
	var lanes := inst.lanes
	var rows := src.rng.int_range(d.vehicles_min, d.vehicles_max)
	var open := src.rng.int_range(0, lanes - 1)
	var dir := 1 if src.rng.chance(0.5) else -1
	open_lanes.clear()
	var row_s := inst.s_rear
	for r in rows:
		open_lanes.append(open)
		var row_len := 0.0
		var row_gap := d.row_gap_m
		var planned: Array[SpawnSource.Record] = []
		for lane in lanes:
			if lane == open:
				continue
			var rec := SpawnSource.Record.new()
			if not src.draw_vehicle(ctx, inst, lane, rec):
				continue
			var ln := src.flow.length_of(rec.type_id)
			row_len = maxf(row_len, ln)
			row_gap = maxf(row_gap, src.flow.min_spacing(rec.profile_id, inst.speed, ln, inst.speed, ln) - ln)
			planned.append(rec)
		for rec in planned:
			rec.s = row_s + row_len * 0.5
			src.add_record(inst, rec, r)
		row_s += row_len + row_gap
		# Next row: one lane over, turning at the edges.
		if open + dir < 0 or open + dir >= lanes:
			dir = -dir
		open += dir


func on_bound(src: SetPieceSource, inst: SetPieceSource.Instance) -> void:
	mark_formation(src, inst)


func step(src: SetPieceSource, inst: SetPieceSource.Instance, dt: float, _player: VehicleState) -> void:
	keep_formation(src, inst, dt)
