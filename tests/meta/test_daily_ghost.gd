@warning_ignore_start("integer_division")
extends WBTest
## WP8.4: the Daily Drive ghost file (DailyGhost), its 20 Hz recorder
## (DailyGhostRecorder) and the store (DailyGhostStore: one file per date, the index in
## the save's `daily` section, pruning). Spec: Core loop → Modes at launch ("Your best
## daily run is recorded ... the car's s, d and heading sampled at 20 Hz"), Save data.
## docs/DAILY.md.

const DATE := "2026-09-30"
const YESTERDAY := "2026-09-29"
const OLD := "2026-09-27"
const FUTURE := "2026-10-02"
const SEED := 2754025057311364035
const HZ := 120
const EVERY := 6
const V := 40.0
const SHIFT := 5.4
const ALLOC_TICKS := 2400

var dt: DailyTuning
var _dir: String


func before_all() -> void:
	dt = DailyTuning.resolve()


func before_each() -> void:
	_dir = "user://test_daily_%d" % OS.get_process_id()
	_wipe()


func after_each() -> void:
	_wipe()


func _wipe() -> void:
	if DirAccess.dir_exists_absolute(_dir):
		for f in DirAccess.get_files_at(_dir):
			DirAccess.remove_absolute(_dir.path_join(f))
		DirAccess.remove_absolute(_dir)


## A recorded ghost: `seconds` at speed V in lane d = 3.5, one right fork at tick 200.
func _ghost(date: String = DATE, score: int = 5000, seconds: float = 3.0) -> DailyGhost:
	var rec := DailyGhostRecorder.new()
	rec.begin(date, SEED, "night_viper", HZ, EVERY, 64)
	var n := roundi(seconds * HZ)
	var d := 3.5
	for k in range(1, n + 1):
		if k == 200:
			rec.note_fork(k, 0, ForkPlan.RIGHT)
			d -= SHIFT
		var fl := DailyGhost.FLAG_LIGHTS if k > n / 2 else 0
		rec.step(k, 100.0 + V * float(k) / HZ, d, 0.01, V, fl, false)
	return rec.finish(score)


# ---------------------------------------------------------------- File

func test_round_trip_keeps_every_field() -> void:
	var a := _ghost()
	a.add_fork(300, 1, ForkPlan.LEFT)
	var bytes := a.encode()
	var b := DailyGhost.decode(bytes)
	if not check(b != null, "decodes"):
		return
	for f: String in ["seed_value", "score", "ticks", "tick_hz", "sample_ticks", "date", "car", "sample_count", "fork_count"]:
		eq(b.get(f), a.get(f), f)
	for f: String in ["tick", "s_q", "d_q", "yaw_q", "v_q", "flags"]:
		eq((b.get(f) as PackedInt64Array).slice(0, b.sample_count), (a.get(f) as PackedInt64Array).slice(0, a.sample_count), f)
	for f: String in ["fork_tick", "fork_index", "fork_side"]:
		eq((b.get(f) as PackedInt64Array).slice(0, b.fork_count), (a.get(f) as PackedInt64Array).slice(0, a.fork_count), f)
	eq(b.fork_side[0], ForkPlan.RIGHT, "a negative-free side survives")
	eq(b.fork_side[1], ForkPlan.LEFT, "LEFT (-1) survives")
	near(b.s_at(b.sample_count - 1), a.s_at(a.sample_count - 1), 1.0 / DailyGhost.Q_POS, "s to 1 mm")
	near(b.yaw_at(0), 0.01, 1.0 / DailyGhost.Q_YAW, "yaw to 1e-4 rad")
	eq(b.encode(), bytes, "re-encoding is byte-identical")
	var head := DailyGhost.peek(bytes)
	eq(head.score, 5000, "the header alone gives the score")
	eq(head.sample_count, 0, "peek reads no samples")


func test_a_ten_minute_ghost_is_small() -> void:
	var g := _ghost(DATE, 1, 600.0)
	var bytes := g.encode()
	eq(g.sample_count, 600 * HZ / EVERY + 1 + 1, "20 Hz, the fork's pre-jump sample, the final sample")
	lt(float(bytes.size()), 40000.0, "10 minutes in < 40 KB (%d B)" % bytes.size())


func test_bad_files_are_refused() -> void:
	var good := _ghost().encode()
	var bad_magic := good.duplicate()
	bad_magic[0] = 0
	var bad_version := good.duplicate()
	bad_version.encode_u16(4, DailyGhost.VERSION + 1)
	var bad_length := good.duplicate()
	bad_length.encode_u32(46, bad_length.decode_u32(46) + 1)
	for bytes: PackedByteArray in [PackedByteArray(), good.slice(0, 20), good.slice(0, good.size() - 1),
			bad_magic, bad_version, bad_length, "not a ghost at all".to_utf8_buffer()]:
		check(DailyGhost.decode(bytes) == null, "refused (%d bytes)" % bytes.size())


# ---------------------------------------------------------------- Recorder

func test_recorder_samples_at_20_hz() -> void:
	var rec := DailyGhostRecorder.new()
	rec.begin(DATE, SEED, "falcon_gt", HZ, dt.ghost_sample_ticks(HZ), 16)
	eq(dt.ghost_sample_ticks(HZ), EVERY, "120 Hz / 20 Hz")
	for k in range(1, HZ + 1):
		rec.step(k, float(k), 3.5, 0.0, V, DailyGhost.FLAG_BRAKE if k == 7 else 0, false)
	var g := rec.finish(10)
	eq(g.sample_count, HZ / EVERY + 1, "20 samples a second + the final one")
	eq(g.tick[0], 1, "the first tick after GO")
	eq(g.tick[1], 1 + EVERY)
	eq(g.flags[1] & DailyGhost.FLAG_BRAKE, DailyGhost.FLAG_BRAKE, "the brake flag")
	eq(g.tick[g.sample_count - 1], HZ, "the last tick")
	check((g.flags[g.sample_count - 1] & DailyGhost.FLAG_FINAL) != 0, "FINAL")
	eq(g.ticks, HZ)
	eq(g.score, 10)
	check(not rec.recording, "finish stops it")
	check(rec.finish(10) == null, "nothing twice")


func test_jumps_are_sampled_with_the_tick_before() -> void:
	var g := _ghost()
	var at := -1
	for i in g.sample_count:
		if int(g.tick[i]) == 200:
			at = i
	if not check(at > 0, "the fork tick is a sample"):
		return
	eq(g.tick[at - 1], 199, "and the tick before it")
	check((int(g.flags[at]) & DailyGhost.FLAG_FORK_SWAP) != 0, "flagged as a jump")
	near(g.d_at(at) - g.d_at(at - 1), -SHIFT, 1e-3, "d jumps by the shift")
	eq(g.fork_count, 1)
	eq(g.fork_tick[0], 200)
	var rec := DailyGhostRecorder.new()
	rec.begin(DATE, SEED, "falcon_gt", HZ, EVERY, 16)
	for k in range(1, 30):
		rec.step(k, float(k), 3.5, 0.0, V, 0, k == 17)
	var r := rec.finish(0)
	var ticks: Array[int] = []
	for i in r.sample_count:
		ticks.append(int(r.tick[i]))
	eq(ticks, [1, 7, 13, 16, 17, 19, 25, 29] as Array[int], "a reset is sampled with the tick before")


func test_recorder_step_allocates_nothing() -> void:
	var rec := DailyGhostRecorder.new()
	rec.begin(DATE, SEED, "falcon_gt", HZ, EVERY, ALLOC_TICKS / EVERY + 8)
	rec.step(1, 0.0, 0.0, 0.0, V, 0, false)
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var mem := Performance.get_monitor(Performance.MEMORY_STATIC)
	for k in range(2, ALLOC_TICKS):
		rec.step(k, float(k), 3.5, 0.0, V, 0, k % 500 == 0)
	eq(Performance.get_monitor(Performance.OBJECT_COUNT), objects, "no objects per tick")
	eq(Performance.get_monitor(Performance.MEMORY_STATIC), mem, "no memory per tick (within the reserve)")


# ---------------------------------------------------------------- Store

func _store(section: Dictionary = {}) -> DailyGhostStore:
	return DailyGhostStore.new(section, dt, _dir)


func test_store_keeps_the_best_run_per_date() -> void:
	var section := {}
	var st := _store(section)
	check(st.load_ghost(DATE) == null, "none yet")
	eq(st.best_score(DATE), -1)
	check(st.offer(_ghost(DATE, 5000), DATE), "the first run is kept")
	eq(st.best_score(DATE), 5000)
	check(FileAccess.file_exists(_dir.path_join(DATE + ".ghost")), "its own file")
	check(section.has(DailyGhostStore.KEY_GHOSTS), "the index lives in the section")
	check(not st.offer(_ghost(DATE, 4000), DATE), "a worse run is not")
	check(not st.offer(_ghost(DATE, 5000), DATE), "nor an equal one")
	eq(st.load_ghost(DATE).score, 5000, "the best stays")
	check(st.offer(_ghost(DATE, 7000), DATE), "a better run replaces it")
	var g := st.load_ghost(DATE)
	eq(g.score, 7000)
	eq(g.car, "night_viper")
	eq(g.sample_count, _ghost().sample_count, "the whole path")
	check(not FileAccess.file_exists(_dir.path_join(DATE + ".ghost.tmp")), "no temp file left")
	eq(st.writes, 2)
	# A fresh store on the same section and folder (the next launch) finds it.
	eq(_store(section).load_ghost(DATE).score, 7000, "survives a restart")


func test_store_prunes_old_dates() -> void:
	var section := {}
	var st := _store(section)
	check(st.write(_ghost(OLD, 1)), "an old day")
	check(st.write(_ghost(FUTURE, 1)), "a day from a wrong clock")
	check(st.write(_ghost(YESTERDAY, 2)), "yesterday")
	var stray := FileAccess.open(_dir.path_join("notes.txt"), FileAccess.WRITE)
	stray.store_string("x")
	stray.close()
	check(st.offer(_ghost(DATE, 3), DATE), "today")
	eq(dt.ghost_keep_days, 2, "the tuning's default: today and yesterday")
	var files := Array(DirAccess.get_files_at(_dir))
	files.sort()
	eq(files, [YESTERDAY + ".ghost", DATE + ".ghost"], "only today and yesterday are left")
	var keys := st.index().keys()
	keys.sort()
	eq(keys, [YESTERDAY, DATE], "the index follows")
	st.prune("2026-10-01")
	eq(Array(DirAccess.get_files_at(_dir)), [DATE + ".ghost"], "a day later, yesterday's goes")
	check(not st.offer(_ghost(OLD, 99), DATE), "an old day's run is never kept")


func test_store_repairs_its_index() -> void:
	var section := {}
	var st := _store(section)
	st.write(_ghost(DATE, 10))
	section.clear()
	st.prune(DATE)
	eq(st.best_score(DATE), 10, "a kept file the index lost is adopted from its header")
	var f := FileAccess.open(st.path_for(DATE), FileAccess.WRITE)
	f.store_string("garbage")
	f.close()
	check(st.load_ghost(DATE) == null, "a damaged file loads as none")
	eq(st.best_score(DATE), -1, "and leaves the index")
	check(not FileAccess.file_exists(st.path_for(DATE)), "and the disk")
	st.write(_ghost(DATE, 10))
	DirAccess.remove_absolute(st.path_for(DATE))
	check(st.load_ghost(DATE) == null, "a missing file loads as none")
	eq(st.best_score(DATE), -1, "its entry goes")


func test_dates() -> void:
	check(DailyGhostStore.valid_date("2026-09-30"))
	for bad: String in ["", "2026-9-30", "2026/09/30", "20260930xx", "abcd-ef-gh"]:
		check(not DailyGhostStore.valid_date(bad), bad)
	eq(DailyGhostStore.days_between("2026-09-29", "2026-09-30"), 1)
	eq(DailyGhostStore.days_between("2026-12-31", "2027-01-01"), 1, "across a year")
	eq(DailyGhostStore.days_between("2026-10-02", "2026-09-30"), -2)
	var st := _store()
	check(st.keeps(DATE, DATE) and st.keeps(YESTERDAY, DATE))
	check(not st.keeps(OLD, DATE) and not st.keeps(FUTURE, DATE))
	eq(Run.daily_seed_for(DATE), Rng.daily_seed(2026, 9, 30), "the date's seed")
	eq(Run.daily_seed_for("junk"), Run.daily_seed_today(), "a bad date plays today")
