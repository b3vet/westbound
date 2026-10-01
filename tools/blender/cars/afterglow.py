"""Afterglow, slot 6 (docs/ART_PRODUCTION.md §4.1.2, §4.1.5): late-game prestige.

Modern mid-engine LONGTAIL endurance racer: a cab-forward bubble canopy sitting low
between tall front and rear fender pods, a long tail with a central shark fin running
into an integrated wing between the rear fenders, a split front splitter, vertical
headlamp stacks, a finned rear diffuser and rear fender skirts (the brief's "closed
rear wheel covers": the four wheels must share one mesh, so the cover is on the Body).
Taillights: thin C-shapes plus a centre strip. Interior: carbon-look (ink) tub, a
flat-topped yoke that still turns through 360 degrees, a screen strip across the dash.

Proposed CarDef: 4.8 x 1.98 x 1.12 m, wheelbase 2.75, brand_orange.

  blender -b --python tools/blender/cars/afterglow.py -- [--export] [--render] [--save]
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import wb_carkit as kit  # noqa: E402
from wb_carkit import MeshBuilder  # noqa: E402
from wb_mesh import v_scale, v_sub  # noqa: E402

S_FLOOR, S_TUCK, S_SILL, S_SIDE, S_UPPER, S_WINDOW, S_PILLAR, S_TOP_OUT, S_TOP_MID, S_TOP_IN = range(10)


class ProfileLoft(kit.Loft):
    """kit.Loft with each strip's outward taken from the section's own edge normal (the
    half-section runs counter-clockwise in x-z, so outward = (dz, -dx)). The kit's
    heuristic (x, 0, z - 0.6) flips top faces below 0.6 m (this nose deck) and valley
    walls that face the centre (the pods' inner sides). No end caps: this car's sections
    are concave, see Afterglow.fan_caps()."""

    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self.caps = (None, None)

    def build(self, b, extra=None):
        st = self.stations(extra)
        n = len(st[0][1])
        for (ya, a, arch0), (yb, c, arch1) in zip(st, st[1:]):
            arch = arch0 and arch1
            for j in range(n - 1):
                m = self.mat_fn(ya, yb, j, arch)
                if m is None:
                    continue
                dx = a[j + 1][0] - a[j][0] + c[j + 1][0] - c[j][0]
                dz = a[j + 1][2] - a[j][2] + c[j + 1][2] - c[j][2]
                out = (dz, 0.0, -dx) if abs(dx) + abs(dz) > 1e-9 else None
                b.face([a[j], c[j], c[j + 1], a[j + 1]], m, out)
        return st


class Afterglow(kit.LoftCar):
    CAR_ID = "afterglow"
    CARDEF = {"length_m": 4.8, "width_m": 1.98, "height_m": 1.12, "wheelbase_m": 2.75,
              "default_paint": (0.961, 0.459, 0.129), "display_name": "Afterglow"}
    WHEELBASE = 2.75
    WHEEL_R = 0.34
    RIM_IN = 0.26
    TIRE_W = 0.28
    TIRE_SIDES = 20
    TRACK_F = 1.64
    TRACK_R = 1.62
    ARCH_R = 0.40
    WELL_X = 0.62
    FLOOR_Z = 0.12
    NOSE_Y = 2.225
    TAIL_Y = -2.575
    # Rails: floorC floorE rocker lowSide shoulder belt roofSide pillarIn roofMid crown roofC.
    # belt/roofSide = the fender pod tops, pillarIn = the valley at the canopy base,
    # roofMid..roofC = canopy (cabin) or the nose / engine deck.
    KEYS = [
        (-2.575, [(0, .34, .04), (.55, .34, .04), (.82, .35, .02), (.90, .40), (.94, .62), (.89, .85), (.76, .87),
                  (.62, .72), (.40, .715), (.20, .715), (0, .715)]),
        (-2.40, [(0, .28), (.55, .28), (.86, .29), (.95, .36), (.975, .64), (.92, .86), (.77, .88), (.62, .74),
                 (.40, .73), (.20, .735), (0, .74)]),
        (-1.95, [(0, .16), (.55, .16), (.87, .15), (.96, .24), (.99, .72), (.93, .84), (.77, .85), (.62, .76),
                 (.40, .765), (.20, .77), (0, .775)]),
        (-1.375, [(0, .12), (.55, .12), (.87, .13), (.96, .22), (.99, .79), (.93, .88), (.77, .89), (.62, .77),
                  (.40, .79), (.20, .80), (0, .81)]),
        (-0.95, [(0, .12), (.55, .12), (.86, .13), (.94, .22), (.975, .70), (.92, .82), (.76, .83), (.62, .78),
                 (.42, .86), (.20, .88), (0, .89)]),
        (-0.45, [(0, .12), (.55, .12), (.86, .13), (.92, .22), (.955, .58), (.91, .72), (.77, .74), (.64, .72),
                 (.52, .98), (.28, 1.08), (0, 1.10)]),
        (0.35, [(0, .12), (.55, .12), (.86, .13), (.92, .22), (.955, .56), (.91, .70), (.77, .72), (.645, .70),
                (.55, 1.04), (.30, 1.11), (0, 1.12)]),
        (1.20, [(0, .12), (.55, .12), (.86, .13), (.93, .22), (.97, .66), (.925, .80), (.775, .81), (.63, .66),
                (.46, .62), (.24, .60), (0, .595)]),
        (1.375, [(0, .12), (.55, .12), (.87, .13), (.955, .24), (.985, .79), (.93, .88), (.775, .89), (.62, .66),
                 (.40, .56), (.20, .54), (0, .53)]),
        (1.90, [(0, .14), (.55, .14), (.86, .15), (.93, .24), (.97, .68), (.91, .76), (.76, .77), (.60, .56),
                (.40, .47), (.20, .45), (0, .445)]),
        (2.225, [(0, .16, -.04), (.55, .16, -.04), (.80, .17, -.02), (.86, .24), (.90, .52), (.86, .58),
                 (.72, .59), (.58, .45), (.40, .39), (.20, .375), (0, .37)]),
    ]
    REGIONS = {"windscreen": (0.35, 1.20), "canopy_side": (-0.40, 1.20), "roof": (-0.45, 0.35),
               "side_glass": (0.0, 0.0), "rear_glass": (0.0, 0.0)}
    MIRROR = (0.78, 0.98, 0.78)
    EYE = (-0.33, 0.05, 0.90)
    CABIN = (-0.55, 1.20)
    DASH = {"y_front": 1.15, "y_rear": 0.72, "top": 0.74, "bottom": 0.50}
    STEER = {"r": 0.17, "thick": 0.024, "spokes": 2, "tilt": -0.30, "sides": 20, "flat": 0.66,
             "pos": (-0.33, 0.64, 0.56)}
    SEAT = {"y": -0.15, "cushion_z": 0.24, "back_top": 0.80, "w": 0.46}
    INTERIOR = dict(kit.LoftCar.INTERIOR, liner="ink", door="ink", floor="ink", dash_top="ink", dash_face="asphalt",
                    seat="asphalt", seat_accent="brand_orange", wheel="ink", spoke="steel_dark", hub="ink",
                    accent="brand_orange", console="ink", strip="screen")
    GAUGE_W = 0.26

    SKIRT_Z = 0.40      # the rear skirt's lower edge
    HEAD_X = 0.75
    HEAD_W = 0.17
    BAR_H = 0.04
    BAR_GAP = 0.02
    HEAD_Z = 0.43
    C_X = (0.50, 0.84)
    C_Z = (0.50, 0.70)
    C_T = 0.032

    # ---------------------------------------------------------------- body

    def build(self):
        orig = kit.Loft
        kit.Loft = ProfileLoft      # body, inner cabin shell and LOD1 all loft through it
        try:
            return super().build()
        finally:
            kit.Loft = orig

    def body_material(self, y0, y1, j, arch):
        ym = (y0 + y1) / 2
        if j in (S_FLOOR, S_TUCK):
            return "trim_ink"
        if j == S_SILL:
            return "trim_ink" if arch else "paint_shade"
        if j in (S_SIDE, S_UPPER, S_WINDOW, S_PILLAR):
            return "paint"
        if j == S_TOP_OUT:
            return "glass" if self.region("canopy_side", ym) else "paint"
        if self.region("windscreen", ym):
            return "glass"
        return "paint"

    def fan_caps(self, b):
        st = self.main_loft().stations(self.arch_ys())
        for (y, pts, _), facing, (cx, cz) in ((st[0], -1, (0.50, 0.52)), (st[-1], 1, (0.50, 0.30))):
            ring = list(pts) + [(0.0, pts[-1][1], pts[-1][2])]
            c = (cx, y, cz)
            for a, b_ in zip(ring, ring[1:] + ring[:1]):
                b.face([c, a, b_], "paint_shade", (0, facing, 0))

    def door_mirror(self, b):
        """Camera-pod mirrors on stalks from the front fender pods (inside the body width)."""
        mx, my, mz = self.MIRROR
        b.box((mx, my, mz + 0.02), (0.018, 0.03, 0.08), "trim_ink", skip=("-z",))
        b.box((mx + 0.015, my, mz + 0.085), (0.07, 0.12, 0.05), "paint", {"-y": "trim_ink"})

    def pod_top_z(self, y, x):
        r = self.station(y)
        (xb, zb, _), (xs, zs, _) = r[5], r[6]
        t = (x - xs) / (xb - xs) if xb != xs else 0.0
        return zs + (zb - zs) * t

    def details(self, b):
        ny, ty = self.NOSE_Y, self.TAIL_Y
        self.fan_caps(b)
        # Split splitter: a dark plate ahead of the nose, the halves apart at the centre.
        b.box((0.49, ny - 0.10, 0.115), (0.78, 0.30, 0.03), "trim_ink")
        # Dark intake mouth between the pods, under the nose.
        b.face([(0.0, ny + 0.004, 0.20), (0.52, ny + 0.004, 0.20), (0.52, ny + 0.004, 0.33), (0.0, ny + 0.004, 0.33)],
               "trim_ink", (0, 1, 0))
        # Headlamp housings: dark panels behind the vertical stacks.
        hz0 = self.HEAD_Z - 1.5 * self.BAR_H - self.BAR_GAP - 0.02
        hz1 = self.HEAD_Z + 1.5 * self.BAR_H + self.BAR_GAP + 0.02
        hx0, hx1 = self.HEAD_X - self.HEAD_W / 2 - 0.02, self.HEAD_X + self.HEAD_W / 2 + 0.02
        b.face([(hx0, ny + 0.004, hz0), (hx1, ny + 0.004, hz0), (hx1, ny + 0.004, hz1), (hx0, ny + 0.004, hz1)],
               "trim_ink", (0, 1, 0))
        # Louvres on top of the front fender pods (over the wheel).
        for i in range(5):
            y = self.axles[0] + 0.20 - i * 0.09
            x0, x1 = 0.79, 0.90
            z0, z1 = self.pod_top_z(y, x0) + 0.004, self.pod_top_z(y, x1) + 0.004
            b.face([(x0, y, z0), (x1, y, z1), (x1, y - 0.045, z1), (x0, y - 0.045, z0)], "trim_ink", (0, 0, 1))
        # Side intake behind the door (mid-engine air), a dark scoop face.
        for (ya, yb_) in ((-0.50, -1.02),):
            za, zb = 0.36, 0.58
            xa, xb = self.side_x(ya, za) + 0.004, self.side_x(yb_, zb) + 0.004
            b.face([(xa, ya, za), (self.side_x(ya, zb) + 0.004, ya, zb), (xb, yb_ + 0.12, zb),
                    (self.side_x(yb_, za) + 0.004, yb_, za)], "trim_ink", (1, 0, 0))
        self.rear_skirt(b)
        self.fin_and_wing(b)
        # Diffuser: dark lower tail panel and fins under the ramp.
        b.face([(0.86, ty - 0.004, 0.34), (0.0, ty - 0.004, 0.34), (0.0, ty - 0.004, 0.46), (0.86, ty - 0.004, 0.46)],
               "trim_ink", (0, -1, 0))
        for fx in (0.14, 0.34, 0.54):
            pts = []
            for y in (-1.95, -2.2, -2.40, ty):
                zf = self.station(y)[0][1]
                pts.append((y, zf))
            top = [(fx, y, zf) for y, zf in pts]
            bot = [(fx, ty, 0.13), (fx, -1.95, 0.13)]
            b.face(top + bot, "trim_ink", (1, 0, 0))
            b.face([(p[0] - 0.012, p[1], p[2]) for p in reversed(top + bot)], "trim_ink", (-1, 0, 0))
        # Exhaust pair in the diffuser panel.
        pipe = MeshBuilder()
        pipe.cylinder_x((0, 0, 0), 0.04, -0.03, 0.05, 8, "trim_steel", cap_mat="trim_ink")
        b.extend(pipe.transformed(lambda p: (p[1], p[0], p[2])), (0.16, ty - 0.02, 0.40))

    def rear_skirt(self, b):
        """A paint panel over the rear wheel opening down to SKIRT_Z, standing just outside the body side."""
        ay = self.axles[1]
        n = 12
        top = []
        for i in range(n + 1):
            y = ay - self.ARCH_R + 2 * self.ARCH_R * i / n
            z, _ = self.arch_open(y)
            z = min(z if z is not None else self.SKIRT_Z, self.station(y)[4][1] - 0.05) + 0.02
            top.append((y, max(z, self.SKIRT_Z + 0.02)))
        # the outer skin follows the body side, a hair proud
        xo = [self.station(y)[3][0] + 0.022 for y, _ in top]
        outer = [(xo[i], y, z) for i, (y, z) in enumerate(top)]
        y0, y1 = top[0][0], top[-1][0]
        outer_poly = [(xo[0], y0, self.SKIRT_Z)] + outer + [(xo[-1], y1, self.SKIRT_Z)]
        b.face(outer_poly, "paint", (1, 0, 0))
        inner_poly = [(p[0] - 0.025, p[1], p[2]) for p in reversed(outer_poly)]
        b.face(inner_poly, "trim_ink", (-1, 0, 0))
        b.face([(xo[0] - 0.025, y0, self.SKIRT_Z), (xo[-1] - 0.025, y1, self.SKIRT_Z), (xo[-1], y1, self.SKIRT_Z),
                (xo[0], y0, self.SKIRT_Z)], "paint_dark", (0, 0, -1))
        for (x, y, z), s in ((outer_poly[0], -1), (outer_poly[-1], 1)):
            b.face([(x - 0.025, y, self.SKIRT_Z), (x, y, self.SKIRT_Z), (x, y, z + 0.08), (x - 0.025, y, z + 0.08)],
                   "paint_dark", (0, s, 0))

    FIN_T = 0.013   # half thickness of the shark fin

    def fin_and_wing(self, b):
        """Right half of the shark fin (its +X face and half its top) and of the wing."""
        t = self.FIN_T
        top = [(-0.42, 1.10), (-1.0, 1.085), (-1.6, 1.06), (-2.10, 1.035), (-2.40, 1.02)]
        base = [(y, self.station(y)[10][1] - 0.01) for y in (-2.40, -2.10, -1.6, -1.0, -0.42)]
        poly = [(t, y, z) for y, z in top] + [(t, y, z) for y, z in base]
        b.face(poly, "paint", (1, 0, 0))
        for (ya, za), (yb, zb) in zip(top, top[1:]):
            b.face([(0.0, ya, za), (t, ya, za), (t, yb, zb), (0.0, yb, zb)], "paint", (0, 0, 1))
        b.face([(0.0, -2.40, 1.02), (0.0, -2.40, base[0][1]), (t, -2.40, base[0][1]), (t, -2.40, 1.02)], "paint",
               (0, -1, 0))
        # Wing: an airfoil plate between the rear pods, meeting the fin.
        wy0, wy1 = -2.555, -2.26
        z0, z1, zl = 0.925, 0.985, 0.955
        xw = 0.80
        b.face([(0.0, wy1, z1), (xw, wy1, z1), (xw, wy0, zl + 0.012), (0.0, wy0, zl + 0.012)], "trim_ink", (0, 0, 1))
        b.face([(0.0, wy0, zl + 0.012), (xw, wy0, zl + 0.012), (xw, wy0, z0), (0.0, wy0, z0)], "paint", (0, -1, 0))
        b.face([(0.0, wy0, z0), (xw, wy0, z0), (xw, wy1, z0 + 0.02), (0.0, wy1, z0 + 0.02)], "trim_ink", (0, 0, -1))
        b.face([(0.0, wy1, z0 + 0.02), (xw, wy1, z0 + 0.02), (xw, wy1, z1), (0.0, wy1, z1)], "paint", (0, 1, 0))
        # End plates standing on the pods.
        pz = self.pod_top_z(-2.45, xw)
        for x, s in ((xw, 1), (xw - 0.02, -1)):
            b.face([(x, wy1 + 0.02, pz - 0.02), (x, wy0 - 0.01, pz - 0.02), (x, wy0 - 0.01, z1 + 0.02),
                    (x, wy1 + 0.02, z1 + 0.02)], "paint", (s, 0, 0))
        b.face([(xw - 0.02, wy1 + 0.02, z1 + 0.02), (xw - 0.02, wy0 - 0.01, z1 + 0.02), (xw, wy0 - 0.01, z1 + 0.02),
                (xw, wy1 + 0.02, z1 + 0.02)], "paint", (0, 0, 1))
        b.face([(xw - 0.02, wy0 - 0.01, pz - 0.02), (xw, wy0 - 0.01, pz - 0.02), (xw, wy0 - 0.01, z1 + 0.02),
                (xw - 0.02, wy0 - 0.01, z1 + 0.02)], "paint", (0, -1, 0))

    def lod1_extras(self, b):
        self.fin_and_wing(b)
        self.fan_caps(b)
        ny = self.NOSE_Y
        b.box((0.49, ny - 0.10, 0.115), (0.78, 0.30, 0.03), "trim_ink")

    def rim(self):
        """Ten thin spokes in dark alloy with a polished lip and a centre-lock hub."""
        return kit.star_rim(self.TIRE_W / 2 + 0.008, self.RIM_IN, spokes=10, spoke_w=(0.016, 0.011),
                            face="trim_steel_dark", dark="trim_ink", hub="trim_steel", lip="trim_steel",
                            hub_r=0.055, depth=0.05)

    # ---------------------------------------------------------------- lights

    def lights(self, rig):
        ny, ty = self.NOSE_Y, self.TAIL_Y
        ly = ny + 0.015
        lt = ty - 0.015
        for side, s in (("L", -1), ("R", 1)):
            # Vertical headlamp stack: three bars.
            hb = MeshBuilder()
            x0, x1 = sorted((s * (self.HEAD_X - self.HEAD_W / 2), s * (self.HEAD_X + self.HEAD_W / 2)))
            for k in (-1, 0, 1):
                z = self.HEAD_Z + k * (self.BAR_H + self.BAR_GAP)
                kit.rect_y(x0, x1, z - self.BAR_H / 2, z + self.BAR_H / 2, ly, "lamp_head", 1, hb)
            rig.light("headlight_" + side, hb, (s * self.HEAD_X, ly, self.HEAD_Z))
            # Front blinker: an amber bar under the stack.
            fb = MeshBuilder()
            fz = self.HEAD_Z - 1.5 * self.BAR_H - self.BAR_GAP - 0.06
            kit.rect_y(x0, x1, fz - 0.022, fz + 0.022, ly, "signal_blinker", 1, fb)
            rig.light("blinker_F" + side, fb, (s * self.HEAD_X, ly, fz))
            # Tail: a thin C (open toward the centre) plus half the centre strip.
            cx0, cx1 = sorted((s * self.C_X[0], s * self.C_X[1]))
            ox0, ox1 = sorted((s * (self.C_X[1] - self.C_T), s * self.C_X[1]))
            z0, z1, t = self.C_Z[0], self.C_Z[1], self.C_T
            zc = (z0 + z1) / 2
            sx0, sx1 = sorted((s * 0.05, s * (self.C_X[0] - 0.04)))

            def c_shape(y, mat, bb, strip):
                kit.rect_y(cx0, cx1, z1 - t, z1, y, mat, -1, bb)
                kit.rect_y(cx0, cx1, z0, z0 + t, y, mat, -1, bb)
                kit.rect_y(ox0, ox1, z0 + t, z1 - t, y, mat, -1, bb)
                if strip:
                    kit.rect_y(sx0, sx1, zc - 0.014, zc + 0.014, y, mat, -1, bb)
                return bb
            tb = c_shape(lt, "lamp_tail", MeshBuilder(), True)
            rig.light("taillight_" + side, tb, (s * sum(self.C_X) / 2, lt, zc))
            bb = c_shape(lt - 0.005, "signal_brake", MeshBuilder(), False)
            rig.light("brake_" + side, bb, (s * sum(self.C_X) / 2, lt - 0.005, zc))
            # Rear blinker: an amber core inside the C, a gap from its bars.
            rb = MeshBuilder()
            bx0, bx1 = sorted((s * (self.C_X[0] + 0.07), s * (self.C_X[1] - t - 0.035)))
            kit.rect_y(bx0, bx1, zc - 0.03, zc + 0.03, lt, "signal_blinker", -1, rb)
            rig.light("blinker_R" + side, rb, (s * (self.C_X[0] + self.C_X[1]) / 2, lt, zc))
        rv = MeshBuilder()
        for s in (-1, 1):
            x0, x1 = sorted((s * 0.26, s * 0.40))
            kit.rect_y(x0, x1, 0.54, 0.575, lt, "signal_reverse", -1, rv)
        rig.light("reverse", rv, (0.0, lt, 0.557))

    def markers(self):
        m = super().markers()
        ty = self.TAIL_Y
        m["exhaust_L"] = (-0.16, ty - 0.08, 0.40)
        m["exhaust_R"] = (0.16, ty - 0.08, 0.40)
        return m

    # ---------------------------------------------------------------- interior

    def dash(self, b):
        """A low racing dash, only as wide as the canopy (the pods are outside it)."""
        d = self.DASH
        yf, yr, top, bot = d["y_front"], d["y_rear"], d["top"], d["bottom"]
        xw = self.station(yr)[7][0] - 0.05
        ws_z = self.top_z(yf, 7)
        b.face([(0, yf + 0.02, ws_z - 0.01), (0, yr, top), (xw, yr, top), (xw, yf + 0.02, ws_z - 0.01)],
               self.imat("dash_top"), (0, 0, 1))
        b.face([(0, yr, top), (0, yr, bot), (xw, yr, bot), (xw, yr, top)], self.imat("dash_face"), (0, -1, 0))
        b.face([(xw, yr, top), (xw, yr, bot), (xw, yf, bot), (xw, yf + 0.02, ws_z - 0.01)], self.imat("dash_face"),
               (1, 0, 0))
        b.face([(0, yr, bot), (0, yf, bot), (xw, yf, bot), (xw, yr, bot)], self.imat("dash_face"), (0, 0, -1))
        # Screen strip across the dash face.
        b.face([(0, yr - 0.006, top - 0.085), (xw - 0.03, yr - 0.006, top - 0.085),
                (xw - 0.03, yr - 0.006, top - 0.035), (0, yr - 0.006, top - 0.035)], "interior_screen", (0, -1, 0))

    def rear_mirror(self, b):
        y = 0.42
        z = self.top_z(y, 10) - 0.10
        b.box((0.0, y, z), (0.19, 0.025, 0.05), self.imat("console"), {"-y": "interior_steel_dark"})
        b.box((0.0, y + 0.02, z + 0.05), (0.015, 0.015, 0.05), self.imat("console"))

    def steering_wheel(self):
        """A yoke: the rim ring flattened top and bottom, two spokes, a hub, an orange
        12 o'clock mark. Still closed all round, so it reads at any steering angle."""
        s = self.STEER
        r, t, n, flat = s["r"], s["thick"], s["sides"], s["flat"]
        b = MeshBuilder()
        rim_m, spoke_m, hub_m, acc_m = (self.imat(k) for k in ("wheel", "spoke", "hub", "accent"))

        def P(rad, a, y):
            x, z = rad * math.cos(a), rad * math.sin(a)
            lim = r * flat + (rad - r)
            z = max(-lim, min(lim, z))
            return (x * 1.12, y, z)
        for i in range(n):
            a0, a1 = 2 * math.pi * i / n, 2 * math.pi * (i + 1) / n
            am = (a0 + a1) / 2
            m = acc_m if abs(math.remainder(am - math.pi / 2, 2 * math.pi)) < math.pi / n else rim_m
            for (r0, y0), (r1, y1) in (((r - t, -t / 2), (r + t, -t / 2)), ((r + t, -t / 2), (r + t, t / 2)),
                                       ((r + t, t / 2), (r - t, t / 2)), ((r - t, t / 2), (r - t, -t / 2))):
                pts = [P(r0, a0, y0), P(r1, a0, y1), P(r1, a1, y1), P(r0, a1, y0)]
                mid = P((r0 + r1) / 2, am, (y0 + y1) / 2)
                ctr = P(r, am, 0.0)
                b.face(pts, m, v_sub(mid, ctr) if (r0 != r1 or y0 != y1) else None)
        hub = MeshBuilder()
        hr = r * 0.34
        hub.lathe_x([(-0.03, hr), (0.02, hr), (0.03, hr * 0.6), (0.03, 0.0)], 10, hub_m)
        b.extend(hub.transformed(lambda p: (p[1] * 1.3, -p[0], p[2] * 0.8)))
        for a in (0.0, math.pi):
            ca = math.cos(a)
            w = 0.035
            r0, r1 = hr * 1.2, (r - t * 0.6) * 1.12
            pts = [(r0 * ca, -0.012, -w), (r1 * ca, -0.004, -w), (r1 * ca, -0.004, w), (r0 * ca, -0.012, w)]
            b.face(pts, spoke_m, (0, -1, 0))
            b.face([(p[0], p[1] + 0.012, p[2]) for p in reversed(pts)], spoke_m, (0, 1, 0))
        return b


CAR = Afterglow

if __name__ == "__main__":
    kit.run(CAR)
