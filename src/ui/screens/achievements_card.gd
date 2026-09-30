class_name AchievementsCard
extends ScreenPanel
## One achievement on the achievements screen (WP8.3): a faceted panel with the title, the
## state line (UNLOCKED, LOCKED, ???, or the progress "7 / 10"), the description and a
## progress bar. Spec: Garage and progression (Achievements); Design system (faceted
## panels, neon edge, gold for celebrations); Accessibility (text size; colour is never
## the only cue: the state line says it). docs/ACHIEVEMENTS.md → Screen.
##
##   ┌──────────────────────────────────────┐
##   │ CLOSE CALLS                  17 / 25 │
##   │ 25 CLOSE PASSES IN ONE RUN.          │
##   │ ▰▰▰▰▰▰▰▰▰▰▰▰▱▱▱▱▱▱                   │
##   └──────────────────────────────────────┘
##
## Unlocked: a gold edge and tab, the title and UNLOCKED in gold, a full gold bar. A locked
## hidden one reads HIDDEN / KEEP DRIVING TO REVEAL IT. / ??? with no bar. Takes no
## touches (the screen has no per-card action).

var ach: AchievementTuning
var def: AchievementDef
var unlocked: bool = false
var title_text: ScreenText
var state_text: ScreenText
var desc_text: ScreenText
var bar: GarageXpBar

var _title_full: String = ""
var _desc_full: String = ""


func _init() -> void:
	super._init()
	title_text = ScreenText.make("", ScreenText.Face.DISPLAY, 19, ScreenText.Ink.TEXT)
	title_text.name = "Title"
	add_child(title_text)
	state_text = ScreenText.make("", ScreenText.Face.LABEL, 14, ScreenText.Ink.MUTED)
	state_text.name = "State"
	state_text.tabular = true
	state_text.align = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(state_text)
	desc_text = ScreenText.make("", ScreenText.Face.BODY, 15, ScreenText.Ink.MUTED)
	desc_text.name = "Description"
	add_child(desc_text)
	bar = GarageXpBar.new()
	bar.name = "Bar"
	add_child(bar)


func setup_card(s: HudStyle, t: AchievementTuning) -> void:
	ach = t
	title_text.size_px = t.card_title_px
	state_text.size_px = t.card_state_px
	desc_text.size_px = t.card_desc_px
	setup(s)
	for c: ScreenText in [title_text, state_text, desc_text]:
		c.setup(s)
	bar.setup(s)


## Shows `d`: unlocked or not, its metric `v` against `threshold` (tracker units).
func show_achievement(d: AchievementDef, is_unlocked: bool, v: float, threshold: float, cat: AchievementCatalog,
		miles: bool) -> void:
	def = d
	unlocked = is_unlocked
	_title_full = AchievementText.title(d, is_unlocked)
	_desc_full = AchievementText.description(d, cat, miles, is_unlocked)
	state_text.text = AchievementText.state(d, v, threshold, is_unlocked, miles)
	edge = ScreenPanel.Edge.GOLD if is_unlocked else ScreenPanel.Edge.IDLE
	title_text.set_ink(ScreenText.Ink.GOLD if is_unlocked else (ScreenText.Ink.MUTED if d.hidden else ScreenText.Ink.TEXT))
	state_text.set_ink(ScreenText.Ink.GOLD if is_unlocked else ScreenText.Ink.MUTED)
	bar.visible = AchievementText.has_bar(d, threshold, is_unlocked)
	bar.gold = is_unlocked
	bar.frac = 1.0 if is_unlocked else (clampf(v / threshold, 0.0, 1.0) if threshold > 0.0 else 0.0)
	queue_redraw()
	layout_card()


func _pad() -> float:
	return style.px(style.tuning.spacing_grid_px * ach.card_pad_cells) if style != null and ach != null else 0.0


## The card's height for its type sizes: padding, the title line, the description line,
## a gap and the bar.
func desired_height() -> float:
	if style == null or ach == null:
		return 0.0
	var g := style.px(style.tuning.spacing_grid_px)
	return _pad() * 2.0 + title_text.get_combined_minimum_size().y + desc_text.get_combined_minimum_size().y \
			+ g + style.px(ach.card_bar_px)


## Lays the texts and the bar out in the card's size (texts cut with … only if they
## cannot fit; the text-fit tests hold them whole at both text sizes).
func layout_card() -> void:
	if style == null or ach == null:
		return
	var pad := _pad()
	var g := style.px(style.tuning.spacing_grid_px)
	var inner := size.x - pad * 2.0
	var ss := state_text.get_combined_minimum_size()
	state_text.size = ss
	var title_h := title_text.get_combined_minimum_size().y
	state_text.position = Vector2(size.x - pad - ss.x, pad + (title_h - ss.y) * 0.5)
	SocialUi.fit_text(title_text, _title_full, maxf(inner - ss.x - g, 0.0))
	title_text.position = Vector2(pad, pad)
	title_text.size = Vector2(title_text.get_combined_minimum_size().x, title_h)
	SocialUi.fit_text(desc_text, _desc_full, maxf(inner, 0.0))
	var dh := desc_text.get_combined_minimum_size().y
	desc_text.position = Vector2(pad, pad + title_h)
	desc_text.size = Vector2(desc_text.get_combined_minimum_size().x, dh)
	var bh := style.px(ach.card_bar_px)
	bar.position = Vector2(pad, size.y - pad - bh)
	bar.size = Vector2(maxf(inner, 0.0), bh)


## The title and description are shown whole (not cut).
func texts_whole() -> bool:
	return title_text.text == _title_full and desc_text.text == _desc_full


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		layout_card()
