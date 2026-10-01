"""P0 calibration assets from Blender (docs/ART_PRODUCTION.md §5 P0, G9).

  calib_box     assets/cars/calib_box/calib_box.glb (+ .car.json, _lod1.glb): a box car
                with every convention node, one Body face per palette colour as
                trim_<name>, the three paint shades, glass, every lamp material, an
                Interior (Cabin with interior_<c> faces and interior_screen,
                SteeringWheel, Gauges), all six markers; shared tire and rim meshes.
  calib_swatch  art/export/props/common/calib_swatch.glb (+ .prop.json): one quad per
                palette name, plus one `white` quad per emissive suffix.

The game side runs them through G1/G9 (tests/art/test_art_pipeline.gd) to prove that
Blender's export reaches the game with exact colours, axes and hierarchy.

  blender -b --python tools/blender/wb_calib.py -- [--save]
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import wb_export  # noqa: E402
import wb_mesh  # noqa: E402
import wb_palette  # noqa: E402
import wb_scaffold_car as scaffold  # noqa: E402

REPO = wb_palette.REPO
CAR_ID = "calib_box"
# Its own CarDef (never in the roster; the game side writes a test fixture like
# tests/art/fixtures/calib_car/calib_car.tres with these numbers).
CARDEF = {"id": CAR_ID, "display_name": "Calib Box", "length_m": 4.5, "width_m": 1.9, "height_m": 1.3,
          "wheelbase_m": 2.7, "default_paint": (0.9, 0.2, 0.15)}
WHEEL_R = 0.34
TIRE_W = 0.26
TRACK = 1.56
SILL_Z = 0.22
BELT_Z = 0.78
TILE = (0.26, 0.13)
PROUD = 0.005
LAMP_PROUD = 0.015
EYE = (-0.36, -0.15, 1.12)
STEER_TILT = 0.35


def build_car():
    L, W, H = CARDEF["length_m"], CARDEF["width_m"], CARDEF["height_m"]
    rig = scaffold.CarRig(CAR_ID, CARDEF).build_tree()
    hx, hy = W / 2, L / 2
    b = wb_mesh.MeshBuilder()
    # Lower box: paint sides, paint_shade sills, trim_ink underside.
    b.box((0, 0, (SILL_Z + BELT_Z) / 2), (W, L, BELT_Z - SILL_Z), "paint",
          {"-z": "trim_ink", "+y": "paint_shade", "-y": "paint_dark"})
    b.box((0, 0, SILL_Z / 2 + 0.06), (W - 0.1, L - 0.2, SILL_Z - 0.12), "paint_shade", {"-z": "trim_ink"})
    # Cabin: glass sides, paint roof.
    b.box((0, -0.2, BELT_Z + (H - BELT_Z) / 2), (W - 0.2, 2.2, H - BELT_Z), "glass",
          {"+z": "paint", "-z": "trim_ink", "+y": "glass_sky_pale"})
    # One trim tile per palette colour on the flanks (right side first, then left).
    names = wb_palette.all_names()
    per_row = int((L - 0.8) // (TILE[0] + 0.02))
    for i, n in enumerate(names):
        side = 1 if i < (len(names) + 1) // 2 else -1
        k = i if side > 0 else i - (len(names) + 1) // 2
        row, col = divmod(k, per_row)
        y0 = -hy + 0.4 + col * (TILE[0] + 0.02)
        z0 = BELT_Z - 0.05 - (row + 1) * (TILE[1] + 0.02)
        x = side * (hx + PROUD)
        pts = [(x, y0, z0), (x, y0 + TILE[0], z0), (x, y0 + TILE[0], z0 + TILE[1]), (x, y0, z0 + TILE[1])]
        b.face(pts, "trim_" + n, (side, 0, 0))
    uv_unwrap_box(b)
    rig.set_mesh("Body", b)

    tire = wb_mesh.MeshBuilder()
    tire.lathe_x([(-TIRE_W / 2, WHEEL_R * 0.62), (-TIRE_W / 2, WHEEL_R), (TIRE_W / 2, WHEEL_R),
                  (TIRE_W / 2, WHEEL_R * 0.62)], 16, ["trim_asphalt", "trim_ink", "trim_asphalt"])
    rim = wb_mesh.MeshBuilder()
    rx = TIRE_W / 2 + 0.01
    rim.lathe_x([(rx - 0.04, WHEEL_R * 0.64), (rx, WHEEL_R * 0.64), (rx, WHEEL_R * 0.2), (rx + 0.01, WHEEL_R * 0.2),
                 (rx + 0.01, 0.0)], 16, ["trim_steel_dark", "trim_steel", "trim_steel_dark", "trim_ink"])
    rig.wheels(tire, rim, WHEEL_R, TRACK)

    lamp_z = (SILL_Z + BELT_Z) / 2
    def lamp(name, x, y, w, h, mat):
        lb = wb_mesh.MeshBuilder()
        lb.box((x, y, lamp_z), (w, 0.02, h), mat)
        rig.light(name, lb, (x, y, lamp_z))
    fy, ry = hy + LAMP_PROUD, -hy - LAMP_PROUD
    for s, t in ((-1, "L"), (1, "R")):
        lamp("headlight_" + t, s * 0.62, fy, 0.34, 0.12, "lamp_head")
        lamp("taillight_" + t, s * 0.66, ry, 0.3, 0.12, "lamp_tail")
        lamp("brake_" + t, s * 0.36, ry, 0.16, 0.1, "signal_brake")
        lamp("blinker_F" + t, s * 0.86, fy, 0.14, 0.09, "signal_blinker")
        lamp("blinker_R" + t, s * 0.86, ry, 0.14, 0.09, "signal_blinker")
    lamp("reverse", 0.0, ry, 0.2, 0.09, "signal_reverse")

    # Interior: a few inward faces in interior colours, a screen, a wheel, gauges.
    cab_b = wb_mesh.MeshBuilder()
    dash_y, dash_z = 0.55, 0.9
    cab_b.box((0, dash_y, dash_z - 0.1), (W - 0.3, 0.3, 0.2), "interior_asphalt", {"+z": "interior_ink", "-y": "interior_roof_slate"})
    cab_b.box((0.3, dash_y - 0.16, dash_z - 0.1), (0.2, 0.01, 0.12), "interior_screen")
    cab_b.box((0, -0.8, H - 0.04), (W - 0.3, 2.0, 0.02), "interior_cream")
    rig.interior_object("Cabin", cab_b)
    sw = wb_mesh.MeshBuilder()
    sw.lathe_x([(-0.02, 0.17), (-0.02, 0.19), (0.02, 0.19), (0.02, 0.17), (-0.02, 0.17)], 16, "interior_ink")
    sw.box((0, 0, 0.18), (0.03, 0.03, 0.03), "interior_cream")  # 12 o'clock mark (before rotation)
    # Built around X; turn it so its axis is Y (the column), then tilt with the rake.
    sw = sw.transformed(lambda p: (-p[1], p[0], p[2]))
    rig.interior_object("SteeringWheel", sw, location=(EYE[0], 0.45, 0.95), rotation=(-STEER_TILT, 0.0, 0.0))
    g = wb_mesh.MeshBuilder()
    gw, gh = 0.26, 0.1
    g.face([(-gw / 2, 0, -gh / 2), (gw / 2, 0, -gh / 2), (gw / 2, 0, gh / 2), (-gw / 2, 0, gh / 2)], "gauges", (0, -1, 0),
           uv=[(0, 0), (1, 0), (1, 1), (0, 1)])
    rig.interior_object("Gauges", g, location=(EYE[0], dash_y - 0.155, dash_z - 0.02))

    for n, loc in {"cam_cockpit": EYE, "cam_hood": (0.0, 1.1, BELT_Z + 0.12), "smoke_hood": (0.0, 1.1, BELT_Z),
                   "exhaust_L": (-0.4, -hy, 0.3), "exhaust_R": (0.4, -hy, 0.3), "shadow": (0.0, 0.0, 0.0)}.items():
        rig.marker(n, loc)

    # LOD1: the same slots, one Body.
    lc = scaffold.collection(CAR_ID + "_lod1", clear=True)
    lroot = scaffold.empty(lc, scaffold.root_name(CAR_ID) + "_LOD1", size=0.3)
    lb = wb_mesh.MeshBuilder()
    lb.box((0, 0, (WHEEL_R + H) / 2), (W, L, H - WHEEL_R), "paint", {"-z": "trim_ink", "+z": "glass"})
    scaffold.mesh_object(lc, "Body_lod1", lb.to_mesh("lod1_" + CAR_ID), lroot)
    return rig


def uv_unwrap_box(b):
    """Simple planar UVs (0-1 over the bounds) for every face, by its main axis."""
    lo = [min(v[i] for v in b.verts) for i in range(3)]
    hi = [max(v[i] for v in b.verts) for i in range(3)]
    ext = [max(hi[i] - lo[i], 1e-6) for i in range(3)]
    for fi, f in enumerate(b.faces):
        pts = [b.verts[i] for i in f]
        n = wb_mesh.poly_normal(pts)
        axis = max(range(3), key=lambda i: abs(n[i]))
        u_ax, v_ax = [i for i in range(3) if i != axis]
        # Put each axis's projection in its own third of the UV square: no overlap
        # between sides of different orientation (a livery mask can tell them apart).
        slot = axis * 2 + (0 if n[axis] >= 0 else 1)
        b.uvs[fi] = [((slot + (p[u_ax] - lo[u_ax]) / ext[u_ax]) / 6.0, (p[v_ax] - lo[v_ax]) / ext[v_ax]) for p in pts]


def build_swatch():
    """One quad per palette name facing -Y (approaching traffic), plus emissive suffixes."""
    col = scaffold.collection("calib_swatch", clear=True)
    b = wb_mesh.MeshBuilder()
    names = wb_palette.all_names() + ["white__" + s for s in ("reflector", "lamp", "window", "flash")]
    row = 10
    for i, n in enumerate(names):
        r, c = divmod(i, row)
        x0, z0 = c * 0.5, 0.2 + r * 0.5
        b.face([(x0, 0, z0), (x0 + 0.4, 0, z0), (x0 + 0.4, 0, z0 + 0.4), (x0, 0, z0 + 0.4)], n, (0, -1, 0))
    me = b.to_mesh("calib_swatch", kind="prop")
    ob = scaffold.mesh_object(col, "calib_swatch", me)
    return ob


def export_all(save_blend=False):
    import bpy
    bpy.ops.wm.read_homefile(use_empty=True)
    build_car()
    wb_export.export_car(CAR_ID, cardef=CARDEF, source="in-house, Blender: tools/blender/wb_calib.py (P0 calibration)")
    ob = build_swatch()
    out = os.path.join(REPO, "art", "export", "props", "common")
    wb_export.export_objects([ob], os.path.join(out, "calib_swatch.glb"))
    wb_export.write_json(os.path.join(out, "calib_swatch.prop.json"),
                         {"mesh": "calib_swatch", "material": "world", "meta": {}, "tris_budget": 400})
    if save_blend:
        path = os.path.join(REPO, "art", "blender", "calib", "calib.blend")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        bpy.ops.wm.save_as_mainfile(filepath=path, compress=True)


if __name__ == "__main__":
    export_all(save_blend="--save" in sys.argv)
