extends Control
## WP9.9 (docs/WEB.md → Slim engine): player names in the game's theme, for comparing the
## text rendering of two web engines (tools/web_template/probe.mjs --names takes a
## screenshot). Latin with diacritics (Turkish, Polish, Nordic, Spanish), Turkish
## upper-casing, a combining accent, Greek and Cyrillic (font fallback), Thai (shaping)
## and an emoji, as `name#tag` like the game shows them. Prints each line's shaped width:
##   PROBE text <width> <line>
##   PROBE done text

const THEME_PATH := "res://src/ui/theme/theme.tres"
const LINES: Array[String] = [
	"Şahin#1234", "şahin ilık ağır ÇĞİÖŞÜ çğıöşü#0042", "Zoë Ñandú Łukasz Øyvind Ærø#7",
	"Céline (combining accent)#55", "Αλέξανδρος Дмитрий#9001", "สมชาย ใจดี#12", "Road Runner 🚗#1",
	"AVATAR WAVE To Ty Yo LT#8",
]
const FONT_SIZE := 30
const MARGIN := 16.0


func _ready() -> void:
	theme = load(THEME_PATH) as Theme
	var bg := ColorRect.new()
	bg.color = Color(0.043, 0.063, 0.125)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var font := get_theme_default_font()
	var y := MARGIN
	for i in LINES.size() + 1:
		var text := LINES[i] if i < LINES.size() else "ŞAHİN uppercase: " + "şahin ilık".to_upper()
		var label := Label.new()
		label.text = text
		label.position = Vector2(MARGIN, y)
		label.add_theme_font_size_override(&"font_size", FONT_SIZE)
		if i == LINES.size():
			label.uppercase = true
			label.language = "tr"
		add_child(label)
		y += FONT_SIZE * 1.6
		print("PROBE text %.3f %s" % [font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x, text])
	print("PROBE done text")
