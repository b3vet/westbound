"""glTF export with the Westbound settings, plus the sidecar JSON (docs/ART_PRODUCTION.md §3.10).

  blender -b art/blender/cars/falcon_gt.blend --python tools/blender/wb_export.py -- --asset=car --id=falcon_gt
  (inside Blender)  import wb_export; wb_export.export_car("falcon_gt")

Cars: collection <id> -> assets/cars/<id>/<id>.glb + <id>.car.json ("modular": true);
collection <id>_lod1 (one mesh object named Body_lod1) -> <id>_lod1.glb as root + Body.
Validates first (wb_validate) and refuses to write a car with errors unless force=True.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import wb_palette  # noqa: E402
import wb_scaffold_car as scaffold  # noqa: E402
import wb_validate  # noqa: E402

REPO = wb_palette.REPO

GLTF_SETTINGS = dict(
    export_format="GLB",
    use_selection=True,
    export_yup=True,
    export_apply=True,
    export_normals=True,
    export_texcoords=True,
    export_tangents=False,
    export_materials="EXPORT",
    export_image_format="NONE",
    export_vertex_color="NONE",
    export_all_vertex_colors=False,
    export_active_vertex_color_when_no_material=False,
    export_attributes=False,
    export_cameras=False,
    export_lights=False,
    export_animations=False,
    export_skins=False,
    export_morph=False,
    export_draco_mesh_compression_enable=False,
    export_extras=False,
)


def _bpy():
    import bpy
    return bpy


def context_override():
    """A window context for operators called from a timer (the MCP bridge); {} in -b."""
    bpy = _bpy()
    wm = bpy.context.window_manager
    if wm is None or not wm.windows:
        return {}
    win = wm.windows[0]
    area = next((a for a in win.screen.areas if a.type == "VIEW_3D"), win.screen.areas[0])
    return dict(window=win, screen=win.screen, area=area, scene=bpy.context.scene,
                view_layer=bpy.context.view_layer)


def export_objects(objects, path):
    """Export exactly `objects` (selection) to `path` (.glb) with GLTF_SETTINGS."""
    bpy = _bpy()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    for ob in bpy.context.view_layer.objects:
        ob.select_set(False)
    for ob in objects:
        ob.hide_set(False)
        ob.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    with bpy.context.temp_override(**context_override()):
        bpy.ops.export_scene.gltf(filepath=path, **GLTF_SETTINGS)
    for ob in objects:
        ob.select_set(False)
    return path


# tools/art/make_calibration.gd IMPORT_TEMPLATE: the car import script, name suffixes on,
# no tangents (§6.3). Written only when missing (Godot adds the uid on first import).
GODOT_IMPORT_TEMPLATE = """[remap]

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


def write_godot_import(glb_path):
    """<file>.glb.import with the car import script, unless one exists."""
    path = glb_path + ".import"
    if os.path.exists(path):
        return
    res = "res://" + os.path.relpath(glb_path, REPO).replace(os.sep, "/")
    with open(path, "w", encoding="utf-8") as f:
        f.write(GODOT_IMPORT_TEMPLATE % res)


def write_json(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent="\t")
        f.write("\n")


def export_car(car_id, out_dir=None, force=False, lod1=None, source=None, cardef=None):
    """Validate and export car `car_id`. Returns the validation report."""
    bpy = _bpy()
    out_dir = out_dir or os.path.join(REPO, "assets", "cars", car_id)
    lod1 = bpy.data.collections.get(car_id + "_lod1") is not None if lod1 is None else lod1
    rep = wb_validate.validate_car(car_id, lod1=lod1, cardef=cardef)
    print(rep.summary())
    if not rep.ok() and not force:
        raise RuntimeError("validation failed; nothing exported")
    col = bpy.data.collections[car_id]
    glb = export_objects(list(col.all_objects), os.path.join(out_dir, car_id + ".glb"))
    write_godot_import(glb)
    write_json(os.path.join(out_dir, car_id + ".car.json"), {
        "root_name": scaffold.root_name(car_id), "modular": True, "forward_axis": "-Z",
        # Smooth bodies: keep the file's split normals (CarModularImport reads this).
        "flat_shading": not any(p.use_smooth for o in col.all_objects if o.type == "MESH" for p in o.data.polygons),
        "source": source or "in-house, Blender: art/blender/cars/%s.blend (tools/blender/cars/%s.py)" % (car_id, car_id),
    })
    if lod1:
        export_lod1(car_id, out_dir)
    return rep


def export_lod1(car_id, out_dir):
    """<id>_lod1 collection (root Empty + Body_lod1) -> <id>_lod1.glb with the mesh node named Body."""
    bpy = _bpy()
    lc = bpy.data.collections[car_id + "_lod1"]
    body = bpy.data.objects["Body"]
    lod = next(o for o in lc.all_objects if o.type == "MESH")
    root = next(o for o in lc.all_objects if o.type == "EMPTY")
    body.name = "Body_lod0_tmp"
    old = lod.name
    lod.name = "Body"
    try:
        write_godot_import(export_objects([root, lod], os.path.join(out_dir, car_id + "_lod1.glb")))
    finally:
        lod.name = old
        body.name = "Body"


def _args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    return dict(a[2:].split("=", 1) if "=" in a else (a[2:], "1") for a in argv if a.startswith("--"))


if __name__ == "__main__":
    a = _args()
    if a.get("asset", "car") != "car":
        raise SystemExit("only --asset=car is implemented so far")
    try:
        export_car(a["id"], a.get("out") and os.path.join(REPO, a["out"]), force=a.get("force") == "1")
    except RuntimeError as e:
        print(e)
        sys.exit(1)
