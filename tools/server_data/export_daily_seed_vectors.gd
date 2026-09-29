extends SceneTree
## Exports Daily Drive seed vectors for the server's Rust port of `Rng.daily_seed`
## (N7.1: POST /api/v1/runs checks that a Daily run's seed matches its UTC date).
## Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Leaderboards (plausibility: "the Daily
## Drive seed matches the date"); src/core/rng.gd (daily_seed, derive_seed, fnv1a32).
##   tools/godot.sh --headless --path . --import      # once, if the project was never imported
##   tools/godot.sh --headless --path . --script res://tools/server_data/export_daily_seed_vectors.gd
##       [-- --out=westbound-server/crates/server/tests/data/daily_seed_vectors.json]
## Seeds are written as decimal strings: they use all 63 bits, and JSON readers that
## hold numbers as doubles (Godot's own among them) would round them.

const DEFAULT_OUT := "westbound-server/crates/server/tests/data/daily_seed_vectors.json"
## Dates covered: every day of these years (leap and non-leap, both centuries' rules)...
const FULL_YEARS: Array[int] = [2024, 2025, 2026, 2027]
## ...plus these edge dates (year, month, day).
const EDGE_DATES: Array[Array] = [
	[1970, 1, 1], [1999, 12, 31], [2000, 2, 29], [2100, 2, 28], [2100, 3, 1],
	[2400, 2, 29], [9999, 12, 31], [1, 1, 1],
]
## Stream-name derivations checked too (derive_seed with other parents and names).
const DERIVE_CASES: Array[Array] = [
	[0, "daily-2026-09-29"], [1, "road"], [42, "traffic"], [-7, "props"],
	[9223372036854775807, "events"], [123456789, "retry/3"], [0, "ç ğ ı ö ş ü"],
]
const MONTHS := 12
const LAST_DAY_FEB_LEAP := 29
const DAYS_IN_MONTH: Array[int] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
const FEB := 2
const LEAP_EVERY := 4
const CENTURY := 100
const QUAD_CENTURY := 400


func _initialize() -> void:
	var out := DEFAULT_OUT
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.get_slice("=", 1)
	var daily: Array = []
	for y in FULL_YEARS:
		for m in range(1, MONTHS + 1):
			for d in range(1, _days_in(y, m) + 1):
				daily.append(_daily_vector(y, m, d))
	for e in EDGE_DATES:
		daily.append(_daily_vector(e[0], e[1], e[2]))
	var derive: Array = []
	for c in DERIVE_CASES:
		derive.append({
			"parent": str(c[0]),
			"name": c[1],
			"seed": str(Rng.derive_seed(c[0], c[1])),
			"fnv1a32": Rng.fnv1a32(c[1]),
		})
	var doc := {
		"source": "src/core/rng.gd (Rng.daily_seed, Rng.derive_seed, Rng.fnv1a32)",
		"generator": "tools/server_data/export_daily_seed_vectors.gd",
		"godot": Engine.get_version_info()["string"],
		"daily": daily,
		"derive": derive,
	}
	var path := ProjectSettings.globalize_path("res://" + out) if not out.begins_with("/") else out
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		printerr("DAILY_SEED_VECTORS FAIL cannot write %s" % path)
		quit(1)
		return
	f.store_string(JSON.stringify(doc, "\t") + "\n")
	f.close()
	print("DAILY_SEED_VECTORS ok %s daily=%d derive=%d" % [path, daily.size(), derive.size()])
	quit(0)


func _daily_vector(y: int, m: int, d: int) -> Dictionary:
	return {"date": "%04d-%02d-%02d" % [y, m, d], "seed": str(Rng.daily_seed(y, m, d))}


func _days_in(y: int, m: int) -> int:
	if m == FEB and _is_leap(y):
		return LAST_DAY_FEB_LEAP
	return DAYS_IN_MONTH[m - 1]


func _is_leap(y: int) -> bool:
	return (y % LEAP_EVERY == 0 and y % CENTURY != 0) or y % QUAD_CENTURY == 0
