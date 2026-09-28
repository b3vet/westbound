class_name Units
extends RefCounted
## Unit conversions at the tuning boundary. Spec: CLAUDE.md "Units".
##
## Tuning fields hold the spec's numbers in the spec's units (km/h, degrees,
## percent, cm, ms, km, minutes), named with a unit suffix. Simulation code works
## in SI (m, s, m/s, rad) and converts once when it reads its params, through
## these helpers or the per-class `*_mps()` / `*_rad()` / `*_frac()` helpers.

const KMH_PER_MPS := 3.6
const M_PER_KM := 1000.0
const M_PER_CM := 0.01
const S_PER_MS := 0.001
const S_PER_MIN := 60.0
const PCT := 100.0
const MPH_PER_KMH := 0.621371192


static func kmh_to_mps(kmh: float) -> float:
	return kmh / KMH_PER_MPS


static func mps_to_kmh(mps: float) -> float:
	return mps * KMH_PER_MPS


static func kmh_to_mph(kmh: float) -> float:
	return kmh * MPH_PER_KMH


## Degrees: use Godot's built-in deg_to_rad() / rad_to_deg().


## 40 (%) -> 0.4
static func pct_to_frac(pct: float) -> float:
	return pct / PCT


static func cm_to_m(cm: float) -> float:
	return cm * M_PER_CM


static func ms_to_s(ms: float) -> float:
	return ms * S_PER_MS


static func km_to_m(km: float) -> float:
	return km * M_PER_KM


static func min_to_s(minutes: float) -> float:
	return minutes * S_PER_MIN


## Tick length in seconds for a rate in Hz.
static func hz_to_dt(hz: float) -> float:
	return 1.0 / hz
