extends Node3D
## M0 placeholder main scene: proves the project boots on each platform.
## Replaced by the title screen in WP8.5.


func _ready() -> void:
	Game.change_state(Game.MENU)
	var label: Label = $UI/Title
	label.text = "WESTBOUND  %s" % ProjectSettings.get_setting("application/config/features")[0]
