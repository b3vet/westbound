class_name RunAttract
extends RefCounted
## The title's attract drive (WP8.5). Spec: UI → Screens ("Title: the attract camera
## drives the selected car"); Cameras → Scripted cameras → Menu ("a slow drive-by of the
## selected car on the road. No scripted camera ever takes control while traffic can
## still hit the player"). docs/RUN.md → Title and attract.
##
## The run in MENU (Run._attract_tick) drives the real PlayerCar through VehiclePhysics
## with the traffic sandbox's bot (IDM on the car ahead, so it never runs into traffic;
## WEAVE: a lane change to a freer lane now and then, when attract_weave) at
## CameraTuning.attract_speed_kmh, from attract_lane. Traffic runs as in a run,
## with the car as a participant (traffic behind slows for it), but the run never steps
## hit detection, lives or scoring in MENU: nothing can hit the car.
##
## The shots, placed in road space (s, d, height over the road) and turned into render
## space with the floating origin, so they follow the road's curves and never sit off
## it: ORBIT (a slow arc around the car at attract_orbit_distance_m) and PASS (a camera
## on the shoulder that the car drives past), alternating. Each takes the side of the car
## whose line of sight no traffic blocks (else the one with more room, inside the
## barriers), and a shot that traffic blocks later cuts to the next (after
## attract_min_shot_s). View-only: nothing here writes the sim. Allocation-free per tick.

enum Shot { ORBIT, PASS }

var tuning: CameraTuning
var bot: SandboxBot
## Shots started so far (the first is an ORBIT).
var shots: int = 0
var kind: Shot = Shot.ORBIT
## +1: the camera is on the car's right (the shoulder side), -1: its left.
var side: float = 1.0
## Seconds into the shot.
var t: float = 0.0
## PASS: where the camera stands (road space).
var pass_s: float = 0.0
var pass_d: float = 0.0
## The last view handed to the rig (render space; tests).
var eye := Vector3.ZERO
var look := Vector3.ZERO

var _run: Run
var _smp := RoadSample.new()
var _cut: bool = false
var _es: float = 0.0
var _ed: float = 0.0


## Takes the run's car in MENU: the bot drives it, the rig hands its pose to the shots.
func begin(run: Run) -> void:
	_run = run
	tuning = run.rig.tuning
	var car := run.car
	bot = SandboxBot.new(run.road, run.sim.state, car.params, run.current_seed)
	bot.mode = SandboxBot.Mode.WEAVE if tuning.attract_weave else SandboxBot.Mode.KEEP
	bot.v_target = Units.kmh_to_mps(tuning.attract_speed_kmh)
	bot.length_m = car.car.length_m
	bot.width_m = car.car.width_m
	car.controller = bot
	bot.target_lane = clampi(tuning.attract_lane, 0, run.road.lane_count(car.state.s) - 1)
	car.place_at(car.state.s, run.road.lane_center_d(bot.target_lane, car.state.s), bot.v_target)
	shots = 0
	run.rig.start_attract()
	_start_shot(Shot.ORBIT)
	update_view()


## Gives the rig back to the chase camera (a run starts).
func end() -> void:
	if _run != null and is_instance_valid(_run.rig):
		_run.rig.stop_attract()
	_run = null
	bot = null


func is_active() -> bool:
	return _run != null


## One attract tick (after the car and traffic): the shot's clock, the cut to the next.
func tick(dt: float) -> void:
	if _run == null:
		return
	t += dt
	var st := _run.car.state
	var done := false
	if kind == Shot.ORBIT:
		done = t >= tuning.attract_orbit_s
	else:
		done = st.s >= pass_s + tuning.attract_pass_past_m or t >= tuning.attract_shot_max_s
	if not done and t >= tuning.attract_min_shot_s:
		_eye_road(kind, side)
		done = is_blocked(_es, _ed)
	if done:
		next_shot()
	update_view()


## Cuts to the next shot (the other kind), e.g. after the road swapped its branch.
func next_shot() -> void:
	_start_shot(Shot.PASS if kind == Shot.ORBIT else Shot.ORBIT)


## The shot's view now, handed to the rig.
func update_view() -> void:
	if _run == null:
		return
	var road := _run.road
	var st := _run.car.state
	var o := _run.origin
	var up := Vector3.UP
	road.sample_into(st.s, _smp)
	look = _smp.local_point(st.d, o.origin_x, o.origin_y, o.origin_z) + up * tuning.attract_look_height_m
	_eye_road(kind, side)
	var h := tuning.attract_orbit_height_m if kind == Shot.ORBIT else tuning.attract_pass_height_m
	road.sample_into(_es, _smp)
	eye = _smp.local_point(_ed, o.origin_x, o.origin_y, o.origin_z) + up * h
	_run.rig.set_attract_view(eye, look, tuning.attract_fov_deg, deg_to_rad(tuning.attract_frame_yaw_deg), _cut)
	_cut = false


func _start_shot(k: Shot) -> void:
	kind = k
	t = 0.0
	shots += 1
	_cut = true
	var road := _run.road
	var st := _run.car.state
	# The side with a clear line to the car; else the one with more room to the barrier.
	var room_right := road.guardrail_d(st.s) - st.d
	var room_left := st.d - road.median_barrier_d(st.s)
	var first := 1.0 if room_right >= room_left else -1.0
	side = first
	for i in 2:
		var sd := first if i == 0 else -first
		_eye_road(k, sd)
		if not is_blocked(_es, _ed):
			side = sd
			break
	if k == Shot.PASS:
		pass_s = st.s + tuning.attract_pass_lead_m
		pass_d = _pass_d(pass_s, side)


## PASS: on the shoulder (no traffic drives through the lens), between the lanes' edge
## and the barrier on that side.
func _pass_d(s: float, sd: float) -> float:
	var road := _run.road
	var d := (road.lanes_right_edge_d(s) + road.guardrail_d(s)) * 0.5 if sd > 0.0 \
			else (road.lanes_left_edge_d(s) + road.median_barrier_d(s)) * 0.5
	return _clamp_d(d, s)


## The shot's eye in road space now (into _es, _ed) for `k` on side `sd`.
func _eye_road(k: Shot, sd: float) -> void:
	var st := _run.car.state
	if k == Shot.ORBIT:
		var u := smoothstep(0.0, 1.0, clampf(t / maxf(tuning.attract_orbit_s, _run.tuning.vehicle.physics_dt()), 0.0, 1.0))
		var a := deg_to_rad(lerpf(tuning.attract_orbit_from_deg, tuning.attract_orbit_to_deg, u))
		var r := tuning.attract_orbit_distance_m
		_es = st.s + r * cos(a)
		_ed = _clamp_d(st.d + sd * r * sin(a), _es)
	elif sd == side and shots > 0 and kind == Shot.PASS and t > 0.0:
		_es = pass_s
		_ed = pass_d
	else:
		_es = st.s + tuning.attract_pass_lead_m
		_ed = _pass_d(_es, sd)


## True when a traffic vehicle (its box grown by attract_clear_margin_m) crosses the line
## from the eye (road space) to the car, short of the car's own box. Allocation-free.
func is_blocked(es: float, ed: float) -> bool:
	var ts := _run.sim.state
	var st := _run.car.state
	var m := tuning.attract_clear_margin_m
	var ds := st.s - es
	var dd := st.d - ed
	var len_sq := ds * ds + dd * dd
	if len_sq <= 0.0:
		return false
	# Stop the line where it enters the car (its half length along the line, roughly).
	var t_end := maxf(0.0, 1.0 - _run.car.car.length_m * 0.5 / sqrt(len_sq))
	for i in ts.capacity:
		if ts.active[i] == 0:
			continue
		var hs := ts.length[i] * 0.5 + m
		var hd := ts.width[i] * 0.5 + m
		if _segment_hits_box(es, ed, ds, dd, t_end, ts.s[i] - hs, ts.s[i] + hs, ts.d[i] - hd, ts.d[i] + hd):
			return true
	return false


## Slab test: does p(t) = (s0 + t ds, d0 + t dd), t in [0, t_end], enter the box?
static func _segment_hits_box(s0: float, d0: float, ds: float, dd: float, t_end: float,
		s_lo: float, s_hi: float, d_lo: float, d_hi: float) -> bool:
	var t0 := 0.0
	var t1 := t_end
	if absf(ds) <= 0.0:
		if s0 < s_lo or s0 > s_hi:
			return false
	else:
		var a := (s_lo - s0) / ds
		var b := (s_hi - s0) / ds
		t0 = maxf(t0, minf(a, b))
		t1 = minf(t1, maxf(a, b))
	if absf(dd) <= 0.0:
		if d0 < d_lo or d0 > d_hi:
			return false
	else:
		var a := (d_lo - d0) / dd
		var b := (d_hi - d0) / dd
		t0 = maxf(t0, minf(a, b))
		t1 = minf(t1, maxf(a, b))
	return t0 <= t1


## d kept inside the carriageway's barriers (with the margin).
func _clamp_d(d: float, s: float) -> float:
	var m := tuning.attract_edge_margin_m
	return clampf(d, _run.road.median_barrier_d(s) + m, _run.road.guardrail_d(s) - m)
