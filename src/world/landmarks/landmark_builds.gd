class_name LandmarkBuilds
extends RefCounted
## Placeholder builds of the four checkpoint landmarks and the warning sign (WP5.3).
## Spec: Core loop → Legs and checkpoints ("express toll gantry, suspension bridge,
## big sign gantry, or tunnel portal"; warning signs at 1 km and 500 m), World →
## Checkpoint landmarks ("big sign gantry with the leg name and distance"), Night
## lighting (retro-reflective signs), Art pipeline (flat-shaded low-poly, palette).
##
## Everything is procedural low-poly in the LandmarkMeshBuilder template frame
## (x = d, y = height, z = -(s - checkpoint s)); the checkpoint line is z = 0. Main
## dimensions come from LandmarkTuning and the road cross-section; the consts below
## are proportions of the placeholder art. Below `overhead_clearance_m`, nothing
## stands between a median barrier and a guardrail (tests/world/test_landmarks.gd).
## Text lines are strips whose text the atlas fills per placement (LandmarkText).

const KIND_SIGN := &"checkpoint_sign"

## Lane-signal green (not in the palette yet: a lit lamp, not a surface).
const LANE_LIGHT := Color(0.35, 1.0, 0.45)
## Tunnel interiors are darker than the same material outside (vertex colour).
const TUNNEL_WALL_SHADE := 0.55
const TUNNEL_ROOF_SHADE := 0.6

# Sign face proportions (share of the panel's inner height).
const BORDER_M := 0.14
const CHEQUER_FRAC := 0.14
const LINE_BIG_FRAC := 0.34
const LINE_SMALL_FRAC := 0.24
const GAP_FRAC := 0.06
## Panels and plates stand this far in front of their backing boxes.
const PANEL_DEPTH_M := 0.18
# Tunnel hill profile: a flat top, a knee at this share of the width and height, the foot.
const HILL_MID_X_FRAC := 0.45
const HILL_MID_Y_FRAC := 0.72
const FACADE_PARAPET_M := 0.5
## The hill's foot sits just below the road level (no gap at the ground).
const HILL_FOOT_Y_M := -0.3
# The sign gantry's CHECKPOINT crown, as shares of the main panel.
const CROWN_WIDTH_FRAC := 0.55
const CROWN_HEIGHT_FRAC := 0.4
const PORTAL_CHAMFER_M := 1.6


static func build(kind: StringName, x: LandmarkSection, t: LandmarkTuning, palette: WBPalette) -> LandmarkTemplate:
	var b := LandmarkMeshBuilder.new(palette, t.bend_station_step_m)
	match kind:
		BiomeDef.LANDMARK_TOLL_GANTRY:
			_toll_gantry(b, x, t)
		BiomeDef.LANDMARK_SUSPENSION_BRIDGE:
			_suspension_bridge(b, x, t)
		BiomeDef.LANDMARK_TUNNEL_PORTAL:
			_tunnel_portal(b, x, t)
		KIND_SIGN:
			_warning_sign(b, t)
			return LandmarkTemplate.from_builder(kind, b, false)
		_:
			_sign_gantry(b, x, t)
	return LandmarkTemplate.from_builder(kind, b, true)


static func kinds() -> Array[StringName]:
	return [BiomeDef.LANDMARK_TOLL_GANTRY, BiomeDef.LANDMARK_SUSPENSION_BRIDGE, BiomeDef.LANDMARK_SIGN_GANTRY,
		BiomeDef.LANDMARK_TUNNEL_PORTAL]


# ---------------------------------------------------------------- Sign faces

## A reflective sign face in one plane (no stacked faces, so no depth fighting at
## range on either renderer): white border, optional chequered band (checkpoint),
## text lines on `bg`. `rows` top to bottom: [share of inner height, line or -1 (gap)
## or -2 (chequer)]. Line indices must already exist (add_line).
static func _sign_face(b: LandmarkMeshBuilder, x0: float, x1: float, y0: float, y1: float, z: float,
		facing: float, bg: Color, rows: Array) -> void:
	var white := b.col(&"white")
	var ink := b.col(&"ink")
	var r := LandmarkMeshBuilder.EMISSIVE_REFLECTOR
	var ix0 := x0 + BORDER_M
	var ix1 := x1 - BORDER_M
	var iy0 := y0 + BORDER_M
	var iy1 := y1 - BORDER_M
	b.panel_face(x0, x1, iy1, y1, z, facing, white, r)
	b.panel_face(x0, x1, y0, iy0, z, facing, white, r)
	b.panel_face(x0, ix0, iy0, iy1, z, facing, white, r)
	b.panel_face(ix1, x1, iy0, iy1, z, facing, white, r)
	var h := iy1 - iy0
	var y := iy1
	for row: Array in rows:
		var rh := float(row[0]) * h
		var line: int = row[1]
		var ya := maxf(y - rh, iy0)
		if line >= 0:
			b.text_strip(ix0, ix1, ya, y, z, facing, line, bg, r)
		elif line == -2:
			var n := maxi(2, int(round((ix1 - ix0) / rh)))
			for i in n:
				var xa := lerpf(ix0, ix1, float(i) / float(n))
				var xb := lerpf(ix0, ix1, float(i + 1) / float(n))
				b.panel_face(xa, xb, ya, y, z, facing, ink if i % 2 == 0 else white, r)
		else:
			b.panel_face(ix0, ix1, ya, y, z, facing, bg, r)
		y = ya
	if y > iy0:
		b.panel_face(ix0, ix1, iy0, y, z, facing, bg, r)


## Adds a line whose strip spans the inner width of a panel x0..x1 at `frac` of its
## inner height (for _sign_face rows).
static func _line(b: LandmarkMeshBuilder, x0: float, x1: float, y0: float, y1: float, frac: float) -> int:
	return b.add_line(x1 - x0 - 2.0 * BORDER_M, (y1 - y0 - 2.0 * BORDER_M) * frac)


## A two-line checkpoint panel with a chequered band: its backing box behind z.
static func _checkpoint_panel(b: LandmarkMeshBuilder, x0: float, x1: float, y0: float, y1: float, z: float,
		facing: float, bg: Color, line_a: int, line_b: int) -> void:
	var rows := [[CHEQUER_FRAC, -2], [GAP_FRAC, -1], [LINE_BIG_FRAC, line_a], [GAP_FRAC, -1],
		[LINE_SMALL_FRAC, line_b]]
	_sign_face(b, x0, x1, y0, y1, z, facing, bg, rows)
	b.panel_back(x0, x1, y0, y1, z, z - facing * PANEL_DEPTH_M, b.col(&"steel_dark"))


# ---------------------------------------------------------------- Warning sign

## Roadside panel on two posts, right of the guardrail: the node sits at the panel's
## inner edge (x = 0), facing approaching traffic. "CHECKPOINT 1 KM" / next leg.
static func _warning_sign(b: LandmarkMeshBuilder, t: LandmarkTuning) -> void:
	var w := t.sign_panel_width_m
	var y0 := t.sign_panel_bottom_m
	var y1 := y0 + t.sign_panel_height_m
	var line_a := _line(b, 0.0, w, y0, y1, LINE_BIG_FRAC)
	var line_b := _line(b, 0.0, w, y0, y1, LINE_SMALL_FRAC)
	_checkpoint_panel(b, 0.0, w, y0, y1, 0.0, 1.0, b.col(&"sign_green"), line_a, line_b)
	var steel := b.col(&"steel")
	for px: float in [w * 0.2, w * 0.8]:
		b.box(Vector3(px - 0.12, 0.0, -PANEL_DEPTH_M - 0.26), Vector3(px + 0.12, y1 - 0.2, -PANEL_DEPTH_M - 0.02),
			steel)


# ---------------------------------------------------------------- Express toll gantry

## A beam across both carriageways on three columns (outer ones beyond the
## guardrails, the middle one inside the median barrier), a blue EXPRESS panel and a
## green lane light over every lane, a CHECKPOINT header over each carriageway, and
## toll booths under canopies beyond each guardrail. No barriers on the lanes.
static func _toll_gantry(b: LandmarkMeshBuilder, x: LandmarkSection, t: LandmarkTuning) -> void:
	var g := x.guardrail_d
	var top := t.toll_beam_top_m
	var bottom := top - t.toll_beam_height_m
	var col_x := g + t.toll_column_offset_m
	var half_d := 0.6
	var dark := b.col(&"steel_dark")
	# Lines: 0 EXPRESS (every lane panel), 1 CHECKPOINT, 2 the next leg (headers).
	var pw := t.toll_lane_panel_width_m
	var ph := t.toll_lane_panel_height_m
	var express := _line(b, 0.0, pw, 0.0, ph, 1.0)
	var hx0 := x.lanes_left_edge_d
	var hx1 := x.lanes_right_edge_d
	var hy0 := top
	var hy1 := top + t.toll_header_height_m
	var line_a := _line(b, hx0, hx1, hy0, hy1, LINE_BIG_FRAC)
	var line_b := _line(b, hx0, hx1, hy0, hy1, LINE_SMALL_FRAC)
	b.box(Vector3(-col_x - 0.7, bottom, -half_d), Vector3(col_x + 0.7, top, half_d), b.col(&"cream"),
		b.col(&"concrete"), true)
	for cx: float in [-col_x, 0.0, col_x]:
		var hw := 0.45 if cx == 0.0 else 0.55
		b.box(Vector3(cx - hw, 0.0, -half_d + 0.05), Vector3(cx + hw, bottom, half_d - 0.05), dark)
	for side: float in [1.0, -1.0]:
		var z := side * (half_d + PANEL_DEPTH_M)
		for i in x.lanes:
			var cx := side * x.lane_center(i)
			var py0 := bottom + 0.12
			_express_panel(b, cx - pw * 0.5, cx + pw * 0.5, py0, py0 + ph, z, side, express)
			# Lane light: a housing under the beam with a lit green lens standing out of it.
			var ly1 := bottom
			var ly0 := bottom - 0.5
			var hz := side * half_d
			b.box(Vector3(cx - 0.3, ly0, hz - 0.3), Vector3(cx + 0.3, ly1, hz + 0.3), dark, null, true)
			var lz0 := hz + side * 0.3
			var lz1 := hz + side * 0.42
			b.box(Vector3(cx - 0.2, ly0 + 0.08, minf(lz0, lz1)), Vector3(cx + 0.2, ly1 - 0.08, maxf(lz0, lz1)),
				LANE_LIGHT, null, true, LandmarkMeshBuilder.EMISSIVE_STREETLAMP)
		# Header over the carriageway (the opposite one reads the same, facing its traffic).
		var x0 := side * hx0 if side > 0.0 else side * hx1
		var x1 := side * hx1 if side > 0.0 else side * hx0
		_checkpoint_panel(b, x0, x1, hy0, hy1, side * (half_d * 0.5), side, b.col(&"sign_green"), line_a, line_b)
		_toll_booths(b, side, g, col_x, t)


static func _express_panel(b: LandmarkMeshBuilder, x0: float, x1: float, y0: float, y1: float, z: float,
		facing: float, line: int) -> void:
	_sign_face(b, x0, x1, y0, y1, z, facing, b.col(&"sign_blue"), [[1.0, line]])
	b.panel_back(x0, x1, y0, y1, z, z - facing * PANEL_DEPTH_M, b.col(&"steel_dark"))


## Booths on an island beyond the guardrail on `side`, under a canopy.
static func _toll_booths(b: LandmarkMeshBuilder, side: float, g: float, col_x: float, t: LandmarkTuning) -> void:
	var cream := b.col(&"cream")
	var glass := b.col(&"ink")
	var bw := t.toll_booth_width_m
	var bl := t.toll_booth_length_m
	var bh := t.toll_booth_height_m
	var ch := t.toll_canopy_height_m
	var cw := t.toll_canopy_width_m
	var cl := t.toll_canopy_length_m
	var inner := g + 0.5
	var outer := inner + cw
	var bx0 := col_x + 1.4
	var bx1 := bx0 + bw
	# Island kerb, booth body, window band, roof.
	_box_side(b, side, inner, outer - 0.5, 0.0, 0.2, -cl * 0.5 + 1.0, cl * 0.5 - 1.0, b.col(&"concrete"))
	for zc: float in [-bl * 0.7, bl * 0.7]:
		_box_side(b, side, bx0, bx1, 0.2, bh, zc - bl * 0.5, zc + bl * 0.5, cream)
		_box_side(b, side, bx0 - 0.12, bx1 + 0.12, bh * 0.45, bh * 0.8, zc - bl * 0.5 - 0.12, zc + bl * 0.5 + 0.12,
			glass)
		_box_side(b, side, bx0 - 0.2, bx1 + 0.2, bh, bh + 0.25, zc - bl * 0.5 - 0.2, zc + bl * 0.5 + 0.2,
			b.col(&"brand_teal"))
	# Canopy slab on four posts, with a teal fascia.
	for px: float in [inner + 0.6, outer - 0.6]:
		for pz: float in [-cl * 0.5 + 1.0, cl * 0.5 - 1.0]:
			_box_side(b, side, px - 0.2, px + 0.2, 0.2, ch, pz - 0.2, pz + 0.2, b.col(&"steel"))
	_box_side(b, side, inner, outer, ch, ch + 0.35, -cl * 0.5, cl * 0.5, b.col(&"cream"), b.col(&"concrete"))
	_box_side(b, side, inner - 0.05, outer + 0.05, ch + 0.35, ch + 0.95, -cl * 0.5 - 0.05, cl * 0.5 + 0.05,
		b.col(&"brand_teal"), b.col(&"concrete"))
	# Light panels under the canopy (lit at night like street lamps).
	var lamp := b.col(&"lamp_warm")
	for lz: float in [-cl * 0.3, 0.0, cl * 0.3]:
		var x0 := inner + 1.5 if side > 0.0 else -(outer - 1.5)
		var x1 := outer - 1.5 if side > 0.0 else -(inner + 1.5)
		b.quad(Vector3(x0, ch - 0.02, lz - 0.4), Vector3(x1, ch - 0.02, lz - 0.4), Vector3(x1, ch - 0.02, lz + 0.4),
			Vector3(x0, ch - 0.02, lz + 0.4), Vector3.DOWN, lamp, LandmarkMeshBuilder.EMISSIVE_STREETLAMP)


## A box given by its |x| range on `side` (mirrored for side -1).
static func _box_side(b: LandmarkMeshBuilder, side: float, ax0: float, ax1: float, y0: float, y1: float, z0: float,
		z1: float, color: Color, top: Variant = null) -> void:
	var x0 := ax0 if side > 0.0 else -ax1
	var x1 := ax1 if side > 0.0 else -ax0
	b.box(Vector3(x0, y0, z0), Vector3(x1, y1, z1), color, top, true)


# ---------------------------------------------------------------- Suspension bridge

## Two towers straddling both carriageways at the checkpoint ± span / 2 (legs beyond
## the guardrails, crossbeams high above), main cables sagging between the tower
## tops, suspenders every few metres down to a walkway girder beyond each guardrail,
## and backstays down to anchor blocks. The road itself is unchanged.
static func _suspension_bridge(b: LandmarkMeshBuilder, x: LandmarkSection, t: LandmarkTuning) -> void:
	var g := x.guardrail_d
	var span := t.bridge_span_m
	var h := t.bridge_tower_height_m
	var lw := t.bridge_tower_leg_width_m
	var leg_in := g + t.bridge_tower_offset_m
	var leg_c := leg_in + lw * 0.5
	var tower := b.col(&"barn_red")
	var tower_shade := b.col(&"barn_red", 0.8)
	var cable_col := b.col(&"barn_red", 0.85)
	var concrete := b.col(&"concrete")
	var saddle := h - 1.0
	var zt := span * 0.5
	var back := t.bridge_backstay_m
	for zc: float in [zt, -zt]:
		for side: float in [1.0, -1.0]:
			var xc := side * leg_c
			# Footing, then a leg tapering in two steps.
			b.box(Vector3(xc - lw, -1.5, zc - lw), Vector3(xc + lw, 0.6, zc + lw), concrete, null, false)
			var h1 := h * 0.45
			b.box(Vector3(xc - lw * 0.5 - 0.3, 0.6, zc - lw * 0.6), Vector3(xc + lw * 0.5 + 0.3, h1, zc + lw * 0.6),
				tower, tower_shade)
			b.box(Vector3(xc - lw * 0.5, h1, zc - lw * 0.5), Vector3(xc + lw * 0.5, h, zc + lw * 0.5), tower,
				tower_shade)
			# Saddle cap and a red beacon (lit at night like a vehicle lamp).
			b.box(Vector3(xc - lw * 0.6, h, zc - lw * 0.6), Vector3(xc + lw * 0.6, h + 0.8, zc + lw * 0.6),
				b.col(&"steel_dark"))
			b.box(Vector3(xc - 0.25, h + 0.8, zc - 0.25), Vector3(xc + 0.25, h + 1.3, zc + 0.25),
				b.col(&"reflector_red"), null, false, LandmarkMeshBuilder.EMISSIVE_VEHICLE)
		# Crossbeams (portal struts) over both carriageways, well above the clearance.
		for cy: float in [t.bridge_crossbeam_low_m, h - 4.0]:
			b.box(Vector3(-leg_c, cy, zc - lw * 0.45), Vector3(leg_c, cy + 2.4, zc + lw * 0.45), tower, tower_shade,
				true)
	var seg := t.bend_station_step_m
	for side: float in [1.0, -1.0]:
		var xc := side * leg_c
		# Walkway girder beyond the guardrail along the whole span (+ approach).
		var gx0 := g + 0.25
		var gx1 := leg_c + 1.2
		var gz := zt + lw
		var gxa := gx0 if side > 0.0 else -gx1
		var gxb := gx1 if side > 0.0 else -gx0
		b.box_along(Vector3(gxa, -1.8, -gz), Vector3(gxb, 0.35, gz), b.col(&"steel_dark"), concrete, true)
		# Main cable: a parabola between the saddles.
		var n := maxi(2, int(ceil(span / seg)))
		var pts := PackedVector3Array()
		for i in n + 1:
			var z := lerpf(zt, -zt, float(i) / float(n))
			var u := z / zt
			pts.append(Vector3(xc, t.bridge_cable_low_m + (saddle - t.bridge_cable_low_m) * u * u, z))
		b.cable(pts, 0.7, cable_col)
		# Suspenders.
		var k := int(floor(span / t.bridge_suspender_spacing_m))
		for i in range(1, k):
			var z := zt - float(i) * t.bridge_suspender_spacing_m
			var u := z / zt
			var y := t.bridge_cable_low_m + (saddle - t.bridge_cable_low_m) * u * u
			b.beam(Vector3(xc, 0.35, z), Vector3(xc, y, z), 0.16, b.col(&"steel_dark"), false)
			# A necklace lamp on the cable at every suspender (lit at night).
			b.box(Vector3(xc - 0.3, y + 0.35, z - 0.3), Vector3(xc + 0.3, y + 0.85, z + 0.3), b.col(&"lamp_warm"),
				null, true, LandmarkMeshBuilder.EMISSIVE_STREETLAMP)
		# Backstays down to anchor blocks outside the span.
		for dir: float in [1.0, -1.0]:
			var z0 := dir * zt
			var z1 := dir * (zt + back)
			var m := maxi(2, int(ceil(back / seg)))
			var stay := PackedVector3Array()
			for i in m + 1:
				var f := float(i) / float(m)
				stay.append(Vector3(xc, lerpf(saddle, 1.5, f), lerpf(z0, z1, f)))
			b.cable(stay, 0.7, cable_col)
			var az := z1 + dir * 2.5
			b.box(Vector3(xc - 2.2, -0.5, minf(z1 - dir * 2.5, az)), Vector3(xc + 2.2, 2.2, maxf(z1 - dir * 2.5, az)),
				concrete)


# ---------------------------------------------------------------- Big sign gantry

## A truss over the player's carriageway (uprights inside the median barrier and
## beyond the guardrail) with one big reflective panel over every lane (chequered
## band, the next leg, the next checkpoint distance) and a CHECKPOINT crown on top.
static func _sign_gantry(b: LandmarkMeshBuilder, x: LandmarkSection, t: LandmarkTuning) -> void:
	var g := x.guardrail_d
	var top := t.sign_gantry_top_m
	var low := top - 1.3
	var out_x := g + t.sign_gantry_upright_offset_m
	var steel := b.col(&"steel")
	var dark := b.col(&"steel_dark")
	var dz := 0.55
	b.box(Vector3(-0.35, 0.0, -0.35), Vector3(0.35, top + 0.2, 0.35), steel)
	b.box(Vector3(out_x - 0.35, 0.0, -0.35), Vector3(out_x + 0.35, top + 0.2, 0.35), steel)
	b.box(Vector3(out_x - 0.8, 0.0, -0.8), Vector3(out_x + 0.8, 0.4, 0.8), b.col(&"concrete"))
	for y: float in [low, top]:
		for z: float in [-dz, dz]:
			b.beam(Vector3(-0.3, y, z), Vector3(out_x + 0.3, y, z), 0.22, steel)
	var bays := 8
	for i in bays:
		var xa := out_x * float(i) / float(bays)
		var xb := out_x * float(i + 1) / float(bays)
		for z: float in [-dz, dz]:
			b.beam(Vector3(xa, low, z), Vector3(xb, top, z), 0.12, dark, false)
	# One wide panel over every lane (the next leg, the next checkpoint distance) and a
	# CHECKPOINT crown on top.
	var y0 := t.overhead_clearance_m + 0.3
	var y1 := y0 + t.sign_gantry_panel_height_m
	var ax0 := x.lanes_left_edge_d - 0.3
	var ax1 := x.lanes_right_edge_d + 0.3
	var z := dz + 0.12 + PANEL_DEPTH_M
	var a0 := _line(b, ax0, ax1, y0, y1, LINE_BIG_FRAC)
	var a1 := _line(b, ax0, ax1, y0, y1, LINE_SMALL_FRAC)
	_checkpoint_panel(b, ax0, ax1, y0, y1, z, 1.0, b.col(&"sign_green"), a0, a1)
	var cw := (ax1 - ax0) * CROWN_WIDTH_FRAC
	var cx := (ax0 + ax1) * 0.5
	var cy0 := y1 + 0.15
	var cy1 := cy0 + t.sign_gantry_panel_height_m * CROWN_HEIGHT_FRAC
	var crown := _line(b, cx - cw * 0.5, cx + cw * 0.5, cy0, cy1, 1.0)
	_sign_face(b, cx - cw * 0.5, cx + cw * 0.5, cy0, cy1, z, 1.0, b.col(&"sign_blue"), [[1.0, crown]])
	b.panel_back(cx - cw * 0.5, cx + cw * 0.5, cy0, cy1, z, z - PANEL_DEPTH_M, dark)
	for px: float in [cx - cw * 0.35, cx + cw * 0.35]:
		b.box(Vector3(px - 0.1, top, dz - 0.1), Vector3(px + 0.1, cy0 + 0.3, z - PANEL_DEPTH_M), dark)


# ---------------------------------------------------------------- Tunnel portal

## A portal façade at the checkpoint line with an opening over each carriageway (a
## pier inside the median barrier), a shell running tunnel_length_m past it (roof,
## walls beyond the guardrails, a central wall on the median, lamp strips; darker
## inside), a hill over it and a plain exit portal. The road is not lowered and the
## lane count does not change (Phase 6).
static func _tunnel_portal(b: LandmarkMeshBuilder, x: LandmarkSection, t: LandmarkTuning) -> void:
	var g := x.guardrail_d
	var wall := g + t.tunnel_wall_offset_m
	var c := t.tunnel_clearance_m
	var cover := t.tunnel_cover_top_m
	var length := t.tunnel_length_m
	var pier := x.median_barrier_d - 0.05
	var face_z := 0.5
	var back_z := -1.0
	var exit_z := -length
	var inner := b.col(&"concrete", TUNNEL_WALL_SHADE)
	var roof := b.col(&"concrete_shade", TUNNEL_ROOF_SHADE)
	var grass := b.col(&"grass")
	var grass_dry := b.col(&"grass_dry")
	var hill := t.tunnel_hill_width_m
	var shell := 1.0
	var plate_w := minf(2.0 * (wall - 2.0), 18.0)
	var py0 := c + 1.0
	var py1 := minf(cover - 0.2, py0 + 3.4)
	var line_a := _line(b, -plate_w * 0.5, plate_w * 0.5, py0, py1, LINE_BIG_FRAC)
	var line_b := _line(b, -plate_w * 0.5, plate_w * 0.5, py0, py1, LINE_SMALL_FRAC)
	for pz: float in [face_z, exit_z - 0.5]:
		var facing := 1.0 if pz > 0.0 else -1.0
		_portal_facade(b, pz, facing * 1.5, wall, pier, c, cover, hill, shell)
	_checkpoint_panel(b, -plate_w * 0.5, plate_w * 0.5, py0, py1, face_z + 0.25, 1.0, b.col(&"sign_green"),
		line_a, line_b)
	# Shell: outer walls (inner faces dark), central wall, roof slab underside.
	for side: float in [1.0, -1.0]:
		var o := Vector2(-side, 0.0)
		b.sweep(PackedVector2Array([Vector2(side * wall, 0.0), Vector2(side * wall, c)]), back_z, exit_z + 1.0,
			PackedVector2Array([o]), inner)
		b.sweep(PackedVector2Array([Vector2(side * pier, 0.0), Vector2(side * pier, c)]), back_z, exit_z + 1.0,
			PackedVector2Array([Vector2(side, 0.0)]), inner)
		# Lamp strip high on each wall face, lit at night like street lamps.
		var n := int(floor((length - 2.0) / t.tunnel_lamp_spacing_m))
		for i in n:
			var z := back_z - 2.0 - float(i) * t.tunnel_lamp_spacing_m
			for lx: float in [side * (wall - 0.04), side * (pier + 0.04)]:
				var facing_x := -side if absf(lx) > wall * 0.5 else side
				b.quad(Vector3(lx, c - 0.9, z), Vector3(lx, c - 0.9, z - 1.6), Vector3(lx, c - 0.6, z - 1.6),
					Vector3(lx, c - 0.6, z), Vector3(facing_x, 0.0, 0.0), b.col(&"lamp_warm"),
					LandmarkMeshBuilder.EMISSIVE_STREETLAMP)
	b.sweep(PackedVector2Array([Vector2(-wall, c), Vector2(wall, c)]), back_z, exit_z + 1.0,
		PackedVector2Array([Vector2(0.0, -1.0)]), roof)
	# Hill over the shell: a flat top and faceted slopes down to the ground.
	var top_x := wall + shell
	var mid_x := top_x + hill * HILL_MID_X_FRAC
	var mid_y := cover * HILL_MID_Y_FRAC
	var foot_x := top_x + hill
	b.sweep(PackedVector2Array([Vector2(-top_x, cover), Vector2(top_x, cover)]), back_z, exit_z + 1.0,
		PackedVector2Array([Vector2(0.0, 1.0)]), grass)
	for side: float in [1.0, -1.0]:
		var prof := PackedVector2Array([Vector2(side * top_x, cover), Vector2(side * mid_x, mid_y),
			Vector2(side * foot_x, HILL_FOOT_Y_M)])
		var outs := PackedVector2Array([Vector2(side * (cover - mid_y), mid_x - top_x),
			Vector2(side * mid_y, foot_x - mid_x)])
		b.sweep(prof, back_z, exit_z + 1.0, outs, grass_dry if side > 0.0 else grass)


## A portal façade `thick` deep from face z `z` (thick > 0 goes toward -z behind a
## face that looks at +z; < 0 mirrors it for the exit): two openings with chamfered
## tops, a pier on the median, and beside it the hill's hipped ends with wing walls.
static func _portal_facade(b: LandmarkMeshBuilder, z: float, thick: float, wall: float, pier: float, c: float,
		cover: float, hill: float, shell: float) -> void:
	var facing := signf(thick)
	var zb := z - thick
	var concrete := b.col(&"cream")
	var shade := b.col(&"concrete_shade")
	var hazard := b.col(&"hazard_yellow")
	var top := cover + FACADE_PARAPET_M
	var ch := PORTAL_CHAMFER_M
	var top_x := wall + shell
	var mid_x := top_x + hill * HILL_MID_X_FRAC
	var mid_y := cover * HILL_MID_Y_FRAC
	var foot_x := top_x + hill
	var fn := Vector3(0.0, 0.0, facing)
	# Front face as convex pieces: top band, pier, the corners' chamfer fills, wings.
	b.quad(Vector3(-wall, c, z), Vector3(wall, c, z), Vector3(wall, top, z), Vector3(-wall, top, z), fn, concrete)
	b.quad(Vector3(-pier, 0.0, z), Vector3(pier, 0.0, z), Vector3(pier, c, z), Vector3(-pier, c, z), fn, shade)
	for side: float in [1.0, -1.0]:
		var w := side * wall
		var p := side * pier
		b.face(PackedVector3Array([Vector3(w, c - ch, z), Vector3(w, c, z), Vector3(w - side * ch, c, z)]), fn,
			concrete)
		b.face(PackedVector3Array([Vector3(p, c - ch, z), Vector3(p, c, z), Vector3(p + side * ch, c, z)]), fn,
			concrete)
		# Façade to the shell's outer face, and its end.
		var tx := side * top_x
		b.quad(Vector3(w, 0.0, z), Vector3(tx, 0.0, z), Vector3(tx, top, z), Vector3(w, top, z), fn, concrete)
		b.quad(Vector3(tx, 0.0, z), Vector3(tx, top, z), Vector3(tx, top, zb), Vector3(tx, 0.0, zb),
			Vector3(side, 0.0, 0.0), shade)
		# The hill's hipped end beside the façade: its profile at the façade's back falls
		# to the ground toward the approach, with a triangular wing wall along the road.
		var zh := zb + facing * hill
		var prof := PackedVector2Array([Vector2(top_x, cover), Vector2(mid_x, mid_y), Vector2(foot_x, HILL_FOOT_Y_M)])
		for k in prof.size() - 1:
			var a := prof[k]
			var q := prof[k + 1]
			b.quad(Vector3(side * a.x, a.y, zb), Vector3(side * q.x, q.y, zb), Vector3(side * q.x, HILL_FOOT_Y_M, zh),
				Vector3(side * a.x, HILL_FOOT_Y_M, zh), Vector3(side * 0.3, 1.0, facing * 0.5),
				b.col(&"grass") if k == 0 else b.col(&"grass_dry"))
		var y_at := lerpf(cover, HILL_FOOT_Y_M, (z - zb) / (zh - zb))
		b.face(PackedVector3Array([Vector3(tx, HILL_FOOT_Y_M, z), Vector3(tx, y_at, z), Vector3(tx, HILL_FOOT_Y_M, zh)]),
			Vector3(-side, 0.0, 0.0), concrete)
		# Reveals (the opening's inner faces), with a hazard band at the wall side.
		b.quad(Vector3(w, 0.0, z), Vector3(w, c - ch, z), Vector3(w, c - ch, zb), Vector3(w, 0.0, zb),
			Vector3(-side, 0.0, 0.0), hazard)
		b.quad(Vector3(p, 0.0, z), Vector3(p, c - ch, z), Vector3(p, c - ch, zb), Vector3(p, 0.0, zb),
			Vector3(side, 0.0, 0.0), hazard)
		b.quad(Vector3(w, c - ch, z), Vector3(w - side * ch, c, z), Vector3(w - side * ch, c, zb),
			Vector3(w, c - ch, zb), Vector3(-side, -1.0, 0.0), shade)
		b.quad(Vector3(p, c - ch, z), Vector3(p + side * ch, c, z), Vector3(p + side * ch, c, zb),
			Vector3(p, c - ch, zb), Vector3(side, -1.0, 0.0), shade)
		b.quad(Vector3(w - side * ch, c, z), Vector3(p + side * ch, c, z), Vector3(p + side * ch, c, zb),
			Vector3(w - side * ch, c, zb), Vector3.DOWN, shade)
	b.quad(Vector3(-top_x, top, z), Vector3(top_x, top, z), Vector3(top_x, top, zb), Vector3(-top_x, top, zb),
		Vector3.UP, shade)
