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
        (TAIL_Y, [(0, .38, .05), (.55, .38, .05), (.76, .38, .03), (.80, .46), (.825, .76), (.79, .885), (.68, .915),
                  (.62, .93), (.36, .935), (.18, .937), (0, .938)]),
        (-2.30, [(0, .33), (.56, .33), (.85, .33), (.90, .44), (.925, .79), (.885, .95), (.77, .982), (.68, .99),
                 (.40, .995), (.20, .997), (0, .998)]),
        (-2.05, [(0, .24), (.58, .23), (.88, .24), (.93, .40), (.958, .79), (.915, .97), (.80, 1.002), (.70, 1.008),
                 (.40, 1.014), (.20, 1.016), (0, 1.017)]),
        (-1.72, [(0, .19), (.58, .18), (.89, .21), (.935, .37), (.975, .785), (.928, .972), (.795, 1.008), (.70, 1.022),
                 (.40, 1.03), (.20, 1.033), (0, 1.034)]),
        (-1.30, [(0, .17), (.58, .17), (.89, .20), (.935, .36), (.975, .775), (.92, .955), (.745, 1.062), (.665, 1.078),
                 (.38, 1.09), (.19, 1.094), (0, 1.095)]),
        (-0.80, [(0, .17), (.58, .17), (.87, .20), (.92, .36), (.962, .755), (.905, .93), (.67, 1.125), (.60, 1.14),
                 (.36, 1.152), (.18, 1.157), (0, 1.158)]),
        (-0.20, [(0, .17), (.58, .17), (.86, .20), (.91, .35), (.955, .72), (.89, .84), (.66, 1.12), (.60, 1.138),
                 (.35, 1.15), (.18, 1.155), (0, 1.156)]),
        (0.75, [(0, .17), (.58, .17), (.86, .20), (.905, .35), (.952, .66), (.895, .778), (.84, .784), (.76, .79),
                (.38, .80), (.18, .804), (0, .806)]),
        (1.00, [(0, .17), (.58, .17), (.86, .20), (.905, .35), (.948, .635), (.89, .748), (.80, .755), (.66, .76),
                (.36, .772), (.18, .777), (0, .779)]),
        (1.70, [(0, .20), (.58, .20), (.86, .22), (.905, .35), (.928, .565), (.875, .645), (.79, .652), (.66, .656),
                (.36, .666), (.18, .67), (0, .672)]),
        (2.05, [(0, .26), (.56, .26), (.83, .28), (.87, .34), (.89, .48), (.84, .525), (.76, .53), (.64, .533),
                (.36, .54), (.18, .543), (0, .544)]),
        (NOSE_Y, [(0, .30, -.04), (.55, .30, -.04), (.74, .30, -.02), (.78, .33), (.79, .43), (.76, .45), (.70, .452),
                  (.60, .454), (.36, .457), (.18, .458), (0, .458)]),
    ]
    # Creases across the car: the windscreen base, the roof's front and rear edges, the
    # rear glass meeting the engine deck. Between them every panel is a smooth curve.
    CREASE_Y = (0.75, -0.20, -0.80, -1.72)
    REGIONS = {"windscreen": (-0.20, 0.75), "rear_glass": (-1.72, -0.80), "side_glass": (-0.75, 0.75)}
    MIRROR = (0.885, 0.52, 0.85)
    # Interior (cab-forward: the driver sits well forward, low)
    EYE = (-0.36, -0.42, 0.90)
    CABIN = (-0.85, 0.75)
    DASH = {"y_front": 0.75, "y_rear": 0.40, "top": 0.80, "bottom": 0.50}
    STEER = {"r": 0.175, "thick": 0.034, "spokes": 2, "tilt": -0.45, "sides": 18, "hub": 0.055}
    SEAT = {"y": -0.60, "cushion_z": 0.30, "back_top": 0.90, "w": 0.50}
    INTERIOR = dict(kit.LoftCar.INTERIOR, liner="roof_slate", door="asphalt", floor="ink", dash_top="ink",
                    dash_face="asphalt", seat="asphalt", seat_accent="barn_red", wheel="ink", spoke="steel_dark",
                    hub="ink", accent="reflector_red", console="ink", strip=None)
    GAUGE_W = 0.28

    SLIT_Z = (0.335, 0.425)       # headlight lens height (0.09 m) on the nose fascia
    SLIT_X = (0.08, 0.54)         # headlight lens, each side
    FBLINK_X = (0.57, 0.68)       # front blinkers at the slit's outer ends
    PANEL_Z = (0.62, 0.87)        # black tail band
    BAR_Z = (0.745, 0.835)        # the light bar
    BAR_X = (0.02, 0.74)
    RBLINK = ((0.48, 0.74), (0.64, 0.71))     # rear blinkers under the bar's ends (x, z)
    WING_Z = (1.115, 1.15)
    WING_Y = (-2.34, -1.96)

    # ---------------------------------------------------------------- body details

    # ---------------------------------------------------------------- surface sampling

    def section(self, y, sub=8):
        """The smooth right-half section at y (no arches): [(x, z)], rail j at index j * sub."""
        lo = self.main_loft()
        pts = [(x, y + dy, z) for (x, z, dy) in lo.station(y)]
        return [(p[0], p[2]) for p in lo._curve(pts, [sub] * (len(pts) - 1))], sub

    def top_z_at(self, y, x):
        """Height of the top surface (belt inward) at (y, x)."""
        pts, sub = self.section(y)
        top = pts[sub * 5:]
        for (xa, za), (xb, zb) in zip(top, top[1:]):
            if min(xa, xb) - 1e-9 <= x <= max(xa, xb) + 1e-9 and abs(xa - xb) > 1e-9:
                return za + (zb - za) * (x - xa) / (xb - xa)
        return top[-1][1]

    def side_x_at(self, y, z):
        """x of the body side (door bottom to window line) at (y, z)."""
        pts, sub = self.section(y)
        side = pts[sub * 3: sub * 5 + 1]
        for (xa, za), (xb, zb) in zip(side, side[1:]):
            if min(za, zb) - 1e-9 <= z <= max(za, zb) + 1e-9 and abs(za - zb) > 1e-9:
                return xa + (xb - xa) * (z - za) / (zb - za)
        return side[-1][0]

    def side_patch(self, b, corners, mat, nu=4, nv=3, lift=0.004):
        """A face grid hugging the side: corners = (y, z) of bottom-front, bottom-rear,
        top-rear, top-front (bilinear)."""
        (y0, z0), (y1, z1), (y2, z2), (y3, z3) = corners

        def P(u, v):
            y = (1 - u) * (1 - v) * y0 + u * (1 - v) * y1 + u * v * y2 + (1 - u) * v * y3
            z = (1 - u) * (1 - v) * z0 + u * (1 - v) * z1 + u * v * z2 + (1 - u) * v * z3
            return (self.side_x_at(y, z) + lift, y, z)
        for i in range(nu):
            for k in range(nv):
                u0, u1, v0, v1 = i / nu, (i + 1) / nu, k / nv, (k + 1) / nv
                b.face([P(u0, v0), P(u1, v0), P(u1, v1), P(u0, v1)], mat, (1, 0, 0), smooth=True, group="intake")

    def top_patch(self, b, corners, mat, nu=3, nv=3, lift=0.005):
        """A face grid hugging the top surface: corners = (x, y) counter-clockwise from above."""
        (x0, y0), (x1, y1), (x2, y2), (x3, y3) = corners

        def P(u, v):
            x = (1 - u) * (1 - v) * x0 + u * (1 - v) * x1 + u * v * x2 + (1 - u) * v * x3
            y = (1 - u) * (1 - v) * y0 + u * (1 - v) * y1 + u * v * y2 + (1 - u) * v * y3
            return (x, y, self.top_z_at(y, x) + lift)
        for i in range(nu):
            for k in range(nv):
                u0, u1, v0, v1 = i / nu, (i + 1) / nu, k / nv, (k + 1) / nv
                b.face([P(u0, v0), P(u1, v0), P(u1, v1), P(u0, v1)], mat, (0, 0, 1), smooth=True, group="duct")

    def details(self, b):
        ny, ty = self.NOSE_Y, self.TAIL_Y
        # Headlight slit housing: a black band across the fascia, inside its rounded corners.
        z0, z1 = self.SLIT_Z
        b.face([(0, ny + 0.004, z0 - 0.012), (0.72, ny + 0.004, z0 - 0.012), (0.72, ny + 0.004, z1 + 0.012),
                (0, ny + 0.004, z1 + 0.012)], "trim_ink", (0, 1, 0))
        # Chin splitter: a dark blade under the nose, a little proud.
        b.box((0.36, ny - 0.03, 0.285), (0.72, 0.10, 0.03), "trim_ink", skip=("-x",))
        # NACA duct on the hood: a dark trapezoid hugging the crowned surface, narrow end forward.
        y0, y1 = 1.18, 1.52
        self.top_patch(b, [(0.40, y0), (0.56, y0), (0.50, y1), (0.46, y1)], "trim_ink")
        # Side intake ahead of the rear wheel: a big dark scoop with two body-colour strakes.
        ya, yb = -0.26, -0.86
        za, zb = 0.40, 0.70
        self.side_patch(b, [(ya - 0.06, za), (yb, za), (yb, zb), (ya + 0.10, zb)], "trim_ink", nu=5, nv=3)
        for zs in (0.50, 0.60):
            yf = ya + 0.10 - (zb - zs) / (zb - za) * 0.16 - 0.01
            for yy0, yy1 in ((yf, (yf + yb) / 2), ((yf + yb) / 2, yb + 0.01)):
                xa0, xa1 = self.side_x_at(yy0, zs) + 0.010, self.side_x_at(yy1, zs) + 0.010
                xb0, xb1 = self.side_x_at(yy0, zs + 0.035) + 0.010, self.side_x_at(yy1, zs + 0.035) + 0.010
                b.face([(xa0, yy0, zs), (xa1, yy1, zs), (xb1, yy1, zs + 0.035), (xb0, yy0, zs + 0.035)], "paint",
                       (1, 0, 0), smooth=True, group="strake")
                b.face([(xb0, yy0, zs + 0.035), (xb1, yy1, zs + 0.035), (xb1 - 0.008, yy1, zs + 0.035),
                        (xb0 - 0.008, yy0, zs + 0.035)], "paint", (0, 0, 1))
        # Louvres over the rear glass: slats across the glass, 4 cm deep, 9 cm apart.
        g0, g1 = self.REGIONS["rear_glass"]
        y = g1 - 0.07
        while y - 0.04 > g0 + 0.03:
            self._slat(b, y, y - 0.04)
            y -= 0.09
        # Black tail panel and a dark diffuser valance below it.
        z0, z1 = self.PANEL_Z
        b.face([(0.78, ty - 0.004, z0), (0, ty - 0.004, z0), (0, ty - 0.004, z1), (0.78, ty - 0.004, z1)],
               "trim_ink", (0, -1, 0))
        b.face([(0.74, ty - 0.004, 0.40), (0, ty - 0.004, 0.40), (0, ty - 0.004, 0.52), (0.74, ty - 0.004, 0.52)],
               "trim_ink", (0, -1, 0))
        for xf in (0.20, 0.42, 0.64):
            b.box((xf, ty - 0.03, 0.43), (0.015, 0.06, 0.08), "trim_ink")
        self._wing(b)

    def _slat(self, b, y0, y1):
        """A louvre blade across the right half of the rear glass, 1.5 cm over its curve."""
        lift = 0.015
        xs = [0.0, 0.16, 0.32, 0.48, 0.60]
        top_a = [(x, y0, self.top_z_at(y0, x) + lift) for x in xs]
        top_b = [(x, y1, self.top_z_at(y1, x) + lift) for x in xs]
        for i in range(len(xs) - 1):
            b.face([top_a[i], top_b[i], top_b[i + 1], top_a[i + 1]], "trim_steel_dark", (0, 0, 1))
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
        b.face([(0.78, ty - 0.004, z0), (0, ty - 0.004, z0), (0, ty - 0.004, z1), (0.78, ty - 0.004, z1)],
               "trim_ink", (0, -1, 0))
        z0, z1 = self.SLIT_Z
        b.face([(0, ny + 0.004, z0 - 0.012), (0.72, ny + 0.004, z0 - 0.012), (0.72, ny + 0.004, z1 + 0.012),
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

    def interior_extras(self, b):
        """A footwell bulkhead just behind the dash's front edge, door to door: closes the
        slivers where the dash ends meet the curved cabin shell."""
        y = self.DASH["y_front"] - 0.03
        top = self.top_z(y, 7) - 0.02
        fz = self.FLOOR_Z + 0.08
        w = self.station(y)[kit.R_SHOULDER][0]
        b.face([(-w, y, fz), (w, y, fz), (w, y, top), (-w, y, top)], self.imat("dash_face"), (0, -1, 0))

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
