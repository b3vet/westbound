extends Node
## Top-level game state machine (autoload `Game`). Spec: Hooks for future modes
## ("Mode state machine with per-mode HUD sections"); Run end; UI → Screens.
## Contract: docs/CONTRACTS.md §14 (state changes are made only by the run).
##
## Flow of one run (src/run/run.gd, docs/RUN.md):
##   BOOT/MENU -> COUNTDOWN -> RUNNING -> CRASH -> RESULTS -> COUNTDOWN (retry)
##   COUNTDOWN / RUNNING <-> PAUSED
## `mode` names the run's mode; `hud_sections()` lists the HUD parts that mode shows.

const BOOT := &"boot"
const MENU := &"menu"
const COUNTDOWN := &"countdown"
const RUNNING := &"running"
const PAUSED := &"paused"
const CRASH := &"crash"
const RESULTS := &"results"

## Mode ids (RunContext.MODE_*; later &"hopper", &"tempo").
const MODE_JOURNEY := &"journey"
const MODE_DAILY := &"daily"

## HUD section ids (the HUD shows a section only when the mode lists it).
const HUD_SCORE := &"score"            ## banked total + personal best (top-left)
const HUD_SUN_BAR := &"sun_bar"        ## sun height + checkpoint distance (top-center)
const HUD_CHAIN := &"chain"            ## chain, multiplier and the event stack
const HUD_LIVES := &"lives"
const HUD_BUTTONS := &"buttons"        ## pause and camera
const HUD_SPEED := &"speed"            ## speed + minimum-speed bar (bottom-left)
const HUD_BOOST := &"boost"            ## boost meter (bottom-right)
const HUD_OBJECTIVE := &"objective"    ## the leg objective line
const HUD_GHOST := &"ghost"            ## Daily Drive: the best-run ghost car marker

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

## Per-mode HUD sections (spec: UI → HUD elements; Modes at launch).
const HUD_SECTIONS := {
	MODE_JOURNEY: [HUD_SCORE, HUD_SUN_BAR, HUD_CHAIN, HUD_LIVES, HUD_BUTTONS, HUD_SPEED,
		HUD_BOOST, HUD_OBJECTIVE],
	MODE_DAILY: [HUD_SCORE, HUD_SUN_BAR, HUD_CHAIN, HUD_LIVES, HUD_BUTTONS, HUD_SPEED,
		HUD_BOOST, HUD_OBJECTIVE, HUD_GHOST],
}

var state: StringName = BOOT
## Current mode id (&"journey", &"daily"; later &"hopper", &"tempo").
var mode: StringName = &""
## The state PAUSED was entered from (resume goes back there).
var paused_from: StringName = &""


func can_change_to(to: StringName) -> bool:
	return TRANSITIONS.get(state, []).has(to)


func change_state(to: StringName) -> void:
	assert(can_change_to(to), "Illegal game state transition %s -> %s" % [state, to])
	_enter_state(to)


## A run begins (first start or retry): sets `mode` and enters COUNTDOWN. A run
## scene opened while another run was still live (a dev scene switch, tests) abandons
## that one: the transition is forced and still announced.
func start_run(run_mode: StringName) -> void:
	mode = run_mode
	if state == COUNTDOWN:
		return
	_enter_state(COUNTDOWN)


## Pause from COUNTDOWN or RUNNING; returns false when not allowed now.
func pause() -> bool:
	if state != COUNTDOWN and state != RUNNING:
		return false
	paused_from = state
	change_state(PAUSED)
	return true


## Back to the state PAUSED was entered from; returns false when not paused.
func resume() -> bool:
	if state != PAUSED:
		return false
	var to := paused_from if paused_from != &"" else RUNNING
	paused_from = &""
	change_state(to)
	return true


## HUD sections shown in `for_mode` (the current mode when empty).
func hud_sections(for_mode: StringName = &"") -> Array:
	var m := for_mode if for_mode != &"" else mode
	return HUD_SECTIONS.get(m, HUD_SECTIONS[MODE_JOURNEY])


func shows_hud_section(section: StringName, for_mode: StringName = &"") -> bool:
	return hud_sections(for_mode).has(section)


func _enter_state(to: StringName) -> void:
	var from := state
	state = to
	Events.game_state_changed.emit(from, to)
	if to == PAUSED or from == PAUSED:
		Events.paused_changed.emit(to == PAUSED)
