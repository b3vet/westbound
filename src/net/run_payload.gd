class_name NetRunPayload
extends RefCounted
## The `POST /api/v1/runs` body built from the `Events.run_over` results. Spec:
## multiplayer handoff → Leaderboards → Single-player runs ("a run summary: mode, seed,
## date, score, stats, car, client build, duration, distance"); docs/SERVER.md →
## Leaderboards & runs API → POST /runs. WP N7.2; docs/NET_CLIENT.md → Runs client.
##
## The body is the RunStats.results keys (docs/RUN.md) the server knows, plus the four
## submission fields: `idempotency_key` (a UUID), `seed` as a decimal String, `date` (the
## UTC date played; the seed's date for Daily Drive), `car` and `client_build`. Anything
## else in the payload (`personal_best`, `new_best`, `previous_best`, keys added later)
## is left out: the server refuses unknown fields. Integer fields stay JSON integers
## after the queue's JSON round trip (normalize()), and a non-finite number is sent as 0.

const KEY := "idempotency_key"
const MODE := "mode"
const SEED := "seed"
const DATE := "date"
const CAR := "car"
const BUILD := "client_build"

const MODE_JOURNEY := "journey"
const MODE_DAILY := "daily"
## Modes that submit (Loop practice and anything else stays local).
const MODES: Array[String] = [MODE_JOURNEY, MODE_DAILY]

## The server's integer fields (JSON integers, never 12.0).
const INT_FIELDS: Array[String] = ["score", "legs_completed", "best_chain", "passes", "close_passes",
		"threads", "cuts", "hits", BUILD]
const FLOAT_FIELDS: Array[String] = ["distance_m", "duration_s", "best_multiplier", "top_speed_kmh",
		"night_time_s", "journey_time_s", "journey_distance_m"]
const BOOL_FIELDS: Array[String] = ["coast_reached", "journey_complete"]
const STRING_FIELDS: Array[String] = [KEY, MODE, SEED, DATE, CAR]

const CAR_FALLBACK := "unknown"
const CAR_MAX := 32
const S_PER_DAY := 86400
const UUID_BYTES := 16
## RFC 4122 version 4 and variant bits.
const UUID_VERSION_BYTE := 6
const UUID_VARIANT_BYTE := 8


## Every key the body may carry, in the documented order (tests compare against it).
static func keys() -> Array[String]:
	var out: Array[String] = []
	out.append_array(STRING_FIELDS)
	out.append(BUILD)
	for k in INT_FIELDS:
		if k != BUILD:
			out.append(k)
	out.append_array(FLOAT_FIELDS)
	out.append_array(BOOL_FIELDS)
	return out


## Whether a finished run is submitted: Journey or Daily Drive, and not a scoreless
## crash at the start (less than `runs_min_distance_m`).
static func eligible(results: Dictionary, t: NetTuning) -> bool:
	if not MODES.has(String(results.get(RunStats.MODE, ""))):
		return false
	if bool(results.get(RunWarmup.RESULT_KEY, false)):
		return false   # WP8.1: the first run's warm-up (no traffic for 20 s) cannot be verified
	var s: Variant = results.get(RunStats.SEED, -1)
	if not (s is int) or int(s) < 0:
		return false
	return _num(results.get(RunStats.SCORE, 0)) > 0.0 \
			or _num(results.get(RunStats.DISTANCE_M, 0.0)) >= t.runs_min_distance_m


## The submission body for `results` (the run_over payload).
static func build(results: Dictionary, key: String, date: String, car: String, client_build: int) -> Dictionary:
	var body := {
		KEY: key,
		MODE: String(results.get(RunStats.MODE, MODE_JOURNEY)),
		SEED: String.num_int64(int(results.get(RunStats.SEED, 0))),
		DATE: date,
		CAR: clean_car(car),
		BUILD: client_build,
	}
	for k in INT_FIELDS:
		if k != BUILD:
			body[k] = maxi(0, int(_num(results.get(StringName(k), 0))))
	for k in FLOAT_FIELDS:
		body[k] = maxf(0.0, _num(results.get(StringName(k), 0.0)))
	for k in BOOL_FIELDS:
		body[k] = bool(results.get(StringName(k), false))
	return body


## A body read back from JSON (the offline queue): integers are integers again, and
## only the known keys remain.
static func normalize(body: Dictionary) -> Dictionary:
	var out := {}
	for k in STRING_FIELDS:
		out[k] = NetApiResult.as_id(body.get(k, ""))
	for k in INT_FIELDS:
		out[k] = maxi(0, int(_num(body.get(k, 0))))
	for k in FLOAT_FIELDS:
		out[k] = maxf(0.0, _num(body.get(k, 0.0)))
	for k in BOOL_FIELDS:
		out[k] = bool(body.get(k, false))
	return out


## A car id the server takes: `a–z 0–9 _ -`, 1–32 characters.
static func clean_car(car: String) -> String:
	var out := ""
	for c in car.to_lower():
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_" or c == "-":
			out += c
	out = out.left(CAR_MAX)
	return out if not out.is_empty() else CAR_FALLBACK


## A random (version 4) UUID: the idempotency key of one run.
static func uuid4() -> String:
	var b := Crypto.new().generate_random_bytes(UUID_BYTES)
	b[UUID_VERSION_BYTE] = (b[UUID_VERSION_BYTE] & 0x0F) | 0x40
	b[UUID_VARIANT_BYTE] = (b[UUID_VARIANT_BYTE] & 0x3F) | 0x80
	var h := b.hex_encode()
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)]


## `YYYY-MM-DD` (UTC) of unix seconds.
static func utc_date(unix_s: float) -> String:
	var d := Time.get_datetime_dict_from_unix_time(int(unix_s))
	return "%04d-%02d-%02d" % [d["year"], d["month"], d["day"]]


## Unix seconds of 00:00 UTC on `date` (`YYYY-MM-DD`); -1 when malformed.
static func date_start(date: String) -> int:
	var p := date.split("-")
	if p.size() != 3 or not p[0].is_valid_int() or not p[1].is_valid_int() or not p[2].is_valid_int():
		return -1
	return Time.get_unix_time_from_datetime_dict({"year": p[0].to_int(), "month": p[1].to_int(),
			"day": p[2].to_int(), "hour": 0, "minute": 0, "second": 0})


## The date to send: the UTC date the run ended; for Daily Drive the date whose seed the
## run used (today or yesterday: a run can end after midnight), else today.
static func run_date(mode: String, run_seed: int, now_unix: float) -> String:
	var today := utc_date(now_unix)
	if mode != MODE_DAILY:
		return today
	for back in 2:
		var d := utc_date(now_unix - float(back * S_PER_DAY))
		if daily_seed_of(d) == run_seed:
			return d
	return today


static func daily_seed_of(date: String) -> int:
	var p := date.split("-")
	if p.size() != 3:
		return -1
	return Rng.daily_seed(p[0].to_int(), p[1].to_int(), p[2].to_int())


static func _num(v: Variant) -> float:
	if v is int:
		return float(v)
	if v is float and is_finite(v as float):
		return v as float
	if v is bool:
		return 1.0 if v else 0.0
	return 0.0
