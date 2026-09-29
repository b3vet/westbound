class_name HudFormat
extends RefCounted
## Number formatting for the HUD. Spec: UI → HUD elements (update rule); Scoring →
## Multiplier ("the HUD shows up to 999×"). docs/HUD.md.
##
## Each readout has an integer *key* (what the label would show) that the HUD compares
## every frame; the string is built only when the key changes (no per-frame strings).

const TIMES := "×"
const THOUSANDS_SEP := ","
const GROUP_DIGITS := 3
const TENTHS := 10


## "1,284,500".
static func thousands(n: int) -> String:
	var s := str(absi(n))
	var i := s.length() - GROUP_DIGITS
	while i > 0:
		s = s.insert(i, THOUSANDS_SEP)
		i -= GROUP_DIGITS
	return "-" + s if n < 0 else s


## What the multiplier readout shows, as an integer: tenths below `decimals_below`,
## whole numbers (× 10) from it, capped at `display_max`.
static func multiplier_key(m: float, decimals_below: float, display_max: float) -> int:
	var shown := clampf(m, 1.0, display_max)
	var tenths := roundi(shown * TENTHS)
	if float(tenths) < decimals_below * TENTHS:
		return tenths
	return mini(roundi(shown), floori(display_max)) * TENTHS


## "12.4×", "124×", "999×" from a multiplier_key.
static func multiplier_text(key: int, decimals_below: float) -> String:
	if float(key) < decimals_below * TENTHS:
		return "%d.%d%s" % [floori(key / float(TENTHS)), key % TENTHS, TIMES]
	return "%d%s" % [floori(key / float(TENTHS)), TIMES]


## Distance in tenths of a km (or a mile): the checkpoint readout's key; −1 = none.
static func distance_key(metres: float, miles: bool) -> int:
	if metres < 0.0:
		return -1
	var km := metres / Units.M_PER_KM
	var v := Units.kmh_to_mph(km) if miles else km
	return roundi(v * TENTHS)


## "1.2" from a distance_key.
static func tenths_text(key: int) -> String:
	return "%d.%d" % [floori(key / float(TENTHS)), key % TENTHS]


## Speed as displayed (whole km/h or mph, never negative).
static func speed_value(mps: float, miles: bool) -> int:
	var kmh := Units.mps_to_kmh(absf(mps))
	return roundi(Units.kmh_to_mph(kmh) if miles else kmh)
