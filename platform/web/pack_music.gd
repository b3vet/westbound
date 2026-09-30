extends SceneTree
## Writes the web build's music pack (WP9.2, docs/WEB.md → Music pack): the music
## tracks (AudioTuning.music_tracks) as their own .pck, next to index.pck, so the first
## load does not wait for 3.7 MiB of music. The game loads it in the background on the
## web (src/platform/web_music_pack.gd) when the main pack leaves the music out (the
## Web preset's exclude filter).
##
##   tools/godot.sh --headless --path . --script res://platform/web/pack_music.gd -- <out.pck>
##
## Each track goes in as an export would pack it: the imported stream
## (res://.godot/imported/...) and a remap-only .import pointing at it. Run after an
## import (tools/export_web.sh does both).

const REMAP_KEYS: Array[String] = ["importer", "type", "uid", "path"]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		printerr("pack_music.gd: usage: -- <out.pck>")
		quit(2)
		return
	quit(_pack(args[0]))


func _pack(out: String) -> int:
	var tracks := AudioTuning.resolve().music_tracks
	var packer := PCKPacker.new()
	if packer.pck_start(out) != OK:
		printerr("pack_music.gd: cannot write %s" % out)
		return 1
	var tmp_dir := out.get_base_dir()
	var temps: Array[String] = []
	for track in tracks:
		var cfg := ConfigFile.new()
		if cfg.load(track + ".import") != OK:
			printerr("pack_music.gd: %s has no .import (run an import first)" % track)
			return 1
		var imported := str(cfg.get_value("remap", "path", ""))
		if imported.is_empty() or not FileAccess.file_exists(imported):
			printerr("pack_music.gd: %s: imported file %s missing" % [track, imported])
			return 1
		var remap_cfg := ConfigFile.new()
		for key in REMAP_KEYS:
			if cfg.has_section_key("remap", key):
				remap_cfg.set_value("remap", key, cfg.get_value("remap", key))
		var remap_file := tmp_dir.path_join("%s.import" % track.get_file())
		if remap_cfg.save(remap_file) != OK:
			printerr("pack_music.gd: cannot write %s" % remap_file)
			return 1
		temps.append(remap_file)
		if packer.add_file(track + ".import", remap_file) != OK or packer.add_file(imported, imported) != OK:
			printerr("pack_music.gd: cannot add %s" % track)
			return 1
	var err := packer.flush()
	for f in temps:
		DirAccess.remove_absolute(f)
	if err != OK:
		printerr("pack_music.gd: flush failed (%s)" % error_string(err))
		return 1
	print("pack_music.gd: %d tracks -> %s" % [tracks.size(), out])
	return 0
