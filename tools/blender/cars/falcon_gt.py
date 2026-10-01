"""Falcon GT, the starter hero car (docs/ART_PRODUCTION.md §4.1.2 slot 1, §4.1.5).

Early-70s fastback GT coupe: long hood, short deck, a fastback roof running into a
small ducktail, slight coke-bottle hips. Twin round headlamps in a dark grille bar,
bonnet bulge, side vents behind the front wheels, ducktail spoiler. Taillights: three
horizontal bars per side in a full-width black panel. Interior: a wood-look (bark)
dash strip, a three-spoke wheel, twin round gauges in a hooded binnacle.

CarDef (data/cars/falcon_gt.tres): 4.5 x 1.9 x 1.25 m, wheelbase 2.65.

  (inside Blender)  import falcon_gt; falcon_gt.FalconGT().build()
  blender -b --python tools/blender/cars/falcon_gt.py -- [--export] [--render] [--save]
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import wb_carkit as kit  # noqa: E402
from wb_carkit import MeshBuilder, disc_y, ring_pts  # noqa: E402


class FalconGT(kit.LoftCar):
    CAR_ID = "falcon_gt"
    WHEELBASE = 2.65
    WHEEL_R = 0.33
    TIRE_W = 0.235
    TRACK_F = 1.56
    TRACK_R = 1.58
    ARCH_R = 0.385
    NOSE_Y = 2.20
    TAIL_Y = -2.30
    # Rounded sections: the door side is a barrel (door bottom -> a soft shoulder that
    # rises over the wheels and dips at the doors -> tumblehome into the glass), the
    # fenders roll over into a crowned hood with a soft bulge, the roof is crowned, and
    # the nose and tail pull in to round the corners in plan.
    KEYS = [
        (TAIL_Y, [(0, .36, .05), (.48, .36, .05), (.72, .37, .03), (.78, .45), (.815, .80), (.78, .94), (.69, .99),
                  (.60, .995), (.35, 1.0), (.18, 1.0), (0, 1.0)]),
        (-2.24, [(0, .31), (.54, .31), (.79, .31), (.835, .42), (.865, .80), (.835, .95), (.73, .998), (.63, 1.003),
                 (.35, 1.003), (.18, 1.003), (0, 1.003)]),
        (-2.10, [(0, .25), (.57, .25), (.85, .26), (.89, .40), (.925, .80), (.885, .94), (.75, .968), (.64, .968),
                 (.35, .968), (.18, .968), (0, .968)]),
        (-1.80, [(0, .19), (.58, .18), (.87, .21), (.905, .37), (.948, .80), (.90, .935), (.76, .975), (.66, .98),
                 (.35, .985), (.18, .985), (0, .985)]),
        (-1.55, [(0, .17), (.58, .17), (.86, .20), (.905, .36), (.952, .80), (.90, .93), (.73, 1.02), (.65, 1.03), (.36, 1.045), (.18, 1.05),
                 (0, 1.05)]),
        (-1.05, [(0, .17), (.58, .17), (.86, .20), (.895, .36), (.94, .77), (.885, .915), (.69, 1.13), (.62, 1.145), (.36, 1.165), (.18, 1.17),
                 (0, 1.17)]),
        (-0.50, [(0, .17), (.58, .17), (.86, .20), (.875, .36), (.915, .72), (.865, .90), (.655, 1.195), (.595, 1.222), (.36, 1.243), (.18, 1.25),
                 (0, 1.25)]),
        (-0.08, [(0, .17), (.58, .17), (.86, .20), (.87, .36), (.91, .71), (.862, .895), (.65, 1.19), (.59, 1.215), (.35, 1.237), (.18, 1.243),
                 (0, 1.245)]),
        (0.52, [(0, .17), (.58, .17), (.86, .20), (.875, .36), (.915, .73), (.865, .885), (.81, .892), (.73, .897), (.34, .90), (.18, .90),
                (0, .90)]),
        (0.62, [(0, .17), (.58, .17), (.86, .20), (.88, .36), (.925, .78), (.885, .83), (.80, .868), (.66, .862), (.31, .868), (.22, .922),
                (0, .932)]),
        (1.00, [(0, .17), (.58, .17), (.86, .20), (.885, .37), (.928, .785), (.89, .83), (.80, .866), (.66, .86), (.31, .865), (.22, .912),
                (0, .922)]),
        (1.70, [(0, .19), (.58, .19), (.86, .21), (.88, .38), (.92, .775), (.88, .815), (.79, .845), (.66, .84),
                (.31, .845), (.22, .882), (0, .89)]),
        (1.95, [(0, .24), (.57, .24), (.835, .27), (.865, .39), (.90, .765), (.86, .80), (.775, .828), (.645, .826),
                (.31, .83), (.23, .857), (0, .862)]),
        (2.10, [(0, .29), (.55, .29), (.79, .31), (.825, .40), (.85, .75), (.81, .785), (.73, .805), (.61, .806),
                (.30, .81), (.24, .822), (0, .826)]),
        (NOSE_Y, [(0, .33, -.05), (.50, .33, -.05), (.73, .34, -.03), (.77, .40), (.785, .72), (.755, .75),
                  (.69, .762), (.59, .765), (.30, .768), (.24, .775), (0, .778)]),
    ]
    # Crisp lines only where a real car has them: the cowl (windscreen base), the floor
    # edge, the rocker and the door bottom. The window line is a material edge.
    CREASE_Y = (0.52,)
    SHARP_RAILS = (1, 2, 3)
    REGIONS = {"windscreen": (-0.08, 0.52), "rear_glass": (-1.55, -0.50), "side_glass": (-1.20, 0.52)}
    MIRROR = (0.872, 0.30, 0.93)
    EYE = (-0.36, -0.36, 0.965)
    CABIN = (-1.15, 0.52)
    DASH = {"y_front": 0.52, "y_rear": 0.36, "top": 0.815, "bottom": 0.52}
    STEER = {"r": 0.185, "thick": 0.022, "spokes": 3, "tilt": -0.42, "sides": 20}
    SEAT = {"y": -0.42, "cushion_z": 0.32, "back_top": 0.93, "w": 0.50}
    INTERIOR = dict(kit.LoftCar.INTERIOR, strip="bark", seat="asphalt", seat_accent="soil_dark", spoke="steel",
                    wheel="bark", door="asphalt", accent="cream")

    GRILLE_Z = (0.46, 0.70)
    HEAD_Z = 0.58
    HEAD_R = 0.078
    HEAD_X = (0.45, 0.635)
    TAIL_PANEL_Z = (0.62, 0.935)
    TAIL_PANEL_X = 0.775
    BAR_H = 0.056
    BAR_GAP = 0.036
    BAR_X = (0.27, 0.62)
    TAIL_BLINK_X = (0.67, 0.75)
    BUMPER_F_Z = (0.355, 0.45)
    BUMPER_R_Z = (0.42, 0.52)

    def details(self, b):
        fy = self.NOSE_Y + 0.004
        gz0, gz1 = self.GRILLE_Z
        b.face([(0, fy, gz0), (0.74, fy, gz0), (0.74, fy, gz1), (0, fy, gz1)], "trim_ink", (0, 1, 0))
        # Chrome bezels around each round headlamp (the lens is the light node).
        for hx in self.HEAD_X:
            outer = ring_pts(hx, self.HEAD_Z, self.HEAD_R + 0.018, 12, fy + 0.012)
            inner = ring_pts(hx, self.HEAD_Z, self.HEAD_R, 12, fy + 0.012)
            back = ring_pts(hx, self.HEAD_Z, self.HEAD_R + 0.018, 12, fy)
            for i in range(12):
                k = (i + 1) % 12
                b.face([outer[i], outer[k], inner[k], inner[i]], "trim_steel", (0, 1, 0))
                b.face([back[i], back[k], outer[k], outer[i]], "trim_steel",
                       (outer[i][0] - hx, 0, outer[i][2] - self.HEAD_Z))
        # Front bumper blade, wrapping the corner.
        z0, z1 = self.BUMPER_F_Z
        ny = self.NOSE_Y
        b.box((0.37, ny + 0.03, (z0 + z1) / 2), (0.74, 0.06, z1 - z0), "trim_steel", skip=("-x", "-y"))
        # Wrap: an angled end following the rounded corner back into the fender.
        b.face([(0.74, ny + 0.06, z0), (0.79, ny - 0.07, z0), (0.79, ny - 0.07, z1), (0.74, ny + 0.06, z1)],
               "trim_steel", (1, 0.4, 0))
        # Three slanted vents behind the front wheel.
        for i in range(3):
            y0 = self.axles[0] - self.ARCH_R - 0.10 - i * 0.07
            zb, zt = 0.47, 0.64
            x = self.surface_x(y0, 0.55) + 0.004
            b.face([(x, y0, zb), (x, y0 - 0.035, zb), (x, y0 - 0.005, zt), (x, y0 + 0.03, zt)], "trim_ink", (1, 0, 0))
        # Rear bumper (outer half; the plate sits between the halves) and the black tail panel.
        z0, z1 = self.BUMPER_R_Z
        ty = self.TAIL_Y
        b.box((0.505, ty - 0.03, (z0 + z1) / 2), (0.51, 0.06, z1 - z0), "trim_steel", skip=("-x",))
        b.face([(0.76, ty - 0.06, z0), (0.76, ty - 0.06, z1), (0.80, ty + 0.06, z1), (0.80, ty + 0.06, z0)],
               "trim_steel", (1, -0.4, 0))
        tz0, tz1 = self.TAIL_PANEL_Z
        px = self.TAIL_PANEL_X
        b.face([(px, ty - 0.004, tz0), (0, ty - 0.004, tz0), (0, ty - 0.004, tz1), (px, ty - 0.004, tz1)],
               "trim_ink", (0, -1, 0))

    def surface_x(self, y, z):
        """The smooth body side's x at (y, z) (lowSide..belt), for flush details."""
        lo = self.main_loft()
        rails, _ = self.arch_rails(y, lo.station(y))
        P = [(x, y + dy, zz) for (x, zz, dy) in rails]
        subs = [1] * (len(P) - 1)
        subs[kit.S_SIDE] = subs[kit.S_UPPER] = 24
        pts = lo._curve(P, subs)
        lo_i = sum(subs[:kit.S_SIDE])
        hi_i = lo_i + subs[kit.S_SIDE] + subs[kit.S_UPPER]
        for a, b in zip(pts[lo_i:hi_i], pts[lo_i + 1:hi_i + 1]):
            if min(a[2], b[2]) <= z <= max(a[2], b[2]) and a[2] != b[2]:
                t = (z - a[2]) / (b[2] - a[2])
                return a[0] + (b[0] - a[0]) * t
        return self.side_x(y, z)

    def lod1_extras(self, b):
        fy = self.NOSE_Y + 0.004
        b.face([(0, fy, self.GRILLE_Z[0]), (0.74, fy, self.GRILLE_Z[0]), (0.74, fy, self.GRILLE_Z[1]),
                (0, fy, self.GRILLE_Z[1])], "trim_ink", (0, 1, 0))
        tz0, tz1 = self.TAIL_PANEL_Z
        ty = self.TAIL_Y - 0.004
        px = self.TAIL_PANEL_X
        b.face([(px, ty, tz0), (0, ty, tz0), (0, ty, tz1), (px, ty, tz1)], "trim_ink", (0, -1, 0))
        z0, z1 = self.BUMPER_F_Z
        b.box((0.37, self.NOSE_Y + 0.03, (z0 + z1) / 2), (0.74, 0.06, z1 - z0), "trim_steel", skip=("-x", "-y"))
        z0, z1 = self.BUMPER_R_Z
        b.box((0.38, self.TAIL_Y - 0.03, (z0 + z1) / 2), (0.76, 0.06, z1 - z0), "trim_steel", skip=("-x", "+y"))

    def center_details(self, b):
        z0, z1 = self.BUMPER_R_Z
        ry = self.TAIL_Y - 0.012
        b.face([(0.25, ry, z0 - 0.03), (-0.25, ry, z0 - 0.03), (-0.25, ry, z1 + 0.03), (0.25, ry, z1 + 0.03)],
               "trim_cream", (0, -1, 0))
        for sx in (-1, 1):
            pipe = MeshBuilder()
            pipe.cylinder_x((0, 0, 0), 0.036, -0.05, 0.10, 8, "trim_steel", cap_mat="trim_ink")
            b.extend(pipe.transformed(lambda p: (p[1], p[0], p[2])), (sx * 0.46, self.TAIL_Y - 0.02, 0.27))

    def lights(self, rig):
        ny, ty = self.NOSE_Y, self.TAIL_Y
        ly = ny + 0.016
        zc = sum(self.TAIL_PANEL_Z) / 2
        lt = ty - 0.018
        for side, s in (("L", -1), ("R", 1)):
            hb = MeshBuilder()
            for hx in self.HEAD_X:
                disc_y(s * hx, self.HEAD_Z, self.HEAD_R, 12, ly, "lamp_head", 1, hb)
            rig.light("headlight_" + side, hb, (s * sum(self.HEAD_X) / 2, ly, self.HEAD_Z))
            fb = MeshBuilder()
            fb.box((s * 0.66, ny - 0.035, 0.305), (0.17, 0.02, 0.08), "signal_blinker", skip=("-y",))
            rig.light("blinker_F" + side, fb, (s * 0.66, ny - 0.025, 0.305))
            tb, bb = MeshBuilder(), MeshBuilder()
            x0, x1 = sorted((s * self.BAR_X[0], s * self.BAR_X[1]))
            for k in (-1, 0, 1):
                z = zc + k * (self.BAR_H + self.BAR_GAP)
                kit.rect_y(x0, x1, z - self.BAR_H / 2, z + self.BAR_H / 2, lt, "lamp_tail", -1, tb)
                kit.rect_y(x0, x1, z - self.BAR_H / 2, z + self.BAR_H / 2, lt - 0.005, "signal_brake", -1, bb)
            cx = s * sum(self.BAR_X) / 2
            rig.light("taillight_" + side, tb, (cx, lt, zc))
            rig.light("brake_" + side, bb, (cx, lt - 0.005, zc))
            rb = MeshBuilder()
            x0, x1 = sorted((s * self.TAIL_BLINK_X[0], s * self.TAIL_BLINK_X[1]))
            h = 2 * (self.BAR_H + self.BAR_GAP) + self.BAR_H
            kit.rect_y(x0, x1, zc - h / 2, zc + h / 2, lt, "signal_blinker", -1, rb)
            rig.light("blinker_R" + side, rb, (s * sum(self.TAIL_BLINK_X) / 2, lt, zc))
        rv = MeshBuilder()
        for s in (-1, 1):
            x0, x1 = sorted((s * 0.06, s * 0.20))
            kit.rect_y(x0, x1, zc - 0.035, zc + 0.035, lt, "signal_reverse", -1, rv)
        rig.light("reverse", rv, (0.0, lt, zc))

    def markers(self):
        m = super().markers()
        m["exhaust_L"] = (-0.46, self.TAIL_Y - 0.12, 0.27)
        m["exhaust_R"] = (0.46, self.TAIL_Y - 0.12, 0.27)
        return m


CAR = FalconGT

if __name__ == "__main__":
    kit.run(CAR)
