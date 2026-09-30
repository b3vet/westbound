class_name GarageCatalog
extends Resource
## Everything the garage offers (WP8.2): the 8 roster slots, the paints and the rims, each
## with its unlock rule. Spec: Garage and progression. Data: data/cars/garage.tres
## (ProgressionTuning.garage_catalog_path). docs/GARAGE.md.
##
## Unlock ids (the save's `unlocks` keys): "car/<slot id>", "paint/<id>", "rim/<id>".

const CAR := "car/"
const PAINT := "paint/"
const RIM := "rim/"

@export var slots: Array[GarageSlot] = []
@export var paints: Array[PaintOption] = []
@export var rims: Array[RimStyle] = []


static func load_path(path: String) -> GarageCatalog:
	return load(path) as GarageCatalog


func slot(slot_id: StringName) -> GarageSlot:
	for s in slots:
		if s.id == slot_id:
			return s
	return null


func paint(paint_id: StringName) -> PaintOption:
	for p in paints:
		if p.id == paint_id:
			return p
	return null


func rim(rim_id: StringName) -> RimStyle:
	for r in rims:
		if r.id == rim_id:
			return r
	return null


## The slot a real car sits in (by its CarDef path), or null.
func slot_for_car_path(path: String) -> GarageSlot:
	for s in slots:
		if s.car_path == path:
			return s
	return null


## Every unlock id in catalog order: the cars, then the paints, then the rims.
func unlock_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for s in slots:
		out.append(CAR + String(s.id))
	for p in paints:
		out.append(PAINT + String(p.id))
	for r in rims:
		out.append(RIM + String(r.id))
	return out


## The item's shown name ("NIGHT VIPER", "SUNSET PAINT", "MESH RIMS"); placeholders
## read COMING SOON.
func item_name(unlock_id: String) -> String:
	if unlock_id.begins_with(CAR):
		var s := slot(StringName(unlock_id.trim_prefix(CAR)))
		if s == null:
			return ""
		var c := s.car()
		return c.display_name.to_upper() if c != null else TEXT_COMING_SOON
	if unlock_id.begins_with(PAINT):
		var p := paint(StringName(unlock_id.trim_prefix(PAINT)))
		return (TEXT_PAINT % p.display_name) if p != null else ""
	if unlock_id.begins_with(RIM):
		var r := rim(StringName(unlock_id.trim_prefix(RIM)))
		return (TEXT_RIMS % r.display_name) if r != null else ""
	return ""


const TEXT_COMING_SOON := "COMING SOON"
const TEXT_PAINT := "%s PAINT"
const TEXT_RIMS := "%s RIMS"
