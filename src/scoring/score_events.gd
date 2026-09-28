class_name ScoreEvents
extends RefCounted
## The score event kinds and bank / loss reasons as plain StringNames, for the pure
## scoring code. Spec: Scoring → Scoring events, Chain and banking.
##
## These are the same values as the constants in src/core/events.gd (Events.PASS,
## Events.REASON_CHECKPOINT, ...). Events is an autoload, which pure sims may not
## reference (lint WB103), so scoring writes these instead; tests/unit/test_scoring.gd
## asserts that the two lists stay equal.

const PASS := &"pass"
const CLOSE_PASS := &"close_pass"
const CUT := &"cut"
const THREAD := &"thread"

const REASON_CHECKPOINT := &"checkpoint"
const REASON_CASH_OUT := &"cash_out"
const REASON_HIT := &"hit"
const REASON_HESITATED := &"hesitated"
const REASON_RUN_END := &"run_end"
