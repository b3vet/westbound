class_name SaveMigrations
extends RefCounted
## The save document's versions and the migration chain v0 -> v1 -> ... -> VERSION.
## Spec: Save data ("versioned"). WP8.1; docs/SAVE.md → Format, Migrations.
##
##   var doc := SaveMigrations.migrate(parsed)   # any older version -> VERSION, sections normalized
##
## Each step takes a document of version N and returns one of version N + 1; it never
## drops data it does not understand (unknown keys ride along). normalize() then makes
## sure every section the current build reads exists with the right type, so a
## hand-edited or half-written file (valid JSON, wrong shapes) loads as far as it can.
## A migration is added by bumping VERSION, adding `_vN_to_vN1`, a case in migrate()
## and a test in tests/core/test_save_migrations.gd with a fixture of the old shape.
##
## Versions:
##   0  a document without "version" (the M0 skeleton's shape: {settings?, bests?}).
##   1  WP0.1-WP7: {version: 1, settings, bests: {mode: score}, journeys: {mode: {...}}}.
##   2  WP8.1: + first_run {chooser_done, warmup_done}, stats, unlocks, daily sections.

const VERSION := 2

const KEY_VERSION := "version"
const KEY_SETTINGS := "settings"
const KEY_BESTS := "bests"
const KEY_JOURNEYS := "journeys"
const KEY_FIRST_RUN := "first_run"
const KEY_CHOOSER_DONE := "chooser_done"
const KEY_WARMUP_DONE := "warmup_done"
## Lifetime stats, unlocks and Daily Drive results: owned by WP8.2 / WP8.3 / WP8.4
## (docs/SAVE.md → Sections). Created empty here so every build has them.
const KEY_STATS := "stats"
const KEY_UNLOCKS := "unlocks"
const KEY_DAILY := "daily"
## Sections that are JSON objects in every document of VERSION.
const OBJECT_SECTIONS: Array[String] = [KEY_SETTINGS, KEY_BESTS, KEY_JOURNEYS, KEY_FIRST_RUN, KEY_STATS,
	KEY_UNLOCKS, KEY_DAILY]


## A fresh install's document: nothing chosen, nothing played.
static func fresh() -> Dictionary:
	var doc := {KEY_VERSION: VERSION}
	return normalize(doc)


## The document's version: 0 without the key, -1 when it is not a whole number >= 0.
static func version_of(doc: Dictionary) -> int:
	if not doc.has(KEY_VERSION):
		return 0
	var v: Variant = doc[KEY_VERSION]
	if not (v is int or v is float):
		return -1
	var f := float(v)
	if not is_finite(f) or f < 0.0 or f != floorf(f):
		return -1
	return int(f)


## Runs every step from the document's version up to VERSION, then normalize().
## A version newer than VERSION or unreadable is returned as is (the caller decides).
static func migrate(doc: Dictionary) -> Dictionary:
	var v := version_of(doc)
	if v < 0 or v > VERSION:
		return doc
	while v < VERSION:
		match v:
			0:
				doc = _v0_to_v1(doc)
			1:
				doc = _v1_to_v2(doc)
		var next := version_of(doc)
		assert(next == v + 1, "SaveMigrations: step from v%d did not bump the version" % v)
		v = next
	return normalize(doc)


## v0 (no "version") -> v1: the same shape, now versioned.
static func _v0_to_v1(doc: Dictionary) -> Dictionary:
	doc[KEY_VERSION] = 1
	return doc


## v1 -> v2: the first-run state (a v1 file was written by a game that has already been
## played or set up, so its player never sees the chooser or the warm-up) and the
## progression sections. Personal bests become whole numbers (JSON reads them back as
## floats) and anything that is not a number is dropped.
static func _v1_to_v2(doc: Dictionary) -> Dictionary:
	doc[KEY_FIRST_RUN] = {KEY_CHOOSER_DONE: true, KEY_WARMUP_DONE: true}
	var bests: Variant = doc.get(KEY_BESTS, {})
	var out := {}
	if bests is Dictionary:
		for mode: Variant in bests:
			var s: Variant = (bests as Dictionary)[mode]
			if (s is int or s is float) and is_finite(float(s)):
				out[str(mode)] = maxi(int(s), 0)
	doc[KEY_BESTS] = out
	doc[KEY_VERSION] = 2
	return doc


## Every section the current build reads, with the right type (a wrong one is replaced
## by an empty one). The first-run flags default to "not done".
static func normalize(doc: Dictionary) -> Dictionary:
	for key in OBJECT_SECTIONS:
		if not (doc.get(key) is Dictionary):
			doc[key] = {}
	var fr: Dictionary = doc[KEY_FIRST_RUN]
	for key: String in [KEY_CHOOSER_DONE, KEY_WARMUP_DONE]:
		if not (fr.get(key) is bool):
			fr[key] = false
	var journeys: Dictionary = doc[KEY_JOURNEYS]
	for mode: Variant in journeys.keys():
		if not (journeys[mode] is Dictionary):
			journeys.erase(mode)
	doc[KEY_VERSION] = VERSION
	return doc
