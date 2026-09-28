extends Node
## Top-level game state machine (autoload `Game`). Spec: Hooks for future modes
## ("Mode state machine with per-mode HUD sections").
##
## M0 skeleton: states and transitions only. Run wiring arrives in Phase 4.

const BOOT := &"boot"
const MENU := &"menu"
const COUNTDOWN := &"countdown"
const RUNNING := &"running"
const PAUSED := &"paused"
const CRASH := &"crash"
const RESULTS := &"results"

## Allowed transitions. Anything else is a programming error.
const TRANSITIONS := {
	BOOT: [MENU, COUNTDOWN],
	MENU: [COUNTDOWN],
	COUNTDOWN: [RUNNING, PAUSED, MENU],
	RUNNING: [PAUSED, CRASH, RESULTS, MENU],
	PAUSED: [RUNNING, COUNTDOWN, MENU],
	CRASH: [RESULTS],
	RESULTS: [COUNTDOWN, MENU],
}

var state: StringName = BOOT
## Current mode id (&"journey", &"daily"; later &"hopper", &"tempo").
var mode: StringName = &""


func can_change_to(to: StringName) -> bool:
	return TRANSITIONS.get(state, []).has(to)


func change_state(to: StringName) -> void:
	assert(can_change_to(to), "Illegal game state transition %s -> %s" % [state, to])
	var from := state
	state = to
	Events.game_state_changed.emit(from, to)
	if to == PAUSED or from == PAUSED:
		Events.paused_changed.emit(to == PAUSED)
