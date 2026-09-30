class_name WebAudioUnlock
extends RefCounted
## The web audio unlock state machine (WP9.2): is the page's audio still locked behind
## the browser's autoplay policy? Spec: Platform (web export); Audio (music). Pure: fed
## the AudioContext state and a clock, no nodes or JavaScript. docs/WEB.md.
##
##   UNKNOWN --running | "" | closed--> UNLOCKED (nothing to wait for: autoplay was
##                                               allowed, or the state is unknowable)
##   UNKNOWN --suspended | interrupted--> LOCKED --running--> UNLOCKED (first: `unlocked`)
##   UNLOCKED --suspended | interrupted--> RELOCKED --running--> UNLOCKED
##
## Music asks holds_music(): only the first lock holds it (the music has not started
## yet). A later lock (iOS interrupts audio when the tab is hidden) does not: the
## music is already playing and simply resumes with the context.

enum State { UNKNOWN, LOCKED, UNLOCKED, RELOCKED }

## Transitions returned by observe().
enum Change { NONE, LOCKED, UNLOCKED, RELOCKED, RESUMED }

const RUNNING := "running"
const SUSPENDED := "suspended"
const INTERRUPTED := "interrupted"
const CLOSED := "closed"

var state: State = State.UNKNOWN
## Clock time of the first observation, of the first unlock (-1: not yet).
var first_seen_s: float = -1.0
var unlocked_s: float = -1.0
## Locks after the first unlock (iOS interruptions), for the dev report.
var relocks: int = 0


## Feeds the AudioContext state at clock time `now_s`; returns the transition.
func observe(ctx_state: String, now_s: float) -> Change:
	if first_seen_s < 0.0:
		first_seen_s = now_s
	var locked := ctx_state == SUSPENDED or ctx_state == INTERRUPTED
	match state:
		State.UNKNOWN:
			if locked:
				state = State.LOCKED
				return Change.LOCKED
			state = State.UNLOCKED
			unlocked_s = now_s
			return Change.NONE
		State.LOCKED:
			if ctx_state == RUNNING or ctx_state == CLOSED:
				state = State.UNLOCKED
				unlocked_s = now_s
				return Change.UNLOCKED
		State.UNLOCKED:
			if locked:
				state = State.RELOCKED
				relocks += 1
				return Change.RELOCKED
		State.RELOCKED:
			if not locked:
				state = State.UNLOCKED
				return Change.RESUMED
	return Change.NONE


## True until the first unlock after a locked start: the music waits for it.
func holds_music() -> bool:
	return state == State.LOCKED


func is_locked() -> bool:
	return state == State.LOCKED or state == State.RELOCKED


## Seconds from the first observation to the first unlock (0: it never locked; -1: not
## unlocked yet).
func wait_s() -> float:
	if unlocked_s < 0.0 or first_seen_s < 0.0:
		return -1.0
	return unlocked_s - first_seen_s
