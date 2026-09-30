class_name CarLook
extends RefCounted
## A car's cosmetics: paint colour and rims (WP8.2). Spec: Car shader ("Paint color ...
## are shader parameters, so recoloring costs nothing"); Modular car convention (Rim:
## swappable mesh); Garage and progression (Cosmetics). The garage picks it
## (Garage.selected_look), PlayerCar.setup and the garage turntable apply it with
## CarModel.apply_rim + apply_paint. Visual only: physics never reads it.

## Paint colour (sRGB).
var paint: Color = Color.WHITE
## null or a model_default style: the model's own rims.
var rim: RimStyle


static func make(paint_color: Color, rim_style: RimStyle = null) -> CarLook:
	var l := CarLook.new()
	l.paint = paint_color
	l.rim = rim_style
	return l


## The car's own look: its default paint and its model's rims.
static func factory(car: CarDef) -> CarLook:
	return make(car.default_paint if car != null else Color.WHITE)


## True when the rims are swapped (not the model's own).
func swaps_rims() -> bool:
	return rim != null and not rim.model_default


## Two looks draw the same (null = the car's factory look).
static func same(a: CarLook, b: CarLook, car: CarDef) -> bool:
	var la := a if a != null else factory(car)
	var lb := b if b != null else factory(car)
	if not la.paint.is_equal_approx(lb.paint):
		return false
	if la.swaps_rims() != lb.swaps_rims():
		return false
	return not la.swaps_rims() or la.rim == lb.rim
