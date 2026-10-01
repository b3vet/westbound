"""Needle, slot 8 (100 lifetime threads) (docs/ART_PRODUCTION.md §4.1.2, §4.1.5).

A late-50s streamliner barchetta: a needle nose, separate pontoon fenders, a very
tapered tail and the narrowest waist in the roster. Closed for now (§7.6 Q3 default):
a low bubble canopy over the cockpit and a head-fairing spine running back from it to
the tail. Tiny oval grille on the nose cone, exposed-look front suspension arms in the
dark recess between the cone and the fenders, covered round headlamps in the fender
fronts, a white racing roundel with a red ring on each door. Taillights: one round
lens per side inside a chrome jet-nozzle ring. Interior: minimal, a central gauge
pair, a wood-rim three-spoke wheel.

Proposed CarDef: 4.5 x 1.86 x 1.10 m, wheelbase 2.6, default paint white #f0ede3.

  blender -b --python tools/blender/cars/needle.py -- [--export] [--render] [--save]
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import wb_carkit as kit  # noqa: E402
import wb_palette  # noqa: E402
from wb_carkit import MeshBuilder, disc_y, ring_pts  # noqa: E402

CONE = [  # nose cone stations: y, half-width, half-height, centre z
    (1.62, 0.32, 0.21, 0.47),
    (1.95, 0.29, 0.18, 0.46),
    (2.12, 0.22, 0.13, 0.45),
    (2.25, 0.13, 0.08, 0.44),
]
CONE_SIDES = 14


class WindingLoft(kit.Loft):
    """kit.Loft with no outward hint for the half-section: its winding (stations toward
    +Y, rails floor -> roof around the outside) is already outward everywhere, while the
    kit's hint (away from x = 0, z = 0.6) flips the inner slopes of the pontoon fenders
    (concave sections)."""

    def build(self, b, extra=None):
        st = self.stations(extra)
        n = len(st[0][1])
        for (ya, a, arch0), (yb, c, arch1) in zip(st, st[1:]):
            for j in range(n - 1):
                m = self.mat_fn(ya, yb, j, arch0 and arch1)
                if m is not None:
                    b.face([a[j], c[j], c[j + 1], a[j + 1]], m)
        tail, nose = st[0][1], st[-1][1]
        if self.caps[0]:
            b.face(list(tail) + [(0.0, tail[-1][1], tail[-1][2])], self.caps[0], (0, -1, 0))
        if self.caps[1]:
            b.face(list(nose) + [(0.0, nose[-1][1], nose[-1][2])], self.caps[1], (0, 1, 0))
        return st


class Needle(kit.LoftCar):
    CAR_ID = "needle"
    CARDEF = {"length_m": 4.5, "width_m": 1.86, "height_m": 1.10, "wheelbase_m": 2.6,
              "default_paint": wb_palette.hex_to_srgb("#f0ede3"), "display_name": "Needle"}
    WHEELBASE = 2.6
    WHEEL_R = 0.32
    TIRE_W = 0.19
    RIM_IN = 0.235
    TRACK_F = 1.46
    TRACK_R = 1.48
    ARCH_R = 0.37
    WELL_X = 0.56
    FLOOR_Z = 0.16
    NOSE_Y = 2.25
    TAIL_Y = -2.25
    FENDER_Y = 1.90           # the front fender tips (the main loft ends here)
    KEYS = [
        (-2.25, [(0, .36, .10), (.30, .36, .10), (.42, .38, .07), (.52, .42), (.62, .58), (.58, .72), (.46, .74),
                 (.34, .745), (.20, .75), (.08, .78), (0, .79)]),
        (-2.10, [(0, .30), (.35, .30), (.55, .31), (.66, .38), (.74, .60), (.70, .75), (.54, .765), (.40, .77),
                 (.24, .775), (.10, .81), (0, .82)]),
        (-1.80, [(0, .22), (.50, .20), (.72, .22), (.82, .36), (.90, .68), (.83, .80), (.62, .77), (.45, .765),
                 (.26, .775), (.10, .83), (0, .845)]),
        (-1.30, [(0, .16), (.52, .16), (.76, .18), (.87, .40), (.93, .76), (.86, .835), (.63, .775), (.46, .77),
                 (.27, .785), (.10, .875), (0, .89)]),
        (-0.85, [(0, .16), (.52, .16), (.74, .18), (.83, .36), (.87, .68), (.81, .79), (.62, .775), (.46, .78),
                 (.28, .80), (.10, .95), (0, .965)]),
        (-0.50, [(0, .16), (.52, .16), (.72, .18), (.79, .34), (.82, .62), (.785, .76), (.58, .79), (.40, .85),
                 (.26, .94), (.12, 1.02), (0, 1.035)]),
        (-0.15, [(0, .16), (.52, .16), (.72, .18), (.78, .34), (.81, .60), (.78, .745), (.60, .80), (.54, .90),
                 (.40, 1.02), (.20, 1.085), (0, 1.10)]),
        (0.15, [(0, .16), (.52, .16), (.72, .18), (.78, .34), (.81, .60), (.785, .745), (.60, .79), (.50, .87),
                (.36, .955), (.18, 1.005), (0, 1.02)]),
        (0.35, [(0, .16), (.52, .16), (.72, .18), (.79, .34), (.83, .62), (.80, .75), (.60, .765), (.42, .775),
                (.28, .79), (.15, .80), (0, .805)]),
        (0.85, [(0, .16), (.52, .16), (.74, .18), (.84, .36), (.89, .70), (.83, .79), (.60, .70), (.44, .69),
                (.30, .72), (.16, .76), (0, .77)]),
        (1.30, [(0, .16), (.52, .16), (.76, .18), (.87, .40), (.93, .76), (.86, .83), (.62, .71), (.44, .675),
                (.30, .70), (.15, .735), (0, .745)]),
        (1.75, [(0, .22), (.50, .22), (.72, .25), (.83, .38), (.90, .66), (.83, .76), (.63, .67), (.45, .625),
                (.30, .645), (.15, .675), (0, .685)]),
        (1.90, [(0, .30), (.45, .30), (.64, .32), (.74, .37), (.84, .56), (.78, .66), (.62, .62), (.45, .585),
                (.30, .595), (.15, .62), (0, .63)]),
    ]
    # The canopy is one glass bubble from the cowl to the head fairing.
    REGIONS = {"canopy": (-0.50, 0.35), "windscreen": (0.15, 0.35), "side_glass": (0.0, 0.0),
               "rear_glass": (0.0, 0.0)}
    MIRROR = None
    EYE = (-0.30, -0.30, 0.97)
    CABIN = (-0.50, 0.35)
    DASH = {"y_front": 0.35, "y_rear": 0.27, "top": 0.79, "bottom": 0.52}
    STEER = {"r": 0.175, "thick": 0.017, "spokes": 3, "tilt": -0.50, "sides": 20, "pos": (-0.30, 0.17, 0.665)}
    SEAT = {"y": -0.24, "cushion_z": 0.30, "back_top": 0.80, "w": 0.44}
    INTERIOR = dict(kit.LoftCar.INTERIOR, wheel="bark", spoke="steel", hub="steel_dark", accent="cream",
                    dash_top="ink", dash_face="asphalt", seat="barn_red", seat_accent="soil_dark", door="asphalt",
                    liner="roof_slate", floor="ink")
    GAUGE_W = 0.26

    HEAD = (0.69, 0.525, 0.075)       # x, z, r (fender-front headlamp)
    NOZZLE = (0.40, 0.58, 0.075)      # x, z, lens r (tail jet nozzle)
    NOZZLE_OUT = 0.097
    NOZZLE_DEPTH = 0.06

    # ---------------------------------------------------------------- body

    def body_material(self, y0, y1, j, arch):
        ym = (y0 + y1) / 2
        if self.region("canopy", ym) and j >= kit.S_TOP_OUT:
            return "glass"
        if j in (kit.S_FLOOR, kit.S_TUCK):
            return "trim_ink"
        if j == kit.S_SILL:
            return "trim_ink" if arch else "paint_shade"
        return "paint"

    def main_loft(self):
        edges = [r[k] for r in self.REGIONS.values() for k in (0, 1)]
        # The front cap is the dark recess behind the nose cone.
        return WindingLoft(self.KEYS, self.body_material, self.arch_rails, extra_ys=self.arch_ys() + edges,
                           caps=("paint_shade", "trim_ink"))

    def details(self, b):
        fy = self.FENDER_Y + 0.002
        # Fender front (paint) over the dark recess, with a chrome bezel around the headlamp.
        b.face([(.52, fy, .32), (.64, fy, .32), (.74, fy, .37), (.84, fy, .56), (.78, fy, .66), (.62, fy, .62),
                (.52, fy, .60)], "paint", (0, 1, 0))
        hx, hz, hr = self.HEAD
        outer = ring_pts(hx, hz, hr + 0.017, 14, fy + 0.008)
        inner = ring_pts(hx, hz, hr, 14, fy + 0.008)
        back = ring_pts(hx, hz, hr + 0.017, 14, fy)
        for i in range(14):
            k = (i + 1) % 14
            b.face([outer[i], outer[k], inner[k], inner[i]], "trim_steel", (0, 1, 0))
            b.face([back[i], back[k], outer[k], outer[i]], "trim_steel", (outer[i][0] - hx, 0, outer[i][2] - hz))
        # Exposed-look front suspension: two wishbones and an upright in the recess.
        sy = self.FENDER_Y + 0.05
        for z in (0.36, 0.49):
            b.box((0.44, sy, z), (0.34, 0.03, 0.028), "trim_steel_dark", skip=("-y",))
        b.box((0.62, sy, 0.425), (0.035, 0.035, 0.17), "trim_steel_dark", skip=("-y",))
        b.box((0.33, sy + 0.01, 0.425), (0.05, 0.05, 0.10), "trim_steel", skip=("-y",))   # damper
        # Racing roundel on the door: white disc with a red ring, following the side.
        self.roundel(b, 0.05, 0.50, 0.165)
        # Tail: chrome jet nozzle around the round lens.
        tx, tz, tr = self.NOZZLE
        y0, y1 = self.TAIL_Y, self.TAIL_Y - self.NOZZLE_DEPTH
        n = 16
        ro = [(tx + self.NOZZLE_OUT * math.cos(2 * math.pi * i / n), tz + self.NOZZLE_OUT * math.sin(2 * math.pi * i / n))
              for i in range(n)]
        ri = [(tx + (tr + 0.006) * math.cos(2 * math.pi * i / n), tz + (tr + 0.006) * math.sin(2 * math.pi * i / n))
              for i in range(n)]
        for i in range(n):
            k = (i + 1) % n
            # outer wall, rim face, inner wall
            b.face([(ro[i][0], y0, ro[i][1]), (ro[i][0], y1, ro[i][1]), (ro[k][0], y1, ro[k][1]),
                    (ro[k][0], y0, ro[k][1])], "trim_steel", (ro[i][0] - tx, 0, ro[i][1] - tz))
            b.face([(ro[i][0], y1, ro[i][1]), (ri[i][0], y1, ri[i][1]), (ri[k][0], y1, ri[k][1]),
                    (ro[k][0], y1, ro[k][1])], "trim_steel", (0, -1, 0))
            b.face([(ri[i][0], y1, ri[i][1]), (ri[i][0], y0 - 0.01, ri[i][1]), (ri[k][0], y0 - 0.01, ri[k][1]),
                    (ri[k][0], y1, ri[k][1])], "trim_ink", (tx - ri[i][0], 0, tz - ri[i][1]))
        # A red accent disc behind the lens (visible as a ring).
        b.face([(p[0], y0 - 0.008, p[2]) for p in ring_pts(tx, tz, tr + 0.006, n, 0)], "trim_reflector_red",
               (0, -1, 0))

    def roundel(self, b, yc, zc, r, n=18):
        ring = r + 0.025

        def on_side(y, z, lift):
            return (self.side_x(y, z) + lift, y, z)
        c = on_side(yc, zc, 0.008)
        for i in range(n):
            a0, a1 = 2 * math.pi * i / n, 2 * math.pi * (i + 1) / n
            p0 = on_side(yc + r * math.cos(a0), zc + r * math.sin(a0), 0.008)
            p1 = on_side(yc + r * math.cos(a1), zc + r * math.sin(a1), 0.008)
            b.face([c, p0, p1], "trim_white", (1, 0, 0))
            q0 = on_side(yc + ring * math.cos(a0), zc + ring * math.sin(a0), 0.006)
            q1 = on_side(yc + ring * math.cos(a1), zc + ring * math.sin(a1), 0.006)
            b.face([p0, q0, q1, p1], "trim_reflector_red", (1, 0, 0))

    def cone(self):
        """The needle nose cone: a closed loft on the centre line (full ring)."""
        keys = []
        for y, rx, rz, zc in CONE:
            pts = []
            for i in range(CONE_SIDES):
                a = 2 * math.pi * i / CONE_SIDES - math.pi / 2
                pts.append((rx * math.cos(a), zc + rz * math.sin(a), 0.0))
            keys.append((y, pts))

        def mat(y0, y1, j, arch):
            a = 2 * math.pi * (j + 0.5) / CONE_SIDES - math.pi / 2
            return "trim_ink" if math.sin(a) < -0.75 else "paint"
        b = MeshBuilder()
        kit.Loft(keys, mat, closed=True, caps=(None, "paint"), center=(0.0, 0.45)).build(b)
        # Tiny oval grille with a chrome surround on the tip.
        y, rx, rz, zc = CONE[-1]
        ring = [(0.10 * math.cos(2 * math.pi * i / 14), y + 0.004, zc - 0.005 + 0.058 * math.sin(2 * math.pi * i / 14))
                for i in range(14)]
        b.face([(p[0] * 1.2, p[1], zc - 0.005 + (p[2] - zc + 0.005) * 1.25) for p in ring], "trim_steel", (0, 1, 0))
        b.face([(p[0], p[1] + 0.003, p[2]) for p in ring], "trim_ink", (0, 1, 0))
        return b

    def center_details(self, b):
        b.extend(self.cone())
        # Twin short pipes under the tail.
        for sx in (-1, 1):
            pipe = MeshBuilder()
            pipe.cylinder_x((0, 0, 0), 0.03, -0.04, 0.08, 8, "trim_steel", cap_mat="trim_ink")
            b.extend(pipe.transformed(lambda p: (p[1], p[0], p[2])), (sx * 0.18, self.TAIL_Y + 0.02, 0.33))

    def lod1(self):
        """kit.LoftCar.lod1 with the winding loft, plus the nose cone."""
        lo = WindingLoft(self.KEYS, self.body_material, self.arch_rails,
                         extra_ys=[ay + s * self.ARCH_R for ay in self.axles for s in (-1.0, -0.7, 0.0, 0.7, 1.0)] +
                         [r[k] for r in self.REGIONS.values() for k in (0, 1)], caps=("paint_shade", "trim_ink"))
        half = MeshBuilder()
        lo.build(half)
        self.lod1_extras(half)
        full = MeshBuilder()
        full.extend(half)
        full.extend(half.mirrored())
        for ay, track in ((self.axles[0], self.TRACK_F), (self.axles[1], self.TRACK_R)):
            for sx in (-1, 1):
                t = MeshBuilder()
                w, R = self.TIRE_W / 2, self.WHEEL_R
                t.lathe_x([(-w, R * 0.6), (-w, R), (w, R), (w, R * 0.6)], 10, "trim_ink")
                t.face([(w + 0.005, R * 0.7 * math.cos(2 * math.pi * i / 10), R * 0.7 * math.sin(2 * math.pi * i / 10))
                        for i in range(10)], "trim_steel", (1, 0, 0))
                if sx < 0:
                    t = t.transformed(lambda p: (-p[0], -p[1], p[2]))
                full.extend(t, (sx * track / 2, ay, R))
        full.extend(self.cone())
        lamps = MeshBuilder()
        self.lamp_faces(lamps)
        full.extend(lamps)
        kit.uv_box(full)
        return full

    def lod1_extras(self, b):
        fy = self.FENDER_Y + 0.002
        b.face([(.52, fy, .32), (.64, fy, .32), (.74, fy, .37), (.84, fy, .56), (.78, fy, .66), (.62, fy, .62),
                (.52, fy, .60)], "paint", (0, 1, 0))

    # ---------------------------------------------------------------- wheels

    def rim(self):
        """A chrome dish with a two-eared knock-off spinner."""
        xf = self.TIRE_W / 2 + 0.008
        r = kit.dish_rim(xf, self.RIM_IN, face="trim_steel", dark="trim_steel_dark", hub="trim_steel", sides=20)
        r.box((xf + 0.025, 0.0, 0.0), (0.03, 0.15, 0.028), "trim_steel", skip=("-x",))
        r.box((xf + 0.025, 0.0, 0.0), (0.03, 0.028, 0.06), "trim_steel_dark", skip=("-x",))
        return r

    # ---------------------------------------------------------------- lights

    def lights(self, rig):
        fy = self.FENDER_Y + 0.002
        hx, hz, hr = self.HEAD
        tx, tz, tr = self.NOZZLE
        ly = self.TAIL_Y - 0.015
        for side, s in (("L", -1), ("R", 1)):
            hb = disc_y(s * hx, hz, hr, 14, fy + 0.017, "lamp_head", 1)
            rig.light("headlight_" + side, hb, (s * hx, fy + 0.017, hz))
            fb = MeshBuilder()
            fb.box((s * 0.70, fy + 0.008, 0.395), (0.12, 0.016, 0.055), "signal_blinker", skip=("-y",))
            rig.light("blinker_F" + side, fb, (s * 0.70, fy + 0.016, 0.395))
            tb = disc_y(s * tx, tz, tr, 16, ly, "lamp_tail", -1)
            rig.light("taillight_" + side, tb, (s * tx, ly, tz))
            bb = disc_y(s * tx, tz, tr * 0.72, 16, ly - 0.005, "signal_brake", -1)
            rig.light("brake_" + side, bb, (s * tx, ly - 0.005, tz))
            rb = MeshBuilder()
            x0, x1 = sorted((s * 0.53, s * 0.605))
            kit.rect_y(x0, x1, tz - 0.04, tz + 0.04, ly, "signal_blinker", -1, rb)
            rig.light("blinker_R" + side, rb, (s * 0.5675, ly, tz))
        rv = kit.rect_y(-0.07, 0.07, 0.47, 0.52, ly, "signal_reverse", -1)
        rig.light("reverse", rv, (0.0, ly, 0.495))

    def markers(self):
        m = super().markers()
        m["exhaust_L"] = (-0.18, self.TAIL_Y - 0.06, 0.33)
        m["exhaust_R"] = (0.18, self.TAIL_Y - 0.06, 0.33)
        return m

    # ---------------------------------------------------------------- interior

    def binnacle(self, b, ex):
        """The gauge pair sits in a central pod."""
        return super().binnacle(b, 0.0)

    def rear_mirror(self, b):
        """No rear-view mirror under the bubble (it would sit in the middle of the view)."""


CAR = Needle

if __name__ == "__main__":
    kit.run(CAR)
