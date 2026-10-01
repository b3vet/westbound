"""Pre-export validation (docs/ART_PRODUCTION.md §3.12.1).

Checks a car collection against the technical contract (§3.1-§3.6) the way the game's
tests will (tests/unit/test_check_car_assets.gd, tools/art/car_modular_import.gd):
units, transforms, names, hierarchy, material names, slot rules, budgets, CarDef
dimensions, axle centre, ground contact, shared wheel meshes, orientation, markers.

  blender -b art/blender/cars/falcon_gt.blend --python tools/blender/wb_validate.py -- --asset=car --id=falcon_gt
  (inside Blender)  import wb_validate; print(wb_validate.validate_car("falcon_gt").summary())

Exit code 1 when there are errors (warnings don't fail).
"""

import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(__file__))
import wb_palette  # noqa: E402
import wb_scaffold_car as scaffold  # noqa: E402

FORBIDDEN_SUFFIXES = ("-col", "-convcol", "-colonly", "-convcolonly", "-navmesh", "-occ", "-occonly",
                      "-rigid", "-vehicle", "-wheel", "-noimp", "-loop", "-cycle")
NAME_RE = re.compile(r"^[A-Za-z0-9_]+$")

# Budgets (data/tuning/progression.tres; §3.5).
BODY_TRIS = 15000
BODY_TRIS_TARGET = 10000
LOD1_TRIS = 5000
INTERIOR_TRIS = 5000
RIM_TRIS = 800
DIM_TOL = 0.05
LENGTH_RANGE = (3.8, 5.2)
GROUND_TOL = 0.02
AXLE_TOL = 0.05
LAMP_MIN = (0.15, 0.08)
EYE_CLEARANCE = 0.25


class Report:
    def __init__(self, title):
        self.title = title
        self.errors = []
        self.warnings = []
        self.info = {}

    def err(self, msg):
        self.errors.append(msg)

    def warn(self, msg):
        self.warnings.append(msg)

    def ok(self):
        return not self.errors

    def summary(self):
        lines = ["%s: %s" % (self.title, "OK" if self.ok() else "%d ERROR(S)" % len(self.errors))]
        for k, v in self.info.items():
            lines.append("  %-18s %s" % (k, v))
        lines += ["  ERROR   " + e for e in self.errors]
        lines += ["  warning " + w for w in self.warnings]
        return "\n".join(lines)

    def as_dict(self):
        return {"title": self.title, "ok": self.ok(), "errors": self.errors, "warnings": self.warnings,
                "info": self.info}


def _bpy():
    import bpy
    return bpy


def tris(ob):
    """Triangles of an object's evaluated mesh (modifiers applied)."""
    bpy = _bpy()
    dg = bpy.context.evaluated_depsgraph_get()
    ev = ob.evaluated_get(dg)
    me = ev.to_mesh()
    n = sum(len(p.vertices) - 2 for p in me.polygons)
    ev.to_mesh_clear()
    return n


def world_bounds(obs):
    """(min, max) of the evaluated vertices of `obs` in world space."""
    bpy = _bpy()
    dg = bpy.context.evaluated_depsgraph_get()
    lo = [math.inf] * 3
    hi = [-math.inf] * 3
    for ob in obs:
        ev = ob.evaluated_get(dg)
        me = ev.to_mesh()
        mw = ob.matrix_world
        for v in me.vertices:
            p = mw @ v.co
            for i in range(3):
                lo[i] = min(lo[i], p[i])
                hi[i] = max(hi[i], p[i])
        ev.to_mesh_clear()
    return lo, hi


def local_bounds(me):
    lo = [min(v.co[i] for v in me.vertices) for i in range(3)]
    hi = [max(v.co[i] for v in me.vertices) for i in range(3)]
    return lo, hi


def _materials(ob):
    return [s.material.name if s.material else "<none>" for s in ob.material_slots]


def _used_materials(ob):
    names = _materials(ob)
    used = sorted({p.material_index for p in ob.data.polygons})
    return [names[i] if i < len(names) else "<none>" for i in used]


def _check_names(rep, obs):
    for ob in obs:
        n = ob.name
        if re.search(r"\.\d{3}$", n):
            rep.err("object %s: Blender duplicate suffix" % n)
        elif not NAME_RE.match(n):
            rep.err("object %s: only A-Z a-z 0-9 _ allowed" % n)
        if n.lower().endswith(FORBIDDEN_SUFFIXES):
            rep.err("object %s: ends in a Godot import suffix" % n)
        if ob.type == "MESH":
            for m in _materials(ob):
                if not NAME_RE.match(m):
                    rep.err("object %s: material '%s' has characters other than A-Z a-z 0-9 _" % (n, m))


def _check_transforms(rep, obs, allowed_rot):
    for ob in obs:
        if any(abs(s - 1.0) > 1e-5 for s in ob.scale):
            rep.err("%s: scale %s (apply scale)" % (ob.name, tuple(round(s, 4) for s in ob.scale)))
        rot = tuple(ob.rotation_euler)
        if ob.name not in allowed_rot and any(abs(r) > 1e-5 for r in rot):
            rep.err("%s: unapplied rotation %s" % (ob.name, tuple(round(r, 4) for r in rot)))
        if ob.hide_viewport or ob.hide_render or ob.hide_get():
            rep.err("%s: hidden objects must not be in the exported collection" % ob.name)
        if ob.type not in ("MESH", "EMPTY"):
            rep.err("%s: type %s not allowed (no cameras, lights, curves, armatures)" % (ob.name, ob.type))
        if ob.type == "MESH":
            for md in ob.modifiers:
                if md.type != "MIRROR":
                    rep.warn("%s: modifier %s will be applied on export" % (ob.name, md.name))
            if ob.data.shape_keys:
                rep.err("%s: shape keys not allowed" % ob.name)


def _degenerate(ob):
    return sum(1 for p in ob.data.polygons if p.area < 1e-8)


def _outward_ratio(ob):
    """Share of faces whose normal points away from the bounding-box centre (convex-ish)."""
    me = ob.data
    lo, hi = local_bounds(me)
    c = [(lo[i] + hi[i]) / 2 for i in range(3)]
    good = 0
    for p in me.polygons:
        d = [p.center[i] - c[i] for i in range(3)]
        if sum(d[i] * p.normal[i] for i in range(3)) >= 0:
            good += 1
    return good / max(1, len(me.polygons))


def validate_car(car_id, lod1=False, cardef=None):
    """Validate collection `car_id` (and `<car_id>_lod1` when lod1)."""
    bpy = _bpy()
    rep = Report("car %s" % car_id)
    bpy.context.view_layer.update()
    cd = cardef or scaffold.read_cardef(car_id)
    us = bpy.context.scene.unit_settings
    if us.system != "METRIC" or abs(us.scale_length - 1.0) > 1e-6:
        rep.err("scene units: Metric, unit scale 1.0 (is %s, %s)" % (us.system, us.scale_length))
    col = bpy.data.collections.get(car_id)
    if col is None:
        rep.err("no collection named %s" % car_id)
        return rep
    obs = list(col.all_objects)
    by = {ob.name: ob for ob in obs}
    rn = scaffold.root_name(car_id)
    _check_names(rep, obs)
    allowed_rot = {"Tire_FL", "Tire_RL", "Rim_FL", "Rim_RL", "SteeringWheel"}
    _check_transforms(rep, obs, allowed_rot)

    # --- tree
    root = by.get(rn)
    if root is None or root.type != "EMPTY":
        rep.err("root Empty %s missing" % rn)
        return rep
    if root.parent is not None or root.location.length > 1e-6:
        rep.err("root must sit at the world origin with no parent")
    roots = [ob for ob in obs if ob.parent is None]
    if roots != [root]:
        rep.err("objects outside the root: %s" % [o.name for o in roots if o != root])
    required = {"Body": rn, "Lights": rn, "Markers": rn, "Interior": rn}
    for w in scaffold.WHEEL_NAMES:
        required[w] = rn
        required["Tire_" + w[-2:]] = w
        required["Rim_" + w[-2:]] = w
    for n in scaffold.LIGHT_NAMES:
        required[n] = "Lights"
    for n in scaffold.MARKER_NAMES:
        required[n] = "Markers"
    for n, parent in required.items():
        ob = by.get(n)
        if ob is None:
            rep.err("missing %s (under %s)" % (n, parent))
        elif ob.parent is None or ob.parent.name != parent:
            rep.err("%s must be a child of %s" % (n, parent))
    if rep.errors:
        return rep
    for n in ("Lights", "Markers", "Interior"):
        if by[n].type != "EMPTY" or by[n].location.length > 1e-6:
            rep.err("%s must be an Empty at the origin" % n)
    for n in scaffold.MARKER_NAMES:
        if by[n].type != "EMPTY":
            rep.err("marker %s must be an Empty" % n)
    for w in scaffold.WHEEL_NAMES:
        if by[w].type != "EMPTY":
            rep.err("%s must be an Empty" % w)
        for part in ("Tire_", "Rim_"):
            ob = by[part + w[-2:]]
            if ob.location.length > 1e-5:
                rep.err("%s must sit at its wheel's origin (local 0)" % ob.name)

    # --- materials
    body = by["Body"]
    for ob in obs:
        if ob.type != "MESH":
            continue
        in_interior = ob.parent is not None and ob.parent.name == "Interior"
        for m in _used_materials(ob):
            p = wb_palette.parse_car(m)
            if p.get("error"):
                rep.err("%s: %s" % (ob.name, p["error"]))
                continue
            if p["kind"] in ("interior", "gauges") and not in_interior:
                rep.err("%s: interior material %s outside Interior" % (ob.name, m))
            if in_interior and p["kind"] == "slot":
                rep.err("%s: car slot material %s inside Interior (use interior_<c>)" % (ob.name, m))
            if ob.name.startswith(("Tire_", "Rim_")) and not (p["kind"] == "slot" and p["slot"] == wb_palette.SLOT_TRIM):
                rep.err("%s: wheels use trim_* only (%s)" % (ob.name, m))
            if ob == body and p["kind"] == "slot" and p["slot"] in (wb_palette.SLOT_LAMP, wb_palette.SLOT_SIGNAL):
                rep.err("Body: lamp/signal material %s belongs on a light node" % m)
        if ob.name == "Gauges":
            if _used_materials(ob) != ["gauges"] or len(ob.data.polygons) != 1 or not ob.data.uv_layers:
                rep.err("Gauges: one quad, material gauges, with UV0")
    for n in scaffold.LIGHT_NAMES:
        want = scaffold.LIGHT_MATERIAL[n.split("_")[0]]
        used = _used_materials(by[n])
        if used != [want]:
            rep.err("%s: must use only %s (uses %s)" % (n, want, used))
    body_mats = _used_materials(body)
    if not any(m in wb_palette.PAINT_SHADES for m in body_mats):
        rep.err("Body has no paint material")
    if not body.data.uv_layers:
        rep.warn("Body has no UV0 (paint faces want a clean unwrap for a later livery)")

    # --- budgets
    tb = tris(body)
    ti = sum(tris(o) for o in obs if o.type == "MESH" and o.parent == by["Interior"])
    tr = tris(by["Rim_FR"])
    tt = tris(by["Tire_FR"])
    tl = sum(tris(by[n]) for n in scaffold.LIGHT_NAMES)
    if tb > BODY_TRIS:
        rep.err("Body %d tris > %d" % (tb, BODY_TRIS))
    elif tb > BODY_TRIS_TARGET:
        rep.warn("Body %d tris above the 6-10k target" % tb)
    if ti > INTERIOR_TRIS:
        rep.err("Interior %d tris > %d" % (ti, INTERIOR_TRIS))
    if tr > RIM_TRIS:
        rep.err("Rim %d tris > %d" % (tr, RIM_TRIS))
    rep.info["tris"] = "Body %d, lights %d, tire %d, rim %d (x4 = %d), interior %d, total drawn outside %d" % (
        tb, tl, tt, tr, 4 * (tt + tr), ti, tb + tl + 4 * (tt + tr))
    slots = sorted({wb_palette.SLOT_NAMES[wb_palette.parse_car(m)["slot"]] for m in body_mats
                    if wb_palette.parse_car(m).get("kind") == "slot"})
    rep.info["body slots"] = "%s (%d draws) + lamps 1 + wheels 1 = %d" % (", ".join(slots), len(slots), len(slots) + 2)
    if len(slots) + 2 > 5:
        rep.err("more than 5 merged draws")

    # --- wheels
    tires = [by["Tire_" + w[-2:]] for w in scaffold.WHEEL_NAMES]
    rims = [by["Rim_" + w[-2:]] for w in scaffold.WHEEL_NAMES]
    if len({t.data.name for t in tires}) != 1:
        rep.err("the four Tire_* must share one mesh (linked duplicates, Alt+D)")
    if len({r.data.name for r in rims}) != 1:
        rep.err("the four Rim_* must share one mesh")
    for ob in tires + rims:
        left = ob.name.endswith(("FL", "RL"))
        want = math.pi if left else 0.0
        rz = ob.rotation_euler.z
        if abs(ob.rotation_euler.x) > 1e-5 or abs(ob.rotation_euler.y) > 1e-5 or \
                abs(math.remainder(rz - want, 2 * math.pi)) > 1e-4:
            rep.err("%s: rotation must be %s" % (ob.name, "180 deg about Z" if left else "zero"))
    tlo, thi = local_bounds(tires[0].data)
    radius = max(thi[1] - tlo[1], thi[2] - tlo[2]) / 2
    if abs((thi[0] + tlo[0]) / 2) > 0.01:
        rep.warn("tire not centred on x = 0 (tread symmetric about its origin)")
    rlo, rhi = local_bounds(rims[0].data)
    if rhi[0] < thi[0] - 0.02:
        rep.warn("rim face (+X) sits inside the tire's outer sidewall")
    pos = {w: by[w].matrix_world.translation for w in scaffold.WHEEL_NAMES}
    for w, p in pos.items():
        if abs(p.z - radius) > GROUND_TOL:
            rep.err("%s hub z %.3f != tire radius %.3f (not on the ground)" % (w, p.z, radius))
    fl, fr, rl, rr = (pos[w] for w in scaffold.WHEEL_NAMES)
    if not (fl.y > 0 and fr.y > 0 and rl.y < 0 and rr.y < 0):
        rep.err("front wheels must be at +Y")
    if not (fl.x < 0 and rl.x < 0 and fr.x > 0 and rr.x > 0):
        rep.err("left wheels must be at -X")
    if abs((fl.y + rl.y) / 2) > AXLE_TOL or abs(fl.x + fr.x) > AXLE_TOL:
        rep.err("origin not centred between the axles (±%.2f m)" % AXLE_TOL)
    wheelbase = fl.y - rl.y
    if abs(wheelbase - cd["wheelbase_m"]) > 0.03:
        rep.warn("wheelbase %.3f != CarDef %.3f" % (wheelbase, cd["wheelbase_m"]))
    rep.info["wheels"] = "radius %.3f, wheelbase %.3f, track F %.3f R %.3f" % (radius, wheelbase, fr.x - fl.x, rr.x - rl.x)

    # --- body size (Body only, like the game: mirrors count)
    lo, hi = world_bounds([body])
    size = [hi[i] - lo[i] for i in range(3)]
    L, W, H = cd["length_m"], cd["width_m"], cd["height_m"]
    rep.info["body size"] = "L %.3f (CarDef %.2f, %+.1f%%)  W %.3f (%.2f, %+.1f%%)  H %.3f (%.2f)" % (
        size[1], L, 100 * (size[1] / L - 1), size[0], W, 100 * (size[0] / W - 1), hi[2], H)
    if not LENGTH_RANGE[0] <= size[1] <= LENGTH_RANGE[1]:
        rep.err("length %.2f outside %.1f-%.1f m" % (size[1], *LENGTH_RANGE))
    if abs(size[1] - L) > L * DIM_TOL:
        rep.err("Body length %.3f not within 5%% of CarDef %.2f" % (size[1], L))
    if abs(size[0] - W) > W * DIM_TOL:
        rep.err("Body width %.3f not within 5%% of CarDef %.2f" % (size[0], W))
    if abs(hi[2] - H) > H * 0.05:
        rep.warn("Body top %.3f vs CarDef height %.2f" % (hi[2], H))
    if lo[2] < -GROUND_TOL:
        rep.err("Body below the ground (min z %.3f)" % lo[2])
    if abs(hi[0] + lo[0]) > 0.02:
        rep.warn("Body not centred on x = 0 (%.3f)" % ((hi[0] + lo[0]) / 2))
    rep.info["body y span"] = "%.3f .. %.3f (front overhang %.3f, rear %.3f)" % (lo[1], hi[1], hi[1] - fl.y, rl.y - lo[1])
    deg = _degenerate(body)
    if deg:
        rep.err("Body: %d degenerate faces" % deg)
    rep.info["body outward"] = "%.0f%% of faces face away from the centre (review the rest)" % (100 * _outward_ratio(body))

    # --- lights and markers
    wp = {n: by[n].matrix_world.translation for n in scaffold.LIGHT_NAMES + scaffold.MARKER_NAMES}
    if not (wp["headlight_L"].y > 0 and wp["headlight_L"].x < 0 and wp["headlight_R"].x > 0 and wp["taillight_L"].y < 0):
        rep.err("headlights must be at the front (+Y), left at -X; taillights at the back")
    for n in scaffold.LIGHT_NAMES:
        llo, lhi = local_bounds(by[n].data)
        dims = sorted([lhi[0] - llo[0], lhi[2] - llo[2]], reverse=True)
        if n.startswith(("head", "tail")) and (dims[0] < LAMP_MIN[0] - 1e-3 or dims[1] < LAMP_MIN[1] - 1e-3):
            rep.warn("%s: lamp face %.2f x %.2f m (brief asks ≥ 0.15 x 0.08)" % (n, dims[0], dims[1]))
        c = [(llo[i] + lhi[i]) / 2 for i in range(3)]
        if max(abs(v) for v in c) > 0.05 and n.startswith("head"):
            rep.warn("%s: origin is not at the lamp centre (beam origin)" % n)
    if not (wp["cam_hood"].y > 0 and wp["exhaust_L"].y < 0 and wp["exhaust_R"].y < 0):
        rep.err("cam_hood must be ahead of the origin, exhausts behind")
    if abs(wp["shadow"].z) > 0.05:
        rep.warn("shadow marker should sit on the ground")
    eye = wp["cam_cockpit"]
    if eye.x > 0:
        rep.warn("cam_cockpit on the right: the driver sits on the left (-X)")
    near = math.inf
    for ob in obs:
        if ob.type == "MESH" and ob.parent == by["Interior"]:
            mw = ob.matrix_world
            for v in ob.data.vertices:
                near = min(near, (mw @ v.co - eye).length)
    if near < EYE_CLEARANCE:
        rep.warn("interior geometry %.2f m from the eye (≥ %.2f)" % (near, EYE_CLEARANCE))
    rep.info["eye"] = "cam_cockpit (%.2f, %.2f, %.2f), nearest interior %.2f m" % (eye.x, eye.y, eye.z, near)
    rep.info["hood cam"] = "(%.2f, %.2f, %.2f)" % tuple(wp["cam_hood"])

    # --- LOD1
    if lod1:
        lc = bpy.data.collections.get(car_id + "_lod1")
        if lc is None:
            rep.err("no %s_lod1 collection" % car_id)
        else:
            lb = [o for o in lc.all_objects if o.type == "MESH"]
            if len(lb) != 1:
                rep.err("LOD1: expected one mesh object (Body_lod1), found %d" % len(lb))
            t = sum(tris(o) for o in lb)
            rep.info["lod1"] = "%d tris" % t
            if t > LOD1_TRIS:
                rep.err("LOD1 %d tris > %d" % (t, LOD1_TRIS))
    return rep


def _args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    return dict(a[2:].split("=", 1) if "=" in a else (a[2:], "1") for a in argv if a.startswith("--"))


if __name__ == "__main__":
    a = _args()
    if a.get("asset", "car") == "car":
        r = validate_car(a["id"], lod1=a.get("lod1") == "1")
    else:
        raise SystemExit("only --asset=car is implemented so far")
    print(r.summary())
    if not r.ok():
        sys.exit(1)
