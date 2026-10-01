"""Player-car scaffold for Blender (docs/ART_PRODUCTION.md §3.6, §5 P0).

Builds the modular car tree the game's import (G1, tools/art/car_modular_import.gd)
expects, in a collection named after the car id:

  Car_<Name>  (Empty, origin)
    Body, Lights/<11 lights>, Wheel_FL/FR/RL/RR/(Tire_XX, Rim_XX),
    Interior/(Cabin, SteeringWheel, Gauges), Markers/<6 markers>

and a reference collection `ref_<id>` (never exported) with a wire box of the CarDef
body. Modelling scripts (tools/blender/cars/<id>.py) call the helpers below to put
meshes into the tree.

CLI (a stub box car, to check the pipeline):
  blender -b --python tools/blender/wb_scaffold_car.py -- --id=falcon_gt [--save=art/blender/cars/x.blend]
"""

import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(__file__))
import wb_palette  # noqa: E402

REPO = wb_palette.REPO

WHEEL_NAMES = ["Wheel_FL", "Wheel_FR", "Wheel_RL", "Wheel_RR"]
LIGHT_NAMES = ["headlight_L", "headlight_R", "taillight_L", "taillight_R", "brake_L", "brake_R",
               "blinker_FL", "blinker_FR", "blinker_RL", "blinker_RR", "reverse"]
MARKER_NAMES = ["cam_cockpit", "cam_hood", "exhaust_L", "exhaust_R", "smoke_hood", "shadow"]
LIGHT_MATERIAL = {"headlight": "lamp_head", "taillight": "lamp_tail", "brake": "signal_brake",
                  "blinker": "signal_blinker", "reverse": "signal_reverse"}
# Root names already used by the placeholder sidecars (assets/cars/placeholder/*.car.json).
ROOT_NAMES = {"falcon_gt": "Car_FalconGT", "night_viper": "Car_NightViper", "brute_v8": "Car_BruteV8",
              "calib_box": "Car_CalibBox"}


def root_name(car_id):
    return ROOT_NAMES.get(car_id) or "Car_" + "".join(p.capitalize() for p in car_id.split("_"))


def read_cardef(car_id, path=None):
    """data/cars/<id>.tres -> dict of the body fields (m) and default_paint (sRGB)."""
    path = path or os.path.join(REPO, "data", "cars", car_id + ".tres")
    text = open(path, encoding="utf-8").read()
    out = {"id": car_id}
    for key in ("length_m", "width_m", "height_m", "wheelbase_m", "top_speed_kmh"):
        m = re.search(r"^%s = ([-\d.]+)" % key, text, re.M)
        if m:
            out[key] = float(m.group(1))
    m = re.search(r'^display_name = "(.*)"', text, re.M)
    out["display_name"] = m.group(1) if m else car_id
    m = re.search(r"^default_paint = Color\(([^)]*)\)", text, re.M)
    out["default_paint"] = tuple(float(v) for v in m.group(1).split(",")[:3]) if m else wb_palette.PREVIEW_PAINT
    return out


# ---------------------------------------------------------------- Blender helpers

def _bpy():
    import bpy
    return bpy


def setup_scene():
    """Metric, unit scale 1 (§3.1)."""
    bpy = _bpy()
    us = bpy.context.scene.unit_settings
    us.system = "METRIC"
    us.scale_length = 1.0
    us.length_unit = "METERS"


def collection(name, clear=False):
    """Get or create a scene collection; `clear` deletes its objects (and orphaned meshes)."""
    bpy = _bpy()
    col = bpy.data.collections.get(name)
    if col is None:
        col = bpy.data.collections.new(name)
        bpy.context.scene.collection.children.link(col)
    if clear:
        for ob in list(col.objects):
            data = ob.data
            bpy.data.objects.remove(ob, do_unlink=True)
            if data is not None and data.users == 0 and isinstance(data, bpy.types.Mesh):
                bpy.data.meshes.remove(data)
    return col


def _find_layer_collection(lc, name):
    if lc.collection.name == name:
        return lc
    for c in lc.children:
        r = _find_layer_collection(c, name)
        if r is not None:
            return r
    return None


def empty(col, name, parent=None, location=(0.0, 0.0, 0.0), size=0.1, display="PLAIN_AXES"):
    bpy = _bpy()
    ob = bpy.data.objects.get(name)
    if ob is None:
        ob = bpy.data.objects.new(name, None)
        col.objects.link(ob)
    ob.empty_display_type = display
    ob.empty_display_size = size
    ob.parent = parent
    ob.matrix_parent_inverse.identity()
    ob.location = location
    ob.rotation_euler = (0.0, 0.0, 0.0)
    ob.scale = (1.0, 1.0, 1.0)
    return ob


def mesh_object(col, name, mesh, parent=None, location=(0.0, 0.0, 0.0), rotation=(0.0, 0.0, 0.0)):
    """Create or replace object `name` with `mesh` (a bpy mesh), parented, local transform."""
    bpy = _bpy()
    ob = bpy.data.objects.get(name)
    if ob is not None and ob.type != "MESH":
        bpy.data.objects.remove(ob, do_unlink=True)
        ob = None
    if ob is None:
        ob = bpy.data.objects.new(name, mesh)
        col.objects.link(ob)
    else:
        old = ob.data
        ob.data = mesh
        if old is not None and old != mesh and old.users == 0:
            bpy.data.meshes.remove(old)
    if ob.name not in col.objects:
        col.objects.link(ob)
    ob.parent = parent
    ob.matrix_parent_inverse.identity()
    ob.location = location
    ob.rotation_euler = rotation
    ob.scale = (1.0, 1.0, 1.0)
    return ob


class CarRig:
    """The §3.6 tree of one car in the open .blend."""

    def __init__(self, car_id, cardef=None):
        self.id = car_id
        self.cardef = cardef or read_cardef(car_id)
        self.col = None
        self.root = None
        self.groups = {}

    def build_tree(self):
        """Create (or reset) the collection, the root and the group Empties."""
        setup_scene()
        self.col = collection(self.id, clear=True)
        self.root = empty(self.col, root_name(self.id), size=0.5, display="ARROWS")
        for g in ("Lights", "Interior", "Markers"):
            self.groups[g] = empty(self.col, g, self.root, size=0.05)
        self.reference_box()
        return self

    def reference_box(self):
        """ref_<id>: a wire box of the CarDef body (L x W x H) on the ground, not exported."""
        bpy = _bpy()
        import wb_mesh
        ref = collection("ref_" + self.id, clear=True)
        L, W, H = self.cardef["length_m"], self.cardef["width_m"], self.cardef["height_m"]
        mb = wb_mesh.MeshBuilder()
        mb.box((0.0, 0.0, H / 2), (W, L, H), "trim_steel")
        ob = mesh_object(ref, "ref_body_" + self.id, mb.to_mesh("ref_body_" + self.id))
        ob.display_type = "WIRE"
        ob.hide_render = True
        ob.hide_select = True
        ref.hide_render = True
        return ob

    def set_mesh(self, name, builder_or_mesh, parent="root", location=(0.0, 0.0, 0.0),
                 rotation=(0.0, 0.0, 0.0), kind="car"):
        mesh = builder_or_mesh
        if hasattr(builder_or_mesh, "to_mesh"):
            mesh = builder_or_mesh.to_mesh(name + "_mesh", kind=kind, paint=self.cardef["default_paint"])
        par = self.root if parent == "root" else (self.groups.get(parent) or _bpy().data.objects[parent])
        return mesh_object(self.col, name, mesh, par, location, rotation)

    def wheels(self, tire_mesh, rim_mesh, radius, track_front, track_rear=None, wheelbase=None):
        """Wheel_XX Empties at the hubs; Tire_XX / Rim_XX share one mesh each (linked
        duplicates); the left pair is turned 180 degrees about Z (§3.6.3)."""
        track_rear = track_rear or track_front
        wb = wheelbase or self.cardef["wheelbase_m"]
        if hasattr(tire_mesh, "to_mesh"):
            tire_mesh = tire_mesh.to_mesh("tire_" + self.id)
        if hasattr(rim_mesh, "to_mesh"):
            rim_mesh = rim_mesh.to_mesh("rim_" + self.id)
        for wn in WHEEL_NAMES:
            front = wn[-2] == "F"
            left = wn[-1] == "L"
            track = track_front if front else track_rear
            x = (-1.0 if left else 1.0) * track / 2
            y = (1.0 if front else -1.0) * wb / 2
            w = empty(self.col, wn, self.root, (x, y, radius), size=radius, display="CIRCLE")
            rot = (0.0, 0.0, math.pi) if left else (0.0, 0.0, 0.0)
            mesh_object(self.col, "Tire_" + wn[-2:], tire_mesh, w, rotation=rot)
            mesh_object(self.col, "Rim_" + wn[-2:], rim_mesh, w, rotation=rot)

    def light(self, name, builder, center):
        """A light mesh under Lights, origin at the lamp centre (the builder is in car
        coordinates; it is moved so `center` becomes the object origin)."""
        import wb_mesh
        local = builder.transformed(lambda p: wb_mesh.v_sub(p, center))
        return self.set_mesh(name, local, "Lights", location=center)

    def marker(self, name, location):
        return empty(self.col, name, self.groups["Markers"], location, size=0.08, display="SPHERE")

    def interior_object(self, name, builder, location=(0.0, 0.0, 0.0), rotation=(0.0, 0.0, 0.0)):
        return self.set_mesh(name, builder, "Interior", location, rotation)


# ---------------------------------------------------------------- CLI: a stub box car

def stub_car(car_id):
    """Every convention node on a box body of the CarDef size (pipeline smoke test)."""
    import wb_mesh
    rig = CarRig(car_id).build_tree()
    c = rig.cardef
    L, W, H = c["length_m"], c["width_m"], c["height_m"]
    r = 0.075 * L
    body = wb_mesh.MeshBuilder()
    body.box((0.0, 0.0, r + (H - r) / 2), (W, L, H - r), "paint", {"-z": "trim_ink"})
    rig.set_mesh("Body", body)
    tire = wb_mesh.MeshBuilder()
    tire.lathe_x([(-0.12, r * 0.6), (-0.12, r), (0.12, r), (0.12, r * 0.6)], 16, "trim_ink")
    rim = wb_mesh.MeshBuilder()
    rim.lathe_x([(0.13, r * 0.6), (0.13, 0.0)], 16, "trim_steel")
    rig.wheels(tire, rim, r, 0.78 * W)
    for n in LIGHT_NAMES:
        front = n.startswith("head") or n.endswith(("FL", "FR"))
        side = -1.0 if n.endswith(("_L", "FL", "RL")) else (0.0 if n == "reverse" else 1.0)
        y = (L / 2 + 0.015) * (1 if front else -1)
        ctr = (side * W * 0.33, y, r + (H - r) * 0.5)
        lb = wb_mesh.MeshBuilder()
        lb.box(ctr, (0.2, 0.01, 0.1), LIGHT_MATERIAL[n.split("_")[0]])
        rig.light(n, lb, ctr)
    for n, loc in {"cam_cockpit": (-0.36 * W, -0.1, 0.8 * H), "cam_hood": (0.0, 0.28 * L, H * 0.75),
                   "exhaust_L": (-0.3, -L / 2, 0.25), "exhaust_R": (0.3, -L / 2, 0.25),
                   "smoke_hood": (0.0, 0.28 * L, H * 0.65), "shadow": (0.0, 0.0, 0.0)}.items():
        rig.marker(n, loc)
    return rig


def _args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    return dict(a[2:].split("=", 1) for a in argv if a.startswith("--") and "=" in a)


if __name__ == "__main__":
    a = _args()
    stub_car(a["id"])
    if a.get("save"):
        _bpy().ops.wm.save_as_mainfile(filepath=os.path.join(REPO, a["save"]))
