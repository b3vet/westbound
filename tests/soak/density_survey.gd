class_name DensitySurvey
extends RefCounted
## Effective traffic density around the player (plan D11, WP4.8; spec: Traffic →
## Traffic director, "density rises from 8 to 16 vehicles per km per lane from leg 1
## to leg 8"). A test observer: it drives TrafficSoakRun (the real sim, director,
## registry and road) with a scripted player and counts the vehicles inside the
## director's density window, [player s - density_window_behind_m, player s +
## density_window_ahead_m] (DirectorTuning), per km per lane. See docs/SPAWNING.md,
## "Density (D11)".
##
##   var row := DensitySurvey.cell(3, 8, DensitySurvey.SCRIPTED)   # {"density", "ratio", ...}
##   var rows := DensitySurvey.table([3, 4], [1, 2, ..., 8], DensitySurvey.SCRIPTED)
##
## Every cell drives `seeds` fresh soak runs at one fixed leg (leg density, mix and
## aggressive share), `runs_km` each, and samples every SAMPLE_S after WARMUP_S (the
## prefill puts nothing behind the player).

## Player profiles:
## - "scripted": the density a player at typical speeds meets. A scripted observer
##   drives at a speed redrawn every SCRIPTED_HOLD_S in [150, 250] km/h, off the
##   carriageway (beside the right lane), so traffic neither follows nor yields to it
##   and its speed never depends on the traffic: the director alone decides what it
##   meets. (A bot that has to follow traffic averages ~120-140 km/h at legs 4-8
##   whatever speed it wants, i.e. it rides along with the left lanes.)
## - "bot": the soak bot weaving at 150-250 km/h (follows traffic, changes lanes).
## - "soak": the soak bot as in the soak (110-250 km/h, weaving 60% of legs, lane
##   keeping and following in the rest).
const SCRIPTED := &"scripted"
const BOT := &"bot"
const SOAK := &"soak"

const SEED := 480801
const SAMPLE_S := 0.5
const WARMUP_S := 20.0
const TYPICAL_MIN_KMH := 150.0
const TYPICAL_MAX_KMH := 250.0
const TYPICAL_WEAVE_PCT := 100.0
const SCRIPTED_HOLD_S := 15.0
## The observer drives this many lanes right of the rightmost lane's center.
const SCRIPTED_OFFSET_LANES := 2
## Near-ahead band reported separately: what the player is about to meet.
const NEAR_AHEAD_M := 300.0
const LEG_KM := 3.5


## One (lanes, leg) cell. `seeds` runs of `legs_per_run` x LEG_KM, all at `leg`.
static func cell(lanes: int, leg: int, profile: StringName, seeds: int = 3, legs_per_run: int = 2,
		base: Tuning = null, leg_km: float = LEG_KM) -> Dictionary:
	var b := base if base != null else Tuning.load_default()
	var t: Tuning = b.duplicate()
	t.traffic = b.traffic.duplicate() as TrafficTuning
	t.traffic.soak_lane_counts = PackedInt32Array([lanes])
	if profile == BOT or profile == SCRIPTED:
		t.traffic.soak_bot_min_kmh = TYPICAL_MIN_KMH
		t.traffic.soak_bot_max_kmh = TYPICAL_MAX_KMH
		t.traffic.soak_bot_weave_pct = TYPICAL_WEAVE_PCT
	var behind := t.director.density_window_behind_m
	var ahead := t.director.density_window_ahead_m
	var window_km := (behind + ahead) / Units.M_PER_KM
	var near_km := NEAR_AHEAD_M / Units.M_PER_KM
	var samples := 0
	var in_window := 0
	var in_near := 0
	var lane_n := PackedInt64Array()
	lane_n.resize(lanes)
	var active_sum := 0
	var peak := 0
	var ticks := 0
	var sim_usec := 0
	var dir_usec := 0
	var at_cap := 0
	var bad := 0
	var target := 0.0
	var speed_sum := 0.0
	var gain_sum := 0.0
	var topups := 0
	var aheads := 0
	for k in seeds:
		var r := TrafficSoakRun.new(k, SEED + 7919 * leg + 104729 * lanes, legs_per_run, leg_km * Units.M_PER_KM, t, leg,
			null, TrafficSoakRun.BOT_WEAVE)
		r.check_windows = false
		target = r.director.target_density_per_km_lane()
		var observer := profile == SCRIPTED
		var obs_rng := Rng.new(Rng.derive_seed(r.seed_value, "density_observer"))
		var next_speed := 0.0
		if observer:
			_observer_speed(r, obs_rng, t)
			r.director.reset(r.bot.state)
		var next := WARMUP_S
		while not r.finished:
			if observer:
				if r.time >= next_speed:
					next_speed += SCRIPTED_HOLD_S
					_observer_speed(r, obs_rng, t)
				_observer_tick(r, lanes)
			else:
				r.tick()
			if r.time < next:
				continue
			next += SAMPLE_S
			var ts := r.sim.state
			var ps := r.bot.state.s
			samples += 1
			speed_sum += r.bot.state.v
			gain_sum += r.director.density_gain
			for i in ts.capacity:
				if ts.active[i] == 0:
					continue
				var rel := ts.s[i] - ps
				if rel >= -behind and rel <= ahead:
					in_window += 1
					if ts.lane[i] >= 0 and ts.lane[i] < lanes:
						lane_n[ts.lane[i]] += 1
				if rel >= 0.0 and rel <= NEAR_AHEAD_M:
					in_near += 1
		var d := r.result()
		topups += r.director.spawned_topup
		aheads += r.director.spawned_ahead
		active_sum += roundi(float(d["mean_active"]) * float(d["ticks"]))
		ticks += int(d["ticks"])
		peak = maxi(peak, int(d["peak_active"]))
		at_cap += int(d["ticks_at_cap"])
		sim_usec += roundi(float(d["sim_usec_per_tick"]) * float(d["ticks"]))
		dir_usec += roundi(float(d["director_usec_per_tick"]) * float(d["ticks"]))
		bad += int(d["collision_pairs"]) + int(d["signal_violations"]) + int(d["ambush_violations"]) \
			+ int(d["unsignaled_moves"]) + int(d["decel_violations"]) + int(d["rear_end_normal"])
	var n := float(maxi(samples, 1))
	var density := float(in_window) / n / (window_km * float(lanes))
	var per_lane: Array[float] = []
	for l in lanes:
		per_lane.append(float(lane_n[l]) / n / window_km)
	return {
		"lanes": lanes, "leg": leg, "profile": String(profile), "target": target, "density": density,
		"ratio": density / target if target > 0.0 else 0.0,
		"near_density": float(in_near) / n / (near_km * float(lanes)),
		"per_lane": per_lane, "vehicles_in_window": float(in_window) / n,
		"mean_active": float(active_sum) / float(maxi(ticks, 1)), "peak_active": peak,
		"at_cap_pct": 100.0 * float(at_cap) / float(maxi(ticks, 1)),
		"sim_usec": float(sim_usec) / float(maxi(ticks, 1)), "director_usec": float(dir_usec) / float(maxi(ticks, 1)),
		"player_kmh": speed_sum / n / Units.kmh_to_mps(1.0), "violations": bad, "gain": gain_sum / n,
		"topup_pct": 100.0 * float(topups) / float(maxi(aheads, 1)),
	}


static func _observer_speed(r: TrafficSoakRun, rng: Rng, t: Tuning) -> void:
	r.bot.state.v = Units.kmh_to_mps(rng.float_range(t.traffic.soak_bot_min_kmh, t.traffic.soak_bot_max_kmh))
	r.bot.state.d = r.road.lane_center_d(r.lanes - 1 + SCRIPTED_OFFSET_LANES, r.bot.state.s)


## One tick with the observer: it moves, traffic and the director step (no rule checks,
## nothing touches it).
static func _observer_tick(r: TrafficSoakRun, lanes: int) -> void:
	var st := r.bot.state
	st.s += st.v * TrafficSoakRun.DT
	st.d = r.road.lane_center_d(lanes - 1 + SCRIPTED_OFFSET_LANES, st.s)
	var u0 := Time.get_ticks_usec()
	r.sim.step(TrafficSoakRun.DT, st, null, r.events)
	var u1 := Time.get_ticks_usec()
	r.events.clear()
	r.director.step(TrafficSoakRun.DT, st)
	r.director_usec += Time.get_ticks_usec() - u1
	r.sim_usec += u1 - u0
	r.active_sum += r.sim.state.count
	if r.sim.state.count >= r.tuning.traffic.max_active_vehicles:
		r.ticks_at_cap += 1
	r.peak_active = maxi(r.peak_active, r.sim.state.count)
	r.time += TrafficSoakRun.DT
	r.ticks += 1
	if st.s >= r.run_m:
		r.finished = true


static func table(lane_counts: Array[int], legs: Array[int], profile: StringName, seeds: int = 3,
		legs_per_run: int = 2, base: Tuning = null) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for lanes in lane_counts:
		for leg in legs:
			out.append(cell(lanes, leg, profile, seeds, legs_per_run, base))
	return out


static func format_row(d: Dictionary) -> String:
	var lanes_txt := PackedStringArray()
	for x: float in d["per_lane"]:
		lanes_txt.append("%.1f" % x)
	return "%d lanes leg %d (%s): target %.1f, window %.2f (%.0f%%), near-ahead %.2f, per lane [%s], in window %.1f, active %.1f (peak %d, cap %.0f%%), sim %.0f us, director %.0f us, player %.0f km/h, gain %.2f, top-up %.0f%%, violations %d" % [
		d["lanes"], d["leg"], d["profile"], d["target"], d["density"], 100.0 * float(d["ratio"]), d["near_density"],
		", ".join(lanes_txt), d["vehicles_in_window"], d["mean_active"], d["peak_active"], d["at_cap_pct"],
		d["sim_usec"], d["director_usec"], d["player_kmh"], d.get("gain", 1.0), d.get("topup_pct", 0.0), d["violations"]]
