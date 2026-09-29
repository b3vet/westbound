extends WBTest
## HUD building blocks. Spec: Scoring → Multiplier ("the HUD shows up to 999×"); UI →
## Design system (tabular numbers, faceted panels with a neon edge), Performance
## budget (one triangle array per widget: HudMesh).

var t: HudTuning


func before_all() -> void:
	t = Tuning.load_default().hud


func test_thousands_separators() -> void:
	eq(HudFormat.thousands(0), "0")
	eq(HudFormat.thousands(999), "999")
	eq(HudFormat.thousands(1000), "1,000")
	eq(HudFormat.thousands(1284500), "1,284,500")
	eq(HudFormat.thousands(-48200), "-48,200")


func test_multiplier_keys_and_text() -> void:
	var below := t.multiplier_decimals_below
	var top := t.multiplier_display_max
	eq(HudFormat.multiplier_text(HudFormat.multiplier_key(1.0, below, top), below), "1.0×")
	eq(HudFormat.multiplier_text(HudFormat.multiplier_key(0.2, below, top), below), "1.0×", "never below 1.0x")
	eq(HudFormat.multiplier_text(HudFormat.multiplier_key(12.44, below, top), below), "12.4×")
	eq(HudFormat.multiplier_text(HudFormat.multiplier_key(250.6, below, top), below), "251×")
	eq(HudFormat.multiplier_text(HudFormat.multiplier_key(1e9, below, top), below), "999×", "capped")
	eq(HudFormat.multiplier_key(12.41, below, top), HudFormat.multiplier_key(12.44, below, top),
			"same shown value, same key (no redraw)")


func test_distance_and_speed_values() -> void:
	eq(HudFormat.distance_key(-1.0, false), -1, "no checkpoint")
	eq(HudFormat.tenths_text(HudFormat.distance_key(1234.0, false)), "1.2")
	eq(HudFormat.tenths_text(HudFormat.distance_key(1609.344, true)), "1.0", "one mile")
	eq(HudFormat.speed_value(Units.kmh_to_mps(212.4), false), 212)
	eq(HudFormat.speed_value(Units.kmh_to_mps(100.0), true), 62, "mph")
	eq(HudFormat.speed_value(-5.0, false), 18, "never negative")


func test_mesh_panel_is_one_triangle_list_with_feathered_edge() -> void:
	var m := HudMesh.new()
	m.begin()
	m.panel(Rect2(0.0, 0.0, 200.0, 80.0), t.panel_bevel_px, Color.BLACK, Color.WHITE, t.neon_border_px)
	var fill_v := HudDraw.CHAMFER_POINTS
	var edge_v := HudDraw.CHAMFER_POINTS * 3 * 4
	eq(m.vertex_count(), fill_v + edge_v, "fan + three bands per edge segment")
	var n := m.vertex_count()
	m.begin()
	m.panel(Rect2(10.0, 10.0, 300.0, 90.0), t.panel_bevel_px, Color.BLACK, Color.WHITE, t.neon_border_px)
	eq(m.vertex_count(), n, "same shapes, same buffer size (reused)")


func test_mesh_skips_invisible_shapes() -> void:
	var m := HudMesh.new()
	m.begin()
	m.rect(Rect2(0.0, 0.0, 10.0, 10.0), Color(1.0, 1.0, 1.0, 0.0))
	m.edge(PackedVector2Array([Vector2.ZERO, Vector2.RIGHT]), 2, 1.0, Color.WHITE)
	eq(m.vertex_count(), 0)


func test_chamfer_cuts_every_corner_by_the_bevel() -> void:
	var p := PackedVector2Array()
	p.resize(HudDraw.CHAMFER_POINTS)
	HudDraw.chamfer(Rect2(0.0, 0.0, 100.0, 50.0), t.panel_bevel_px, p)
	eq(p[0], Vector2(t.panel_bevel_px, 0.0))
	eq(p[2], Vector2(100.0, t.panel_bevel_px))
	eq(p[7], Vector2(0.0, t.panel_bevel_px))
