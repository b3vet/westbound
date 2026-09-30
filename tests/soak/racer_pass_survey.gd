class_name RacerPassSurvey
extends RefCounted
## Racers passing a fast player through full traffic (plan D17, WP6.7's finding; WP6.9
## "racers weave harder"). Spec: Traffic → Spawning (faster vehicles from behind),
## Driver types, Fairness rules. A test observer, the WP6.7 harness: TrafficSoakRun (the
## real sim, director, registry and procedural road) at one fixed leg with the density
## survey's observer (DensitySurvey: off the carriageway, so traffic neither follows nor
## yields to it) held at a steady speed. It counts, per km the observer drives:
##   - arrivals (WP6.7's racers from behind) and the arrivals that got past it;
##   - racers of any origin that passed it / that it overtook (the director's counters);
## and it checks the weaving itself (the rule checker runs every tick; the observer is
## off the road, so only traffic-to-traffic rules can trip):
##   - `cut_ins`: racer lane moves with a traffic car behind in the target lane, and
##     `cut_in_min_raw_mps2` the hardest raw IDM deceleration (before the sim's 6 m/s^2
##     clamp) any such car needs while the racer is its leader, over the move and
##     CUT_IN_WATCH_S after it: the move must never need the clamp;
##   - `racer_max_moves_10s`: the most lateral moves one racer started in any
##     ZIGZAG_WINDOW_S (readability).
## See docs/SPAWNING.md, "Racers weave harder (WP6.9)".
##
##   var row := RacerPassSurvey.cell(3, 8, 200.0)    # {"arrivals_per_km", "passes_per_km", ...}

const SEED := 690901
const WARMUP_S := 20.0
const CUT_IN_WATCH_S := 5.0
const ZIGZAG_WINDOW_S := 10.0
## Cut-in watch slots (racer moves in flight at once).
const MAX_WATCH := 64
## Moves remembered per racer slot (the zig-zag window).
const ZIGZAG_MEMORY := 8


## One cell: `seeds` runs of `legs_per_run` x `leg_km` at `leg` on `lanes` lanes, the
## observer at `kmh`. `base`: tuning (null = the defaults).
static func cell(lanes: int, leg: int, kmh: float, seeds: int = 4, legs_per_run: int = 2, leg_km: float = 3.75,
		base: Tuning = null) -> Dictionary:
	var b := base if base != null else Tuning.load_default()
	var t: Tuning = b.duplicate()
	t.traffic = b.traffic.duplicate() as TrafficTuning
	t.traffic.soak_lane_counts = PackedInt32Array([lanes])
	t.traffic.soak_bot_min_kmh = kmh
	t.traffic.soak_bot_max_kmh = kmh
	var km := 0.0
	var arrivals := 0
	var arrivals_passed := 0
	var racers_passed := 0
	var overtaken := 0
	var bad := 0
	var collisions := 0
	var cut_ins := 0
	var cut_in_min := 0.0
	var cut_in_over_clamp := 0
	var max_moves := 0
	var racer_moves := 0
	var racer_v := 0.0
	var racer_n := 0
	var in_window := 0
	var samples := 0
	var behind := t.director.density_window_behind_m
	var ahead := t.director.density_window_ahead_m
	var window_km := (behind + ahead) / Units.M_PER_KM
	var clamp_mps2 := t.traffic.max_decel_mps2
	for k in seeds:
		var r := TrafficSoakRun.new(k, SEED + 7919 * leg + 104729 * lanes + roundi(kmh), legs_per_run,
			leg_km * Units.M_PER_KM, t, leg)
		r.check_windows = false
		var obs_rng := Rng.new(Rng.derive_seed(r.seed_value, "racer_pass_observer"))
		DensitySurvey._observer_speed(r, obs_rng, t)
		r.director.reset(r.bot.state)
		var racer := r.registry.profile_index(&"racer")
		var st := r.sim.state
		# Cut-in watches: follower slot, its vehicle id, the racer slot, until when.
		var w_f := PackedInt32Array()
		var w_fid := PackedInt32Array()
		var w_r := PackedInt32Array()
		var w_until := PackedFloat64Array()
		# Per slot: the vehicle id seen, its last lc_state, its recent move start times.
		var seen_vid := PackedInt32Array()
		seen_vid.resize(st.capacity)
		seen_vid.fill(-1)
		var prev_lc := PackedInt32Array()
		prev_lc.resize(st.capacity)
		var move_t := PackedFloat64Array()
		move_t.resize(st.capacity * ZIGZAG_MEMORY)
		var move_n := PackedInt32Array()
		move_n.resize(st.capacity)
		var next_sample := WARMUP_S
		var s_start := 0.0
		var base_arr := 0
		var base_arr_passed := 0
		var base_passed := 0
		var base_over := 0
		var warm := false
		while not r.finished:
			_observer_tick(r, lanes)
			if not warm and r.time >= WARMUP_S:
				warm = true
				s_start = r.bot.state.s
				base_arr = r.director.racer_arrivals
				base_arr_passed = r.director.arrivals_passed_player
				base_passed = r.director.racers_passed_player
				base_over = r.director.racers_overtaken
			for i in st.capacity:
				if st.active[i] == 0 or st.profile_id[i] != racer:
					continue
				if seen_vid[i] != st.vehicle_id[i]:
					seen_vid[i] = st.vehicle_id[i]
					prev_lc[i] = st.lc_state[i]
					move_n[i] = 0
					continue
				var lc := st.lc_state[i]
				if lc == TrafficState.LaneChange.MOVING and prev_lc[i] != lc and st.target_lane[i] != st.lane[i]:
					if warm:
						racer_moves += 1
					# Zig-zag: moves this racer started within the window.
					var m := move_n[i]
					move_t[i * ZIGZAG_MEMORY + m % ZIGZAG_MEMORY] = r.time
					move_n[i] = m + 1
					var in_win := 0
					for q in mini(m + 1, ZIGZAG_MEMORY):
						if r.time - move_t[i * ZIGZAG_MEMORY + q] < ZIGZAG_WINDOW_S:
							in_win += 1
					max_moves = maxi(max_moves, in_win)
					# The new follower in the target lane: the nearest traffic car behind.
					var f := _follower_in_lane(r, i, st.target_lane[i])
					if f >= 0 and w_f.size() < MAX_WATCH:
						cut_ins += 1
						w_f.append(f)
						w_fid.append(st.vehicle_id[f])
						w_r.append(i)
						w_until.append(r.time + st.lc_duration[i] + CUT_IN_WATCH_S)
				prev_lc[i] = lc
			var q := 0
			while q < w_f.size():
				var f := w_f[q]
				if r.time > w_until[q] or st.active[f] == 0 or st.vehicle_id[f] != w_fid[q]:
					w_f.remove_at(q)
					w_fid.remove_at(q)
					w_r.remove_at(q)
					w_until.remove_at(q)
					continue
				if r.sim.leader_of(f) == w_r[q]:
					var a := r.sim.idm_accel(f)
					if a < cut_in_min:
						cut_in_min = a
					if a < -clamp_mps2:
						cut_in_over_clamp += 1
				q += 1
			if r.time >= next_sample and warm:
				next_sample += 0.5
				samples += 1
				var ps := r.bot.state.s
				for i in st.capacity:
					if st.active[i] == 0:
						continue
					var rel := st.s[i] - ps
					if rel >= -behind and rel <= ahead:
						in_window += 1
					if st.profile_id[i] == racer:
						racer_v += st.v[i]
						racer_n += 1
		km += (r.bot.state.s - s_start) / Units.M_PER_KM
		arrivals += r.director.racer_arrivals - base_arr
		arrivals_passed += r.director.arrivals_passed_player - base_arr_passed
		racers_passed += r.director.racers_passed_player - base_passed
		overtaken += r.director.racers_overtaken - base_over
		var c := r.checker
		collisions += c.collision_pairs
		bad += c.collision_pairs + c.signal_violations + c.unsignaled_moves + c.ambush_violations \
			+ c.decel_violations + c.brake_flag_violations + c.offroad_violations
	var kmf := maxf(km, 1e-9)
	return {
		"lanes": lanes, "leg": leg, "kmh": kmh, "km": km,
		"arrivals": arrivals, "arrivals_per_km": float(arrivals) / kmf,
		"arrivals_passed": arrivals_passed, "passes_per_km": float(arrivals_passed) / kmf,
		"racers_passed": racers_passed, "racers_passed_per_km": float(racers_passed) / kmf,
		"racers_overtaken": overtaken, "racers_overtaken_per_km": float(overtaken) / kmf,
		"violations": bad, "collisions": collisions,
		"cut_ins": cut_ins, "cut_in_min_raw_mps2": cut_in_min, "cut_in_beyond_clamp_ticks": cut_in_over_clamp,
		"racer_moves": racer_moves, "racer_max_moves_10s": max_moves,
		"racer_kmh": racer_v / float(maxi(racer_n, 1)) / Units.kmh_to_mps(1.0),
		"density": float(in_window) / float(maxi(samples, 1)) / (window_km * float(lanes)),
	}


## The nearest vehicle behind racer i whose body overlaps lane `lane` (-1: none within
## the IDM lookahead).
static func _follower_in_lane(r: TrafficSoakRun, i: int, lane: int) -> int:
	var st := r.sim.state
	var c := r.road.lane_center_d(lane, st.s[i])
	var half := r.road.lane_width(st.s[i]) * 0.5
	var best := -1
	var best_s := -INF
	for j in st.capacity:
		if j == i or st.active[j] == 0 or st.s[j] >= st.s[i]:
			continue
		if st.s[i] - st.s[j] > r.tuning.traffic.idm_lookahead_m:
			continue
		if absf(st.d[j] - c) < half + st.width[j] * 0.5 and st.s[j] > best_s:
			best_s = st.s[j]
			best = j
	return best


## One tick: the observer moves (off the road), traffic, the rule checker, the director.
static func _observer_tick(r: TrafficSoakRun, lanes: int) -> void:
	var st := r.bot.state
	st.s += st.v * TrafficSoakRun.DT
	st.d = r.road.lane_center_d(lanes - 1 + DensitySurvey.SCRIPTED_OFFSET_LANES, st.s)
	r.sim.step(TrafficSoakRun.DT, st, null, r.events)
	r.events.clear()
	r.checker.observe(r.time, r.sim.state, st)
	r.director.step(TrafficSoakRun.DT, st)
	r.time += TrafficSoakRun.DT
	r.ticks += 1
	if st.s >= r.run_m:
		r.finished = true


static func format_row(d: Dictionary) -> String:
	return "%d lanes leg %d at %.0f km/h (%.1f km): arrivals %.2f/km, passed %.2f/km (%d of %d); racers passed %.2f/km, overtaken %.2f/km; racers %.0f km/h; density %.2f; cut-ins %d (hardest raw %.2f m/s^2, %d ticks beyond the clamp); racer moves %d (max %d in 10 s); violations %d" % [
		d["lanes"], d["leg"], d["kmh"], d["km"], d["arrivals_per_km"], d["passes_per_km"], d["arrivals_passed"],
		d["arrivals"], d["racers_passed_per_km"], d["racers_overtaken_per_km"], d["racer_kmh"], d["density"],
		d["cut_ins"], d["cut_in_min_raw_mps2"], d["cut_in_beyond_clamp_ticks"], d["racer_moves"],
		d["racer_max_moves_10s"], d["violations"]]
