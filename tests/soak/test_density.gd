extends WBTest
## Effective density around the player (plan D11; spec: Traffic → Traffic director,
## "density rises ... per km per lane from leg 1 to leg 8"). DensitySurvey drives the
## real sim and director with a scripted player at 150-250 km/h and counts vehicles in
## the director's density window. Numbers and the before/after table: docs/SPAWNING.md,
## "Density (D11)". Full table: `soak_main.gd -- --density` (see there).

## The effective density tracks the leg's target within this (plan D11: ~8%).
const TRACK_TOLERANCE := 0.10

var t: Tuning


func before_all() -> void:
	t = Tuning.load_default()


func test_survey_pipeline_on_a_short_run() -> void:
	var row := DensitySurvey.cell(3, 8, DensitySurvey.SCRIPTED, 1, 1, null, 2.0)
	print("      %s" % DensitySurvey.format_row(row))
	near(float(row["target"]), t.director.density_per_km_lane(8), 1e-9, "target = the leg ramp")
	gt(float(row["density"]), 0.0)
	finite(float(row["ratio"]))
	gt(float(row["player_kmh"]), DensitySurvey.TYPICAL_MIN_KMH - 1.0, "the observer drives at typical speeds")
	le(int(row["peak_active"]), t.traffic.max_active_vehicles)
	eq(int(row["violations"]), 0)


## Legs 1, 4 and 8 on 3 and 4 lanes: the density a player at typical speeds meets is
## the leg's target (the director's shortfall, 67-94% before D11, is gone), without
## rule violations and without living at the cap.
func soak_effective_density_tracks_target() -> void:
	for lanes: int in [3, 4]:
		for leg: int in [1, 4, 8]:
			var row := DensitySurvey.cell(lanes, leg, DensitySurvey.SCRIPTED, 3, 2)
			print("      %s" % DensitySurvey.format_row(row))
			within_pct(float(row["density"]), float(row["target"]), TRACK_TOLERANCE, "%d lanes leg %d" % [lanes, leg])
			eq(int(row["violations"]), 0)
			lt(float(row["at_cap_pct"]), 5.0, "%d lanes leg %d: the cap rarely binds" % [lanes, leg])
