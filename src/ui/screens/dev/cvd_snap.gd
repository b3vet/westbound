extends SceneTree
## DEV ONLY: writes color-blindness previews of screenshots (WP9.3). Spec: UI, HUD and
## design system → Accessibility (Color independence). docs/ACCESSIBILITY.md.
##
## tools/snap.sh runs it after a capture when given --cvd=protan,deutan,tritan,mono (or
## --cvd=all); by hand:
##   godot --headless --path . --script res://src/ui/screens/dev/cvd_snap.gd -- \
##         --cvd=deutan,protan shot1.png shot2.png
## Each input gets <name>_cvd-<kind>.png beside it (CvdFilter), printed as "SNAP <path>".
## Exit codes: 0 ok, 1 an image failed, 2 bad arguments.

const ALL := "all"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var kinds: Array[StringName] = []
	var files := PackedStringArray()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--cvd="):
			for k in a.trim_prefix("--cvd=").split(",", false):
				if k == ALL:
					kinds.append_array(CvdFilter.KINDS)
				elif CvdFilter.is_kind(StringName(k)):
					kinds.append(StringName(k))
				else:
					printerr("cvd: unknown kind %s (protan, deutan, tritan, mono or all)" % k)
					quit(2)
					return
		else:
			files.append(a)
	if kinds.is_empty() or files.is_empty():
		printerr("cvd: usage: --cvd=protan,deutan,tritan,mono|all <png>...")
		quit(2)
		return
	for f in files:
		var img := Image.load_from_file(f)
		if img == null or img.is_empty():
			printerr("cvd: cannot read %s" % f)
			quit(1)
			return
		for k in kinds:
			var out := "%s_cvd-%s.png" % [f.get_basename(), k]
			if CvdFilter.apply(img, k).save_png(out) != OK:
				printerr("cvd: cannot write %s" % out)
				quit(1)
				return
			print("SNAP %s" % out)
	quit(0)
