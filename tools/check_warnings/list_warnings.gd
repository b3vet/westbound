extends SceneTree
## Prints an override.cfg raising every GDScript warning the project has at
## "warn" level (1) to "error" (2). Warnings the project disables stay off. Used by tools/check_warnings.sh.

const PREFIX := "debug/gdscript/warnings/"
const SKIP := ["enable", "exclude_addons", "renamed_in_godot_4_hint", "directory_rules"]


func _initialize() -> void:
	var lines := PackedStringArray(["[debug]", ""])
	for p in ProjectSettings.get_property_list():
		var n: String = p["name"]
		if not n.begins_with(PREFIX) or p["type"] != TYPE_INT:
			continue
		var key := n.trim_prefix(PREFIX)
		if SKIP.has(key) or int(ProjectSettings.get_setting(n)) != 1:
			continue
		lines.append("gdscript/warnings/%s=2" % key)
	print("\n".join(lines))
	quit(0)
