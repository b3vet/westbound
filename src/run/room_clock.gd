class_name RoomClock
extends RefCounted
# lint: sim
## The multiplayer room clock (N3.2 preview in the loop test mode; N5 rooms). Spec:
## WESTBOUND_MULTIPLAYER_HANDOFF.md → Time of day in multiplayer ("Cycle: 32 minutes
## long, with 22 minutes of day (morning → afternoon → golden hour → sunset) and 10
## minutes of night"; "Public rooms: the clock is derived from UTC time"; "Night ×2";
## "HUD: the sun bar is replaced by a small clock showing time until night or dawn").
## docs/LOOP_MAP.md → Loop test mode.
##
## Pure and headless: the owner sets the time once (UTC seconds; the run reads the wall
## clock at its start, tests pass a fixed value) and advances it by the sim's dt, so a
## run replays exactly from its start time. The phase is (time - epoch) mod cycle.
##
## Sky: the day maps linearly from sky_t_morning to sky_t_sunset (morning, afternoon,
## golden hour, sunset); the night runs sunset -> sky_t_night over room_nightfall_s,
## holds the night, and runs up to morning (sky_t 1 == 0) over the last room_dawn_s.
## Night x2 covers the whole night (from sunset to the end of the cycle).

var time_s: float = 0.0

var _epoch: float
var _cycle: float
var _day: float
var _nightfall: float
var _dawn: float
var _morning: float
var _sunset: float
var _night: float


func _init(loop: LoopTuning, sun: SunTuning) -> void:
	_epoch = loop.room_clock_epoch_unix_s
	_cycle = maxf(loop.room_cycle_s(), 1.0)
	_day = clampf(loop.room_day_s(), 0.0, _cycle)
	var night := _cycle - _day
	_nightfall = clampf(loop.room_nightfall_s, 0.0, night)
	_dawn = clampf(loop.room_dawn_s, 0.0, night - _nightfall)
	_morning = sun.sky_t_morning
	_sunset = sun.sky_t_sunset
	_night = sun.sky_t_night


## Sets the clock (UTC seconds since the Unix epoch).
func set_time(unix_s: float) -> void:
	time_s = unix_s


func advance(dt: float) -> void:
	time_s += dt


## Seconds into the current cycle, in [0, cycle).
func phase_s() -> float:
	return fposmod(time_s - _epoch, _cycle)


## Where in the cycle (0 = the day starts, 1 = the next day), for the HUD's clock.
func cycle_frac() -> float:
	return phase_s() / _cycle


## The day's share of the cycle (the HUD's night mark).
func day_frac() -> float:
	return _day / _cycle


func is_night() -> bool:
	return phase_s() >= _day


## Seconds until the night starts (by day) or the day starts (at night).
func seconds_to_flip() -> float:
	var p := phase_s()
	return _day - p if p < _day else _cycle - p


## The sky timeline value for this moment (SkyRig.sky_t), in [0, 1).
func sky_t() -> float:
	var p := phase_s()
	if p < _day:
		return lerpf(_morning, _sunset, p / _day) if _day > 0.0 else _sunset
	var q := p - _day
	var night := _cycle - _day
	if q < _nightfall:
		return lerpf(_sunset, _night, q / _nightfall)
	var dawn_from := night - _dawn
	if q < dawn_from:
		return _night
	var u := (q - dawn_from) / _dawn if _dawn > 0.0 else 1.0
	return fposmod(lerpf(_night, 1.0 + _morning, u), 1.0)


## Mixes the clock into `h` (exact bits). Allocation-free.
func hash_into(h: int) -> int:
	return TraceHash.mix_float(h, time_s)
