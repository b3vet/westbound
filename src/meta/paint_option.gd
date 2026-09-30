class_name PaintOption
extends Resource
## A paint colour for the garage (WP8.2). Spec: Garage and progression ("Levels unlock
## cars, paint colors and rims"; "Cosmetics. Paint colors and rims now"); Car shader
## ("Paint color ... [is a] shader parameter, so recoloring costs nothing"); Art pipeline
## (one palette of about 30 colours). Listed in data/cars/garage.tres; every paint fits
## every car. docs/GARAGE.md.

@export var id: StringName = &""
@export var display_name: String = ""
## sRGB (the vehicle shader's paint_color).
@export var color: Color = Color.WHITE
## The car's own CarDef.default_paint instead of `color` (the FACTORY option).
@export var factory: bool = false
## The driver level that unlocks it.
@export var unlock_level: int = 1


## The colour this paint gives `car`.
func color_for(car: CarDef) -> Color:
	if factory and car != null:
		return car.default_paint
	return color
