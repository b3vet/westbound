class_name MetaTuning
extends Resource
## Save, settings choices and the first run. Spec: Controls → Settings and first run ("a
## one-screen chooser for steering and throttle (default: drag + auto), then a 20-second
## empty-road warm-up so players feel it before traffic"); Save data. WP8.1;
## docs/SAVE.md. Saved as data/tuning/meta.tres.

@export_group("First run")
## The empty-road warm-up on the first Journey run (spec: 20 s), in RUNNING time.
@export var warmup_s: float = 20.0
## After the warm-up, traffic density ramps from 0 to the leg's over this long (the
## director plans the new traffic beyond the fog, so it arrives out of the distance).
@export var warmup_fade_s: float = 12.0   # not in spec
## The ramp's steps (each is one director density change).
@export var warmup_fade_steps: int = 4   # not in spec
## The hint's "TRAFFIC AHEAD" line stays this long after the warm-up ends.
@export var warmup_end_note_s: float = 2.5   # not in spec

@export_group("Settings choices")
## Dead zone and response curve rows: multipliers of the tuned values (ControlsTuning:
## drag dead zone 4 %, gyro 2 deg, curve exponent 1.6), clamped by PlayerInput to
## setting_scale_min/max_factor. Captions in SettingsPanel (SMALL / NORMAL / LARGE,
## GENTLE / NORMAL / SHARP).
@export var settings_dead_zones: PackedFloat64Array = [0.5, 1.0, 2.0]   # not in spec
@export var settings_curves: PackedFloat64Array = [0.625, 1.0, 1.375]   # not in spec: exponent 1.0 / 1.6 / 2.2


static func resolve() -> MetaTuning:
	var t := Tuning.load_default()
	return t.meta if t.meta != null else MetaTuning.new()
