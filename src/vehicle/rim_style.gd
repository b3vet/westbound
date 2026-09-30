class_name RimStyle
extends Resource
## A rim option for the garage (WP8.2). Spec: Modular car convention ("Rim: swappable
## mesh (scaled to wheel radius)"; Rim budget 800 triangles, shared); Garage and
## progression ("Cosmetics. Paint colors and rims now"). Listed in data/cars/garage.tres.
##
## A simple flat-shaded variant of the stub rim (CarModel.build_styled_rim_mesh): a face
## disc, spokes, an optional lip ring, in the vehicle shader's trim slot (vertex colours,
## sRGB). `model_default` keeps the model's own rims (the stock option), so the default
## look never changes a model. docs/GARAGE.md.

@export var id: StringName = &""
@export var display_name: String = ""
## Keep the model's own Rim meshes (no swap).
@export var model_default: bool = false
## The driver level that unlocks it.
@export var unlock_level: int = 1

@export_group("Shape")
@export var spokes: int = 5
## Rim radius as a fraction of the wheel radius.
@export var radius_frac: float = 0.62
## Spoke half-width as a fraction of the rim radius.
@export var spoke_width_frac: float = 0.12
## Outer lip ring width as a fraction of the rim radius (0 = none).
@export var lip_frac: float = 0.0

@export_group("Colours (sRGB)")
@export var face_color: Color = Color(0.56, 0.56, 0.58)
@export var spoke_color: Color = Color(0.2, 0.2, 0.21)
@export var lip_color: Color = Color(0.8, 0.8, 0.82)
