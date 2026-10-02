extends WBTest
## MusicMood (src/audio/music_mood.gd): which mood the moment wants. Spec: Audio
## ("Music"); not in spec: the moods (owner decision). docs/AUDIO.md → Music.

const M := MusicMood.Mood
const P := SunClock.Phase

var audio: AudioTuning
var sun: SunTuning


func before_all() -> void:
	audio = AudioTuning.resolve()
	sun = Tuning.load_default().sun


func _mood() -> MusicMood:
	return MusicMood.new(audio, sun)


## A solo run by day at `sky_t` in the farmland.
func _day(mm: MusicMood, sky_t: float) -> int:
	return mm.update(true, false, false, &"farmland", P.DAY, sky_t)


func test_menu_outside_a_run_beats_everything() -> void:
	var mm := _mood()
	eq(mm.update(false, false, false, &"", P.DAY, sun.sky_t_run_start), M.MENU, "title, garage, results")
	eq(mm.update(false, true, true, &"city", P.NIGHT, sun.sky_t_night), M.MENU, "room lobby on rush at night: still menu")
	eq(mm.likely_next(M.MENU), M.DAY)


func test_day_golden_night_from_the_sun() -> void:
	var mm := _mood()
	eq(_day(mm, sun.sky_t_run_start), M.DAY, "the run's afternoon")
	eq(_day(mm, sun.sky_t_golden_hour - 0.01), M.DAY, "just before the golden hour")
	eq(_day(mm, sun.sky_t_golden_hour), M.GOLDEN, "from the golden hour")
	eq(mm.update(true, false, false, &"farmland", P.NIGHTFALL, sun.sky_t_sunset), M.NIGHT, "nightfall")
	eq(mm.update(true, false, false, &"farmland", P.NIGHT, sun.sky_t_night), M.NIGHT, "night")
	eq(mm.likely_next(M.DAY), M.GOLDEN)
	eq(mm.likely_next(M.GOLDEN), M.NIGHT)
	eq(mm.likely_next(M.NIGHT), M.DAY)


func test_golden_latch_survives_a_sun_lift() -> void:
	var mm := _mood()
	eq(_day(mm, sun.sky_t_golden_hour + 0.02), M.GOLDEN)
	check(mm.golden_latched)
	eq(_day(mm, sun.sky_t_golden_hour - 0.05), M.GOLDEN, "a checkpoint lift back below the golden hour keeps GOLDEN")
	mm.reset()
	eq(_day(mm, sun.sky_t_golden_hour - 0.05), M.DAY, "a new run clears the latch")


func test_latch_clears_at_night_and_dawn_is_day() -> void:
	var mm := _mood()
	_day(mm, sun.sky_t_golden_hour + 0.02)
	eq(mm.update(true, false, false, &"farmland", P.NIGHT, sun.sky_t_night), M.NIGHT)
	check(not mm.golden_latched, "the night clears the latch")
	eq(mm.update(true, false, false, &"farmland", P.DAWN, sun.sky_t_dawn), M.DAY, "the dawn plays DAY")
	eq(_day(mm, sun.sky_t_morning), M.DAY, "morning after the night: DAY")
	eq(_day(mm, sun.sky_t_afternoon), M.DAY, "no latch left over")


func test_leaving_the_run_clears_the_latch() -> void:
	var mm := _mood()
	_day(mm, sun.sky_t_golden_hour + 0.02)
	mm.update(false, false, false, &"", P.DAY, sun.sky_t_golden_hour + 0.02)
	eq(_day(mm, sun.sky_t_run_start), M.DAY, "the next run starts by day")


func test_rush_in_a_rush_hour_room() -> void:
	var mm := _mood()
	eq(mm.update(true, true, true, &"", P.DAY, sun.sky_t_run_start), M.RUSH, "room on RUSH HOUR")
	eq(mm.update(true, true, true, &"", P.NIGHT, sun.sky_t_night), M.RUSH, "RUSH beats NIGHT")
	eq(mm.likely_next(M.RUSH), M.NIGHT, "after rush: the time of day")
	eq(mm.update(true, true, false, &"", P.DAY, sun.sky_t_run_start), M.DAY, "a normal-density room")
	eq(mm.update(true, true, false, &"city", P.DAY, sun.sky_t_run_start), M.DAY, "the city biome in a room is not rush")


func test_rush_in_a_solo_city_leg() -> void:
	var mm := _mood()
	check(audio.music_rush_biomes.has(&"city"), "data: the city plays rush")
	eq(mm.update(true, false, false, &"city", P.DAY, sun.sky_t_run_start), M.RUSH, "solo city leg")
	eq(mm.likely_next(M.RUSH), M.DAY)
	eq(mm.update(true, false, false, &"city", P.DAY, sun.sky_t_golden_hour + 0.02), M.RUSH, "RUSH beats GOLDEN")
	eq(mm.time_mood, M.GOLDEN, "the time of day still runs underneath (and latches)")
	eq(mm.likely_next(M.RUSH), M.GOLDEN)
	eq(mm.update(true, false, false, &"valley_fog", P.DAY, sun.sky_t_golden_hour - 0.05), M.GOLDEN,
		"out of the city: back to the latched golden hour")
	eq(mm.update(true, false, true, &"desert", P.DAY, sun.sky_t_run_start), M.GOLDEN, "room_rush only counts in a room")


func test_pools_cover_every_track_once() -> void:
	var seen := {}
	for m in MusicMood.COUNT:
		var pool := audio.music_pool(m)
		check(not pool.is_empty(), "%s has tracks" % MusicMood.NAMES[m])
		for path in pool:
			check(audio.music_tracks.has(path), "%s is in music_tracks" % path)
			check(ResourceLoader.exists(path), "%s exists" % path)
			check(not seen.has(path), "%s in one pool only" % path)
			seen[path] = true
	eq(seen.size(), audio.music_tracks.size(), "every track has a mood")
	eq(audio.music_bpm.size(), audio.music_tracks.size(), "a tempo per track")
	check(audio.music_pool_day.has("res://assets/audio/music_slampe.ogg"), "Slampe by day")
	check(audio.music_pool_night.has("res://assets/audio/music_midnight_drive.ogg"), "Midnight Drive at night")
	check(audio.music_pool_rush.has("res://assets/audio/music_cyber_runner.ogg"), "Cyber Runner in the rush")
