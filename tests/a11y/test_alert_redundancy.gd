extends WBTest
## Audio and haptic redundancy of the critical warnings (WP9.3). Spec: UI, HUD and design
## system → Accessibility ("every event has its own word and sound"); Audio, haptics and
## game feel ("every scoring event gets sound, haptics and a visual response"); Lives
## (first hit: "a distinct audio sting and a strong haptic pattern"). docs/ACCESSIBILITY.md
## → Audio and haptic redundancy.
##
## Each warning is emitted on the bus with a real GameAudio and a recording Haptics
## listening: a sound (a voice started) and a pulse (a haptic sent) must follow, unless
## the channel is in KNOWN_GAPS. The gaps are outside this work package's paths
## (src/audio, src/platform: the handoff requests them); the test holds each gap to
## still being a gap, so fixing one fails here until it moves out of KNOWN_GAPS and the
## doc's table.

const HapticsScript := preload("res://src/platform/haptics.gd")
const AUDIO := &"audio"
const HAPTIC := &"haptic"

## [id, emit method].
const ROWS: Array[Array] = [
	["lives_lost", "_emit_hit"],
	["crash", "_emit_crash"],
	["hesitated", "_emit_hesitated"],
	["min_speed_warning", "_emit_too_slow"],
	["set_piece_warning", "_emit_set_piece"],
	["shoulder_penalty", "_emit_shoulder"],
]
## Channels with no cue yet (handoff requests): id -> channels.
const KNOWN_GAPS := {
	"hesitated": [HAPTIC],
	"min_speed_warning": [AUDIO, HAPTIC],
	"set_piece_warning": [AUDIO, HAPTIC],
	"shoulder_penalty": [AUDIO, HAPTIC],
}

var _nodes: Array[Node] = []
var _h: HapticsScript
var _a: GameAudio


func before_each() -> void:
	Settings.restore_defaults()
	Settings.set_value(&"haptics", true)
	_h = HapticsScript.new()
	_h.backend = HapticsScript.Backend.RECORD
	_add(_h)
	_a = GameAudio.new()
	_a.autoplay_music = false
	_a.game_state = Game.RUNNING
	_add(_a)
	_a.player = VehicleState.new()
	_a.player.s = 500.0
	_a.player.v = Units.kmh_to_mps(150.0)
	_a.player_input = VehicleInput.new()


func after_each() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	Settings.restore_defaults()


func _add(n: Node) -> Node:
	tree.root.add_child(n)
	_nodes.append(n)
	return n


func test_critical_warnings_have_a_sound_and_a_pulse() -> void:
	for row in ROWS:
		var id: String = row[0]
		_h.advance_real(1.0)   # any stronger pulse has ended
		_a.pool.stop_all()
		var voices := _a.pool.log_count
		var sent := _h.sent_count
		call(row[1])
		var got := {AUDIO: _a.pool.log_count > voices, HAPTIC: _h.sent_count > sent}
		var gaps: Array = KNOWN_GAPS.get(id, [])
		for ch: StringName in [AUDIO, HAPTIC]:
			if gaps.has(ch):
				check(not got[ch], "%s: %s now has a %s cue: move it out of KNOWN_GAPS and docs/ACCESSIBILITY.md"
						% [id, id, ch])
			else:
				check(got[ch], "%s: a %s cue" % [id, ch])


func _emit_hit() -> void:
	Events.hit.emit(Events.HIT_TRAFFIC, 1)


func _emit_crash() -> void:
	Events.crash_started.emit()


func _emit_hesitated() -> void:
	Events.hesitated.emit()


func _emit_too_slow() -> void:
	Events.too_slow_changed.emit(true)


func _emit_set_piece() -> void:
	Events.set_piece_warning.emit(&"road_works", 400.0)


func _emit_shoulder() -> void:
	Events.shoulder_penalty_changed.emit(true)
