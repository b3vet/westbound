extends WBTest
## ColorScript (data/color_script.tres): keyframes at SunTuning positions, pure
## per-channel interpolation, cyclic wrap, every channel set, UI accent API.
## Spec: World → Color script; Core loop → Sky timeline.

const EPS := 1e-5

var _cs: ColorScript
var _sun: SunTuning


func before_each() -> void:
	_sun = Tuning.load_default().sun.duplicate() as SunTuning
	_cs = (ColorScript.load_default().duplicate(true)) as ColorScript
	_cs.bind(_sun)


func _near_value(actual: Variant, expected: Variant, message: String) -> bool:
	if expected is Color:
		var a: Color = actual
		var e: Color = expected
		return near(a.r, e.r, EPS, message + ".r") and near(a.g, e.g, EPS, message + ".g") \
				and near(a.b, e.b, EPS, message + ".b") and near(a.a, e.a, EPS, message + ".a")
	return near(float(actual), float(expected), EPS, message)


func test_data_is_valid() -> void:
	var errors := _cs.validate(_sun)
	check(errors.is_empty(), "validate(): %s" % "; ".join(errors))


func test_every_keyframe_sets_every_channel() -> void:
	eq(_cs.keys.size(), ColorScript.KEY_ORDER.size(), "one key per timeline keyframe")
	for name: StringName in ColorScript.KEY_ORDER:
		var k := _cs.get_key(name)
		if not check(k != null, "keyframe %s present" % name):
			continue
		for c: StringName in ColorScript.CHANNELS:
			check(ColorScript.is_channel_set(k, c), "%s.%s is set" % [name, c])


func test_channels_cover_every_exported_field() -> void:
	# A channel added to ColorKey but not to CHANNELS would never interpolate.
	var probe := ColorKey.new()
	for p: Dictionary in probe.get_property_list():
		var usage: int = p["usage"]
		if usage & PROPERTY_USAGE_SCRIPT_VARIABLE == 0 or usage & PROPERTY_USAGE_STORAGE == 0:
			continue
		var n := StringName(p["name"])
		if n == &"key":
			continue
		check(ColorScript.CHANNELS.has(n), "ColorKey.%s listed in CHANNELS" % n)


func test_positions_come_from_sun_tuning() -> void:
	for name: StringName in ColorScript.KEY_ORDER:
		near(_cs.position_of(name), float(_sun.get("sky_t_%s" % name)), 0.0, name)
	# Moving a keyframe in the tuning moves the palette with it.
	_sun.sky_t_golden_hour = 0.4
	_cs.bind(_sun)
	near(_cs.position_of(&"golden_hour"), 0.4, 0.0, "rebound position")
	var at := _cs.sample(0.4)
	_near_value(at.sky_horizon, _cs.get_key(&"golden_hour").sky_horizon, "value at the moved key")


func test_values_exact_at_each_keyframe() -> void:
	for name: StringName in ColorScript.KEY_ORDER:
		var k := _cs.get_key(name)
		var s := _cs.sample(_cs.position_of(name))
		eq(s.key, name, "sampled key name")
		for c: StringName in ColorScript.CHANNELS:
			_near_value(s.get(c), k.get(c), "%s.%s" % [name, c])


func test_midpoints_interpolate_linearly() -> void:
	var n := ColorScript.KEY_ORDER.size()
	for i in n - 1:
		var a := _cs.get_key(ColorScript.KEY_ORDER[i])
		var b := _cs.get_key(ColorScript.KEY_ORDER[i + 1])
		var t0 := _cs.position_of(a.key)
		var t1 := _cs.position_of(b.key)
		var s := _cs.sample(lerpf(t0, t1, 0.5))
		for c: StringName in ColorScript.CHANNELS:
			_near_value(s.get(c), lerp(a.get(c), b.get(c), 0.5), "mid %s-%s .%s" % [a.key, b.key, c])
	# A quarter of the way is a quarter of the change.
	var g := _cs.get_key(&"golden_hour")
	var ss := _cs.get_key(&"sunset")
	var q := lerpf(_cs.position_of(&"golden_hour"), _cs.position_of(&"sunset"), 0.25)
	near(_cs.sample(q).sun_elevation_deg, lerpf(g.sun_elevation_deg, ss.sun_elevation_deg, 0.25), EPS)


func test_wraps_dawn_to_morning() -> void:
	var dawn := _cs.get_key(&"dawn")
	var morning := _cs.get_key(&"morning")
	var t_dawn := _cs.position_of(&"dawn")
	var mid := lerpf(t_dawn, 1.0, 0.5)
	var s := _cs.sample(mid)
	for c: StringName in ColorScript.CHANNELS:
		_near_value(s.get(c), lerp(dawn.get(c), morning.get(c), 0.5), "dawn->morning .%s" % c)
	# 1.0 is morning; out-of-range values wrap.
	_near_value(_cs.sample(1.0).sky_zenith, morning.sky_zenith, "sky_t 1.0 == morning")
	_near_value(_cs.sample(-0.5 + _cs.position_of(&"sunset") + 0.5).sky_zenith,
			_cs.get_key(&"sunset").sky_zenith, "negative wraps")
	_near_value(_cs.sample(2.0 + mid).sky_horizon, s.sky_horizon, "sky_t + 2 wraps")
	# Continuity at the seam: just before 1.0 ~ morning.
	near(_cs.sample(1.0 - 1e-7).sun_elevation_deg, morning.sun_elevation_deg, 1e-3)


func test_wraps_when_first_key_is_not_at_zero() -> void:
	_sun.sky_t_morning = 0.05
	_cs.bind(_sun)
	var dawn := _cs.get_key(&"dawn")
	var morning := _cs.get_key(&"morning")
	# 0.0 lies between dawn (0.85) and morning (1.05): (1.0 - 0.85) / 0.2 = 0.75.
	var f := (1.0 - _sun.sky_t_dawn) / (1.0 + _sun.sky_t_morning - _sun.sky_t_dawn)
	near(_cs.sample(0.0).sun_elevation_deg,
			lerpf(dawn.sun_elevation_deg, morning.sun_elevation_deg, f), EPS)


func test_sample_into_reuses_the_buffer() -> void:
	var out := ColorKey.new()
	_cs.sample_into(_cs.position_of(&"night"), out)
	_near_value(out.fog_color, _cs.get_key(&"night").fog_color, "night fog")
	_cs.sample_into(_cs.position_of(&"afternoon"), out)
	_near_value(out.fog_color, _cs.get_key(&"afternoon").fog_color, "afternoon fog")


func test_accent_api() -> void:
	for name: StringName in ColorScript.KEY_ORDER:
		_near_value(_cs.accent_at(_cs.position_of(name)), _cs.get_key(name).ui_accent, "accent %s" % name)
	var a := _cs.get_key(&"sunset").ui_accent
	var b := _cs.get_key(&"dusk").ui_accent
	_near_value(_cs.accent_at(lerpf(_cs.position_of(&"sunset"), _cs.position_of(&"dusk"), 0.5)),
			a.lerp(b, 0.5), "accent midpoint")


func test_night_is_dark_and_lights_ramp_from_dusk() -> void:
	# The shape the spec asks for: emissives rise from dusk, stars at night,
	# the sun below the horizon at night and above it by day.
	var day := _cs.get_key(&"afternoon")
	var dusk := _cs.get_key(&"dusk")
	var night := _cs.get_key(&"night")
	lt(day.emissive_streetlamp, dusk.emissive_streetlamp, "street lamps rise into dusk")
	le(dusk.emissive_streetlamp, night.emissive_streetlamp, "and peak at night")
	gt(night.stars, dusk.stars, "stars fade in")
	lt(night.sun_elevation_deg, 0.0, "sun below the horizon at night")
	gt(day.sun_elevation_deg, 0.0, "sun up in the afternoon")
	lt(night.fog_start_frac, day.fog_start_frac, "night fog is closer")
	lt(night.fog_color.get_luminance(), day.fog_color.get_luminance(), "night fog is darker")
	le(night.fog_end_frac, 1.0, "fog never ends past the view distance")


func test_nearest_key() -> void:
	eq(_cs.nearest_key(_cs.position_of(&"sunset") + 0.01), &"sunset")
	eq(_cs.nearest_key(0.99), &"morning", "cyclic distance")
