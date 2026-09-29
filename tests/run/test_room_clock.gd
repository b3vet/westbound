extends WBTest
## RoomClock (N3.2): the multiplayer room clock. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md →
## Time of day in multiplayer ("Cycle: 32 minutes long, with 22 minutes of day (morning →
## afternoon → golden hour → sunset) and 10 minutes of night"; "Public rooms: the clock
## is derived from UTC time"; "Night ×2"; the HUD's time until night or dawn).

var loop_t: LoopTuning
var sun: SunTuning


func before_all() -> void:
	loop_t = LoopTuning.load_default()
	sun = Tuning.load_default().sun


func _clock(unix_s: float) -> RoomClock:
	var c := RoomClock.new(loop_t, sun)
	c.set_time(unix_s)
	return c


func test_spec_cycle() -> void:
	near(loop_t.room_cycle_s(), 32.0 * 60.0, 1e-9, "32 minutes")
	near(loop_t.room_day_s(), 22.0 * 60.0, 1e-9, "22 minutes of day")
	near(loop_t.density_per_km_lane, 10.0, 1e-9, "normal room density")


func test_day_then_night_from_utc() -> void:
	var cycle := loop_t.room_cycle_s()
	var day := loop_t.room_day_s()
	var t0 := loop_t.room_clock_epoch_unix_s + cycle * 931_000.0
	var c := _clock(t0)
	near(c.phase_s(), 0.0, 1e-6, "a cycle starts at the epoch + k cycles")
	check(not c.is_night(), "the day first")
	near(c.seconds_to_flip(), day, 1e-6, "22 min until night")
	near(c.sky_t(), sun.sky_t_morning, 1e-9, "morning")
	c.set_time(t0 + day - 1.0)
	check(not c.is_night())
	near(c.sky_t(), lerpf(sun.sky_t_morning, sun.sky_t_sunset, (day - 1.0) / day), 1e-9, "golden hour to sunset")
	c.advance(1.0)
	check(c.is_night(), "night at 22 min")
	near(c.sky_t(), sun.sky_t_sunset, 1e-9, "sunset")
	near(c.seconds_to_flip(), cycle - day, 1e-6, "10 min until the day")
	c.advance(loop_t.room_nightfall_s)
	near(c.sky_t(), sun.sky_t_night, 1e-9, "night keyframe after the nightfall")
	c.set_time(t0 + cycle - loop_t.room_dawn_s * 0.5)
	check(c.is_night(), "the dawn is still night (x2)")
	check(c.sky_t() > sun.sky_t_night, "dawning")
	c.set_time(t0 + cycle)
	check(not c.is_night(), "the next day")
	near(c.sky_t(), sun.sky_t_morning, 1e-6)


func test_every_room_shares_the_clock() -> void:
	# UTC-derived: two clocks at the same UTC second agree, whenever they started.
	var a := _clock(1_800_000_000.0)
	var b := _clock(1_799_990_000.0)
	b.advance(10_000.0)
	near(a.phase_s(), b.phase_s(), 1e-6)
	eq(a.is_night(), b.is_night())
	near(a.sky_t(), b.sky_t(), 1e-9)


func test_sky_is_continuous() -> void:
	var c := _clock(loop_t.room_clock_epoch_unix_s)
	var prev := c.sky_t()
	var steps := 1920 * 4
	var dt := loop_t.room_cycle_s() / float(steps)
	var worst := 0.0
	for i in steps:
		c.advance(dt)
		var now := c.sky_t()
		var d := absf(now - prev)
		d = minf(d, 1.0 - d)   # sky_t is cyclic (1 == 0 at morning)
		worst = maxf(worst, d)
		prev = now
		ge(now, 0.0)
		lt(now, 1.0)
	lt(worst, 0.01, "no jump in the sky over a whole cycle")


func test_night_lasts_ten_minutes() -> void:
	var c := _clock(loop_t.room_clock_epoch_unix_s)
	var night_s := 0.0
	for i in 1920:
		c.advance(1.0)
		if c.is_night():
			night_s += 1.0
	near(night_s, 600.0, 1.0, "10 minutes of night per cycle")
