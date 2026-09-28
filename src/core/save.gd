extends Node
## Local versioned save in user:// (autoload `Save`). Spec: Save data.
##
## M0 skeleton: versioned JSON document with a migration hook.
## Unlocks, stats, bests and ghosts are added in WP8.1.

const PATH := "user://save.json"
const VERSION := 1

var data := {}


func _ready() -> void:
	load_from_disk()


func load_from_disk() -> void:
	data = {"version": VERSION}
	if not FileAccess.file_exists(PATH):
		return
	var text := FileAccess.get_file_as_string(PATH)
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		data = _migrate(parsed)
		if data.has("settings"):
			Settings.from_dict(data["settings"])


func save_to_disk() -> void:
	data["version"] = VERSION
	data["settings"] = Settings.to_dict()
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		push_error("Save: cannot write %s (%s)" % [PATH, FileAccess.get_open_error()])
		return
	f.store_string(JSON.stringify(data))


## Upgrade an older save document to VERSION, one step at a time.
func _migrate(doc: Dictionary) -> Dictionary:
	var v: int = int(doc.get("version", 0))
	if v > VERSION:
		push_warning("Save: version %d is newer than %d; loading defaults" % [v, VERSION])
		return {"version": VERSION}
	doc["version"] = VERSION
	return doc
