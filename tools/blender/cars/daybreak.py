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

T = TONNEAU_Z
R = RAIL_Z

# Right-half rails: floorC floorE rocker lowSide shoulder belt roofSide pillarIn roofMid crown roofC.
LOW = [(0, .22), (.60, .22), (.862, .25), (.902, .40), (.952, .69)]      # floor .. shoulder (cab, bed)
BED = LOW + [(.918, R), (.848, R + .008), (.828, T), (.40, T), (.20, T + .004), (0, T + .005)]


def _cab(roof, belt_z=.955):
    """Cab section: a tumblehome side window and a crowned roof with rounded edges."""
    return LOW + [(.905, belt_z), (.748, roof - .052), (.69, roof - .024), (.42, roof - .008), (.22, roof - .002),
                  (0, roof)]


def _hood(z):
    """Hood section: a crisp fender line (belt) rolling over into a crowned hood."""
    return LOW + [(.912, z - .045), (.862, z - .032), (.74, z - .026), (.42, z - .018), (.22, z - .004), (0, z)]


def tube(b, pts, r, mat, sides=10, group="tube", caps=(True, True)):
    """A smooth round tube swept along `pts` (parallel-transport frames)."""
    n = len(pts)
    tan = []
    for i in range(n):
        a, c = pts[max(i - 1, 0)], pts[min(i + 1, n - 1)]
        tan.append(v_norm(v_sub(c, a)))
    ref = (0.0, 0.0, 1.0) if abs(tan[0][2]) < 0.9 else (0.0, 1.0, 0.0)
    u = v_norm(v_cross(v_cross(tan[0], ref), tan[0]))
    rings = []
    for i in range(n):
        t = tan[i]
        dot = u[0] * t[0] + u[1] * t[1] + u[2] * t[2]
        u = v_norm(v_sub(u, v_scale(t, dot)))
        w = v_cross(t, u)
        rings.append([v_add(pts[i], v_add(v_scale(u, r * math.cos(2 * math.pi * k / sides)),
                                          v_scale(w, r * math.sin(2 * math.pi * k / sides)))) for k in range(sides)])
    for i in range(n - 1):
        for k in range(sides):
            k1 = (k + 1) % sides
            quad = [rings[i][k], rings[i][k1], rings[i + 1][k1], rings[i + 1][k]]
            mid = v_scale(v_add(v_add(quad[0], quad[1]), v_add(quad[2], quad[3])), 0.25)
            ctr = v_scale(v_add(pts[i], pts[i + 1]), 0.5)
            b.face(quad, mat, v_sub(mid, ctr), smooth=True, group=group)
    if caps[0]:
        b.face(rings[0], mat, v_scale(tan[0], -1))
    if caps[1]:
        b.face(rings[-1], mat, tan[-1])


def arc(p0, p1, n, axis="xy"):
    """A quarter ellipse from p0 to p1 in plan (x, y): leaves p0 along x, arrives at p1 along y."""
    out = []
    for i in range(n + 1):
        th = (math.pi / 2) * i / n
        out.append((p0[0] + (p1[0] - p0[0]) * math.sin(th), p1[1] + (p0[1] - p1[1]) * math.cos(th)))
    return out


def sweep_bumper(b, plan, z0, z1, depth, mat, top_mat, sign, group):
    """A bumper blade following a plan polyline [(x, y)] from the centre line out and round
    the corner; `sign` +1 = the front (outward is +y first), -1 = the rear."""
    n = len(plan)
    nrm = []
    for i in range(n):
        a, c = plan[max(i - 1, 0)], plan[min(i + 1, n - 1)]
        tx, ty = c[0] - a[0], c[1] - a[1]
        ln = math.hypot(tx, ty)
        tx, ty = tx / ln, ty / ln
        nrm.append((-ty * sign, tx * sign) if sign > 0 else (ty, -tx))
    outer = plan
    inner = [(p[0] - m[0] * depth, p[1] - m[1] * depth) for p, m in zip(plan, nrm)]
    for i in range(n - 1):
        a, c, ai, ci = outer[i], outer[i + 1], inner[i], inner[i + 1]
        mo = ((nrm[i][0] + nrm[i + 1][0]) / 2, (nrm[i][1] + nrm[i + 1][1]) / 2, 0.0)
        b.face([(a[0], a[1], z0), (c[0], c[1], z0), (c[0], c[1], z1), (a[0], a[1], z1)], mat, mo,
               smooth=True, group=group)
        b.face([(a[0], a[1], z1), (c[0], c[1], z1), (ci[0], ci[1], z1), (ai[0], ai[1], z1)], top_mat, (0, 0, 1))
        b.face([(a[0], a[1], z0), (ai[0], ai[1], z0), (ci[0], ci[1], z0), (c[0], c[1], z0)], "trim_ink", (0, 0, -1))
    e, ei = outer[-1], inner[-1]
    tx, ty = e[0] - outer[-2][0], e[1] - outer[-2][1]
    b.face([(e[0], e[1], z0), (ei[0], ei[1], z0), (ei[0], ei[1], z1), (e[0], e[1], z1)], mat, (tx, ty, 0))


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
    # Creases across the car: the cab back wall (bed, sill, window top), the windscreen
    # header and the cowl. The panels between them are smooth.
    CREASE_Y = (WALL_BASE, WIN_BASE, CAB_BACK, -0.05, 0.62)
    SHARP_RAILS = (1, 2, 3, kit.R_BELT)
    LOFT_STEP = 0.15
    KEYS = [
        # Tail: the tailgate, with rounded plan corners.
        (TAIL, [(0, .44, .05), (.58, .44, .05), (.80, .45, .03), (.838, .52), (.866, .72), (.846, R),
                (.792, R + .005), (.772, T), (.40, T), (.20, T + .004), (0, T + .005)]),
        (-2.42, [(0, .37), (.58, .37), (.835, .38), (.878, .46), (.915, .71), (.885, R), (.82, R + .007),
                 (.80, T), (.40, T), (.20, T + .004), (0, T + .005)]),
        (-2.30, [(0, .29), (.59, .29), (.855, .30), (.896, .42), (.942, .70), (.91, R), (.84, R + .008),
                 (.82, T), (.40, T), (.20, T + .004), (0, T + .005)]),
        (-2.10, BED),
        (WALL_BASE, BED),
        # Cab back wall: the rear window sill, then the window top (= the roof's rear edge).
        (WIN_BASE, LOW + [(.905, .955), (.79, 1.095), (.70, 1.10), (.42, 1.105), (.22, 1.108), (0, 1.11)]),
        (CAB_BACK, _cab(1.385)),
        (-0.70, _cab(1.40)),
        (-0.30, _cab(1.40)),
        (-0.05, _cab(1.384)),
        # Cowl: the windscreen base.
        (0.62, LOW + [(.908, .948), (.862, .956), (.80, .96), (.42, .966), (.22, .97), (0, .972)]),
        (0.72, _hood(.976)),
        (1.20, _hood(.968)),
        (1.75, _hood(.950)),
        (2.10, [(0, .27), (.58, .27), (.85, .29), (.89, .41), (.935, .69), (.895, .89), (.848, .898), (.73, .903),
                (.42, .91), (.22, .922), (0, .926)]),
        (2.28, [(0, .32), (.56, .32), (.82, .33), (.862, .42), (.902, .69), (.866, .868), (.81, .877), (.71, .881),
                (.40, .887), (.22, .897), (0, .90)]),
        # The nose: a small flat fascia inside rounded corners.
        (NOSE, [(0, .34, -.04), (.55, .34, -.04), (.79, .35, -.03), (.83, .42), (.852, .69), (.822, .842, -.02),
                (.765, .850, -.03), (.675, .853, -.03), (.40, .857, -.03), (.22, .86, -.03), (0, .862, -.03)]),
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
    TAIL_LAMP_X = (0.675, 0.828)
    TAIL_LAMP_Z = (0.60, 0.92)
    TAIL_BLINK_Z = (0.50, 0.57)
    ROLL_Y = -1.00
    ROLL_X = 0.845
    ROLL_TOP = 1.30

    def main_loft(self):
        edges = [r[k] for r in self.REGIONS.values() for k in (0, 1)]
        return kit.Loft(self.KEYS, self.body_material, self.arch_rails, extra_ys=self.arch_ys() + edges,
                        caps=("paint", "paint_shade"), creases_y=self.CREASE_Y, sharp_rails=self.SHARP_RAILS,
                        step=self.LOFT_STEP, seg=self.LOFT_SEG, max_sub=self.LOFT_MAX_SUB)

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
        # Front bumper: a chrome blade following the rounded nose round the corner.
        z0, z1 = self.BUMPER_F_Z
        ny = self.NOSE_Y
        plan = [(0.0, ny + 0.07), (0.40, ny + 0.07)] + arc((0.74, ny + 0.07), (0.905, ny - 0.13), 6)
        sweep_bumper(b, plan, z0, z1, 0.08, "trim_steel", "trim_steel", 1, "bumper_f")
        # Step-side hint: a dark notch between the cab and the rear wheel, and a step plate.
        ya, yb = -0.87, -1.05
        xs = self.side_x((ya + yb) / 2, 0.55) + 0.004
        b.face([(xs, ya, 0.45), (xs, yb, 0.45), (xs, yb, 0.53), (xs, ya, 0.53)], "trim_ink", (1, 0, 0))
        b.box((xs + 0.015, (ya + yb) / 2, 0.44), (0.03, abs(yb - ya) + 0.02, 0.03), "trim_steel", skip=("-x",))
        # Body-side rub strip (80s): a dark band along the doors and the bed side.
        zr0, zr1 = 0.60, 0.645
        for y0, y1 in ((self.axles[0] - self.ARCH_R - 0.06, -0.79), (-0.83, self.axles[1] + self.ARCH_R + 0.06),
                       (self.axles[1] - self.ARCH_R - 0.06, self.TAIL_Y + 0.20)):
            ys = [y0 + (y1 - y0) * i / 6 for i in range(7)]
            for ya_, yb_ in zip(ys, ys[1:]):
                xa_, xb_ = self.side_x(ya_, 0.62) + 0.005, self.side_x(yb_, 0.62) + 0.005
                b.face([(xa_, ya_, zr0), (xb_, yb_, zr0), (xb_, yb_, zr1), (xa_, ya_, zr1)], "trim_ink", (1, 0, 0))
        # Rear step bumper (dark tread on top), wrapped round the rounded tail corners.
        z0, z1 = self.BUMPER_R_Z
        ty = self.TAIL_Y
        plan = [(0.0, ty - 0.09), (0.40, ty - 0.09)] + arc((0.76, ty - 0.09), (0.915, ty + 0.10), 6)
        sweep_bumper(b, plan, z0, z1, 0.10, "trim_steel", "trim_ink", -1, "bumper_r")
        # Roll bar: one bent round hoop (centre line -> corner -> down to the bed rail) and a
        # back stay to the rail; smooth tubes.
        rx, ry, top = self.ROLL_X, self.ROLL_Y, self.ROLL_TOP
        rb = 0.10
        hoop = [(0.0, ry, top), (rx - rb, ry, top)]
        for i in range(1, 6):
            th = (math.pi / 2) * i / 6
            hoop.append((rx - rb + rb * math.sin(th), ry, top - rb + rb * math.cos(th)))
        hoop += [(rx, ry, top - rb), (rx, ry, RAIL_Z - 0.01)]
        tube(b, hoop, 0.032, "trim_steel", group="roll_hoop", caps=(False, True))
        tube(b, [(rx, ry - 0.03, top - 0.06), (rx, -1.55, RAIL_Z - 0.01)], 0.026, "trim_steel", group="roll_stay")
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
        tube(b, [along(0.04), along(0.30)], 0.03, self.imat("hub"), sides=8, group="column")
        root = along(0.07)
        tip = v_add(root, (0.20, -0.06, 0.03))
        tube(b, [v_add(root, (0.02, 0.0, 0.0)), tip], 0.007, "interior_steel", sides=6, group="shifter")
        b.box(tip, (0.035, 0.035, 0.035), self.imat("wheel"))


CAR = Daybreak

if __name__ == "__main__":
    kit.run(CAR)
