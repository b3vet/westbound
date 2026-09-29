extends SceneTree
## Regenerates src/ui/theme/theme.tres from HudTuning and the spec colors (UiTheme).
## Spec: UI, HUD and design system → Design system. Run after changing the design
## numbers in data/tuning/hud.tres:
##   tools/godot.sh --headless --path . --script res://src/ui/theme/build_theme.gd
## tests/ui/test_ui_theme.gd fails when the saved theme is out of date.


func _initialize() -> void:
	var th := UiTheme.build(Tuning.load_default().hud)
	var err := ResourceSaver.save(th, UiTheme.PATH)
	if err != OK:
		printerr("build_theme: cannot save %s (error %d)" % [UiTheme.PATH, err])
		quit(1)
		return
	print("build_theme: wrote %s" % UiTheme.PATH)
	quit(0)
