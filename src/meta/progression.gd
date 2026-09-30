class_name Progression
extends RefCounted
## Driver level math (WP8.2). Spec: Garage and progression ("Driver level. Lifetime banked
## score feeds a driver level. Levels unlock cars, paint colors and rims"). Pure: numbers
## in (ProgressionTuning), numbers out; no save, no nodes. docs/GARAGE.md → Driver level.
##
##   XP for a run  = the run's banked score x xp_per_point (0 outside xp_modes)
##   XP to reach L = level_xp_base x (L - 1) ^ level_xp_exponent   (level 1 = 0 XP)
##   level         = the highest L <= max_level whose XP is reached


## XP a finished run earns (its RunStats.results with the banked score).
static func xp_for_run(results: Dictionary, t: ProgressionTuning) -> int:
	if not counts_for_xp(StringName(str(results.get(RunStats.MODE, &""))), t):
		return 0
	return maxi(roundi(float(int(results.get(RunStats.SCORE, 0))) * t.xp_per_point), 0)


static func counts_for_xp(run_mode: StringName, t: ProgressionTuning) -> bool:
	return t.xp_modes.has(run_mode)


static func counts_for_milestones(run_mode: StringName, t: ProgressionTuning) -> bool:
	return t.milestone_modes.has(run_mode)


## Total lifetime XP needed to reach `level` (0 for level 1 and below).
static func xp_to_reach(level: int, t: ProgressionTuning) -> int:
	if level <= 1:
		return 0
	return roundi(float(t.level_xp_base) * pow(float(level - 1), t.level_xp_exponent))


## The driver level for lifetime `xp` (1 to max_level).
static func level_for_xp(xp: int, t: ProgressionTuning) -> int:
	var level := 1
	while level < t.max_level and xp >= xp_to_reach(level + 1, t):
		level += 1
	return level


## Progress from the current level to the next, 0 to 1 (1 at max_level).
static func level_progress(xp: int, t: ProgressionTuning) -> float:
	var level := level_for_xp(xp, t)
	if level >= t.max_level:
		return 1.0
	var lo := xp_to_reach(level, t)
	var hi := xp_to_reach(level + 1, t)
	return clampf(float(xp - lo) / float(maxi(hi - lo, 1)), 0.0, 1.0)


## XP still needed for the next level (0 at max_level).
static func xp_to_next(xp: int, t: ProgressionTuning) -> int:
	var level := level_for_xp(xp, t)
	if level >= t.max_level:
		return 0
	return maxi(xp_to_reach(level + 1, t) - xp, 0)
