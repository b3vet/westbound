"""Self-review renders and design sheets (docs/ART_PRODUCTION.md §3.12.1, §5 P1).

Workbench, material colours, back faces culled (every game shader culls), from the
game's own views (numbers from data/tuning/camera.tres and progression.tres):
  chase     7 m behind, 3.6 m up, looking 12 m ahead at the ground, 62 deg vertical FOV
  chase3q   the chase camera 25 deg off to the side (lane change)
  garage    the turntable: 8.2 m, 2.3 m up, FOV 30, car yaw 215 (front three-quarter)
  side, front, rear, top   orthographic
  rear50    a traffic-style check: 50 m behind at eye height
  cockpit   at Markers/cam_cockpit, looking +Y, 1 deg down, 62 deg vertical FOV (Interior shown)

  blender -b art/blender/cars/falcon_gt.blend --python tools/blender/wb_render.py -- --id=falcon_gt [--views=chase,garage]
  (inside Blender)  wb_render.render_car("falcon_gt", views=["garage"])
Output: art/renders/<id>/<view>.png and <id>_sheet.png.
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import wb_palette  # noqa: E402

REPO = wb_palette.REPO
PHONE_ASPECT = 1361 / 720
BG = (0.93, 0.91, 0.87)  # a warm off-white sheet background (linear-ish, for readability)

VIEWS = {
    # name: (kind, location, target or rotation, fov_or_ortho_scale, aspect)
    "chase": ("persp", (0.0, -7.0, 3.6), (0.0, 12.0, 0.0), 62.0, PHONE_ASPECT),
    "chase3q": ("persp", (-7.0 * math.sin(math.radians(25)), -7.0 * math.cos(math.radians(25)), 3.6),
                (0.0, 12.0, 0.0), 62.0, PHONE_ASPECT),
    "garage": ("persp", (8.2 * math.sin(math.radians(35)), 8.2 * math.cos(math.radians(35)), 2.3 - 0.14),
               (0.0, 0.0, -0.35 - 0.14), 30.0, 16 / 10),
    "garage_rear": ("persp", (-8.2 * math.sin(math.radians(35)), -8.2 * math.cos(math.radians(35)), 2.3 - 0.14),
                    (0.0, 0.0, -0.35 - 0.14), 30.0, 16 / 10),
    "side": ("ortho", (10.0, 0.0, 0.62), (0.0, 0.0, 0.62), 5.2, 2.6),
    "front": ("ortho", (0.0, 10.0, 0.62), (0.0, 0.0, 0.62), 2.3, 1.45),
    "rear": ("ortho", (0.0, -10.0, 0.62), (0.0, 0.0, 0.62), 2.3, 1.45),
    "top": ("ortho", (0.0, 0.0, 10.0), (0.0, 0.0, 0.0), 5.2, 2.6),
    "chase_close": ("persp", (0.0, -7.0, 3.6), (0.0, 0.0, 0.5), 22.0, 16 / 10),
    "rear50": ("persp", (0.0, -50.0, 1.2), (0.0, 0.0, 0.7), 62.0, PHONE_ASPECT),
}
SHEET_ORDER = ["garage", "chase_close", "side", "garage_rear", "front", "rear", "top", "chase"]


def _bpy():
    import bpy
    return bpy


def _look_rotation(loc, target):
    from mathutils import Vector
    d = Vector(target) - Vector(loc)
    return d.to_track_quat("-Z", "Y").to_euler()


def _camera(name="wb_render_cam"):
    bpy = _bpy()
    ob = bpy.data.objects.get(name)
    if ob is None:
        cam = bpy.data.cameras.new(name)
        ob = bpy.data.objects.new(name, cam)
        bpy.context.scene.collection.objects.link(ob)
    return ob


def setup_workbench(light="STUDIO", bg=BG):
    bpy = _bpy()
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_WORKBENCH"
    sh = sc.display.shading
    sh.light = light
    if light == "STUDIO":
        sh.studio_light = "outdoor.sl" if "outdoor.sl" in [s.name for s in bpy.context.preferences.studio_lights] else sh.studio_light
    sh.color_type = "MATERIAL"
    sh.show_cavity = False
    sh.show_object_outline = False
    sh.show_shadows = False
    sh.show_specular_highlight = False
    sh.show_backface_culling = True
    sc.display.render_aa = "8"
    if sc.world is None:
        sc.world = bpy.data.worlds.new("World")
    sc.world.color = bg
    sc.render.film_transparent = False
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGB"
    sc.view_settings.view_transform = "Standard"


def _visibility(car_id, cockpit):
    """Only the car collection renders; Interior only in the cockpit view."""
    bpy = _bpy()
    for col in bpy.data.collections:
        col.hide_render = col.name != car_id
    interior = bpy.data.objects.get("Interior")
    if interior is not None:
        for ob in interior.children_recursive:
            ob.hide_render = not cockpit
    for n in ("brake_L", "brake_R", "blinker_FL", "blinker_FR", "blinker_RL", "blinker_RR", "reverse"):
        ob = bpy.data.objects.get(n)
        if ob is not None:
            ob.hide_render = True


def render_view(car_id, view, out_dir, height=720, offset=(0.0, 0.0, 0.0)):
    bpy = _bpy()
    sc = bpy.context.scene
    cam = _camera()
    cockpit = view == "cockpit"
    _visibility(car_id, cockpit)
    if cockpit:
        eye = bpy.data.objects["cam_cockpit"].matrix_world.translation
        kind, loc, fov, aspect = "persp", tuple(eye), 62.0, PHONE_ASPECT
        target = (eye.x, eye.y + 40.0, eye.z - 40.0 * math.tan(math.radians(1.0)))
    else:
        kind, loc, target, fov, aspect = VIEWS[view]
    loc = tuple(loc[i] + offset[i] for i in range(3))
    target = tuple(target[i] + offset[i] for i in range(3))
    cam.location = loc
    cam.rotation_euler = _look_rotation(loc, target)
    if view == "top":
        cam.rotation_euler = (0.0, 0.0, math.pi / 2)  # nose to the right
    cd = cam.data
    cd.clip_start = 0.02 if cockpit else 0.1
    cd.clip_end = 500.0
    cd.sensor_fit = "VERTICAL"
    if kind == "ortho":
        cd.type = "ORTHO"
        cd.sensor_fit = "HORIZONTAL"
        cd.ortho_scale = fov
    else:
        cd.type = "PERSP"
        cd.angle_y = math.radians(fov)
    sc.camera = cam
    sc.render.resolution_y = height
    sc.render.resolution_x = int(round(height * aspect))
    sc.render.resolution_percentage = 100
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, view + ".png")
    sc.render.filepath = path
    ctx = {}
    try:
        import wb_export
        ctx = wb_export.context_override()
    except Exception:
        pass
    with bpy.context.temp_override(**ctx):
        bpy.ops.render.render(write_still=True)
    return path


def render_car(car_id, views=None, out_dir=None, height=720, sheet=True, paint=None, suffix=""):
    """Render `views` (default: the sheet views + cockpit) of car collection `car_id`."""
    bpy = _bpy()
    out_dir = out_dir or os.path.join(REPO, "art", "renders", car_id)
    views = views or SHEET_ORDER + ["cockpit", "rear50"]
    if paint is not None:
        wb_palette.set_paint_preview(paint)
    setup_workbench()
    paths = {}
    for v in views:
        if v == "cockpit" and bpy.data.objects.get("cam_cockpit") is None:
            continue
        paths[v] = render_view(car_id, v, out_dir, height)
        if suffix:
            new = paths[v][:-4] + suffix + ".png"
            os.replace(paths[v], new)
            paths[v] = new
    for col in bpy.data.collections:
        col.hide_render = False
    if sheet and all(v in paths for v in SHEET_ORDER):
        paths["sheet"] = compose_sheet([paths[v] for v in SHEET_ORDER],
                                       os.path.join(out_dir, car_id + suffix + "_sheet.png"))
    return paths


def compose_sheet(paths, out, cols=4, cell_h=360):
    """Tile PNGs into one image (numpy, Blender's bundled Python)."""
    bpy = _bpy()
    import numpy as np
    imgs = []
    for p in paths:
        im = bpy.data.images.load(p, check_existing=False)
        w, h = im.size
        a = np.array(im.pixels[:], dtype=np.float32).reshape(h, w, 4)
        bpy.data.images.remove(im)
        # nearest-neighbour resize to cell height
        s = cell_h / h
        nw = int(round(w * s))
        yi = (np.arange(cell_h) / s).astype(int).clip(0, h - 1)
        xi = (np.arange(nw) / s).astype(int).clip(0, w - 1)
        imgs.append(a[yi][:, xi])
    rows = [imgs[i:i + cols] for i in range(0, len(imgs), cols)]
    gap = 8
    width = max(sum(i.shape[1] for i in r) + gap * (len(r) + 1) for r in rows)
    height = len(rows) * cell_h + gap * (len(rows) + 1)
    canvas = np.ones((height, width, 4), dtype=np.float32)
    canvas[..., :3] = 0.2
    y = height - gap - cell_h  # Blender images are bottom-up
    for r in rows:
        x = gap
        for im in r:
            canvas[y:y + cell_h, x:x + im.shape[1]] = im
            x += im.shape[1] + gap
        y -= cell_h + gap
    img = bpy.data.images.new("wb_sheet", width, height, alpha=False)
    img.pixels = canvas.ravel()
    img.filepath_raw = out
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)
    return out


def _args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    return dict(a[2:].split("=", 1) if "=" in a else (a[2:], "1") for a in argv if a.startswith("--"))


if __name__ == "__main__":
    a = _args()
    render_car(a["id"], views=a["views"].split(",") if a.get("views") else None)
