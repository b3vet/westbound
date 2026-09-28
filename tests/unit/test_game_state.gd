extends WBTest
## Game state machine transitions (autoload `Game`).

var _seen: Array = []


func _on_changed(from: StringName, to: StringName) -> void:
	_seen.append([from, to])


func test_legal_transitions_emit() -> void:
	var game: Node = tree.root.get_node("Game")
	game.state = game.BOOT
	_seen.clear()
	Events.game_state_changed.connect(_on_changed)
	game.change_state(game.MENU)
	game.change_state(game.COUNTDOWN)
	game.change_state(game.RUNNING)
	Events.game_state_changed.disconnect(_on_changed)
	eq(_seen.size(), 3)
	eq(game.state, game.RUNNING)


func test_illegal_transitions_are_rejected() -> void:
	var game: Node = tree.root.get_node("Game")
	game.state = game.MENU
	check(not game.can_change_to(game.RESULTS), "menu -> results must be illegal")
	check(game.can_change_to(game.COUNTDOWN))
