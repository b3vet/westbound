extends WBTest
## Steering response curve. Spec: Controls → Tests ("Mapping: the steering curve maps
## correctly at the dead-zone edge, the midpoint and full input"), for both drag
## (dead zone 4% of max_drag) and gyro (2° of a 25° max angle), exponent 1.6.

const EPS := 1e-12

var c: ControlsTuning


func before_all() -> void:
	c = Tuning.load_default().controls


func test_spec_numbers_feed_the_curve() -> void:
	near(c.drag_dead_zone_frac(), 0.04, EPS)
	near(c.response_curve_exponent, 1.6, EPS)
	near(c.gyro_dead_zone_frac(), 2.0 / 25.0, EPS)


func _check_mapping(dz: float, what: String) -> void:
	var e := c.response_curve_exponent
	# Dead-zone edge: exactly 0 at it, just above it barely moves (continuous).
	eq(SteeringInput.curve(dz, dz, e), 0.0, what + " at the dead-zone edge")
	eq(SteeringInput.curve(-dz, dz, e), 0.0, what + " at the negative edge")
	eq(SteeringInput.curve(dz * 0.5, dz, e), 0.0, what + " inside the dead zone")
	var just := SteeringInput.curve(dz + 1e-6, dz, e)
	gt(just, 0.0, what + " just past the edge")
	lt(just, 1e-6, what + " continuous at the edge")
	# Midpoint of the live range -> 0.5^exponent; midpoint of the raw range too.
	var mid := dz + (1.0 - dz) * 0.5
	near(SteeringInput.curve(mid, dz, e), pow(0.5, e), EPS, what + " live-range midpoint")
	near(SteeringInput.curve(0.5, dz, e), pow((0.5 - dz) / (1.0 - dz), e), EPS, what + " input 0.5")
	near(SteeringInput.curve(-mid, dz, e), -pow(0.5, e), EPS, what + " odd symmetry")
	# Full input and beyond.
	eq(SteeringInput.curve(1.0, dz, e), 1.0, what + " full right")
	eq(SteeringInput.curve(-1.0, dz, e), -1.0, what + " full left")
	eq(SteeringInput.curve(3.0, dz, e), 1.0, what + " clamped")
	# Monotonic over the whole range.
	var prev := -2.0
	for i in 201:
		var u := -1.0 + float(i) / 100.0
		var v := SteeringInput.curve(u, dz, e)
		ge(v, prev, what + " monotonic at %.2f" % u)
		prev = v


func test_drag_mapping() -> void:
	_check_mapping(c.drag_dead_zone_frac(), "drag")


func test_gyro_mapping_in_degrees() -> void:
	_check_mapping(c.gyro_dead_zone_frac(), "gyro")
	var e := c.response_curve_exponent
	var dz := c.gyro_dead_zone_frac()
	var mx := c.gyro_max_angle_deg
	eq(SteeringInput.curve(2.0 / mx, dz, e), 0.0, "2 deg is the edge")
	eq(SteeringInput.curve(25.0 / mx, dz, e), 1.0, "25 deg is full")
	near(SteeringInput.curve(13.5 / mx, dz, e), pow(0.5, e), 1e-12, "13.5 deg is the midpoint")


func test_inverse_round_trip() -> void:
	var e := c.response_curve_exponent
	var dz := c.drag_dead_zone_frac()
	for s: float in [-1.0, -0.7, -0.25, 0.0, 0.1, 0.5, 0.9, 1.0]:
		var u := SteeringInput.inverse_curve(s, dz, e)
		near(SteeringInput.curve(u, dz, e), s, 1e-12, "round trip %.2f" % s)


func test_tuning_additions_load_from_data() -> void:
	# WP2.2 fields (not in spec) are written into data/tuning/controls.tres and match
	# the class defaults, and the SI helpers convert them.
	var defaults := ControlsTuning.new()
	for p: Dictionary in defaults.get_property_list():
		if p["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE and p["type"] == TYPE_FLOAT:
			near(float(c.get(p["name"])), float(defaults.get(p["name"])), EPS, p["name"])
	near(c.flick_window_s(), 0.04, EPS)
	near(c.flick_rearm_frac(), 0.5, EPS)
	near(c.gamepad_dead_zone_frac(), 0.12, EPS)
	near(c.pedal_brake_min_frac(), 0.2, EPS)
	near(c.wheel_visual_max_rad(), deg_to_rad(c.wheel_visual_max_deg), EPS)
	eq(c.wheel_facets, defaults.wheel_facets, "int field matches its default")
	var text := FileAccess.get_file_as_string("res://data/tuning/controls.tres")
	for key: String in ["flick_window_ms", "gyro_min_gravity_mps2", "gamepad_dead_zone_pct",
			"fallback_screen_height_cm", "pedal_width_cm", "pedal_height_cm",
			"boost_cap_height_cm", "brake_width_cm", "brake_height_cm", "pedal_capture_cm",
			"boost_cap_rearm_cm", "controls_scale_min_factor", "controls_scale_max_factor",
			"wheel_visual_diameter_cm", "wheel_visual_max_deg", "wheel_facets",
			"wheel_rim_inner_pct", "wheel_hub_pct", "wheel_spoke_width_pct", "wheel_edge_alpha_pct",
			"controls_margin_cm", "controls_gap_cm", "pedal_brake_min_pct",
			"setting_scale_min_factor", "setting_scale_max_factor", "overlay_ring_alpha_pct",
			"overlay_ring_radius_px", "overlay_dot_radius_px", "overlay_idle_alpha_pct",
			"overlay_label_px", "flick_rearm_pct"]:
		check(text.contains(key + " = "), key + " is in controls.tres")
