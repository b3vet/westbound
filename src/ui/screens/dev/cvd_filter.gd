class_name CvdFilter
extends RefCounted
## DEV ONLY: simulated color-vision deficiency for review (WP9.3). Spec: UI, HUD and design
## system → Accessibility (Color independence: "event messages never rely on color
## alone"). docs/ACCESSIBILITY.md → Color-blindness check.
##
## Applied to screenshots after capture (tools/snap.sh --cvd=...), never in gameplay
## rendering: the game's only post effect stays the single color grade (Rendering
## budget). Dichromacy uses the Machado, Oliveira and Fernandes (2009) matrices at
## severity 1.0, applied in linear RGB; `mono` is achromatopsia (relative luminance,
## Rec. 709), a check that a meaning survives without any hue.
##
##   CvdFilter.simulate(Color, &"deutan") -> Color
##   CvdFilter.apply(image, &"protan") -> Image   (a filtered copy, RGBA8)

const PROTAN := &"protan"
const DEUTAN := &"deutan"
const TRITAN := &"tritan"
const MONO := &"mono"
const KINDS: Array[StringName] = [PROTAN, DEUTAN, TRITAN, MONO]

## Rows of the 3x3 matrices (linear RGB in, linear RGB out). Published constants.
const M_PROTAN: PackedFloat64Array = [
	0.152286, 1.052583, -0.204868,
	0.114503, 0.786281, 0.099216,
	-0.003882, -0.048116, 1.051998]
const M_DEUTAN: PackedFloat64Array = [
	0.367322, 0.860646, -0.227968,
	0.280085, 0.672501, 0.047413,
	-0.011820, 0.042940, 0.968881]
const M_TRITAN: PackedFloat64Array = [
	1.255528, -0.076749, -0.178779,
	-0.078411, 0.930809, 0.147602,
	0.004733, 0.691367, 0.303900]
## Rec. 709 relative luminance weights (every row the same: grey out).
const M_MONO: PackedFloat64Array = [
	0.2126, 0.7152, 0.0722,
	0.2126, 0.7152, 0.0722,
	0.2126, 0.7152, 0.0722]
## Entries of the linear -> sRGB lookup (the 8-bit channel after the matrix).
const LUT_SIZE := 4096
const BYTE_MAX := 255


static func is_kind(kind: StringName) -> bool:
	return KINDS.has(kind)


static func matrix(kind: StringName) -> PackedFloat64Array:
	match kind:
		PROTAN:
			return M_PROTAN
		DEUTAN:
			return M_DEUTAN
		TRITAN:
			return M_TRITAN
	return M_MONO


## One color as someone with `kind` sees it (sRGB in and out; alpha kept).
static func simulate(c: Color, kind: StringName) -> Color:
	var m := matrix(kind)
	var l := c.srgb_to_linear()
	var r := clampf(m[0] * l.r + m[1] * l.g + m[2] * l.b, 0.0, 1.0)
	var g := clampf(m[3] * l.r + m[4] * l.g + m[5] * l.b, 0.0, 1.0)
	var b := clampf(m[6] * l.r + m[7] * l.g + m[8] * l.b, 0.0, 1.0)
	return Color(r, g, b, c.a).linear_to_srgb()


## A filtered copy of `src` (converted to RGBA8). Lookup tables keep a 1280x720 frame
## to a few seconds of GDScript.
static func apply(src: Image, kind: StringName) -> Image:
	var img := src.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var m := matrix(kind)
	var to_lin := PackedFloat64Array()
	to_lin.resize(BYTE_MAX + 1)
	for i in BYTE_MAX + 1:
		to_lin[i] = Color(float(i) / BYTE_MAX, 0.0, 0.0).srgb_to_linear().r
	var to_srgb := PackedByteArray()
	to_srgb.resize(LUT_SIZE)
	for i in LUT_SIZE:
		var v := Color(float(i) / (LUT_SIZE - 1), 0.0, 0.0).linear_to_srgb().r
		to_srgb[i] = clampi(roundi(v * BYTE_MAX), 0, BYTE_MAX)
	var data := img.get_data()
	var top := float(LUT_SIZE - 1)
	for p in range(0, data.size(), 4):
		var r := to_lin[data[p]]
		var g := to_lin[data[p + 1]]
		var b := to_lin[data[p + 2]]
		data[p] = to_srgb[int(clampf(m[0] * r + m[1] * g + m[2] * b, 0.0, 1.0) * top + 0.5)]
		data[p + 1] = to_srgb[int(clampf(m[3] * r + m[4] * g + m[5] * b, 0.0, 1.0) * top + 0.5)]
		data[p + 2] = to_srgb[int(clampf(m[6] * r + m[7] * g + m[8] * b, 0.0, 1.0) * top + 0.5)]
	return Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, data)


## A rough perceptual distance between two sRGB colors (CIE76 ΔE in Lab, D65).
static func delta_e(a: Color, b: Color) -> float:
	var la := _lab(a)
	var lb := _lab(b)
	return la.distance_to(lb)


static func _lab(c: Color) -> Vector3:
	var l := c.srgb_to_linear()
	var x := (0.4124 * l.r + 0.3576 * l.g + 0.1805 * l.b) / 0.95047   # lint: allow-number sRGB -> XYZ (D65)
	var y := 0.2126 * l.r + 0.7152 * l.g + 0.0722 * l.b   # lint: allow-number sRGB -> XYZ (D65)
	var z := (0.0193 * l.r + 0.1192 * l.g + 0.9505 * l.b) / 1.08883   # lint: allow-number sRGB -> XYZ (D65)
	var fx := _f(x)
	var fy := _f(y)
	var fz := _f(z)
	return Vector3(116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz))   # lint: allow-number CIE Lab


static func _f(t: float) -> float:
	const E := 216.0 / 24389.0   # lint: allow-number CIE Lab epsilon
	const K := 24389.0 / 27.0   # lint: allow-number CIE Lab kappa
	return pow(t, 1.0 / 3.0) if t > E else (K * t + 16.0) / 116.0   # lint: allow-number CIE Lab
