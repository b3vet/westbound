class_name AchievementText
extends RefCounted
## The words and numbers an achievement shows (WP8.3): its description with the threshold
## in the player's units, and its progress line. Spec: Garage and progression
## (Achievements); Accessibility (colour is never the only cue: every state has a word).
## Used by the achievements screen and the unlock toast. docs/ACHIEVEMENTS.md.

const TITLE_HIDDEN := "HIDDEN"
const DESC_HIDDEN := "KEEP DRIVING TO REVEAL IT."
const STATE_UNLOCKED := "UNLOCKED"
const STATE_LOCKED := "LOCKED"
const STATE_HIDDEN := "???"
const PROGRESS := "%s / %s"
const N := "{n}"
const CLEARANCE := "{clearance}"
const UNIT_KMH := " KM/H"
const UNIT_MPH := " MPH"
const UNIT_CM := " CM"
const UNIT_IN := " IN"
const TIMES := "×"
## Metres per inch and centimetres per metre (unit conversions for the text).
const M_PER_IN := 0.0254   # lint: allow-number unit conversion
const CM_PER_M := 100.0   # lint: allow-number unit conversion


## The title shown for `def` (HIDDEN while a hidden one is locked).
static func title(def: AchievementDef, unlocked: bool) -> String:
	return TITLE_HIDDEN if def.hidden and not unlocked else def.title


## The description with {n} (the threshold) and {clearance} filled in.
static func description(def: AchievementDef, cat: AchievementCatalog, miles: bool, unlocked: bool = true) -> String:
	if def.hidden and not unlocked:
		return DESC_HIDDEN
	var s := def.description
	if s.contains(N):
		s = s.replace(N, amount(def, AchievementCatalog.internal_threshold(def), miles, true))
	if s.contains(CLEARANCE):
		s = s.replace(CLEARANCE, clearance(cat.hairline_clearance_m if cat != null else 0.0, miles))
	return s


## A value of `def`'s metric (tracker units) as text; `with_unit` adds km/h or mph.
static func amount(def: AchievementDef, v: float, miles: bool, with_unit: bool) -> String:
	match def.unit:
		AchievementDef.Unit.POINTS:
			return HudFormat.thousands(floori(v))
		AchievementDef.Unit.MULTIPLIER:
			return "%d%s" % [floori(v), TIMES]
		AchievementDef.Unit.SPEED:
			var kmh := Units.mps_to_kmh(v)
			var shown := roundi(Units.kmh_to_mph(kmh) if miles else kmh)
			if with_unit:
				return "%d%s" % [shown, UNIT_MPH if miles else UNIT_KMH]
			return str(shown)
	return HudFormat.thousands(floori(v))


## "25 CM" (or "10 IN" with miles).
static func clearance(metres: float, miles: bool) -> String:
	if miles:
		return "%d%s" % [roundi(metres / M_PER_IN), UNIT_IN]
	return "%d%s" % [roundi(metres * CM_PER_M), UNIT_CM]


## The card's state line: UNLOCKED; ??? (hidden and locked); LOCKED (a one-off); else
## "7 / 10", "287 / 300 KM/H", "32× / 50×".
static func state(def: AchievementDef, v: float, threshold: float, unlocked: bool, miles: bool) -> String:
	if unlocked:
		return STATE_UNLOCKED
	if def.hidden:
		return STATE_HIDDEN
	if threshold <= 1.0 or not def.show_progress:
		return STATE_LOCKED
	var shown := minf(v, threshold)
	if def.unit == AchievementDef.Unit.SPEED:
		return PROGRESS % [amount(def, shown, miles, false), amount(def, threshold, miles, true)]
	return PROGRESS % [amount(def, shown, miles, false), amount(def, threshold, miles, false)]


## Whether the card shows a progress bar (not for a locked hidden one or a one-off).
static func has_bar(def: AchievementDef, threshold: float, unlocked: bool) -> bool:
	if unlocked:
		return true
	return not def.hidden and def.show_progress and threshold > 1.0
