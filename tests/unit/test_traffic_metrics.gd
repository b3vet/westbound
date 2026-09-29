extends WBTest
## Logged traffic metrics per build (spec: Traffic → Tests (headless): "gaps per km,
## lane changes per vehicle per minute, mean speed per lane, set pieces per leg. A
## regression beyond ±15% on any of them fails the test"), and the D7 cap input
## (plan §2 D7: cap 60 vs ~90 at leg 8). Baseline: tests/baselines/traffic_metrics.json
## (rewrite deliberately: tools/soak.sh --update-baseline). See docs/SOAK.md.

const METRIC_KEYS: Array[String] = [
	"gaps_per_km", "lane_changes_per_vehicle_min", "set_pieces_per_leg", "mean_speed_kmh_lane_0",
	"mean_speed_kmh_lane_1", "mean_speed_kmh_lane_2",
]

## A lane's mean speed stays this close to its flow speed (sanity, fast tier).
const PLAUSIBLE_KMH := 25.0

var t: Tuning


func before_all() -> void:
	t = Tuning.load_default()


func test_metrics_pipeline_on_a_short_run() -> void:
	# Fast tier: the metrics are computed, complete and plausible on a short run, and the
	# committed baseline has every metric. (The ±15% regression check needs the
	# 16-run reference: soak tier.)
	var base := TrafficMetricsReference.load_baseline()
	if check(base.has("reference"), "baseline has 'reference' (tools/soak.sh --update-baseline)"):
		var bm: Dictionary = base["reference"]["metrics"]
		for k in METRIC_KEYS:
			check(bm.has(k), "baseline has %s" % k)
	var cur := TrafficMetricsReference.run("fast")
	var m: Dictionary = cur["metrics"]
	print("      fast: %s" % JSON.stringify(m))
	for k in METRIC_KEYS:
		if check(m.has(k), "metric %s" % k):
			finite(float(m[k]), k)
	gt(float(m["gaps_per_km"]), 0.0)
	gt(float(m["lane_changes_per_vehicle_min"]), 0.0)
	ge(float(m["set_pieces_per_leg"]), 0.0, "set pieces per leg (WP6.2: wave peaks get set pieces)")
	var lanes := int(cur["config"]["lanes"])
	for l in lanes:
		var flow := t.traffic.lane_flow_speed_mps(l, lanes) / Units.kmh_to_mps(1.0)
		near(float(m["mean_speed_kmh_lane_%d" % l]), flow, PLAUSIBLE_KMH, "lane %d mean speed near its flow speed" % l)


func soak_metrics_reference_matches_baseline() -> void:
	var base := TrafficMetricsReference.load_baseline()
	if not check(base.has("reference"), "baseline has 'reference' (tools/soak.sh --update-baseline)"):
		return
	var bm: Dictionary = base["reference"]["metrics"]
	var cur := TrafficMetricsReference.run("reference")
	var cm: Dictionary = cur["metrics"]
	print("      reference (%d runs, %.0f km): %s" % [cur["config"]["runs"], cur["config"]["km"], JSON.stringify(cm)])
	var bad := TrafficMetrics.compare(cm, bm, t.traffic.metrics_tolerance_pct)
	for line in bad:
		print("        regression: ", line)
	eq(bad.size(), 0, "reference metrics within ±%.0f%% of the baseline" % t.traffic.metrics_tolerance_pct)


func test_compare_flags_regressions_beyond_tolerance() -> void:
	var base := {"a": 10.0, "b": 2.0, "zero": 0.0, "gone": 1.0}
	eq(TrafficMetrics.compare({"a": 11.4, "b": 1.72, "zero": 0.0, "gone": 1.0}, base, 15.0).size(), 0, "inside ±15%")
	eq(TrafficMetrics.compare({"a": 11.6, "b": 2.0, "zero": 0.0, "gone": 1.0}, base, 15.0).size(), 1, "+16%")
	eq(TrafficMetrics.compare({"a": 10.0, "b": 1.6, "zero": 0.0, "gone": 1.0}, base, 15.0).size(), 1, "-20%")
	eq(TrafficMetrics.compare({"a": 10.0, "b": 2.0, "zero": 0.1, "gone": 1.0}, base, 15.0).size(), 1, "0 must stay 0")
	eq(TrafficMetrics.compare({"a": 10.0, "b": 2.0, "zero": 0.0}, base, 15.0).size(), 1, "a missing metric fails")


func test_metric_definitions_on_a_known_layout() -> void:
	var road := StraightRoadPath.new(2, t.road)
	var ts := TrafficState.new(8)
	var player := VehicleState.new()
	player.s = 0.0
	# Lane 0: sedans (4.8 m) at 100, 130 (gap 25.2 m) and 140 (gap 5.2 m); lane 1: one at 300.
	var lanes := [0, 0, 0, 1]
	var ss := [100.0, 130.0, 140.0, 300.0]
	var vs := [30.0, 30.0, 36.0, 20.0]
	for k in 4:
		var i := ts.allocate()
		ts.s[i] = ss[k]
		ts.v[i] = vs[k]
		ts.lane[i] = lanes[k]
		ts.target_lane[i] = lanes[k]
		ts.length[i] = 4.8
		ts.width[i] = 1.85
	var m := TrafficMetrics.new(t)
	var dt := t.traffic.metrics_sample_interval_s
	m.sample(dt, ts, player, road)
	m.add_lane_changes(2)
	m.add_legs(1)
	var d := m.to_dict()
	var lane_km := 2.0 * t.traffic.spawn_ahead_m / Units.M_PER_KM
	near(float(d["gaps_per_km"]), 1.0 / lane_km, 1e-9, "one gap >= %.0f m" % t.traffic.metrics_gap_min_m)
	near(float(d["density_per_km_lane"]), 4.0 / lane_km, 1e-9)
	near(float(d["mean_speed_kmh_lane_0"]), 32.0 * 3.6, 1e-6)
	near(float(d["mean_speed_kmh_lane_1"]), 20.0 * 3.6, 1e-6)
	near(float(d["lane_changes_per_vehicle_min"]), 2.0 / (4.0 * dt / 60.0), 1e-9)
	eq(float(d["set_pieces_per_leg"]), 0.0, "no set pieces added")
	m.add_legs(1, 3)
	near(float(m.to_dict()["set_pieces_per_leg"]), 1.5, 1e-9, "3 set pieces over 2 legs")


## D7 input: leg-8 density at cap 60 and cap 90 on 3 and 4 lanes (3 seeds each): the
## sim's tick cost, how often the cap binds, the vehicles the director keeps and the
## density the player sees.
func soak_d7_cap_60_vs_90() -> void:
	for lanes_run: int in [0, 3]:
		for cap: int in [60, 90]:
			var tc: Tuning = t.duplicate()
			tc.traffic = t.traffic.duplicate() as TrafficTuning
			tc.traffic.max_active_vehicles = cap
			var sim_us := 0.0
			var dir_us := 0.0
			var active := 0.0
			var at_cap := 0.0
			var peak := 0
			var density := 0.0
			var lanes := 0
			var seeds: Array[int] = [3303, 3304, 3305]
			for sd in seeds:
				var r := TrafficSoakRun.new(lanes_run, sd, 2, 3500.0, tc, 8)
				r.check_windows = false
				r.run_to_end()
				var d := r.result()
				lanes = r.lanes
				sim_us += float(d["sim_usec_per_tick"])
				dir_us += float(d["director_usec_per_tick"])
				active += float(d["mean_active"])
				at_cap += float(d["ticks_at_cap"]) / float(d["ticks"])
				peak = maxi(peak, int(d["peak_active"]))
				density += float(r.metrics.to_dict()["density_per_km_lane"])
				le(int(d["peak_active"]), cap)
				eq(int(d["collision_pairs"]) + int(d["signal_violations"]) + int(d["ambush_violations"]), 0)
			var n := float(seeds.size())
			print("      D7 %d lanes, cap %d: sim %.0f usec/tick, director %.0f usec/tick, mean active %.1f, peak %d, at the cap %.0f%% of ticks, density shown %.2f per km per lane (leg 8 target %.0f)" % [
				lanes, cap, sim_us / n, dir_us / n, active / n, peak, 100.0 * at_cap / n, density / n,
				t.director.density_per_km_lane(8)])
