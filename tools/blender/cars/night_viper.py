"""Night Viper, the first "fast" car (docs/ART_PRODUCTION.md §4.1.2 slot 2, §4.1.5).

Mid-80s wedge supercar: a knife-edge nose, a flat hood rising in one line to a steep,
cab-forward windscreen, a short flat roof, louvred rear glass over a flat engine deck,
big side intakes ahead of the rear wheels, NACA ducts on the hood and a rear wing.
No pop-up lamps: a thin full-width headlight slit under the leading edge.
Taillights: one full-width red light bar in a black tail panel (blinkers below its ends).
Interior: an angular binnacle with digital-look side panels, a thick two-spoke wheel,
a high centre console.

CarDef (data/cars/night_viper.tres): 4.6 x 1.95 x 1.15 m, wheelbase 2.6.

  blender -b --python tools/blender/cars/night_viper.py -- [--export] [--render] [--save]
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import wb_carkit as kit  # noqa: E402
from wb_carkit import MeshBuilder  # noqa: E402
from wb_mesh import v_add, v_scale  # noqa: E402


class _Loft(kit.Loft):
    """The kit's Loft judges "outward" from a fixed axis 0.6 m up, which flips faces on
    this car's low wedge nose (the hood tip is at 0.45 m). Here outward is judged from
    each station's own mid-height between the floor and the top rails."""

    def build(self, b, extra=None):
        st = self.stations(extra)
        n = len(st[0][1])
        for (ya, a, arch0), (yb, c, arch1) in zip(st, st[1:]):
            arch = arch0 and arch1
            zc = (a[0][2] + a[-1][2] + c[0][2] + c[-1][2]) / 4
            for j in range(n - 1):
                m = self.mat_fn(ya, yb, j, arch)
                if m is None:
                    continue
                p = [a[j], c[j], c[j + 1], a[j + 1]]
                mid = v_scale(v_add(v_add(p[0], p[1]), v_add(p[2], p[3])), 0.25)
                out = (0.0, 0.0, -1.0) if j == 0 else (mid[0], 0.0, mid[2] - zc)
                b.face(p, m, out)
        tail, nose = st[0][1], st[-1][1]
        if self.caps[0]:
            b.face(list(tail) + [(0.0, tail[-1][1], tail[-1][2])], self.caps[0], (0, -1, 0))
        if self.caps[1]:
            b.face(list(nose) + [(0.0, nose[-1][1], nose[-1][2])], self.caps[1], (0, 1, 0))
        return st


class NightViper(kit.LoftCar):
    CAR_ID = "night_viper"
    WHEELBASE = 2.6
    WHEEL_R = 0.335
    TIRE_W = 0.26
    RIM_IN = 0.22
    TRACK_F = 1.60
    TRACK_R = 1.64
    ARCH_R = 0.39
    WELL_X = 0.62
    NOSE_Y = 2.22
    TAIL_Y = -2.38
    # Rails: floorC floorE rocker lowSide shoulder belt roofSide pillarIn roofMid crown roofC
    KEYS = [
        (TAIL_Y, [(0, .38), (.55, .38), (.84, .38), (.93, .45), (.955, .80), (.93, .965), (.80, .985),
                  (.70, .99), (.40, .99), (.20, .99), (0, .99)]),
        (-2.30, [(0, .34), (.56, .34), (.88, .33), (.955, .44), (.972, .80), (.945, .97), (.82, .99),
                 (.70, .998), (.40, 1.0), (.20, 1.0), (0, 1.0)]),
        (-1.80, [(0, .20), (.58, .19), (.90, .22), (.965, .38), (.975, .79), (.93, .975), (.80, 1.0),
                 (.70, 1.012), (.40, 1.018), (.20, 1.02), (0, 1.02)]),
        (-1.72, [(0, .19), (.58, .18), (.90, .21), (.965, .37), (.975, .788), (.928, .972), (.795, 1.005),
                 (.70, 1.02), (.40, 1.026), (.20, 1.028), (0, 1.028)]),
        (-0.80, [(0, .17), (.58, .17), (.88, .20), (.95, .36), (.962, .755), (.905, .93), (.67, 1.125),
                 (.60, 1.14), (.36, 1.148), (.18, 1.15), (0, 1.15)]),
        (-0.20, [(0, .17), (.58, .17), (.87, .20), (.935, .35), (.945, .715), (.89, .835), (.66, 1.125),
                 (.60, 1.14), (.35, 1.148), (.18, 1.15), (0, 1.15)]),
        (0.75, [(0, .17), (.58, .17), (.87, .20), (.93, .35), (.94, .655), (.89, .775), (.84, .782),
                (.76, .786), (.38, .792), (.18, .797), (0, .80)]),
        (1.00, [(0, .17), (.58, .17), (.87, .20), (.925, .35), (.935, .63), (.885, .745), (.80, .75),
                (.66, .752), (.36, .758), (.18, .762), (0, .764)]),
        (1.70, [(0, .20), (.58, .20), (.86, .22), (.91, .35), (.925, .56), (.88, .64), (.80, .646),
                (.66, .648), (.36, .654), (.18, .658), (0, .66)]),
        (2.12, [(0, .28), (.56, .28), (.82, .30), (.88, .33), (.90, .45), (.86, .50), (.78, .506),
                (.64, .508), (.36, .512), (.18, .515), (0, .516)]),
        (NOSE_Y, [(0, .30), (.55, .30), (.78, .30), (.84, .32), (.86, .43), (.84, .45), (.76, .452),
                  (.62, .453), (.36, .455), (.18, .456), (0, .456)]),
    ]
    REGIONS = {"windscreen": (-0.20, 0.75), "rear_glass": (-1.72, -0.80), "side_glass": (-0.75, 0.75)}
    MIRROR = (0.885, 0.52, 0.85)
    # Interior (cab-forward: the driver sits well forward, low)
    EYE = (-0.36, -0.42, 0.96)
    CABIN = (-0.85, 0.75)
    DASH = {"y_front": 0.75, "y_rear": 0.40, "top": 0.80, "bottom": 0.50}
    STEER = {"r": 0.175, "thick": 0.034, "spokes": 2, "tilt": -0.45, "sides": 18, "hub": 0.055}
    SEAT = {"y": -0.60, "cushion_z": 0.30, "back_top": 0.90, "w": 0.50}
    INTERIOR = dict(kit.LoftCar.INTERIOR, liner="roof_slate", door="asphalt", floor="ink", dash_top="ink",
                    dash_face="asphalt", seat="asphalt", seat_accent="barn_red", wheel="ink", spoke="steel_dark",
                    hub="ink", accent="reflector_red", console="ink", strip=None)
    GAUGE_W = 0.28

    SLIT_Z = (0.335, 0.425)       # headlight lens height (0.09 m) on the nose fascia
    SLIT_X = (0.10, 0.66)         # headlight lens, each side
    FBLINK_X = (0.69, 0.80)       # front blinkers at the slit's outer ends
    PANEL_Z = (0.60, 0.92)        # black tail panel
    BAR_Z = (0.745, 0.845)        # the light bar
    BAR_X = (0.02, 0.86)
    RBLINK = ((0.56, 0.86), (0.635, 0.715))   # rear blinkers under the bar's ends (x, z)
    WING_Z = (1.115, 1.15)
    WING_Y = (-2.34, -1.96)

    # ---------------------------------------------------------------- body details

    def main_loft(self):
        edges = [r[k] for r in self.REGIONS.values() for k in (0, 1)]
        return _Loft(self.KEYS, self.body_material, self.arch_rails, extra_ys=self.arch_ys() + edges)

    def details(self, b):
        ny, ty = self.NOSE_Y, self.TAIL_Y
        # Headlight slit housing: a black band across the fascia.
        z0, z1 = self.SLIT_Z
        b.face([(0, ny + 0.004, z0 - 0.012), (0.84, ny + 0.004, z0 - 0.012), (0.84, ny + 0.004, z1 + 0.012),
                (0, ny + 0.004, z1 + 0.012)], "trim_ink", (0, 1, 0))
        # Chin splitter: a dark blade under the nose, a little proud.
        b.box((0.40, ny - 0.02, 0.285), (0.80, 0.10, 0.03), "trim_ink", skip=("-x",))
        # NACA ducts on the hood (a dark trapezoid, narrow end forward).
        for yc in (1.35,):
            y0, y1 = yc - 0.17, yc + 0.17
            za, zb = self.top_z(y0, 8) + 0.004, self.top_z(y1, 8) + 0.004
            b.face([(0.40, y0, za), (0.56, y0, za), (0.50, y1, zb), (0.46, y1, zb)], "trim_ink", (0, 0.2, 1))
        # Side intake ahead of the rear wheel: a big dark recess with two body-colour strakes.
        ya, yb = -0.26, -0.86
        za, zb = 0.40, 0.72
        xa, xb = self.side_x(ya, (za + zb) / 2) + 0.004, self.side_x(yb, (za + zb) / 2) + 0.004
        pts = [(xa, ya + 0.10, zb), (xa, ya - 0.06, za), (xb, yb, za), (xb, yb, zb)]
        b.face(pts, "trim_ink", (1, 0, 0))
        for zs in (0.50, 0.61):
            y0 = ya + 0.10 - (zb - zs) / (zb - za) * 0.16 - 0.01
            x0, x1 = xa + 0.006, xb + 0.006
            b.face([(x0, y0, zs), (x1, yb + 0.01, zs), (x1, yb + 0.01, zs + 0.035), (x0, y0 + 0.006, zs + 0.035)],
                   "paint", (1, 0, 0))
            b.face([(x0, y0, zs + 0.035), (x1, yb + 0.01, zs + 0.035), (x1 - 0.006, yb + 0.01, zs + 0.035),
                    (x0 - 0.006, y0 + 0.006, zs + 0.035)], "paint", (0, 0, 1))
        # Louvres over the rear glass: slats across the glass, 4 cm deep, 9 cm apart.
        g0, g1 = self.REGIONS["rear_glass"]
        y = g1 - 0.07
        while y - 0.04 > g0 + 0.03:
            self._slat(b, y, y - 0.04)
            y -= 0.09
        # Black tail panel and a dark diffuser valance below it.
        z0, z1 = self.PANEL_Z
        b.face([(0.90, ty - 0.004, z0), (0, ty - 0.004, z0), (0, ty - 0.004, z1), (0.90, ty - 0.004, z1)],
               "trim_ink", (0, -1, 0))
        b.face([(0.84, ty - 0.004, 0.39), (0, ty - 0.004, 0.39), (0, ty - 0.004, 0.52), (0.84, ty - 0.004, 0.52)],
               "trim_ink", (0, -1, 0))
        for xf in (0.20, 0.42, 0.64):
            b.box((xf, ty - 0.03, 0.43), (0.015, 0.06, 0.08), "trim_ink")
        self._wing(b)

    def _slat(self, b, y0, y1):
        """A louvre blade across the right half of the rear glass (raised 1.5 cm)."""
        ra, rb = self.station(y0), self.station(y1)
        lift = 0.015
        top_a = [(ra[i][0], y0, ra[i][1] + lift) for i in range(7, 11)]
        top_b = [(rb[i][0], y1, rb[i][1] + lift) for i in range(7, 11)]
        for i in range(3):
            b.face([top_a[i], top_b[i], top_b[i + 1], top_a[i + 1]], "trim_steel_dark", (0, 0, 1))
        for i in range(3):
            base = [(p[0], p[1], p[2] - lift - 0.003) for p in (top_b[i], top_b[i + 1])]
            b.face([top_b[i], base[0], base[1], top_b[i + 1]], "trim_steel_dark", (0, -1, 0.3))

    def _wing(self, b):
        z0, z1 = self.WING_Z
        y0, y1 = self.WING_Y
        # Wing plane (right half), paint on top, dark underside and edges.
        b.box((0.46, (y0 + y1) / 2, (z0 + z1) / 2), (0.92, y1 - y0, z1 - z0), "trim_ink",
              {"+z": "paint", "-y": "paint_shade"}, skip=("-x",))
        # End plate.
        b.box((0.935, (y0 + y1) / 2 - 0.02, (z0 + z1) / 2 - 0.05), (0.03, y1 - y0 + 0.08, z1 - z0 + 0.10), "paint",
              {"-z": "trim_ink"})
        # Strut from the deck.
        deck = self.top_z(-2.12, 8)
        b.box((0.52, -2.14, (deck + z0) / 2), (0.03, 0.14, z0 - deck + 0.01), "trim_ink", skip=("-z", "+z"))

    def center_details(self, b):
        ty = self.TAIL_Y
        for sx in (-1, 1):
            for dx in (-0.05, 0.05):
                pipe = MeshBuilder()
                pipe.cylinder_x((0, 0, 0), 0.03, -0.03, 0.08, 8, "trim_steel", cap_mat="trim_ink")
                b.extend(pipe.transformed(lambda p: (p[1], p[0], p[2])), (sx * 0.32 + dx, ty - 0.03, 0.44))

    def lod1_extras(self, b):
        self._wing(b)
        ty, ny = self.TAIL_Y, self.NOSE_Y
        z0, z1 = self.PANEL_Z
        b.face([(0.90, ty - 0.004, z0), (0, ty - 0.004, z0), (0, ty - 0.004, z1), (0.90, ty - 0.004, z1)],
               "trim_ink", (0, -1, 0))
        z0, z1 = self.SLIT_Z
        b.face([(0, ny + 0.004, z0 - 0.012), (0.84, ny + 0.004, z0 - 0.012), (0.84, ny + 0.004, z1 + 0.012),
                (0, ny + 0.004, z1 + 0.012)], "trim_ink", (0, 1, 0))

    def rim(self):
        """80s 'telephone dial': a flat silver disc with five dark pockets and a polished lip."""
        xf = self.TIRE_W / 2 + 0.008
        R = self.RIM_IN
        r = MeshBuilder()
        r.lathe_x([(xf - 0.02, R), (xf, R), (xf, R * 0.9), (xf - 0.006, R * 0.86), (xf - 0.006, R * 0.25),
                   (xf + 0.004, R * 0.22), (xf + 0.01, 0.0)], 20,
                  ["trim_steel", "trim_steel", "trim_steel_dark", "trim_steel", "trim_steel_dark", "trim_ink"])
        for i in range(5):
            a = 2 * math.pi * i / 5 + math.pi / 2
            cy, cz = 0.58 * R * math.cos(a), 0.58 * R * math.sin(a)
            pts = [(xf - 0.003, cy + 0.045 * math.cos(2 * math.pi * k / 8), cz + 0.045 * math.sin(2 * math.pi * k / 8))
                   for k in range(8)]
            r.face(pts, "trim_steel_dark", (1, 0, 0))
        return r

    # ---------------------------------------------------------------- lights

    def lights(self, rig):
        ny, ty = self.NOSE_Y, self.TAIL_Y
        z0, z1 = self.SLIT_Z
        zc = (z0 + z1) / 2
        d = 0.015
        bz0, bz1 = self.BAR_Z
        bzc = (bz0 + bz1) / 2
        for side, s in (("L", -1), ("R", 1)):
            x0, x1 = sorted((s * self.SLIT_X[0], s * self.SLIT_X[1]))
            rig.light("headlight_" + side, kit.lamp_box((x0 + x1) / 2, zc, x1 - x0, z1 - z0, ny, d, "lamp_head", 1),
                      ((x0 + x1) / 2, ny + d, zc))
            x0, x1 = sorted((s * self.FBLINK_X[0], s * self.FBLINK_X[1]))
            rig.light("blinker_F" + side, kit.lamp_box((x0 + x1) / 2, zc, x1 - x0, z1 - z0, ny, d, "signal_blinker", 1),
                      ((x0 + x1) / 2, ny + d, zc))
            x0, x1 = sorted((s * self.BAR_X[0], s * self.BAR_X[1]))
            rig.light("taillight_" + side, kit.lamp_box((x0 + x1) / 2, bzc, x1 - x0, bz1 - bz0, ty, d, "lamp_tail", -1),
                      ((x0 + x1) / 2, ty - d, bzc))
            rig.light("brake_" + side,
                      kit.rect_y(x0, x1, bz0, bz1, ty - d - 0.005, "signal_brake", -1),
                      ((x0 + x1) / 2, ty - d - 0.005, bzc))
            (bx0, bx1), (rz0, rz1) = self.RBLINK
            x0, x1 = sorted((s * bx0, s * bx1))
            rig.light("blinker_R" + side, kit.lamp_box((x0 + x1) / 2, (rz0 + rz1) / 2, x1 - x0, rz1 - rz0, ty, d,
                                                        "signal_blinker", -1), ((x0 + x1) / 2, ty - d, (rz0 + rz1) / 2))
        rv = MeshBuilder()
        (rz0, rz1) = self.RBLINK[1]
        for s in (-1, 1):
            x0, x1 = sorted((s * 0.08, s * 0.24))
            kit.lamp_box((x0 + x1) / 2, (rz0 + rz1) / 2, x1 - x0, rz1 - rz0, ty, d, "signal_reverse", -1, rv)
        rig.light("reverse", rv, (0.0, ty - d, (rz0 + rz1) / 2))

    def markers(self):
        m = super().markers()
        m["exhaust_L"] = (-0.32, self.TAIL_Y - 0.11, 0.44)
        m["exhaust_R"] = (0.32, self.TAIL_Y - 0.11, 0.44)
        return m

    # ---------------------------------------------------------------- interior

    def binnacle(self, b, ex):
        """Angular pod: a slab with raked sides and a flat visor; digital panels beside the gauges."""
        d = self.DASH
        yr, top = d["y_rear"], d["top"]
        w = self.GAUGE_W / 2 + 0.06
        vis = top + 0.06
        bot = top - 0.14
        yb, yf = yr - 0.12, yr
        x0, x1 = ex - w, ex + w
        mat, face = self.imat("dash_top"), self.imat("dash_face")
        # Visor top (wider at the back), a sharp lip, raked sides, underside.
        b.face([(x0 - 0.02, yb, vis), (x1 + 0.02, yb, vis), (x1, yf, vis - 0.01), (x0, yf, vis - 0.01)], mat, (0, 0, 1))
        b.face([(x0 - 0.02, yb, vis), (x0 - 0.02, yb, vis - 0.025), (x1 + 0.02, yb, vis - 0.025), (x1 + 0.02, yb, vis)],
               mat, (0, -1, 0))
        for x, xo, sgn in ((x0, x0 - 0.02, -1), (x1, x1 + 0.02, 1)):
            b.face([(xo, yb, vis), (x, yf, vis - 0.01), (x, yf, bot), (x, yb + 0.06, bot)], mat, (sgn, 0, 0))
        b.face([(x0, yb + 0.06, bot), (x0, yf, bot), (x1, yf, bot), (x1, yb + 0.06, bot)], mat, (0, 0, -1))
        b.face([(x0, yb + 0.06, bot), (x1, yb + 0.06, bot), (x1, yb + 0.06, bot + 0.012), (x0, yb + 0.06, bot + 0.012)],
               mat, (0, -1, 0))
        back = yf - 0.03
        b.face([(x0, back, bot), (x1, back, bot), (x1, back, vis - 0.03), (x0, back, vis - 0.03)], face, (0, -1, 0))
        # Digital-look side panels (glowing screens) either side of the gauges.
        gz = (bot + vis - 0.03) / 2
        for sx in (-1, 1):
            cx = ex + sx * (self.GAUGE_W / 2 + 0.03)
            b.face([(cx - 0.022, back - 0.004, gz - 0.035), (cx + 0.022, back - 0.004, gz - 0.035),
                    (cx + 0.022, back - 0.004, gz + 0.035), (cx - 0.022, back - 0.004, gz + 0.035)],
                   "interior_screen", (0, -1, 0))
        return (ex, back - 0.01, gz)

    def console(self, b):
        """A high centre console: a tall tunnel from the dash to the seats, with a screen strip."""
        d = self.DASH
        fz = self.FLOOR_Z + 0.10
        yf, yr = d["y_rear"] + 0.02, self.SEAT["y"] + 0.05
        top_f, top_r = d["top"] - 0.15, fz + 0.33
        w = 0.13
        m = self.imat("console")
        b.face([(-w, yr, top_r), (w, yr, top_r), (w, yf, top_f), (-w, yf, top_f)], m, (0, -0.3, 1))
        for x, sgn in ((-w, -1), (w, 1)):
            b.face([(x, yr, fz), (x, yf, fz), (x, yf, top_f), (x, yr, top_r)], self.imat("dash_face"), (sgn, 0, 0))
        b.face([(-w, yr, fz), (w, yr, fz), (w, yr, top_r), (-w, yr, top_r)], m, (0, -1, 0))
        # A radio screen on the sloped face and a gear lever.
        t = 0.35
        ya, za = yr + (yf - yr) * t, top_r + (top_f - top_r) * t
        yb_, zb = yr + (yf - yr) * (t + 0.22), top_r + (top_f - top_r) * (t + 0.22)
        b.face([(-0.08, ya, za + 0.004), (0.08, ya, za + 0.004), (0.08, yb_, zb + 0.004), (-0.08, yb_, zb + 0.004)],
               "interior_screen", (0, -0.3, 1))
        sy, sz = yr + 0.10, top_r + (top_f - top_r) * 0.08
        b.box((0.0, sy, sz + 0.07), (0.018, 0.018, 0.14), self.imat("hub"), skip=("-z",))
        b.box((0.0, sy, sz + 0.15), (0.045, 0.045, 0.045), self.imat("wheel"))


CAR = NightViper

if __name__ == "__main__":
    kit.run(CAR)
