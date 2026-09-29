class_name WorksPropQuery
extends HitDetection.PropQuery
## Hits on road-works props (WP6.3). Spec: Lives, hits and crashes → what counts as a
## hit ("roadside objects"; "first touch anywhere": the first contact of the tick);
## Traffic → set-piece table (road works: "cones and a barrier"). docs/SET_PIECES.md.
##
## HitDetection's prop hook: every tick it sweeps the player's inset box against the
## static boxes of every live road works (RoadWorksPiece's layout, in road space): each
## cone (cone_size_m square), the barrier line and the arrow board's trailer, and
## reports the earliest contact (source HIT_PROP). Cones are sorted along s, so only
## the ones within reach of the player's sweep are tested (a binary search).
## Pure and allocation-free (HitDetection.sweep_static_box does the separating-axis
## sweep).

var source: SetPieceSource
var _sweep: HitDetection
## Contacts reported (tests, dev).
var hits: int = 0


func _init(src: SetPieceSource, lives: LivesTuning) -> void:
	source = src
	_sweep = HitDetection.new(lives, 0)


func query_into(s0: float, d0: float, s1: float, d1: float, yaw: float, half_len: float, half_wid: float,
		out: HitDetection.Contact) -> bool:
	var best := INF
	var reach := half_len + half_wid + absf(s1 - s0)
	for inst in source.instances:
		if inst.stage != SetPieceSource.Stage.RUNNING:
			continue
		var w := inst.controller as RoadWorksPiece
		if w == null or s1 < inst.zone_s0 - reach or s0 > inst.zone_s1 + reach:
			continue
		var d := inst.def
		var hc := d.cone_size_m * 0.5
		var lo := minf(s0, s1) - reach - hc
		var hi := maxf(s0, s1) + reach + hc
		var k := w.cone_s.bsearch(lo)
		while k < w.cone_s.size() and w.cone_s[k] <= hi:
			best = _box(s0, d0, s1, d1, yaw, half_len, half_wid, w.cone_s[k], w.cone_d[k], hc, hc, best, out)
			k += 1
		var bl := (w.barrier_s1 - w.barrier_s0) * 0.5
		best = _box(s0, d0, s1, d1, yaw, half_len, half_wid, w.barrier_s0 + bl, w.barrier_d, bl,
			d.barrier_width_m * 0.5, best, out)
		best = _box(s0, d0, s1, d1, yaw, half_len, half_wid, w.arrow_s, w.arrow_d, d.arrow_board_length_m * 0.5,
			d.arrow_board_width_m * 0.5, best, out)
	if is_inf(best):
		return false
	hits += 1
	return true


func _box(s0: float, d0: float, s1: float, d1: float, yaw: float, hl: float, hw: float, bs: float, bd: float,
		bhl: float, bhw: float, best: float, out: HitDetection.Contact) -> float:
	var toi := _sweep.sweep_static_box(s0, d0, s1, d1, yaw, hl, hw, bs, bd, bhl, bhw)
	if toi < 0.0 or toi >= best:
		return best
	out.hit = true
	out.source = HitDetection.HIT_PROP
	out.toi = toi
	out.s = _sweep.last_s
	out.d = _sweep.last_d
	return toi
