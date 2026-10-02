extends SceneTree
## Writes the web build's music packs (WP9.2, docs/WEB.md → Music packs): each music
## track (AudioTuning.music_tracks) as its own <dir>/<track>.pck (music_menu_1.pck ...),
## so the first load does not wait for the music and the game fetches each track just
## before it plays it (src/platform/web_music_pack.gd), when the main pack leaves the
## music out (the Web preset's exclude filter).
##
##   tools/godot.sh --headless --path . --script res://platform/web/pack_music.gd -- <out dir>
##
## Each track goes in as an export would pack it: the imported stream
## (res://.godot/imported/...) and a remap-only .import pointing at it. Run after an
## import (tools/export_web.sh does both).

const REMAP_KEYS: Array[String] = ["importer", "type", "uid", "path"]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		printerr("pack_music.gd: usage: -- <out dir>")
		quit(2)
		return
	quit(_pack_all(args[0]))


func _pack_all(out_dir: String) -> int:
	if DirAccess.make_dir_recursive_absolute(out_dir) != OK:
		printerr("pack_music.gd: cannot make %s" % out_dir)
		return 1
	var tracks := AudioTuning.resolve().music_tracks
	for track in tracks:
		var out := out_dir.path_join(WebMusicPack.pack_name(track) + ".pck")
		if _pack(track, out) != OK:
			return 1
	print("pack_music.gd: %d tracks -> %s/*.pck" % [tracks.size(), out_dir])
	return 0


func _pack(track: String, out: String) -> Error:
	var cfg := ConfigFile.new()
	if cfg.load(track + ".import") != OK:
		printerr("pack_music.gd: %s has no .import (run an import first)" % track)
		return FAILED
	var imported := str(cfg.get_value("remap", "path", ""))
	if imported.is_empty() or not FileAccess.file_exists(imported):
		printerr("pack_music.gd: %s: imported file %s missing" % [track, imported])
		return FAILED
	var remap_cfg := ConfigFile.new()
	for key in REMAP_KEYS:
		if cfg.has_section_key("remap", key):
			remap_cfg.set_value("remap", key, cfg.get_value("remap", key))
	var remap_file := out.get_base_dir().path_join("%s.import" % track.get_file())
	if remap_cfg.save(remap_file) != OK:
		printerr("pack_music.gd: cannot write %s" % remap_file)
		return FAILED
	var packer := PCKPacker.new()
	var err := packer.pck_start(out)
	if err == OK:
		err = packer.add_file(track + ".import", remap_file)
	if err == OK:
		err = packer.add_file(imported, imported)
	if err == OK:
		err = packer.flush()
	DirAccess.remove_absolute(remap_file)
	if err != OK:
		printerr("pack_music.gd: %s -> %s failed (%s)" % [track, out, error_string(err)])
		return FAILED
	return OK
