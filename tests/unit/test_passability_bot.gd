extends WBTest
## The bot driver on passability's path (spec: Traffic → Passability guarantee, "The
## same module runs in tests with a bot driver"). PassabilityBot (tests/soak) drives
## through the real TrafficSim, TrafficDirector (with its passability checks) and the
## procedural road: it never touches a car, never drops below the minimum speed, always
## finds a path, and the independent impossible-window oracle agrees with it.

const SEED := 5150


## Drives run `index` (its lane count: TrafficTuning.soak_lane_counts cycled) for
## `legs` legs of `leg_m` at leg `fixed_leg`'s density; checks the bot's record.
func _drive(index: int, legs: int, leg_m: float, fixed_leg: int, label: String) -> void:
	var r := TrafficSoakRun.new(index, SEED, legs, leg_m, null, fixed_leg)
	var min_v := r.tuning.scoring.min_speed_mps()
	var below := 0
	while not r.finished:
		r.tick()
		if r.bot.state.v < min_v - 1e-6:
			below += 1
	var res := r.result()
	print("      %s: %d lanes, %.1f km at %.0f km/h, %d checks (%.1f ms each), no path %d, contacts %d, windows %d" % [
		label, r.lanes, res["km"], float(res["km"]) * 3600.0 / float(res["sim_s"]), res["bot_checks"],
		float(res["bot_check_usec"]) / maxf(float(res["bot_checks"]), 1.0) / 1000.0, res["bot_no_path_checks"],
		res["contact_episodes"], res["impossible_windows"]])
	check(bool(res["finished"]), "%s: finished" % label)
	eq(int(res["contact_episodes"]), 0, "%s: never touched a car" % label)
	eq(below, 0, "%s: never below the minimum speed" % label)
	eq(int(res["bot_no_path_checks"]), 0, "%s: always had a path" % label)
	eq(int(res["impossible_windows"]), 0, "%s: the oracle agrees" % label)
	eq(int(res["collision_pairs"]), 0, "%s: no traffic collisions" % label)


func test_bot_drives_dense_traffic_on_its_path() -> void:
	_drive(0, 2, 500.0, 8, "leg 8, 3 lanes")


func soak_bot_drives_every_lane_count() -> void:
	# The soak's lane-count cycle (3, 3, 2, 4): legs 1-8 of 2.5 km each.
	for k in 4:
		_drive(k, 8, 2500.0, 0, "run %d" % k)
