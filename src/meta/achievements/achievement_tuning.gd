class_name AchievementTuning
extends Resource
## Achievements (WP8.3): where the catalog is, the unlock toast and the achievements
## screen. Spec: Garage and progression (Achievements); UI → Screens (toasts never pause
## play); HUD layout (thumb zones, the middle third stays clear); Accessibility (text size
## 100% / 125%). Saved as data/achievements/tuning.tres (outside data/tuning/: WP8.3 owns
## data/achievements/; the root Tuning can reference it later). docs/ACHIEVEMENTS.md.

const PATH := "res://data/achievements/tuning.tres"

static var _default: AchievementTuning

## The achievements and the platform ids (AchievementCatalog).
@export_file("*.tres") var catalog_path: String = "res://data/achievements/catalog.tres"

@export_group("Unlock toast")
## On screen for toast_s (fade in over toast_in_s, out over toast_out_s), real time.
@export var toast_s: float = 3.2
@export var toast_in_s: float = 0.2
@export var toast_out_s: float = 0.5
## Size at 100 % text (canvas px; grows with the text size, never past the space between
## the middle third and the safe edge).
@export var toast_size_px: Vector2 = Vector2(340.0, 74.0)
## Unlocks waiting behind the one on show (more are dropped from the toast, never from
## the save).
@export var toast_queue_max: int = 4
## The header line's size (px at 100 %) and the title's scale of the event font.
@export var toast_header_px: int = 13
@export var toast_title_scale: float = 1.0
## Canvas layer: above the run's screens (60), below the dev HUD (100).
@export var toast_layer: int = 70

@export_group("Achievements screen")
## Cards per row and rows per tab.
@export var screen_columns: int = 3
@export var screen_rows: int = 3
## Card text sizes (px at 100 %): title, the progress / state line, description.
@export var card_title_px: int = 19
@export var card_state_px: int = 14
@export var card_desc_px: int = 15
## The progress bar's height (px at 100 %) and the card's inner padding (spacing cells).
@export var card_bar_px: float = 6.0
@export var card_pad_cells: float = 1.5


static func load_default() -> AchievementTuning:
	if _default == null:
		_default = load(PATH) as AchievementTuning
	return _default
