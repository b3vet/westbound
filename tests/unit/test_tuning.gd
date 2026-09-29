extends WBTest
## Tuning: loads from data, every section present, and every value of the spec's
## "Tuning reference" table asserted explicitly (one check per value). Spec: Tuning
## reference; Architecture rule 3; plan deviation D3.

const EPS := 1e-9

var t: Tuning


func before_all() -> void:
	t = Tuning.load_default()


# ---------------------------------------------------------------- Loading

func test_load_default_loads_and_caches() -> void:
	if not check(t != null, "Tuning.load_default() returned null"):
		return
	check(Tuning.load_default() == t, "load_default must return the cached instance")
	eq(t.resource_path, Tuning.DEFAULT_PATH)


func test_every_section_present_and_typed() -> void:
	eq(t.missing_sections(), PackedStringArray(), "missing tuning sections")
	check(t.quality is QualityTuning)
	check(t.road is RoadTuning)
	check(t.vehicle is VehicleTuning)
	check(t.controls is ControlsTuning)
	check(t.camera is CameraTuning)
	check(t.traffic is TrafficTuning)
	check(t.director is DirectorTuning)
	check(t.passability is PassabilityTuning)
	check(t.scoring is ScoringTuning)
	check(t.lives is LivesTuning)
	check(t.sun is SunTuning)
	check(t.legs is LegsTuning)
	check(t.feel is FeelTuning)
	check(t.hud is HudTuning)
	check(t.progression is ProgressionTuning)


func test_sections_are_separate_files() -> void:
	# D3: each system's tuning lives in its own data/tuning/<section>.tres.
	for section: String in Tuning.section_names():
		var res: Resource = t.get(section)
		if not check(res != null, section):
			continue
		eq(res.resource_path, "res://data/tuning/%s.tres" % section, section)


func test_quality_tier_arrays_are_consistent() -> void:
	var q := t.quality
	var n := q.tier_names.size()
	eq(q.render_scale.size(), n)
	eq(q.msaa_samples.size(), n)
	eq(q.view_distance_m.size(), n)
	eq(q.particle_scale.size(), n)
	ge(q.tier_index(q.default_tier), 0, "default tier must be a tier name")


# ---------------------------------------------------------------- Tuning reference table (spec)

func test_ref_physics_tick() -> void:
	# 120 Hz (far traffic 30 Hz beyond 200 m)
	eq(t.vehicle.physics_tick_hz, 120)
	eq(t.traffic.near_tick_hz, 120)
	eq(t.traffic.far_tick_hz, 30)
	near(t.traffic.near_radius_m, 200.0, EPS)


func test_ref_frame_cap() -> void:
	# 60 fps gameplay, 30 fps menus
	eq(t.quality.gameplay_fps, 60)
	eq(t.quality.menu_fps, 30)


func test_ref_render_scale() -> void:
	# 0.6 / 0.75 / 0.9 (Low / Medium / High)
	var q := t.quality
	near(q.render_scale[q.tier_index("low")], 0.6, EPS)
	near(q.render_scale[q.tier_index("medium")], 0.75, EPS)
	near(q.render_scale[q.tier_index("high")], 0.9, EPS)


func test_ref_view_distance() -> void:
	# 500 / 700 / 800 m
	var q := t.quality
	near(q.view_distance_m[q.tier_index("low")], 500.0, EPS)
	near(q.view_distance_m[q.tier_index("medium")], 700.0, EPS)
	near(q.view_distance_m[q.tier_index("high")], 800.0, EPS)


func test_ref_lane_width_and_shoulder() -> void:
	# 3.6 m / 3.0 m
	near(t.road.lane_width_m, 3.6, EPS)
	near(t.road.shoulder_m, 3.0, EPS)


func test_ref_lanes_per_direction() -> void:
	# 3 (biomes 2-4)
	eq(t.road.lanes_default, 3)
	eq(t.road.lanes_min, 2)
	eq(t.road.lanes_max, 4)


func test_ref_curve_radius_and_grade() -> void:
	# 1,200 m or more / 5% max
	near(t.road.min_curve_radius_m, 1200.0, EPS)
	near(t.road.max_grade_pct, 5.0, EPS)


func test_ref_floating_origin() -> void:
	# every 2 km
	near(t.road.floating_origin_shift_km, 2.0, EPS)


func test_ref_lane_change_time() -> void:
	# 0.80 / 1.00 / 1.15 s at 100 / 200 / 280 km/h
	var v := t.vehicle
	eq(v.lane_change_speeds_kmh, PackedFloat64Array([100.0, 200.0, 280.0]))
	near(v.lane_change_times_s[0], 0.80, EPS)
	near(v.lane_change_times_s[1], 1.00, EPS)
	near(v.lane_change_times_s[2], 1.15, EPS)
	near(v.lane_change_tolerance_pct, 5.0, EPS)


func test_ref_max_steer_angle() -> void:
	# 30 deg at 0 km/h -> 3.5 deg at 250 km/h
	near(t.vehicle.steer_max_deg_at_rest, 30.0, EPS)
	near(t.vehicle.steer_max_deg_at_speed, 3.5, EPS)
	near(t.vehicle.steer_ease_end_kmh, 250.0, EPS)


func test_ref_braking() -> void:
	near(t.vehicle.braking_mps2, 9.0, EPS)


func test_ref_minimum_speed() -> void:
	near(t.scoring.min_speed_kmh, 100.0, EPS)


func test_ref_hesitation_timeout() -> void:
	near(t.scoring.hesitation_timeout_s, 3.0, EPS)


func test_ref_speed_factor() -> void:
	# 1.0 at 100 km/h -> 2.0 at 250 km/h
	var sc := t.scoring
	near(sc.speed_factor_at_min, 1.0, EPS)
	near(sc.speed_factor_min_kmh, 100.0, EPS)
	near(sc.speed_factor_at_max, 2.0, EPS)
	near(sc.speed_factor_max_kmh, 250.0, EPS)


func test_ref_multiplier_decay() -> void:
	# 0.5/s x (1.0 at 100 km/h -> 0.1 at 250 km/h)
	var sc := t.scoring
	near(sc.multiplier_decay_per_s, 0.5, EPS)
	near(sc.decay_term_at_min, 1.0, EPS)
	near(sc.decay_term_min_kmh, 100.0, EPS)
	near(sc.decay_term_at_max, 0.1, EPS)
	near(sc.decay_term_max_kmh, 250.0, EPS)


func test_ref_below_minimum_drain() -> void:
	near(t.scoring.below_min_drain_per_s, 3.0, EPS)


func test_ref_event_points_and_gains() -> void:
	# Pass / close / cut / thread: 10 / 30 / 15 / 50 base; +1 / +3 / +1 / +5 multiplier
	var sc := t.scoring
	eq(sc.pass_points, 10)
	eq(sc.close_pass_points, 30)
	eq(sc.cut_points, 15)
	eq(sc.thread_points, 50)
	near(sc.pass_multiplier_gain, 1.0, EPS)
	near(sc.close_pass_multiplier_gain, 3.0, EPS)
	near(sc.cut_multiplier_gain, 1.0, EPS)
	near(sc.thread_multiplier_gain, 5.0, EPS)


func test_ref_close_pass_clearance() -> void:
	near(t.scoring.close_pass_clearance_m, 1.0, EPS)


func test_ref_cut() -> void:
	# 140 km/h / 15 m
	near(t.scoring.cut_min_speed_kmh, 140.0, EPS)
	near(t.scoring.cut_traffic_window_m, 15.0, EPS)


func test_ref_shoulder_penalty() -> void:
	# decay x3; gains blocked 3 s after 2 s on shoulder
	near(t.scoring.shoulder_decay_factor, 3.0, EPS)
	near(t.scoring.shoulder_penalty_block_s, 3.0, EPS)
	near(t.scoring.shoulder_penalty_after_s, 2.0, EPS)


func test_ref_boost() -> void:
	# 3 s; +8% top speed; fill: slipstream 20%/s, close +10%, thread +25%
	near(t.scoring.boost_full_s, 3.0, EPS)
	near(t.vehicle.boost_top_speed_bonus_pct, 8.0, EPS)
	near(t.scoring.boost_fill_slipstream_pct_per_s, 20.0, EPS)
	near(t.scoring.boost_fill_close_pass_pct, 10.0, EPS)
	near(t.scoring.boost_fill_thread_pct, 25.0, EPS)


func test_ref_night_multiplier() -> void:
	near(t.scoring.night_factor, 2.0, EPS)


func test_ref_lives_and_ghost() -> void:
	# 2 / 2.0 s
	eq(t.lives.lives, 2)
	near(t.lives.ghost_period_s, 2.0, EPS)


func test_ref_first_hit_speed_loss() -> void:
	near(t.lives.first_hit_speed_loss_pct, 20.0, EPS)


func test_ref_clean_leg_restore() -> void:
	eq(t.lives.clean_leg_restore, true)


func test_ref_sunset_time() -> void:
	# 5 min at base rate; x3 below minimum speed
	near(t.sun.sunset_from_start_min, 5.0, EPS)
	near(t.sun.too_slow_sink_factor, 3.0, EPS)


func test_ref_checkpoint_sun_lift() -> void:
	# 40% of day span + up to 20% for pace
	near(t.sun.checkpoint_lift_pct, 40.0, EPS)
	near(t.sun.checkpoint_pace_lift_max_pct, 20.0, EPS)


func test_ref_legs() -> void:
	# 3.5 km / 8
	near(t.legs.leg_length_km, 3.5, EPS)
	eq(t.legs.legs_to_coast, 8)


func test_ref_signal_time() -> void:
	# 1.0 s (aggressive 0.6 s, floor 0.5 s)
	near(t.traffic.signal_time_s, 1.0, EPS)
	near(t.traffic.signal_time_aggressive_s, 0.6, EPS)
	near(t.traffic.signal_time_floor_s, 0.5, EPS)


func test_ref_lane_change_move_time() -> void:
	# 2.0-3.0 s (aggressive 1.5 s)
	near(t.traffic.lane_change_move_min_s, 2.0, EPS)
	near(t.traffic.lane_change_move_max_s, 3.0, EPS)
	near(t.traffic.lane_change_move_aggressive_s, 1.5, EPS)


func test_ref_no_ambush() -> void:
	# 1.5 s + 1.0 m margin
	near(t.traffic.no_ambush_window_s, 1.5, EPS)
	near(t.traffic.no_ambush_margin_m, 1.0, EPS)


func test_ref_traffic_max_deceleration() -> void:
	near(t.traffic.max_decel_mps2, 6.0, EPS)


func test_ref_density_by_leg() -> void:
	# 8 -> 16 vehicles per km per lane
	near(t.director.density_first_per_km_lane, 8.0, EPS)
	near(t.director.density_last_per_km_lane, 16.0, EPS)


func test_ref_aggressive_share() -> void:
	# 5% -> 20%
	near(t.director.aggressive_share_first_pct, 5.0, EPS)
	near(t.director.aggressive_share_last_pct, 20.0, EPS)


func test_ref_max_active_vehicles() -> void:
	eq(t.traffic.max_active_vehicles, 60)


func test_ref_field_of_view() -> void:
	# 62 deg -> 78 deg with speed
	near(t.camera.fov_min_deg, 62.0, EPS)
	near(t.camera.fov_max_deg, 78.0, EPS)


func test_ref_drag_control() -> void:
	# 2.5 cm max drag, 4% dead zone, curve exponent 1.6
	near(t.controls.drag_max_cm, 2.5, EPS)
	near(t.controls.drag_dead_zone_pct, 4.0, EPS)
	near(t.controls.response_curve_exponent, 1.6, EPS)


func test_ref_gyro_control() -> void:
	# 25 deg max, 2 deg dead zone, 60 ms smoothing
	near(t.controls.gyro_max_angle_deg, 25.0, EPS)
	near(t.controls.gyro_dead_zone_deg, 2.0, EPS)
	near(t.controls.gyro_smoothing_ms, 60.0, EPS)


# ---------------------------------------------------------------- Other spec numbers (spot checks per section)

func test_quality_tiers_and_governor() -> void:
	var q := t.quality
	eq(q.msaa_samples, PackedInt32Array([0, 0, 2]))
	eq(q.particle_scale, PackedFloat64Array([0.5, 1.0, 1.0]))
	eq(q.default_tier, "medium")
	eq(q.battery_saver_fps, 30)
	near(q.governor_miss_frac, 0.10, EPS)
	near(q.governor_window_s, 10.0, EPS)
	near(q.governor_step_down_interval_s, 10.0, EPS)
	near(q.governor_step_up_after_s, 60.0, EPS)
	near(q.governor_render_scale_step, 0.1, EPS)
	near(q.governor_render_scale_floor, 0.5, EPS)
	near(q.governor_particle_step_frac, 0.5, EPS)
	near(q.governor_view_distance_step_m, 150.0, EPS)
	eq(q.draw_call_budget, 100)
	eq(q.triangle_budget, 150000)


func test_scoring_rules_numbers() -> void:
	var sc := t.scoring
	near(sc.pass_lateral_window_m, 5.4, EPS)
	near(sc.cut_per_car_cooldown_s, 3.0, EPS)
	near(sc.thread_window_s, 0.5, EPS)
	near(sc.thread_clearance_m, 1.5, EPS)
	near(sc.slipstream_distance_m, 15.0, EPS)
	near(sc.slipstream_min_speed_kmh, 120.0, EPS)
	near(sc.min_speed_grace_after_hit_s, 3.0, EPS)
	eq(sc.min_speed_grace_until_reached, true)
	near(sc.multiplier_start, 1.0, EPS)


func test_lives_and_feel_numbers() -> void:
	near(t.lives.first_hit_wobble_s, 0.6, EPS)
	near(t.lives.collision_inset_m, 0.08, EPS)
	near(t.lives.collision_test_max_speed_kmh, 350.0, EPS)
	near(t.feel.slowmo_first_hit_scale, 0.5, EPS)
	near(t.feel.slowmo_first_hit_s, 0.3, EPS)
	near(t.feel.slowmo_crash_scale, 0.25, EPS)
	near(t.feel.slowmo_crash_s, 2.5, EPS)
	near(t.feel.slowmo_thread_scale, 0.6, EPS)
	near(t.feel.slowmo_thread_s, 0.25, EPS)
	near(t.feel.haptic_hit_ms, 150.0, EPS)
	near(t.feel.haptic_crash_ms, 400.0, EPS)
	near(t.feel.speed_lines_min_kmh, 180.0, EPS)
	near(t.traffic.hit_recover_s, 4.0, EPS)


func test_sun_and_legs_numbers() -> void:
	near(t.sun.dawn_transition_s, 6.0, EPS)
	near(t.sun.thread_nudge_pct, 1.0, EPS)
	eq(t.sun.close_pass_nudge_count, 5)
	near(t.sun.close_pass_nudge_window_s, 10.0, EPS)
	near(t.sun.close_pass_nudge_pct, 1.0, EPS)
	eq(t.legs.checkpoint_warning_distances_m, PackedFloat64Array([1000.0, 500.0]))
	near(t.legs.fork_sign_distance_m, 1000.0, EPS)
	eq(t.legs.bonus_threads_min_count, 3)
	near(t.legs.bonus_heat_multiplier, 10.0, EPS)
	near(t.legs.bonus_heat_hold_s, 15.0, EPS)
	near(t.hud.leg_toast_s, 2.5, EPS)
	# Sky timeline is ordered and the run starts before sunset.
	var s := t.sun
	check(s.sky_t_morning < s.sky_t_afternoon and s.sky_t_afternoon < s.sky_t_golden_hour
		and s.sky_t_golden_hour < s.sky_t_sunset and s.sky_t_sunset < s.sky_t_dusk
		and s.sky_t_dusk < s.sky_t_night and s.sky_t_night < s.sky_t_dawn and s.sky_t_dawn < 1.0,
		"sky_t keyframes must be increasing within [0, 1)")
	lt(s.sky_t_run_start, s.sky_t_sunset)


func test_traffic_director_passability_numbers() -> void:
	var tt := t.traffic
	near(tt.brake_light_decel_mps2, 1.0, EPS)
	near(tt.brake_light_strong_decel_mps2, 4.0, EPS)
	near(tt.player_b_safe_mps2, 2.0, EPS)
	near(tt.idm_delta, 4.0, EPS)
	near(tt.hesitant_cancel_pct, 20.0, EPS)
	near(tt.spawn_ahead_m, 750.0, EPS)
	near(tt.spawn_behind_m, 150.0, EPS)
	near(tt.despawn_behind_m, 200.0, EPS)
	near(tt.close_pass_horn_pct, 30.0, EPS)
	near(tt.cut_in_brake_tap_distance_m, 10.0, EPS)
	near(tt.blind_spot_horn_s, 3.0, EPS)
	near(tt.metrics_tolerance_pct, 15.0, EPS)
	var dr := t.director
	near(dr.wave_period_min_s, 45.0, EPS)
	near(dr.wave_period_max_s, 90.0, EPS)
	near(dr.breather_min_s, 10.0, EPS)
	near(dr.breather_max_s, 15.0, EPS)
	eq(dr.hesitant_first_leg, 3)
	near(dr.blind_window_m, 150.0, EPS)
	near(dr.blind_density_cap_pct, 60.0, EPS)
	near(dr.set_piece_min_warning_m, 300.0, EPS)
	near(dr.spawn_batch_length_m, 300.0, EPS)
	var p := t.passability
	eq(p.sim_hz, 10)
	near(p.horizon_s, 8.0, EPS)
	near(p.step_s, 0.25, EPS)
	near(p.clearance_m, 0.3, EPS)
	eq(p.max_rerolls, 5)


func test_vehicle_controls_camera_numbers() -> void:
	var v := t.vehicle
	near(v.steer_full_lock_s, 0.12, EPS)
	near(v.slip_angle_max_deg, 8.0, EPS)
	near(v.handling_scale_min, 0.9, EPS)
	near(v.handling_scale_max, 1.1, EPS)
	near(v.body_roll_max_deg, 4.0, EPS)
	near(v.body_pitch_max_deg, 2.0, EPS)
	near(v.body_spring_hz, 2.5, EPS)
	near(v.body_damping_ratio, 0.6, EPS)
	# Owner decision 2026-09-28: braking stays 9 m/s^2; the spec's "250 -> 100 km/h in
	# about 1.3 s" is dropped for the model's time (WP1.5, docs/PHYSICS.md).
	near(v.brake_target_s, 3.6, EPS)
	near(v.car_top_speed_min_kmh, 240.0, EPS)
	near(v.car_top_speed_max_kmh, 300.0, EPS)
	var c := t.controls
	near(c.drag_release_ms, 80.0, EPS)
	near(c.drag_brake_threshold_pct, 30.0, EPS)
	near(c.flick_boost_min_mps, 0.6, EPS)
	near(c.keyboard_steer_ramp_s, 0.15, EPS)
	near(c.first_run_warmup_s, 20.0, EPS)
	near(t.camera.look_ahead_max_m, 1.2, EPS)
	near(t.camera.roll_max_deg, 1.5, EPS)
	near(t.camera.distance_pullback_max_pct, 15.0, EPS)
	near(t.camera.fov_min_speed_kmh, 100.0, EPS)
	eq(t.progression.ghost_sample_hz, 20)


# ---------------------------------------------------------------- Unit helpers

func test_units_conversions() -> void:
	near(Units.kmh_to_mps(36.0), 10.0, EPS)
	near(Units.mps_to_kmh(10.0), 36.0, EPS)
	near(Units.pct_to_frac(40.0), 0.4, EPS)
	near(Units.cm_to_m(2.5), 0.025, EPS)
	near(Units.ms_to_s(80.0), 0.08, EPS)
	near(Units.km_to_m(3.5), 3500.0, EPS)
	near(Units.min_to_s(5.0), 300.0, EPS)
	near(Units.hz_to_dt(120.0), 1.0 / 120.0, EPS)


func test_section_si_helpers() -> void:
	near(t.scoring.min_speed_mps(), 100.0 / 3.6, EPS)
	near(t.scoring.cut_min_speed_mps(), 140.0 / 3.6, EPS)
	near(t.road.floating_origin_shift_m(), 2000.0, EPS)
	near(t.road.max_grade_frac(), 0.05, EPS)
	near(t.road.max_curvature(), 1.0 / 1200.0, EPS)
	near(t.legs.leg_length_m(), 3500.0, EPS)
	near(t.controls.drag_max_m(), 0.025, EPS)
	near(t.controls.drag_release_s(), 0.08, EPS)
	near(t.controls.gyro_smoothing_s(), 0.06, EPS)
	near(t.lives.first_hit_speed_keep_frac(), 0.8, EPS)
	near(t.vehicle.physics_dt(), 1.0 / 120.0, EPS)
	near(t.traffic.far_dt(), 1.0 / 30.0, EPS)
	# 5 min from the starting afternoon to sunset at the base rate.
	near(t.sun.base_sink_per_s() * 300.0, t.sun.day_span(), EPS)


func test_curve_helpers() -> void:
	var sc := t.scoring
	near(sc.speed_factor(Units.kmh_to_mps(50.0)), 1.0, EPS, "clamped below")
	near(sc.speed_factor(Units.kmh_to_mps(175.0)), 1.5, EPS)
	near(sc.speed_factor(Units.kmh_to_mps(300.0)), 2.0, EPS, "clamped above")
	near(sc.decay_term(Units.kmh_to_mps(100.0)), 1.0, EPS)
	near(sc.decay_term(Units.kmh_to_mps(250.0)), 0.1, EPS)
	near(t.vehicle.steer_max_rad(0.0), deg_to_rad(30.0), EPS)
	near(t.vehicle.steer_max_rad(Units.kmh_to_mps(250.0)), deg_to_rad(3.5), EPS)
	near(t.director.density_per_km_lane(1), 8.0, EPS)
	near(t.director.density_per_km_lane(8), 16.0, EPS)
	near(t.director.density_per_km_lane(12), 16.0, EPS, "holds after leg 8")
	near(t.director.aggressive_share_frac(1), 0.05, EPS)
	near(t.director.aggressive_share_frac(8), 0.20, EPS)
	# Lane flow speed rises toward the left (lane 0 = next to the median).
	gt(t.traffic.lane_flow_speed_mps(0, 3), t.traffic.lane_flow_speed_mps(1, 3))
	gt(t.traffic.lane_flow_speed_mps(1, 3), t.traffic.lane_flow_speed_mps(2, 3))
