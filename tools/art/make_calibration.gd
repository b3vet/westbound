extends SceneTree
## Writes the game-side calibration assets (WP-ART-G; docs/ART_PRODUCTION.md §5 P0, G9)
## from ArtCalib, as the Blender agent's exports would arrive:
##
##   tools/godot.sh --headless --path . --script res://tools/art/make_calibration.gd
##   tools/godot.sh --headless --path . --import      # imports the car and rim files
##
##   tests/art/fixtures/calib_car/   calib_car.glb (+ .car.json, .glb.import with the car
##                                   import script), calib_car_lod1.glb, calib_car.tres
##                                   (its CarDef: tests only, never in the roster)
##   tests/art/fixtures/calib_rim/   calib_rim.glb (+ .rim.json, .glb.import)
##   tests/art/fixtures/export/      (gdignored, like art/export) traffic/calib_traffic.glb
##                                   (+ .traffic.json, _lod1.glb), props/common/calib_swatch.glb
##                                   (+ .prop.json): inputs for tools/art/convert.gd
## Deterministic geometry; rerun after changing ArtCalib, then reimport.

const DIR := "res://tests/art/fixtures/"
const CAR_DIR := DIR + "calib_car/"
const RIM_DIR := DIR + "calib_rim/"
const EXPORT_DIR := DIR + "export/"
const IMPORT_TEMPLATE := """[remap]

importer="scene"
importer_version=1
type="PackedScene"

[deps]

source_file="%s"

[params]

nodes/root_type=""
nodes/root_name=""
nodes/apply_root_scale=true
nodes/root_scale=1.0
nodes/use_name_suffixes=true
nodes/use_node_type_suffixes=true
meshes/ensure_tangents=false
meshes/generate_lods=false
meshes/create_shadow_meshes=false
meshes/light_baking=0
animation/import=false
import_script/path="res://assets/cars/car_import.gd"
materials/extract=0
gltf/naming_version=2
gltf/embedded_image_handling=0
"""

var _failed := false


func _initialize() -> void:
	var c := ArtCalib.new()
	_glb(c.build_car(), CAR_DIR + "calib_car.glb", true)
	_json(CAR_DIR + "calib_car.car.json", {"root_name": "Car_CalibCar", "modular": true,
		"source": "in-house, generated: tools/art/make_calibration.gd (ArtCalib.build_car)"})
	_glb(c.build_car_lod1(), CAR_DIR + "calib_car_lod1.glb", true)
	var def := ArtCalib.car_def(CAR_DIR + "calib_car.glb")
	if ResourceSaver.save(def, CAR_DIR + "calib_car.tres") != OK:
		_fail("cannot save the CarDef")
	_glb(c.build_rim(), RIM_DIR + "calib_rim.glb", true)
	_json(RIM_DIR + "calib_rim.rim.json", {"root_name": "Rim_Calib", "rim": "calib",
		"source": "in-house, generated: tools/art/make_calibration.gd (ArtCalib.build_rim)"})
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(EXPORT_DIR))
	var ignore := FileAccess.open(EXPORT_DIR + ".gdignore", FileAccess.WRITE)
	if ignore != null:
		ignore.close()
	_glb(c.build_traffic(), EXPORT_DIR + "traffic/calib_traffic.glb", false)
	_glb(c.build_traffic(true), EXPORT_DIR + "traffic/calib_traffic_lod1.glb", false)
	_json(EXPORT_DIR + "traffic/calib_traffic.traffic.json", {"model": "calib_traffic",
		"vehicle_type": String(ArtCalib.TRAFFIC_TYPE), "paint_palette": []})
	_glb(c.build_swatch(), EXPORT_DIR + "props/common/calib_swatch.glb", false)
	_json(EXPORT_DIR + "props/common/calib_swatch.prop.json", {"mesh": "calib_swatch", "material": "world_windows",
		"meta": {"length_m": 10.0}, "tris_budget": 1000})
	quit(1 if _failed else 0)


func _glb(scene_root: Node, path: String, with_import: bool) -> void:
	var err := ArtCalib.write_glb(scene_root, path)
	scene_root.free()
	if err != OK:
		_fail("cannot write %s (%d)" % [path, err])
		return
	print("wrote ", path)
	if with_import and not FileAccess.file_exists(path + ".import"):
		var f := FileAccess.open(path + ".import", FileAccess.WRITE)
		f.store_string(IMPORT_TEMPLATE % path)
		f.close()


func _json(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_fail("cannot write %s" % path)
		return
	f.store_string(JSON.stringify(data, "\t") + "\n")
	f.close()
	print("wrote ", path)


func _fail(msg: String) -> void:
	printerr("make_calibration: ", msg)
	_failed = true
