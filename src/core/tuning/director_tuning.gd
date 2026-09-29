class_name DirectorTuning
extends Resource
## Traffic director: intensity waves, difficulty by leg, crest caps, set-piece rules.
## Spec: Traffic → Traffic director, fairness rules 4 and 6, Passability (batch length).
## Saved as data/tuning/director.tres. Per-set-piece numbers live in SetPieceDef data.

@export_group("Intensity waves (WP6.2, docs/SPAWNING.md \"Intensity waves\")")
## A cycle (build, peak, breather) lasts this long at the reference pace.
@export var wave_period_min_s: float = 45.0
@export var wave_period_max_s: float = 90.0
@export var breather_min_s: float = 10.0
@export var breather_max_s: float = 15.0
## "Every leg ends with a short breather before the checkpoint": its length (it is the
## breather of the leg's last cycle).
@export var checkpoint_breather_min_s: float = 10.0
@export var checkpoint_breather_max_s: float = 15.0
## The waves are laid out along the road: a cycle's seconds become meters at this pace
## (a typical sun-chasing speed). A slower player takes longer to drive a cycle.
@export var wave_reference_pace_kmh: float = 160.0   # not in spec
## Share of a cycle's build + peak that is peak (drawn per cycle).
@export var wave_peak_min_pct: float = 25.0   # not in spec
@export var wave_peak_max_pct: float = 40.0   # not in spec
## Intensity at the start of a build (it rises linearly to 1 at the peak; a breather is 0).
@export var wave_build_start_intensity: float = 0.5   # not in spec
## Density at intensity 0 (a breather) and 1 (a peak), % of the leg's target density.
## Linear in between. Plan D17 (WP6.6): breathers 50 -> 70 % (at leg 8 the peaks sit at
## IDM's ceiling, so deep breathers only took density away: 74 % of the leg-8 target).
@export var wave_breather_density_pct: float = 70.0   # not in spec
@export var wave_peak_density_pct: float = 125.0   # not in spec
## The meeting map (which part of the wave a vehicle planned now belongs to): the
## player meets a vehicle ahead in a lane slower than itself at its closing speed. The
## closing speed is floored at this, and the map reaches at most this far ahead.
@export var wave_min_closing_kmh: float = 10.0   # not in spec
@export var wave_meet_lookahead_m: float = 4000.0   # not in spec
## Time constant of the player's smoothed pace used by the meeting map.
@export var wave_pace_smoothing_s: float = 5.0   # not in spec
## Samples per lane for the wave-shaped density target of the density window.
@export var wave_window_samples: int = 8   # not in spec
## Batches overlap traffic of earlier batches (it drove into them), and Flow fills the
## gaps between live vehicles (and the band top-up adds to lanes) to keep lanes dense as
## IDM stretches them. Neither happens where the waves' density multiplier is below
## this, so breathers (50%) and blind windows (60%) stay thin; builds and peaks fill.
@export var wave_fill_min_mult: float = 0.75   # not in spec
## The density gain integrates the window's error low-passed over this long, so the
## waves (which the window follows with a lag) do not swing it.
@export var wave_gain_smoothing_s: float = 20.0   # not in spec

@export_group("Difficulty by leg (ramps linearly first -> last leg, then holds)")
@export var ramp_first_leg: int = 1
@export var ramp_last_leg: int = 8
@export var density_first_per_km_lane: float = 8.0
## Plan D11 (owner, M3): the spec's 16 at leg 8 raised; see density_window_*.
@export var density_last_per_km_lane: float = 18.0
@export var aggressive_share_first_pct: float = 5.0
@export var aggressive_share_last_pct: float = 20.0
@export var hesitant_first_leg: int = 3

@export_group("Fairness")
## Within this distance after a blind crest or bend: density capped, no set pieces.
@export var blind_window_m: float = 150.0
@export var blind_density_cap_pct: float = 60.0
## Set pieces may exceed the 6 m/s^2 deceleration clamp only if announced this far ahead.
@export var set_piece_min_warning_m: float = 300.0

@export_group("Set pieces (WP6.2, docs/SET_PIECES.md)")
## "Set piece variety grows": the kinds in the order they unlock (data/set_pieces/<id>.tres;
## ids without a file are skipped), and how many of them are unlocked at legs 1, 2, ...
## (the last value holds). A SetPieceDef's own min_leg also applies.
@export var set_piece_unlock_order: Array[StringName] = [&"truck_wall", &"rolling_roadblock", &"slalom",
		&"convoy", &"merge_zone", &"road_works", &"tunnel_squeeze"]   # not in spec: the order
@export var set_pieces_unlocked_by_leg: PackedInt32Array = [1, 2, 3, 4, 5, 6, 7, 7]   # not in spec
## "Peak (often a set piece)": the chance a wave peak gets one, ramped like the density.
@export var set_piece_chance_first_pct: float = 50.0   # not in spec
@export var set_piece_chance_last_pct: float = 80.0   # not in spec
## Set pieces live at once (scheduled or running).
@export var set_piece_max_active: int = 1   # not in spec
## Scripted speeds stay at least this far above the minimum speed, so following a set
## piece is always a valid path (passability) and only threading it scores.
@export var set_piece_min_speed_margin_kmh: float = 5.0   # not in spec
## No set piece is met within these ranges around a checkpoint (the landmark and its
## signs; the suspension bridge spans 360 m), ...
@export var set_piece_checkpoint_clear_before_m: float = 600.0   # not in spec
@export var set_piece_checkpoint_clear_after_m: float = 400.0   # not in spec
## ... nor does one drive through this range around a lane-count change, tunnel or fork
## (road-dependent pieces get their own road hooks in WP6.3).
@export var set_piece_feature_clear_m: float = 200.0   # not in spec
## A piece that does not fit the live traffic at its planned rear is tried this much
## further ahead, up to the end of its batch.
@export var set_piece_placement_step_m: float = 10.0   # not in spec
## A peak gets a piece only if the player, at the smoothed pace, would reach it within
## this share of the piece's approach_max_s (the rest is slack for the pace changing):
## a piece a slow player would never meet is not spawned.
@export_range(0.0, 100.0) var set_piece_meet_max_pct: float = 75.0   # not in spec

@export_group("Density around the player (plan D11; not in spec)")
## The window the director's effective density is measured over (dev report, the
## density survey): [player s - behind, player s + ahead].
@export var density_window_behind_m: float = 150.0   # not in spec
@export var density_window_ahead_m: float = 600.0   # not in spec
## The effective density is measured this often; its relative shortfall is integrated
## into the planning gain at this rate (per second per unit of relative error).
@export var density_control_interval_s: float = 0.25   # not in spec
@export var density_gain_rate_per_s: float = 0.05   # not in spec: slow (spawns reach the window 10-40 s later)
## Planning gain range (1 = the target density exactly).
@export var density_gain_min: float = 0.7   # not in spec
## Plan D17 (WP6.6): 1.5 -> 1.8 (the leg-8 gain sat at 1.5 with the waves and faster lanes).
@export var density_gain_max: float = 1.8   # not in spec
## After each batch, lanes the player is catching (their flow speed + this below the
## player's speed) are topped up to target x gain in the band beyond the fog.
@export var density_topup_speed_margin_kmh: float = 10.0   # not in spec
## At most this many top-up spawns per batch (keeps the director-rate cost bounded).
@export var density_topup_max_per_batch: int = 16   # not in spec

@export_group("Closer following in late legs (plan D11; not in spec)")
## Every driver profile's IDM time headway T is scaled by this, ramped like the density
## (first -> last leg). IDM's equilibrium gaps, not the director, cap how dense a lane
## can stay at its flow speed (~13-14 vehicles per km per lane with the profiles' own
## T around a fast player); denser late legs need closer following.
@export var headway_scale_first: float = 1.0   # not in spec
## Plan D17 (WP6.6): 0.8 -> 0.55, the ceiling for waves and faster lanes (D15) at leg 8.
@export var headway_scale_last: float = 0.55   # not in spec

@export_group("Behind spawns: the view test (orchestrator, D11; not in spec)")
## Fairness rule 5 ("behind the camera frustum") as a fixed virtual view volume, not the
## live camera: a road point more than this far behind the player is out of view, any
## other is in view. Every camera mode sits <= 11 m behind the car and looks forward,
## so a behind spawn (spawn_behind_m, ~150 m) is never visible, and camera mode and
## screen aspect never change traffic (leaderboards, Daily Drive on every device).
@export var behind_spawn_view_margin_m: float = 25.0   # not in spec

@export_group("Batches")
@export var spawn_batch_length_m: float = 300.0


## 0 at ramp_first_leg, 1 at ramp_last_leg and beyond. Legs are 1-based.
func leg_ramp(leg: int) -> float:
	return clampf(float(leg - ramp_first_leg) / float(ramp_last_leg - ramp_first_leg), 0.0, 1.0)


func density_per_km_lane(leg: int) -> float:
	return lerpf(density_first_per_km_lane, density_last_per_km_lane, leg_ramp(leg))


func headway_scale(leg: int) -> float:
	return lerpf(headway_scale_first, headway_scale_last, leg_ramp(leg))


func aggressive_share_frac(leg: int) -> float:
	return Units.pct_to_frac(lerpf(aggressive_share_first_pct, aggressive_share_last_pct, leg_ramp(leg)))


## The chance (0..1) that a wave peak on `leg` gets a set piece.
func set_piece_chance_frac(leg: int) -> float:
	return Units.pct_to_frac(lerpf(set_piece_chance_first_pct, set_piece_chance_last_pct, leg_ramp(leg)))


## How many kinds of set_piece_unlock_order are unlocked on `leg` (1-based).
func set_pieces_unlocked(leg: int) -> int:
	var n := set_pieces_unlocked_by_leg.size()
	if n == 0:
		return set_piece_unlock_order.size()
	return clampi(set_pieces_unlocked_by_leg[clampi(leg - 1, 0, n - 1)], 0, set_piece_unlock_order.size())


## Density multiplier (x the leg's target) at wave intensity `intensity` (0..1).
func wave_density_mult(intensity: float) -> float:
	return Units.pct_to_frac(lerpf(wave_breather_density_pct, wave_peak_density_pct, clampf(intensity, 0.0, 1.0)))


# ---------------------------------------------------------------- Fast traffic (plan D15, WP6.6)

## The Racer's share (190-250 km/h sports cars, plan D15; owner, M5 playtest), ramped
## like the aggressive share, wherever it may spawn (its profile's left lanes). With
## the aggressive share (5 -> 20 %) the fast traffic rises from 15 % at leg 1 to 35 %
## at leg 8 of the lanes both may use. A lane only fast profiles fit (the leftmost
## lane, see TrafficTuning.lane_flow_speeds_from_right_kmh) is all fast: the two share
## it in proportion.
@export_group("Fast traffic (plan D15; not in spec)")
@export var racer_share_first_pct: float = 10.0   # not in spec
@export var racer_share_last_pct: float = 15.0   # not in spec


func racer_share_frac(leg: int) -> float:
	return Units.pct_to_frac(lerpf(racer_share_first_pct, racer_share_last_pct, leg_ramp(leg)))


# ---------------------------------------------------------------- Racers from behind (plan D17, WP6.7)

## Owner decision (plan D17: "Yes, pass me at speed"): behind spawns need the player to
## be slower than a lane's flow, so a player at 170-230 km/h only ever met racers ahead.
## Racer arrivals: a seeded process of fast cars (racers, and aggressive drivers when
## theirs can be) spawned out of view behind the player whenever the arriving car's OWN
## desired speed beats the player's by racer_arrival_speed_margin_kmh. They pass it
## legally (IDM gaps at spawn, MOBIL with blinkers, no-ambush, rear-end prevention).
## See docs/SPAWNING.md "Racers from behind (WP6.7)".
@export_group("Racers from behind (plan D17, WP6.7; not in spec)")
## Seconds between arrivals, drawn uniformly per arrival, ramped like the density from
## leg 1 to leg 8. The clock runs at the wave's density multiplier where the player is
## and stops in breathers (wave, fork and finale) and near set pieces.
@export var racer_arrival_interval_first_min_s: float = 20.0   # not in spec
@export var racer_arrival_interval_first_max_s: float = 40.0   # not in spec
@export var racer_arrival_interval_last_min_s: float = 10.0   # not in spec
@export var racer_arrival_interval_last_max_s: float = 20.0   # not in spec
## An arrival's desired speed is drawn at least this far above the player's speed (and
## its spawn speed never goes below it), so it always closes on the player.
@export var racer_arrival_speed_margin_kmh: float = 15.0   # not in spec
## Share of the arrivals drawn as aggressive drivers (when the profile's top speed beats
## the player's by the margin; otherwise a racer arrives).
@export var racer_arrival_aggressive_pct: float = 25.0   # not in spec
## A due arrival that finds no lane (visible, the gaps don't fit, the lane is not clear
## to the player) retries after this.
@export var racer_arrival_retry_s: float = 0.5   # not in spec
## Spawn points tried, farthest first: spawn_behind_m (TrafficTuning, ~150 m) behind the
## player, then this much closer at a time down to racer_arrival_behind_min_m (every one
## far beyond behind_spawn_view_margin_m, so out of view in every camera mode).
@export var racer_arrival_behind_min_m: float = 90.0   # not in spec
@export var racer_arrival_behind_step_m: float = 20.0   # not in spec
## No arrival while a requested breather (fork approach, journey finale) or a live set
## piece's zone lies within this far ahead of the player: a racer passing now would
## reach it (the fork guard would remove it in view; it would drive into the piece).
@export var racer_arrival_clear_ahead_m: float = 2000.0   # not in spec
## A clear run: holding its spawn speed, the arrival must get this far past the player
## (the player and the lane's traffic predicted at their speeds) before any slower car
## in its lane makes it brake below the player's speed, so it passes instead of
## queueing, out of view, behind a car the player is passing.
@export var racer_arrival_pass_clear_m: float = 40.0   # not in spec
## Racers passing the player / overtaken by it (DevStats, the dev report) are counted
## this often (a dev counter; the side test has hysteresis).
@export var racer_pass_check_interval_s: float = 0.1   # not in spec


## Seconds to the next arrival on `leg` for a uniform draw `u` in [0, 1].
func racer_arrival_interval_s(leg: int, u: float) -> float:
	var k := leg_ramp(leg)
	var lo := lerpf(racer_arrival_interval_first_min_s, racer_arrival_interval_last_min_s, k)
	var hi := lerpf(racer_arrival_interval_first_max_s, racer_arrival_interval_last_max_s, k)
	return lerpf(lo, hi, clampf(u, 0.0, 1.0))
