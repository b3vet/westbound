"""Daybreak, the daily driver (docs/ART_PRODUCTION.md §4.1.2 slot 7, §4.1.5).

A 70s-80s coupé utility: a sport pickup built on a coupe. A cab with a short roof and a
small rear window, an open bed under a flat tonneau cover (paint_shade) at the bed-rail
height, a roll bar behind the cab carrying a four-lamp light bar (trim lenses, not
lights), a step-side hint between the cab and the rear wheel, a big step bumper. Tall
vertical taillights at the bed corners. Interior: a bench seat, a column shifter, a
large thin wheel.

Unlock: a 7-day Daily Drive streak. Proposed CarDef: 4.9 x 1.95 x 1.40 m, wheelbase 2.95,
default paint hazard_yellow (sunrise yellow).

  blender -b --python tools/blender/cars/daybreak.py -- [--export] [--render] [--save]
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import wb_carkit as kit  # noqa: E402
from wb_carkit import MeshBuilder  # noqa: E402
from wb_mesh import v_add, v_cross, v_norm, v_scale, v_sub  # noqa: E402

NOSE = 2.36
TAIL = -2.46
TONNEAU_Z = 0.935
RAIL_Z = 0.955
CAB_BACK = -0.80        # top of the cab back wall
WALL_BASE = -0.835      # the tonneau meets the cab back wall here
WIN_BASE = -0.825       # rear window sill (the wall below it is paint)

# Bed rails (right half): floorC floorE rocker lowSide shoulder belt roofSide pillarIn roofMid crown roofC
BED = [(0, .22), (.60, .22), (.88, .24), (.93, .42), (.955, .80), (.935, RAIL_Z), (.845, RAIL_Z + .005),
       (.825, TONNEAU_Z), (.40, TONNEAU_Z), (.20, TONNEAU_Z), (0, TONNEAU_Z)]


def _cab(roof, roof_side_x=.76, belt=(.93, .965)):
    """Cab section: lower body rails and a roof at `roof` (centre height)."""
    return [(0, .22), (.60, .22), (.88, .24), (.93, .42), (.945, .80), belt, (roof_side_x, roof - .045),
            (roof_side_x - .06, roof - .025), (.40, roof - .01), (.20, roof - .003), (0, roof)]


def _hood(y_z, fender_x=.93):
    """Hood section at a given hood centre height."""
    z = y_z
    return [(0, .22), (.60, .22), (.88, .24), (.93, .42), (.945, .80), (fender_x, z - .025), (.85, z - .02),
            (.72, z - .018), (.35, z - .015), (.25, z - .005), (0, z)]


def beam(b, p0, p1, w, mat, caps=True):
    """A square tube of width `w` from p0 to p1."""
    d = v_norm(v_sub(p1, p0))
    up = (0.0, 0.0, 1.0) if abs(d[2]) < 0.9 else (1.0, 0.0, 0.0)
    u = v_norm(v_cross(d, up))
    v = v_norm(v_cross(u, d))
    h = w / 2

    def corner(p, su, sv):
        return v_add(p, v_add(v_scale(u, su * h), v_scale(v, sv * h)))
    for (su0, sv0), (su1, sv1), out in (((1, -1), (1, 1), u), ((1, 1), (-1, 1), v), ((-1, 1), (-1, -1), v_scale(u, -1)),
                                        ((-1, -1), (1, -1), v_scale(v, -1))):
        b.face([corner(p0, su0, sv0), corner(p0, su1, sv1), corner(p1, su1, sv1), corner(p1, su0, sv0)], mat, out)
    if caps:
        b.face([corner(p1, 1, 1), corner(p1, -1, 1), corner(p1, -1, -1), corner(p1, 1, -1)], mat, d)
        b.face([corner(p0, 1, 1), corner(p0, -1, 1), corner(p0, -1, -1), corner(p0, 1, -1)], mat, v_scale(d, -1))


class Daybreak(kit.LoftCar):
    CAR_ID = "daybreak"
    CARDEF = {"length_m": 4.9, "width_m": 1.95, "height_m": 1.40, "wheelbase_m": 2.95,
              "default_paint": (250 / 255, 199 / 255, 41 / 255), "display_name": "Daybreak"}
    WHEELBASE = 2.95
    WHEEL_R = 0.345
    TIRE_W = 0.245
    RIM_IN = 0.215
    TRACK_F = 1.60
    TRACK_R = 1.60
    ARCH_R = 0.40
    WELL_X = 0.62
    FLOOR_Z = 0.22
    NOSE_Y = NOSE
    TAIL_Y = TAIL
    KEYS = [
        (TAIL, [(0, .44, .05), (.58, .44, .05), (.84, .45, .03), (.90, .52), (.925, .80), (.915, RAIL_Z),
                (.84, RAIL_Z + .005), (.82, TONNEAU_Z), (.40, TONNEAU_Z), (.20, TONNEAU_Z), (0, TONNEAU_Z)]),
        (-2.40, [(0, .32), (.58, .32), (.86, .32), (.925, .44), (.95, .80), (.93, RAIL_Z), (.845, RAIL_Z + .005),
                 (.825, TONNEAU_Z), (.40, TONNEAU_Z), (.20, TONNEAU_Z), (0, TONNEAU_Z)]),
        (-2.10, BED),
        (WALL_BASE, BED),
        (WIN_BASE, [(0, .22), (.60, .22), (.88, .24), (.93, .42), (.945, .80), (.93, .965), (.80, 1.10), (.70, 1.11),
                    (.40, 1.12), (.20, 1.12), (0, 1.12)]),
        (CAB_BACK, _cab(1.385)),
        (-0.76, _cab(1.40)),
        (-0.05, _cab(1.39, .755, (.93, .96))),
        (0.62, [(0, .22), (.60, .22), (.88, .24), (.93, .42), (.945, .80), (.93, .95), (.87, .958), (.79, .963),
                (.40, .968), (.20, .97), (0, .97)]),
        (0.70, _hood(.97)),
        (1.60, _hood(.945)),
        (2.24, [(0, .30), (.58, .30), (.85, .32), (.915, .44), (.935, .80), (.90, .88), (.83, .885), (.70, .887),
                (.35, .89), (.25, .895), (0, .90)]),
        (NOSE, [(0, .34, -.04), (.55, .34, -.04), (.80, .35, -.03), (.86, .42), (.88, .78), (.86, .85), (.79, .855),
                (.68, .858), (.35, .86), (.25, .862), (0, .865)]),
    ]
    REGIONS = {"windscreen": (-0.05, 0.62), "rear_glass": (WIN_BASE, CAB_BACK), "side_glass": (-0.66, 0.62),
               "bed": (TAIL, WALL_BASE), "wall": (WALL_BASE, WIN_BASE)}
    MIRROR = (0.90, 0.44, 1.02)
    # Interior: an upright cab, a bench.
    EYE = (-0.38, -0.30, 1.16)
    CABIN = (CAB_BACK, 0.62)
    DASH = {"y_front": 0.62, "y_rear": 0.42, "top": 0.955, "bottom": 0.62}
    STEER = {"r": 0.21, "thick": 0.016, "spokes": 2, "tilt": -0.45, "sides": 22, "pos": (-0.38, 0.26, 0.82)}
    SEAT = {"y": -0.40, "cushion_z": 0.52, "back_top": 1.10, "w": 0.74}
    INTERIOR = dict(kit.LoftCar.INTERIOR, seat="soil", seat_accent="soil_dark", door="soil_dark", dash_top="asphalt",
                    dash_face="roof_slate", liner="roof_slate", wheel="ink", spoke="steel", hub="steel_dark",
                    accent="cream", console="asphalt", floor="ink", strip=None)

    # Front and rear detail layout.
    GRILLE_Z = (0.52, 0.78)
    HEAD_Z = (0.635, 0.735)
    HEAD_X = ((0.50, 0.625), (0.645, 0.77))
    BUMPER_F_Z = (0.36, 0.50)
    BUMPER_R_Z = (0.30, 0.46)
    TAIL_LAMP_X = (0.72, 0.88)
    TAIL_LAMP_Z = (0.60, 0.92)
    TAIL_BLINK_Z = (0.50, 0.57)
    ROLL_Y = -1.00
    ROLL_X = 0.845
    ROLL_TOP = 1.30

    def main_loft(self):
        edges = [r[k] for r in self.REGIONS.values() for k in (0, 1)]
        return kit.Loft(self.KEYS, self.body_material, self.arch_rails, extra_ys=self.arch_ys() + edges,
                        caps=("paint", "paint_shade"))

    def body_material(self, y0, y1, j, arch):
        ym = (y0 + y1) / 2
        if j in (kit.S_FLOOR, kit.S_TUCK):
            return "trim_ink"
        if j == kit.S_SILL:
            return "trim_ink" if arch else "paint_shade"
        if j in (kit.S_SIDE, kit.S_UPPER):
            return "paint"
        if self.region("bed", ym):
            if j == kit.S_WINDOW:
                return "paint"          # bed rail cap
            if j == kit.S_PILLAR:
                return "trim_ink"       # the rail's inner lip down to the cover
            return "paint_shade"        # tonneau
        if self.region("wall", ym):
            return "paint"
        if self.region("rear_glass", ym):
            return "glass" if j in (kit.S_TOP_MID, kit.S_TOP_IN) else "paint"
        if j == kit.S_WINDOW:
            return "glass" if self.region("side_glass", ym) else "paint"
        if j == kit.S_PILLAR:
            return "paint"
        if self.region("windscreen", ym):
            return "glass"
        return "paint"

    # ---------------------------------------------------------------- details

    def details(self, b):
        fy = self.NOSE_Y + 0.004
        gz0, gz1 = self.GRILLE_Z
        # Grille: dark panel with two chrome bars in the middle, chrome frames round the lamps.
        b.face([(0, fy, gz0), (0.82, fy, gz0), (0.82, fy, gz1), (0, fy, gz1)], "trim_ink", (0, 1, 0))
        for zb in (0.585, 0.675):
            b.box((0.22, fy + 0.008, zb), (0.44, 0.016, 0.022), "trim_steel", skip=("-y", "-x"))
        hz0, hz1 = self.HEAD_Z
        x0, x1 = self.HEAD_X[0][0] - 0.02, self.HEAD_X[1][1] + 0.02
        for (a, c) in (((x0, hz1), (x1, hz1 + 0.02)), ((x0, hz0 - 0.02), (x1, hz0))):
            b.box(((a[0] + c[0]) / 2, fy + 0.008, (a[1] + c[1]) / 2), (c[0] - a[0], 0.016, c[1] - a[1]),
                  "trim_steel", skip=("-y",))
        for xs in (x0 - 0.0, x1):
            b.box((xs, fy + 0.008, (hz0 + hz1) / 2), (0.02, 0.016, hz1 - hz0), "trim_steel", skip=("-y",))
        # Front bumper: a big chrome blade wrapping the corner.
        z0, z1 = self.BUMPER_F_Z
        ny = self.NOSE_Y
        b.box((0.45, ny + 0.035, (z0 + z1) / 2), (0.90, 0.07, z1 - z0), "trim_steel", skip=("-x", "-y"))
        b.face([(0.90, ny + 0.07, z0), (0.90, ny - 0.12, z0), (0.90, ny - 0.12, z1), (0.90, ny + 0.07, z1)],
               "trim_steel", (1, 0, 0))
        b.face([(0.90, ny - 0.12, z0), (0.90, ny + 0.07, z0), (0, ny + 0.07, z0), (0, ny, z0)], "trim_ink",
               (0, 0, -1))
        # Step-side hint: a dark notch between the cab and the rear wheel, and a step plate.
        ya, yb = -0.87, -1.05
        xs = self.side_x((ya + yb) / 2, 0.55) + 0.004
        b.face([(xs, ya, 0.45), (xs, yb, 0.45), (xs, yb, 0.53), (xs, ya, 0.53)], "trim_ink", (1, 0, 0))
        b.box((xs + 0.015, (ya + yb) / 2, 0.44), (0.03, abs(yb - ya) + 0.02, 0.03), "trim_steel", skip=("-x",))
        # Body-side rub strip (80s): a dark band along the doors and the bed side.
        zr0, zr1 = 0.60, 0.645
        for y0, y1 in ((self.axles[0] - self.ARCH_R - 0.06, -0.79), (-0.83, self.axles[1] + self.ARCH_R + 0.06),
                       (self.axles[1] - self.ARCH_R - 0.06, self.TAIL_Y + 0.08)):
            ys = [y0 + (y1 - y0) * i / 6 for i in range(7)]
            for ya_, yb_ in zip(ys, ys[1:]):
                xa_, xb_ = self.side_x(ya_, 0.62) + 0.005, self.side_x(yb_, 0.62) + 0.005
                b.face([(xa_, ya_, zr0), (xb_, yb_, zr0), (xb_, yb_, zr1), (xa_, ya_, zr1)], "trim_ink", (1, 0, 0))
        # Rear step bumper with a dark tread on top.
        z0, z1 = self.BUMPER_R_Z
        ty = self.TAIL_Y
        b.box((0.465, ty - 0.045, (z0 + z1) / 2), (0.93, 0.09, z1 - z0), "trim_steel", {"+z": "trim_ink"},
              skip=("-x", "+y"))
        b.face([(0.93, ty, z0), (0.93, ty, z1), (0, ty, z1), (0, ty, z0)], "trim_ink", (0, 0, -1))
        # Roll bar: upright on the bed rail, the crossbar half, a back stay down to the rail.
        rx, ry, top = self.ROLL_X, self.ROLL_Y, self.ROLL_TOP
        beam(b, (rx, ry, RAIL_Z), (rx, ry, top + 0.03), 0.06, "trim_steel")
        beam(b, (0.0, ry, top), (rx + 0.03, ry, top), 0.06, "trim_steel", caps=False)
        b.face([(rx + 0.03, ry - 0.03, top - 0.03), (rx + 0.03, ry + 0.03, top - 0.03),
                (rx + 0.03, ry + 0.03, top + 0.03), (rx + 0.03, ry - 0.03, top + 0.03)], "trim_steel", (1, 0, 0))
        beam(b, (rx, ry - 0.02, top - 0.02), (rx, -1.55, RAIL_Z + 0.02), 0.05, "trim_steel")
        # Light bar: two lamps per side on the crossbar (dark housings, cream lenses forward).
        for lx in (0.17, 0.47):
            b.box((lx, ry, top + 0.075), (0.17, 0.10, 0.09), "trim_ink", {"+y": "trim_ink"})
            kit.rect_y(lx - 0.07, lx + 0.07, top + 0.04, top + 0.11, ry + 0.052, "trim_cream", 1, b)
        # Tailgate handle recess.
        b.box((0.0 + 0.07, ty - 0.008, 0.88), (0.14, 0.016, 0.04), "trim_ink", skip=("+y", "-x"))

    def center_details(self, b):
        ty = self.TAIL_Y
        b.face([(0.20, ty - 0.008, 0.52), (-0.20, ty - 0.008, 0.52), (-0.20, ty - 0.008, 0.66),
                (0.20, ty - 0.008, 0.66)], "trim_cream", (0, -1, 0))
        pipe = MeshBuilder()
        pipe.cylinder_x((0, 0, 0), 0.035, -0.08, 0.06, 8, "trim_steel", cap_mat="trim_ink")
        b.extend(pipe.transformed(lambda p: (p[1], p[0], p[2])), (0.55, ty - 0.02, 0.255))

    def lod1_extras(self, b):
        fy = self.NOSE_Y + 0.004
        b.face([(0, fy, self.GRILLE_Z[0]), (0.82, fy, self.GRILLE_Z[0]), (0.82, fy, self.GRILLE_Z[1]),
                (0, fy, self.GRILLE_Z[1])], "trim_ink", (0, 1, 0))
        z0, z1 = self.BUMPER_F_Z
        b.box((0.45, self.NOSE_Y + 0.035, (z0 + z1) / 2), (0.90, 0.07, z1 - z0), "trim_steel", skip=("-x", "-y"))
        z0, z1 = self.BUMPER_R_Z
        b.box((0.465, self.TAIL_Y - 0.045, (z0 + z1) / 2), (0.93, 0.09, z1 - z0), "trim_steel", skip=("-x", "+y"))
        rx, ry, top = self.ROLL_X, self.ROLL_Y, self.ROLL_TOP
        b.box((rx, ry, (RAIL_Z + top) / 2), (0.06, 0.06, top - RAIL_Z), "trim_steel", skip=("-z",))
        b.box((rx / 2, ry, top), (rx, 0.06, 0.06), "trim_steel", skip=("-x",))
        b.box((0.32, ry, top + 0.075), (0.47, 0.10, 0.09), "trim_ink", skip=("-x",))

    def rim(self):
        """Styled steel: six wide spokes read as slots in a dish."""
        return kit.star_rim(self.TIRE_W / 2 + 0.008, self.RIM_IN, spokes=6, spoke_w=(0.045, 0.06), hub_r=0.075,
                            lip_in_frac=0.9, dark="trim_ink")

    # ---------------------------------------------------------------- lights

    def lights(self, rig):
        ny, ty = self.NOSE_Y, self.TAIL_Y
        face = ny + 0.004
        hz0, hz1 = self.HEAD_Z
        for side, s in (("L", -1), ("R", 1)):
            hb = MeshBuilder()
            for (a, c) in self.HEAD_X:
                xa, xb = sorted((s * a, s * c))
                kit.lamp_box((xa + xb) / 2, (hz0 + hz1) / 2, xb - xa, hz1 - hz0, face, 0.015, "lamp_head", 1, hb)
            cx = s * (self.HEAD_X[0][0] + self.HEAD_X[1][1]) / 2
            rig.light("headlight_" + side, hb, (cx, face + 0.015, (hz0 + hz1) / 2))
            # Front blinkers: under the headlamps, in the grille panel.
            fb = MeshBuilder()
            xa, xb = sorted((s * 0.52, s * 0.76))
            kit.lamp_box((xa + xb) / 2, 0.575, xb - xa, 0.05, face, 0.015, "signal_blinker", 1, fb)
            rig.light("blinker_F" + side, fb, ((xa + xb) / 2, face + 0.015, 0.575))
            # Tall vertical taillights at the bed corners; the brake lens 5 mm proud of it.
            xa, xb = sorted((s * self.TAIL_LAMP_X[0], s * self.TAIL_LAMP_X[1]))
            z0, z1 = self.TAIL_LAMP_Z
            ly = ty - 0.004
            tb = kit.lamp_box((xa + xb) / 2, (z0 + z1) / 2, xb - xa, z1 - z0, ly, 0.015, "lamp_tail", -1)
            rig.light("taillight_" + side, tb, ((xa + xb) / 2, ly - 0.015, (z0 + z1) / 2))
            bb = kit.rect_y(xa + 0.012, xb - 0.012, z0 + 0.012, z1 - 0.012, ly - 0.020, "signal_brake", -1)
            rig.light("brake_" + side, bb, ((xa + xb) / 2, ly - 0.020, (z0 + z1) / 2))
            # Rear blinkers: amber, below the tall lamp with a gap.
            z0, z1 = self.TAIL_BLINK_Z
            rb = kit.lamp_box((xa + xb) / 2, (z0 + z1) / 2, xb - xa, z1 - z0, ly, 0.015, "signal_blinker", -1)
            rig.light("blinker_R" + side, rb, ((xa + xb) / 2, ly - 0.015, (z0 + z1) / 2))
        # Reverse: two small white lamps in the rear bumper face.
        rv = MeshBuilder()
        by = ty - 0.09
        for s in (-1, 1):
            xa, xb = sorted((s * 0.28, s * 0.42))
            kit.lamp_box((xa + xb) / 2, 0.38, xb - xa, 0.055, by, 0.015, "signal_reverse", -1, rv)
        rig.light("reverse", rv, (0.0, by - 0.015, 0.38))

    def markers(self):
        m = super().markers()
        tip = (0.55, self.TAIL_Y - 0.10, 0.255)
        m["exhaust_L"] = tip
        m["exhaust_R"] = tip
        return m

    # ---------------------------------------------------------------- interior

    def seat(self, b, x):
        """One half of a bench seat (the two halves meet on the centre line)."""
        s = self.SEAT
        y, cz, bt, w = s["y"], s["cushion_z"], s["back_top"], s["w"]
        sg = -1.0 if x < 0 else 1.0
        xa, xb = sorted((0.0, sg * w))
        m, acc = self.imat("seat"), self.imat("seat_accent")
        fz = self.FLOOR_Z + 0.10
        inner = "+x" if sg < 0 else "-x"
        b.box(((xa + xb) / 2, y + 0.21, (fz + cz) / 2), (w, 0.50, cz - fz), m, skip=("-z", inner))
        lean = 0.13
        yb = y - 0.04
        prof = [(xa, yb, cz), (xb, yb, cz), (xb, yb - lean, bt), (xa, yb - lean, bt)]
        b.face(prof, m, (0, 1, 0.2))
        back = [(p[0], p[1] - 0.10, p[2]) for p in prof]
        b.face(list(reversed(back)), m, (0, -1, 0))
        oi = (1, 2) if sg > 0 else (0, 3)
        b.face([prof[oi[0]], prof[oi[1]], back[oi[1]], back[oi[0]]], m, (sg, 0, 0))
        b.face([prof[3], prof[2], back[2], back[3]], m, (0, 0, 1))
        # Pleats: three horizontal bands across the backrest.
        for t in (0.25, 0.5, 0.75):
            za, zb = t, t + 0.08

            def P(xx, tt):
                return (xx, yb - lean * tt + 0.006, cz + (bt - cz) * tt)
            b.face([P(xa, za), P(xb, za), P(xb, zb), P(xa, zb)], acc, (0, 1, 0.2))

    def console(self, b):
        """No console with a bench: a radio face in the dash instead."""
        d = self.DASH
        yr, top = d["y_rear"], d["top"]
        b.face([(-0.10, yr - 0.004, top - 0.16), (0.10, yr - 0.004, top - 0.16), (0.10, yr - 0.004, top - 0.10),
                (-0.10, yr - 0.004, top - 0.10)], "interior_screen", (0, -1, 0))

    def interior_extras(self, b):
        """Steering column and the column shifter stalk."""
        hx, hy, hz = self.STEER["pos"]
        t = self.STEER["tilt"]
        axis = (0.0, math.cos(t), math.sin(t))   # forward along the column

        def along(d):
            return v_add((hx, hy, hz), v_scale(axis, d))
        beam(b, along(0.04), along(0.30), 0.06, self.imat("hub"))
        root = along(0.07)
        tip = v_add(root, (0.20, -0.06, 0.03))
        beam(b, v_add(root, (0.02, 0.0, 0.0)), tip, 0.014, "interior_steel")
        b.box(tip, (0.035, 0.035, 0.035), self.imat("wheel"))


CAR = Daybreak

if __name__ == "__main__":
    kit.run(CAR)
