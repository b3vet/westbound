class_name LandmarkTextAtlas
extends RefCounted
## Sign text baked into one small coverage texture (WP5.3). Spec: World → Checkpoint
## landmarks ("big sign gantry with the leg name and distance"), Night lighting
## (retro-reflective signs), Performance budget (no extra passes; one texture for
## every sign). docs/CONTRACTS.md §13: the text is sampled by landmark.gdshader, a
## world-shader variant, so fog, the color grade and the night ramps treat it exactly
## like the sign it sits on, on both renderers.
##
## Every text line of every pooled build owns a fixed region (shelf-packed at
## warm-up), sized to its strip's aspect. `draw(region, text)` rasterises the font's
## glyphs on the CPU through the TextServer (no viewport, so it also works headless)
## and `commit()` uploads the changed regions once (the texture is R8 with mipmaps:
## coverage in red, no colour conversion anywhere). The font is the engine's default
## UI font (Open Sans SemiBold, embedded in Godot), a plain highway-style sans.

var width: int = 0
var height: int = 0
var row_px: int = 0
var gutter_px: int = 0
var cap_frac: float = 0.6
var side_margin_frac: float = 0.4
var texture: ImageTexture
## Regions allocated (tests read this).
var regions: Array[Rect2i] = []
## Last text drawn into each region (tests read this).
var region_text: PackedStringArray = []
## Regions that did not fit (sizing error; tests assert 0).
var dropped: int = 0

## Glyphs rendered into the font's cache once per size, before first use (sign text
## is upper case; any other character is rendered when it first appears).
const CHARSET := "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,:-—·/&'()"

## Composition in the glyph cache's format (LA8, opaque black: blending white glyphs
## leaves coverage in L) and the uploaded R8 copy (with mipmaps).
var _compose: Image
var _r8: Image
var _dirty_regions := PackedInt32Array()
## Characters already rendered into the font's glyph cache, per size.
var _prepared := {}
var _font: Font
var _ts: TextServer
var _font_rid: RID
var _shelf_x: int = 0
var _shelf_y: int = 0
var _dirty: bool = true
var _cap_per_px: float = 0.0


func _init(t: LandmarkTuning) -> void:
	width = t.text_atlas_width_px
	height = t.text_atlas_height_px
	row_px = t.text_row_px
	gutter_px = t.text_gutter_px
	cap_frac = t.text_cap_height_frac
	side_margin_frac = t.text_side_margin_frac
	_compose = Image.create(width, height, false, Image.FORMAT_LA8)
	_compose.fill(Color.BLACK)
	_font = ThemeDB.fallback_font
	_ts = TextServerManager.get_primary_interface()
	var rids := _font.get_rids()
	_font_rid = rids[0] if not rids.is_empty() else RID()
	_shelf_x = gutter_px
	_shelf_y = gutter_px
	_r8 = Image.create(width, height, true, Image.FORMAT_R8)
	_r8.fill(Color.BLACK)
	texture = ImageTexture.create_from_image(_r8)
	_dirty = false
	if _font_rid.is_valid():
		_prepare(_base_size(), "")


## A region for a text line whose strip is `aspect` (width / height) wide. Returns
## its index, or -1 when the atlas is full.
func alloc(aspect: float) -> int:
	var w := clampi(roundi(float(row_px) * aspect), row_px, width - 2 * gutter_px)
	if _shelf_x + w + gutter_px > width:
		_shelf_x = gutter_px
		_shelf_y += row_px + gutter_px
	if _shelf_y + row_px + gutter_px > height:
		dropped += 1
		return -1
	regions.append(Rect2i(_shelf_x, _shelf_y, w, row_px))
	region_text.append("")
	_shelf_x += w + gutter_px
	return regions.size() - 1


## Region `i` as (u0, v0, du, dv) for the shader's line_rect[].
func uv_rect(i: int) -> Vector4:
	if i < 0:
		return Vector4.ZERO
	var r := regions[i]
	return Vector4(float(r.position.x) / float(width), float(r.position.y) / float(height),
		float(r.size.x) / float(width), float(r.size.y) / float(height))


## Rasterises `text` centred in region `i` (clears it first). Text too wide for the
## region is set smaller. Director rate: allocates. No-op if the text is unchanged.
func draw(i: int, text: String) -> void:
	if i < 0 or region_text[i] == text:
		return
	region_text[i] = text
	var r := regions[i]
	_compose.fill_rect(r, Color.BLACK)
	_dirty_regions.append(i)
	_dirty = true
	if text == "" or not _font_rid.is_valid():
		return
	var size := _base_size()
	var avail := float(r.size.x) - 2.0 * side_margin_frac * float(row_px)
	_prepare(size, text)
	var adv := _advance(text, size)
	if adv > avail and adv > 0.0:
		size = _quantize(float(size) * avail / adv)
		_prepare(size, text)
		adv = _advance(text, size)
	var fs := Vector2i(size, 0)
	var cap := float(size) * _cap_height_per_px()
	var baseline := float(r.position.y) + (float(row_px) + cap) * 0.5
	var pen := float(r.position.x) + (float(r.size.x) - adv) * 0.5
	for k in text.length():
		var g := _ts.font_get_glyph_index(_font_rid, size, text.unicode_at(k), 0)
		var ti := _ts.font_get_glyph_texture_idx(_font_rid, fs, g)
		if ti >= 0:
			var uv := _ts.font_get_glyph_uv_rect(_font_rid, fs, g)
			var off := _ts.font_get_glyph_offset(_font_rid, fs, g)
			var src := _page(size, ti)
			var src_rect := Rect2i(Vector2i(uv.position), Vector2i(uv.size))
			var dst := Vector2i(roundi(pen + off.x), roundi(baseline + off.y))
			# Clip to the region (never draw into a neighbour).
			var clip := Rect2i(dst, src_rect.size).intersection(r)
			if clip.size.x > 0 and clip.size.y > 0:
				var src_clip := Rect2i(src_rect.position + (clip.position - dst), clip.size)
				_compose.blend_rect(src, src_clip, clip.position)
		pen += _ts.font_get_glyph_advance(_font_rid, size, g).x


## Uploads the atlas if anything was drawn since the last commit: the changed
## regions go into the R8 image, its mipmaps are rebuilt and it is uploaded once.
func commit() -> void:
	if not _dirty:
		return
	_dirty = false
	for i in _dirty_regions:
		var r := regions[i]
		var sub := _compose.get_region(r)
		sub.convert(Image.FORMAT_R8)
		_r8.blit_rect(sub, Rect2i(Vector2i.ZERO, r.size), r.position)
	_dirty_regions.clear()
	_r8.generate_mipmaps()
	texture.update(_r8)


## Share of region `i`'s pixels with ink (tests).
func ink_share(i: int) -> float:
	var r := regions[i]
	var n := 0
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if _compose.get_pixel(x, y).r > 0.5:
				n += 1
	return float(n) / float(r.size.x * r.size.y)


## Glyphs are rasterised so that a capital is cap_frac of the row: the font's capital
## height per pixel of size (from the ink of "H").
func _cap_height_per_px() -> float:
	if _cap_per_px > 0.0:
		return _cap_per_px
	_cap_per_px = 1.0
	if not _font_rid.is_valid():
		return _cap_per_px
	var probe := row_px
	var g := _ts.font_get_glyph_index(_font_rid, probe, "H".unicode_at(0), 0)
	_ts.font_render_glyph(_font_rid, Vector2i(probe, 0), g)
	var h := _ts.font_get_glyph_size(_font_rid, Vector2i(probe, 0), g).y
	if h > 0.0:
		_cap_per_px = h / float(probe)
	return _cap_per_px


func _advance(text: String, size: int) -> float:
	var w := 0.0
	for k in text.length():
		var g := _ts.font_get_glyph_index(_font_rid, size, text.unicode_at(k), 0)
		w += _ts.font_get_glyph_advance(_font_rid, size, g).x
	return w


## The font size whose capitals fill cap_frac of a row.
func _base_size() -> int:
	return _quantize(float(row_px) * cap_frac / _cap_height_per_px())


## Font sizes in steps of two pixels (fewer glyph caches).
static func _quantize(size: float) -> int:
	return maxi(2, int(floor(size * 0.5)) * 2)


## Renders the charset (once per size) and any other character of `text` into the
## font's glyph cache.
func _prepare(size: int, text: String) -> void:
	var fs := Vector2i(size, 0)
	var done: String = _prepared.get(size, "")
	var add := ""
	if done == "":
		add = CHARSET
	for k in text.length():
		var ch := text[k]
		if done.find(ch) < 0 and add.find(ch) < 0:
			add += ch
	if add == "":
		return
	for k in add.length():
		_ts.font_render_glyph(_font_rid, fs, _ts.font_get_glyph_index(_font_rid, size, add.unicode_at(k), 0))
	_prepared[size] = done + add


## Glyph-cache page `ti` of `size` in the composition's format (the cache is LA8 for
## plain fonts: used as is).
func _page(size: int, ti: int) -> Image:
	var img := _ts.font_get_texture_image(_font_rid, Vector2i(size, 0), ti)
	if img.get_format() != _compose.get_format():
		img = img.duplicate() as Image
		img.convert(_compose.get_format())
	return img
