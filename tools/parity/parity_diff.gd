extends SceneTree

## Pixels whose direct difference is at most this skip the edge-tolerance search.
const EDGE_TOLERANCE_SKIP := 2
## Pixel difference between PNG pairs (renderer parity check, tools/parity.sh).
##   godot --headless --script res://tools/parity/parity_diff.gd -- \
##       --max=<p99.9 limit> --mean=<mean limit> [--diff-dir=DIR] a.png b.png [a2.png b2.png ...]
## Per pair prints "PARITY <name> max= p999= p99= mean= raw_max= ok|FAIL". Numbers are
## per-channel absolute differences in 0..255. max/p999/p99 are over each pixel's
## largest channel difference, edge-tolerant: a pixel only counts by how far it lies
## outside the other image's color range within one pixel (the renderers upscale in
## different color spaces, so silhouette edges blend with different weights). mean is the plain mean over all pixels and
## channels; raw_max the plain maximum. The limits apply to p99.9 and the mean.
## Exit 0 when every pair is within limits, 1 otherwise, 2 on bad input.


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var max_limit := 8.0
	var mean_limit := 2.0
	var diff_dir := ""
	var files: PackedStringArray = []
	for a in args:
		if a.begins_with("--max="):
			max_limit = float(a.get_slice("=", 1))
		elif a.begins_with("--mean="):
			mean_limit = float(a.get_slice("=", 1))
		elif a.begins_with("--diff-dir="):
			diff_dir = a.get_slice("=", 1)
		else:
			files.append(a)
	if files.is_empty() or files.size() % 2 != 0:
		printerr("parity_diff: need pairs of PNGs")
		quit(2)
		return
	var failed := false
	for i in range(0, files.size(), 2):
		var r := _compare(files[i], files[i + 1], diff_dir)
		if r.is_empty():
			quit(2)
			return
		var ok: bool = r["p999"] <= max_limit and r["mean"] <= mean_limit
		failed = failed or not ok
		print("PARITY %s max=%d p999=%d p99=%d mean=%.3f raw_max=%d %s" % [
			files[i].get_file(), r["max"], r["p999"], r["p99"], r["mean"], r["raw_max"],
			"ok" if ok else "FAIL"])
	quit(1 if failed else 0)


func _compare(path_a: String, path_b: String, diff_dir: String) -> Dictionary:
	var a := Image.load_from_file(path_a)
	var b := Image.load_from_file(path_b)
	if a == null or b == null:
		printerr("parity_diff: cannot load %s or %s" % [path_a, path_b])
		return {}
	a.convert(Image.FORMAT_RGB8)
	b.convert(Image.FORMAT_RGB8)
	if a.get_size() != b.get_size():
		printerr("parity_diff: size mismatch %s vs %s" % [a.get_size(), b.get_size()])
		return {}
	var da := a.get_data()
	var db := b.get_data()
	var w := a.get_width()
	var h := a.get_height()
	# hist: each pixel's largest channel difference after the edge tolerance.
	var hist := PackedInt64Array()
	hist.resize(256)
	var total := 0
	var raw_max := 0
	var diff := PackedByteArray()
	var want_diff := not diff_dir.is_empty()
	if want_diff:
		diff.resize(da.size())
	for p in range(0, da.size(), 3):
		var dr := absi(da[p] - db[p])
		var dg := absi(da[p + 1] - db[p + 1])
		var dbb := absi(da[p + 2] - db[p + 2])
		total += dr + dg + dbb
		var m := maxi(dr, maxi(dg, dbb))
		raw_max = maxi(raw_max, m)
		if m > EDGE_TOLERANCE_SKIP:
			# Silhouette edges: the renderers upscale the 3D buffer in different
			# color spaces (Compatibility filters sRGB values, Mobile linear ones),
			# so edge pixels blend the same colors with other weights. Count only
			# how far a pixel lies outside the other image's local color range.
			var px := posmod(floori(p / 3.0), w)
			var py := floori(p / 3.0 / w)
			m = maxi(_neighbour_min(da, db, p, px, py, w, h), _neighbour_min(db, da, p, px, py, w, h))
		hist[m] += 1
		if want_diff:
			var v := mini(m * 16, 255)
			diff[p] = v
			diff[p + 1] = v
			diff[p + 2] = v
	var pixels := w * h
	if want_diff:
		var img := Image.create_from_data(a.get_width(), a.get_height(), false, Image.FORMAT_RGB8, diff)
		img.save_png(diff_dir.path_join(path_a.get_file().get_basename() + "_diff.png"))
	return {
		"raw_max": raw_max,
		"max": _percentile(hist, pixels, 1.0),
		"p999": _percentile(hist, pixels, 0.999),
		"p99": _percentile(hist, pixels, 0.99),
		"mean": float(total) / float(pixels * 3),
	}


## How far pixel `p` of `x` lies outside the per-channel [min, max] range of the
## 3x3 neighbourhood of the same position in `y` (largest channel). An edge pixel
## that blends the same two colors with a different weight scores 0.
func _neighbour_min(x: PackedByteArray, y: PackedByteArray, p: int, px: int, py: int, w: int, h: int) -> int:
	var worst := 0
	for c in 3:
		var lo := 255
		var hi := 0
		for oy in range(maxi(py - 1, 0), mini(py + 2, h)):
			for ox in range(maxi(px - 1, 0), mini(px + 2, w)):
				var v := y[(oy * w + ox) * 3 + c]
				lo = mini(lo, v)
				hi = maxi(hi, v)
		var xv := x[p + c]
		worst = maxi(worst, maxi(lo - xv, xv - hi))
	return worst


func _percentile(hist: PackedInt64Array, count: int, q: float) -> int:
	var need := int(ceil(q * count))
	var acc := 0
	for v in hist.size():
		acc += hist[v]
		if acc >= need:
			return v
	return hist.size() - 1
