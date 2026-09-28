class_name HitDetection
extends RefCounted
# lint: sim
## Player contact detection in road space, swept over each tick. Spec: Lives, hits and
## crashes -> What counts as a hit (oriented boxes in road space, inset 8 cm from the
## visual body on each side; traffic, barriers and guardrails, roadside objects;
## barrier scrapes count) and its collision-box test (agreement up to 350 km/h, no
## tunnelling between 120 Hz ticks). Contracts: docs/CONTRACTS.md sections 2, 4, 5.
## Method and limits: docs/CORE_LOOP.md.
##
## Pure and headless; step() is allocation-free. It only reports contacts: Lives
## decides whether one counts (ghost period) and what it costs.
##
## Boxes: the player (s, d, yaw) with the car body set by set_player_body(); each live
## traffic slot (s, d, heading atan2(v_lat, v), length x width). Both are inset by
## lives.collision_inset_m on every side. (s, d) is treated as a local Cartesian
## frame: with radius >= 1,200 m the metric error across a car is below 0.4%.
##
## Swept test: each box moves linearly from its pose at the previous step() to its pose
## now (headings held at the current tick's; they change by at most yaw_rate x dt).
## The separating-axis test on the relative motion gives the exact first time of
## overlap in the tick, so a contact that begins and ends between two ticks (a corner
## clip at 350 km/h) is still found. Barriers: each inset corner's lateral gap to the
## median barrier face (left corners) and the guardrail (right corners), evaluated at
## the corner's own s (lane tapers move the guardrail), interpolated over the tick.
## The earliest contact of the tick wins (traffic, then barriers, then props on ties).

## Contact sources: the Events.HIT_* values (mirrored: sim code never touches the
## Events autoload; test_hit_detection asserts they match).
const HIT_TRAFFIC := &"traffic"
const HIT_BARRIER := &"barrier"
const HIT_PROP := &"prop"

## Box corners, and separating axes of two 2D boxes (two per box).
const _CORNERS := 4
const _AXES := 4
## _sweep_boxes() result for "no contact this tick".
const _NONE := -1.0


## One contact, written into a caller-owned instance by step().
class Contact:
	extends RefCounted
	var hit: bool = false
	var source: StringName = &""   ## HIT_TRAFFIC / HIT_BARRIER / HIT_PROP (== Events.HIT_*)
	var slot: int = -1             ## TrafficState slot for traffic, else -1
	var vehicle_id: int = -1       ## TrafficState.vehicle_id for traffic, else -1
	var toi: float = 0.0           ## fraction of the tick (0..1) when the contact began
	var s: float = 0.0             ## contact point, road space
	var d: float = 0.0
	var normal_s: float = 0.0      ## unit contact normal from the player toward the other body
	var normal_d: float = 0.0
	var rel_v_s: float = 0.0       ## player velocity minus the other body's (m/s, road space)
	var rel_v_d: float = 0.0
	var side: int = 0              ## +1 on the player's right, -1 left, 0 at the nose or tail
	var end: int = 0               ## +1 at the nose, -1 at the tail, 0 on a flank
	var away_side: int = 0         ## lateral deflection away from the contact: +1 right, -1 left, 0 none

	func clear() -> void:
		hit = false
		source = &""
		slot = -1
		vehicle_id = -1
		toi = 0.0
		s = 0.0
		d = 0.0
		normal_s = 0.0
		normal_d = 0.0
		rel_v_s = 0.0
		rel_v_d = 0.0
		side = 0
		end = 0
		away_side = 0

	func copy_from(o: Contact) -> void:
		hit = o.hit
		source = o.source
		slot = o.slot
		vehicle_id = o.vehicle_id
		toi = o.toi
		s = o.s
		d = o.d
		normal_s = o.normal_s
		normal_d = o.normal_d
		rel_v_s = o.rel_v_s
		rel_v_d = o.rel_v_d
		side = o.side
		end = o.end
		away_side = o.away_side


## Hook for roadside objects (props beyond the guardrail are covered by the guardrail
## check for now). Subclass and pass to set_prop_query(). Must not allocate.
class PropQuery:
	extends RefCounted

	## The player's inset box sweeps from center (s0, d0) to (s1, d1) this tick with
	## heading `yaw` (road-relative) and half extents half_len x half_wid. On contact,
	## fill out.hit / source (HIT_PROP) / toi / s / d (the rest is derived) and
	## return true.
	func query_into(_s0: float, _d0: float, _s1: float, _d1: float, _yaw: float, _half_len: float,
			_half_wid: float, _out: Contact) -> bool:
		return false


var _inset: float
var _broadphase: float
var _hl: float = 0.0
var _hw: float = 0.0
var _prop_query: PropQuery = null
var _prop_contact := Contact.new()

var _has_prev: bool = false
var _prev_ps: float = 0.0
var _prev_pd: float = 0.0
var _prev_s := PackedFloat64Array()
var _prev_d := PackedFloat64Array()
var _prev_id := PackedInt32Array()

# Scratch results of the last _sweep_boxes() (no allocation).
var _c_s: float = 0.0
var _c_d: float = 0.0
var _c_ns: float = 0.0
var _c_nd: float = 0.0


func _init(lives: LivesTuning, traffic_capacity: int) -> void:
	_inset = lives.collision_inset_m
	_broadphase = lives.collision_broadphase_m
	_prev_s.resize(traffic_capacity)
	_prev_d.resize(traffic_capacity)
	_prev_id.resize(traffic_capacity)
	_prev_id.fill(-1)


## The player car's visual body (CarDef.length_m, width_m); the inset is applied here.
func set_player_body(length_m: float, width_m: float) -> void:
	_hl = maxf(length_m * 0.5 - _inset, 0.0)
	_hw = maxf(width_m * 0.5 - _inset, 0.0)


func set_prop_query(q: PropQuery) -> void:
	_prop_query = q


## Run start, respawn or any teleport: the next step() sweeps from these poses.
func reset(player: VehicleState, traffic: TrafficState) -> void:
	_prev_ps = player.s
	_prev_pd = player.d
	_has_prev = true
	_prev_id.fill(-1)
	if traffic == null:
		return
	for i in mini(traffic.capacity, _prev_id.size()):
		if traffic.active[i] == 1:
			_prev_id[i] = traffic.vehicle_id[i]
			_prev_s[i] = traffic.s[i]
			_prev_d[i] = traffic.d[i]


## One tick, after physics and traffic moved (tick order step 4). Finds the earliest
## contact of the player's box since the previous step() and writes it to `out`.
## `road` null means no barriers (tests). Returns out.hit.
func step(dt: float, player: VehicleState, traffic: TrafficState, road: RoadPath, out: Contact) -> bool:
	out.clear()
	if not _has_prev:
		_prev_ps = player.s
		_prev_pd = player.d
		_has_prev = true
	var ps0 := _prev_ps
	var pd0 := _prev_pd
	var ps1 := player.s
	var pd1 := player.d
	_prev_ps = ps1
	_prev_pd = pd1
	var inv_dt := 1.0 / dt if dt > 0.0 else 0.0
	var pc := cos(player.yaw)
	var pn := sin(player.yaw)
	var best := INF

	if traffic != null:
		var p_reach := _hl + _hw
		var n := mini(traffic.capacity, _prev_id.size())
		for i in n:
			if traffic.active[i] == 0:
				_prev_id[i] = -1
				continue
			var ts1 := traffic.s[i]
			if absf(ts1 - ps1) > _broadphase:
				_prev_id[i] = -1   # re-enters the window with no sweep (it cannot reach the player in one tick)
				continue
			var td1 := traffic.d[i]
			var ts0 := ts1
			var td0 := td1
			var id := traffic.vehicle_id[i]
			if _prev_id[i] == id:
				ts0 = _prev_s[i]
				td0 = _prev_d[i]
			_prev_id[i] = id
			_prev_s[i] = ts1
			_prev_d[i] = td1
			var bhl := maxf(traffic.length[i] * 0.5 - _inset, 0.0)
			var bhw := maxf(traffic.width[i] * 0.5 - _inset, 0.0)
			# Broad phase: a box's extent along any axis is at most hl + hw.
			var reach := p_reach + bhl + bhw
			var r0s := ts0 - ps0
			var r1s := ts1 - ps1
			if (r0s > reach and r1s > reach) or (r0s < -reach and r1s < -reach):
				continue
			var r0d := td0 - pd0
			var r1d := td1 - pd1
			if (r0d > reach and r1d > reach) or (r0d < -reach and r1d < -reach):
				continue
			var yaw_b := atan2(traffic.v_lat[i], traffic.v[i])
			var toi := _sweep_boxes(ps0, pd0, ps1, pd1, pc, pn, _hl, _hw,
				ts0, td0, ts1, td1, cos(yaw_b), sin(yaw_b), bhl, bhw)
			if toi < 0.0 or toi >= best:
				continue
			best = toi
			out.hit = true
			out.source = HIT_TRAFFIC
			out.slot = i
			out.vehicle_id = id
			out.toi = toi
			out.s = _c_s
			out.d = _c_d
			out.normal_s = _c_ns
			out.normal_d = _c_nd
			out.rel_v_s = ((ps1 - ps0) - (ts1 - ts0)) * inv_dt
			out.rel_v_d = ((pd1 - pd0) - (td1 - td0)) * inv_dt

	if road != null:
		# Left corners (fy = -1) against the median barrier face, right corners
		# (fy = +1) against the guardrail.
		for k in _CORNERS:
			var fx := 1.0 if k % 2 == 0 else -1.0
			var fy := -1.0 if k < 2 else 1.0
			var os := fx * _hl * pc - fy * _hw * pn
			var od := fx * _hl * pn + fy * _hw * pc
			var cs0 := ps0 + os
			var cs1 := ps1 + os
			var cd0 := pd0 + od
			var cd1 := pd1 + od
			var g0: float
			var g1: float
			var face1: float
			if fy < 0.0:
				g0 = cd0 - road.median_barrier_d(cs0)
				face1 = road.median_barrier_d(cs1)
				g1 = cd1 - face1
			else:
				g0 = road.guardrail_d(cs0) - cd0
				face1 = road.guardrail_d(cs1)
				g1 = face1 - cd1
			if g1 >= 0.0 and g0 >= 0.0:
				continue
			var toi := 0.0 if g0 < 0.0 else g0 / (g0 - g1)
			if toi >= best:
				continue
			best = toi
			out.hit = true
			out.source = HIT_BARRIER
			out.slot = -1
			out.vehicle_id = -1
			out.toi = toi
			out.s = cs0 + (cs1 - cs0) * toi
			out.d = cd0 + (cd1 - cd0) * toi + (g0 + (g1 - g0) * toi) * fy
			out.normal_s = 0.0
			out.normal_d = fy
			out.rel_v_s = (ps1 - ps0) * inv_dt
			out.rel_v_d = (pd1 - pd0) * inv_dt

	if _prop_query != null:
		_prop_contact.clear()
		if _prop_query.query_into(ps0, pd0, ps1, pd1, player.yaw, _hl, _hw, _prop_contact) \
				and _prop_contact.toi < best:
			best = _prop_contact.toi
			out.copy_from(_prop_contact)
			out.hit = true
			out.slot = -1
			out.vehicle_id = -1
			var ms := ps0 + (ps1 - ps0) * out.toi
			var md := pd0 + (pd1 - pd0) * out.toi
			var ls := out.s - ms
			var ld := out.d - md
			var ll := sqrt(ls * ls + ld * ld)
			out.normal_s = ls / ll if ll > 0.0 else pc
			out.normal_d = ld / ll if ll > 0.0 else pn
			out.rel_v_s = (ps1 - ps0) * inv_dt
			out.rel_v_d = (pd1 - pd0) * inv_dt

	if not out.hit:
		return false
	_classify(out, pc, pn, ps0 + (ps1 - ps0) * out.toi, pd0 + (pd1 - pd0) * out.toi)
	return true


## Side / end / deflection direction of `c` in the player's frame (heading cos, sin).
func _classify(c: Contact, pc: float, pn: float, ps: float, pd: float) -> void:
	var nf := c.normal_s * pc + c.normal_d * pn        # along the player's nose
	var nr := -c.normal_s * pn + c.normal_d * pc       # along the player's right
	if absf(nr) >= absf(nf):
		c.side = 1 if nr > 0.0 else -1
		c.end = 0
		c.away_side = -c.side
	else:
		c.end = 1 if nf > 0.0 else -1
		c.side = 0
		# Nose or tail: deflect away from the side of the player the contact point is on.
		var lat := -(c.s - ps) * pn + (c.d - pd) * pc
		c.away_side = 0 if lat == 0.0 else (-1 if lat > 0.0 else 1)


## Swept separating-axis test of two oriented boxes moving linearly over one tick.
## Box A: center (a0s, a0d) -> (a1s, a1d), heading (ac, an) = (cos, sin), half extents
## ahl x ahw; box B likewise. Returns the first time of overlap in [0, 1), or -1.
## On overlap, _c_s/_c_d hold the contact point and _c_ns/_c_nd the normal (A -> B).
func _sweep_boxes(a0s: float, a0d: float, a1s: float, a1d: float, ac: float, an: float,
		ahl: float, ahw: float, b0s: float, b0d: float, b1s: float, b1d: float, bc: float,
		bn: float, bhl: float, bhw: float) -> float:
	var r0s := b0s - a0s
	var r0d := b0d - a0d
	var ws := (b1s - b0s) - (a1s - a0s)
	var wd := (b1d - b0d) - (a1d - a0d)
	var enter := -INF
	var leave := INF
	# Axes: A forward (ac, an), A right (-an, ac), B forward (bc, bn), B right (-bn, bc).
	for k in _AXES:
		var xs: float
		var xd: float
		match k:
			0:
				xs = ac
				xd = an
			1:
				xs = -an
				xd = ac
			2:
				xs = bc
				xd = bn
			_:
				xs = -bn
				xd = bc
		var rad := _extent(ahl, ahw, ac, an, xs, xd) + _extent(bhl, bhw, bc, bn, xs, xd)
		var p0 := r0s * xs + r0d * xd
		var pw := ws * xs + wd * xd
		if pw == 0.0:
			if absf(p0) >= rad:
				return _NONE
			continue
		var t1 := (-rad - p0) / pw
		var t2 := (rad - p0) / pw
		if t1 > t2:
			var tmp := t1
			t1 = t2
			t2 = tmp
		enter = maxf(enter, t1)
		leave = minf(leave, t2)
		if enter >= leave:
			return _NONE
	if enter >= 1.0 or leave <= 0.0:
		return _NONE
	var toi := maxf(enter, 0.0)

	# Contact geometry at toi: the normal is the axis of least penetration (the axis
	# just entered), the point is on A's face along it, centered on the overlap.
	var as_ := a0s + (a1s - a0s) * toi
	var ad := a0d + (a1d - a0d) * toi
	var bs := b0s + (b1s - b0s) * toi
	var bd := b0d + (b1d - b0d) * toi
	var rs := bs - as_
	var rd := bd - ad
	var best_pen := INF
	var ns := 1.0
	var nd := 0.0
	for k in _AXES:
		var xs: float
		var xd: float
		match k:
			0:
				xs = ac
				xd = an
			1:
				xs = -an
				xd = ac
			2:
				xs = bc
				xd = bn
			_:
				xs = -bn
				xd = bc
		var rad := _extent(ahl, ahw, ac, an, xs, xd) + _extent(bhl, bhw, bc, bn, xs, xd)
		var p := rs * xs + rd * xd
		var pen := rad - absf(p)
		if pen < best_pen:
			best_pen = pen
			var sgn := -1.0 if p < 0.0 else 1.0
			ns = xs * sgn
			nd = xd * sgn
	var ts := -nd
	var td := ns
	var a_n := _extent(ahl, ahw, ac, an, ns, nd)
	var a_t := _extent(ahl, ahw, ac, an, ts, td)
	var b_t := _extent(bhl, bhw, bc, bn, ts, td)
	var ca_t := as_ * ts + ad * td
	var cb_t := bs * ts + bd * td
	var lo := maxf(ca_t - a_t, cb_t - b_t)
	var hi := minf(ca_t + a_t, cb_t + b_t)
	var m := (lo + hi) * 0.5
	var along := as_ * ns + ad * nd + a_n
	_c_s = ns * along + ts * m
	_c_d = nd * along + td * m
	_c_ns = ns
	_c_nd = nd
	return toi


## Half extent of a box (half length hl along heading (c, n), half width hw across it)
## projected on the unit axis (xs, xd).
static func _extent(hl: float, hw: float, c: float, n: float, xs: float, xd: float) -> float:
	return hl * absf(c * xs + n * xd) + hw * absf(-n * xs + c * xd)
