"""Brute V8, the milestone muscle car (docs/ART_PRODUCTION.md §4.1.2 slot 3, §4.1.5).

Early-70s muscle car: boxy and wide, a long flat hood with a raised shaker scoop, a
flat roof, a semi-fastback rear glass onto a flat deck with a spoiler lip, wide rear
haunches. Chrome front bumper around a full-width grille with quad round headlamps,
side exhaust pipes along the rockers, raised white-letter tires, a five-slot mag rim.
Taillights: two large square lamps per side. Interior: a flat metal dash, a big
thin-rimmed wheel, a pistol-grip shifter.

CarDef (data/cars/brute_v8.tres): 4.8 x 1.95 x 1.35 m, wheelbase 2.8.

  blender -b --python tools/blender/cars/brute_v8.py -- [--export] [--render] [--save]
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import wb_carkit as kit  # noqa: E402
from wb_carkit import MeshBuilder, disc_y, ring_pts  # noqa: E402


class BruteV8(kit.LoftCar):
    CAR_ID = "brute_v8"
    WHEELBASE = 2.8
    WHEEL_R = 0.35
    TIRE_W = 0.27
    RIM_IN = 0.225
    TRACK_F = 1.60
    TRACK_R = 1.64
    ARCH_R = 0.41
    WELL_X = 0.62
    NOSE_Y = 2.35
    TAIL_Y = -2.45
    # Boxy: near-vertical sides, a sharp shoulder, flat roof and hood.
    KEYS = [
        (TAIL_Y, [(0, .40, .04), (.56, .40, .04), (.86, .40, .03), (.92, .46), (.94, .86), (.925, 1.0), (.80, 1.02),
                  (.70, 1.02), (.35, 1.02), (.18, 1.02), (0, 1.02)]),
        (-2.38, [(0, .34), (.58, .34), (.90, .33), (.955, .44), (.965, .86), (.94, .995), (.82, 1.0), (.70, 1.0),
                 (.35, 1.0), (.18, 1.0), (0, 1.0)]),
        (-1.90, [(0, .20), (.60, .19), (.91, .21), (.965, .40), (.975, .86), (.945, .99), (.83, .995), (.72, .997),
                 (.35, 1.0), (.18, 1.0), (0, 1.0)]),
        (-1.55, [(0, .18), (.60, .18), (.91, .20), (.965, .38), (.975, .855), (.94, .985), (.80, .995), (.71, 1.0),
                 (.35, 1.005), (.18, 1.005), (0, 1.005)]),
        (-0.95, [(0, .18), (.60, .18), (.90, .20), (.95, .37), (.96, .85), (.925, .965), (.74, 1.31), (.68, 1.33),
                 (.35, 1.345), (.18, 1.35), (0, 1.35)]),
        (-0.20, [(0, .18), (.60, .18), (.89, .20), (.935, .37), (.945, .84), (.915, .955), (.73, 1.31), (.67, 1.33),
                 (.35, 1.345), (.18, 1.35), (0, 1.35)]),
        (0.45, [(0, .18), (.60, .18), (.89, .20), (.935, .37), (.948, .835), (.915, .95), (.86, .955), (.78, .96),
                (.35, .963), (.18, .965), (0, .965)]),
        (0.55, [(0, .18), (.60, .18), (.895, .20), (.94, .37), (.952, .835), (.92, .945), (.84, .95), (.74, .952),
                (.35, .955), (.18, .955), (0, .955)]),
        (1.40, [(0, .18), (.60, .18), (.90, .21), (.945, .39), (.955, .83), (.92, .94), (.84, .945), (.74, .947),
                (.35, .95), (.18, .95), (0, .95)]),
        (2.15, [(0, .24), (.60, .24), (.88, .28), (.93, .42), (.945, .825), (.915, .93), (.84, .935), (.74, .937),
                (.35, .94), (.18, .94), (0, .94)]),
        (NOSE_Y, [(0, .32, -.04), (.56, .32, -.04), (.84, .33, -.02), (.90, .40), (.915, .82), (.895, .91),
                  (.83, .915), (.73, .917), (.35, .92), (.18, .92), (0, .92)]),
    ]
    REGIONS = {"windscreen": (-0.20, 0.45), "rear_glass": (-1.55, -0.95), "side_glass": (-0.90, 0.45)}
    MIRROR = (0.925, 0.25, 1.0)
    EYE = (-0.37, -0.48, 1.12)
    CABIN = (-1.30, 0.45)
    DASH = {"y_front": 0.45, "y_rear": 0.28, "top": 0.95, "bottom": 0.62}
    STEER = {"r": 0.21, "thick": 0.015, "spokes": 3, "tilt": -0.40, "sides": 22}
    SEAT = {"y": -0.55, "cushion_z": 0.38, "back_top": 1.02, "w": 0.52}
    INTERIOR = dict(kit.LoftCar.INTERIOR, dash_face="steel_dark", dash_top="asphalt", seat="ink",
                    seat_accent="asphalt", wheel="ink", spoke="steel", hub="steel_dark", accent="cream",
                    door="asphalt", liner="asphalt")

    GRILLE_Z = (0.52, 0.80)
    GRILLE_X = 0.86
    HEAD_Z = 0.66
    HEAD_R = 0.078
    HEAD_X = (0.50, 0.70)
    BUMPER_F_Z = (0.38, 0.50)
    BUMPER_R_Z = (0.44, 0.56)
    TAIL_Z = (0.68, 0.88)
    TAIL_X = ((0.28, 0.50), (0.54, 0.76))
    TAIL_BLINK_X = (0.80, 0.90)
    SCOOP = {"y": (1.12, 1.52), "w": 0.27, "top": 1.075}
    PIPE = {"x": 0.935, "z": 0.19, "r": 0.042, "y": (-0.93, 0.93)}

    # ---------------------------------------------------------------- body details

    def details(self, b):
        fy = self.NOSE_Y + 0.004
        gz0, gz1 = self.GRILLE_Z
        gx = self.GRILLE_X
        # Full-width dark grille with a chrome surround.
        b.face([(0, fy, gz0), (gx, fy, gz0), (gx, fy, gz1), (0, fy, gz1)], "trim_ink", (0, 1, 0))
        for z0, z1 in ((gz1, gz1 + 0.022), (gz0 - 0.022, gz0)):
            b.face([(0, fy + 0.003, z0), (gx + 0.02, fy + 0.003, z0), (gx + 0.02, fy + 0.003, z1),
                    (0, fy + 0.003, z1)], "trim_steel", (0, 1, 0))
        b.face([(gx, fy + 0.003, gz0), (gx + 0.02, fy + 0.003, gz0), (gx + 0.02, fy + 0.003, gz1),
                (gx, fy + 0.003, gz1)], "trim_steel", (0, 1, 0))
        # Horizontal grille bars (thin, dark grey) between the lamps and the centre.
        for z in (0.60, 0.72):
            b.face([(0, fy + 0.002, z - 0.012), (0.40, fy + 0.002, z - 0.012), (0.40, fy + 0.002, z + 0.012),
                    (0, fy + 0.002, z + 0.012)], "trim_asphalt", (0, 1, 0))
        # Chrome bezels around the quad headlamps.
        for hx in self.HEAD_X:
            outer = ring_pts(hx, self.HEAD_Z, self.HEAD_R + 0.02, 12, fy + 0.012)
            inner = ring_pts(hx, self.HEAD_Z, self.HEAD_R, 12, fy + 0.012)
            back = ring_pts(hx, self.HEAD_Z, self.HEAD_R + 0.02, 12, fy)
            for i in range(12):
                k = (i + 1) % 12
                b.face([outer[i], outer[k], inner[k], inner[i]], "trim_steel", (0, 1, 0))
                b.face([back[i], back[k], outer[k], outer[i]], "trim_steel",
                       (outer[i][0] - hx, 0, outer[i][2] - self.HEAD_Z))
        # Heavy chrome front bumper, wrapping the corner.
        z0, z1 = self.BUMPER_F_Z
        ny = self.NOSE_Y
        b.box((0.44, ny + 0.03, (z0 + z1) / 2), (0.88, 0.07, z1 - z0), "trim_steel", skip=("-x", "-y"))
        b.face([(0.88, ny + 0.065, z0), (0.88, ny - 0.14, z0), (0.88, ny - 0.14, z1), (0.88, ny + 0.065, z1)],
               "trim_steel", (1, 0, 0))
        b.face([(0.88, ny - 0.14, z1), (0.905, ny - 0.14, z1), (0.905, ny - 0.14, z0), (0.88, ny - 0.14, z0)],
               "trim_steel", (0, -1, 0))
        # Rear bumper and tail panel.
        z0, z1 = self.BUMPER_R_Z
        ty = self.TAIL_Y
        b.box((0.45, ty - 0.03, (z0 + z1) / 2), (0.90, 0.07, z1 - z0), "trim_steel", skip=("-x",))
        tz0, tz1 = self.TAIL_Z
        b.face([(0.92, ty - 0.004, tz0 - 0.04), (0, ty - 0.004, tz0 - 0.04), (0, ty - 0.004, tz1 + 0.04),
                (0.92, ty - 0.004, tz1 + 0.04)], "trim_ink", (0, -1, 0))
        # Chrome frames around the square tail lamps.
        for x0, x1 in self.TAIL_X:
            e = 0.018
            yf = ty - 0.009
            for (a0, a1, c0, c1) in ((x0 - e, x1 + e, tz1, tz1 + e), (x0 - e, x1 + e, tz0 - e, tz0),
                                     (x0 - e, x0, tz0, tz1), (x1, x1 + e, tz0, tz1)):
                b.face([(a1, yf, c0), (a0, yf, c0), (a0, yf, c1), (a1, yf, c1)], "trim_steel", (0, -1, 0))
        # Spoiler lip across the deck's rear edge.
        lip = MeshBuilder()
        prof = [(0.0, 0.0), (0.0, 0.075), (0.17, 0.0)]  # (dy, dz): high at the tail, sloping forward onto the deck
        cy, cz = sum(p[0] for p in prof) / 3, sum(p[1] for p in prof) / 3
        for i in range(3):
            (ya, za), (yb, zb) = prof[i], prof[(i + 1) % 3]
            lip.face([(0, ya, za), (0.86, ya, za), (0.86, yb, zb), (0, yb, zb)], "trim_ink",
                     (0, (ya + yb) / 2 - cy, (za + zb) / 2 - cz))
        lip.face([(0.86, 0, 0), (0.86, 0, 0.075), (0.86, 0.17, 0)], "trim_ink", (1, 0, 0))
        b.extend(lip, (0, ty + 0.005, 1.018))
        # Side exhaust pipes along the rockers, with chrome tips.
        p = self.PIPE
        pipe = MeshBuilder()
        pipe.cylinder_x((0, 0, 0), p["r"], p["y"][0], p["y"][1], 10, "trim_steel", cap_mat="trim_ink")
        b.extend(pipe.transformed(lambda q: (q[1], q[0], q[2])), (p["x"], 0.0, p["z"]))
        # Pipe brackets (dark) up to the rocker.
        for yb in (-0.6, 0.0, 0.6):
            b.box((p["x"] - 0.03, yb, p["z"] + 0.04), (0.04, 0.05, 0.06), "trim_ink", skip=("-z",))
        # Hood pins (two small dark studs near the nose).
        for x in (0.55,):
            b.box((x, self.NOSE_Y - 0.18, self.top_z(self.NOSE_Y - 0.18) + 0.01), (0.04, 0.04, 0.02), "trim_steel",
                  skip=("-z",))

    def center_details(self, b):
        # Shaker scoop: a dark box standing through the hood, intake open to the front.
        s = self.SCOOP
        y0, y1 = s["y"]
        w, top = s["w"], s["top"]
        base = self.top_z(y1) - 0.01
        sc = MeshBuilder()
        # Body: slanted front, flat top, vertical sides and back.
        pts_side = [(y0, base), (y1, base), (y1, top), (y0 + 0.06, top)]
        for sx in (-1, 1):
            sc.face([(sx * w, y, z) for y, z in pts_side], "trim_ink", (sx, 0, 0))
        sc.face([(-w, y0 + 0.06, top), (w, y0 + 0.06, top), (w, y1, top), (-w, y1, top)], "trim_asphalt", (0, 0, 1))
        sc.face([(-w, y0, base), (w, y0, base), (w, y0 + 0.06, top), (-w, y0 + 0.06, top)], "trim_ink", (0, 1, 0.3))
        sc.face([(-w, y1, base), (w, y1, base), (w, y1, top), (-w, y1, top)], "trim_ink", (0, -1, 0))
        # Intake mouth: a chrome lip framing a black opening on the front face.
        m = 0.03
        yf = y0 + 0.025
        zm0, zm1 = base + 0.035, top - 0.02
        for (a0, a1, c0, c1) in ((-w, w, zm1, top - 0.002), (-w, w, base + 0.01, zm0), (-w, -w + m, zm0, zm1),
                                 (w - m, w, zm0, zm1)):
            sc.face([(a0, yf + 0.012, c0), (a1, yf + 0.012, c0), (a1, yf + 0.012, c1), (a0, yf + 0.012, c1)],
                    "trim_steel", (0, 1, 0))
        # Chrome base plate around the scoop on the hood.
        sc.box((0, (y0 + y1) / 2, base + 0.008), (2 * w + 0.06, y1 - y0 + 0.06, 0.016), "trim_steel", skip=("-z",))
        b.extend(sc)
        # Rear licence plate in the middle of the tail panel.
        tz0, tz1 = self.TAIL_Z
        ry = self.TAIL_Y - 0.012
        zc = (tz0 + tz1) / 2
        b.face([(0.24, ry, zc - 0.075), (-0.24, ry, zc - 0.075), (-0.24, ry, zc + 0.075), (0.24, ry, zc + 0.075)],
               "trim_cream", (0, -1, 0))

    def lod1_extras(self, b):
        fy = self.NOSE_Y + 0.004
        gz0, gz1 = self.GRILLE_Z
        b.face([(0, fy, gz0), (self.GRILLE_X, fy, gz0), (self.GRILLE_X, fy, gz1), (0, fy, gz1)], "trim_ink", (0, 1, 0))
        z0, z1 = self.BUMPER_F_Z
        b.box((0.44, self.NOSE_Y + 0.03, (z0 + z1) / 2), (0.88, 0.07, z1 - z0), "trim_steel", skip=("-x", "-y"))
        z0, z1 = self.BUMPER_R_Z
        b.box((0.45, self.TAIL_Y - 0.03, (z0 + z1) / 2), (0.90, 0.07, z1 - z0), "trim_steel", skip=("-x", "+y"))
        tz0, tz1 = self.TAIL_Z
        ty = self.TAIL_Y - 0.004
        b.face([(0.92, ty, tz0 - 0.04), (0, ty, tz0 - 0.04), (0, ty, tz1 + 0.04), (0.92, ty, tz1 + 0.04)], "trim_ink",
               (0, -1, 0))
        s = self.SCOOP
        base = self.top_z(s["y"][1]) - 0.01
        b.box((s["w"] / 2, sum(s["y"]) / 2, (base + s["top"]) / 2), (s["w"], s["y"][1] - s["y"][0], s["top"] - base),
              "trim_ink", skip=("-x", "-z"))
        p = self.PIPE
        pipe = MeshBuilder()
        pipe.cylinder_x((0, 0, 0), p["r"], p["y"][0], p["y"][1], 6, "trim_steel")
        b.extend(pipe.transformed(lambda q: (q[1], q[0], q[2])), (p["x"], 0.0, p["z"]))

    # ---------------------------------------------------------------- wheels

    def tire(self, sides=None):
        t = super().tire(sides)
        # Raised white letters: a thin white band on the outer (+X) sidewall.
        w = self.TIRE_W / 2
        t.lathe_x([(w + 0.003, 0.300), (w + 0.003, 0.278)], sides or self.TIRE_SIDES, "trim_white")
        return t

    def rim(self):
        """Five-slot mag: a polished dish with five dark slots and a chrome lip."""
        xf = self.TIRE_W / 2 + 0.008
        R = self.RIM_IN
        r = MeshBuilder()
        r.lathe_x([(xf - 0.02, R), (xf, R), (xf, R * 0.9), (xf - 0.012, R * 0.86), (xf - 0.012, R * 0.36),
                   (xf, R * 0.30), (xf + 0.004, R * 0.30), (xf + 0.004, 0.0)], 20,
                  ["trim_steel", "trim_steel", "trim_steel_dark", "trim_steel", "trim_steel", "trim_steel", "trim_ink"])
        # Five slots: dark rounded rectangles between hub and lip.
        for i in range(5):
            a = 2 * math.pi * i / 5 + math.pi / 2 + math.pi / 5
            ca, sa = math.cos(a), math.sin(a)
            pa, pb = -sa, ca
            r0, r1 = R * 0.42, R * 0.80
            h0, h1 = 0.022, 0.034
            x = xf - 0.010
            pts = [(x, r0 * ca - h0 * pa, r0 * sa - h0 * pb), (x, r1 * ca - h1 * pa, r1 * sa - h1 * pb),
                   (x, r1 * ca + h1 * pa, r1 * sa + h1 * pb), (x, r0 * ca + h0 * pa, r0 * sa + h0 * pb)]
            r.face(pts, "trim_ink", (1, 0, 0))
        # Five lug studs around the hub.
        for i in range(5):
            a = 2 * math.pi * i / 5 + math.pi / 2
            y, z = R * 0.22 * math.cos(a), R * 0.22 * math.sin(a)
            r.box((xf + 0.009, y, z), (0.01, 0.018, 0.018), "trim_steel_dark", skip=("-x",))
        return r

    # ---------------------------------------------------------------- lights

    def lights(self, rig):
        ny, ty = self.NOSE_Y, self.TAIL_Y
        ly = ny + 0.016
        lt = ty - 0.019
        tz0, tz1 = self.TAIL_Z
        zc = (tz0 + tz1) / 2
        for side, s in (("L", -1), ("R", 1)):
            hb = MeshBuilder()
            for hx in self.HEAD_X:
                disc_y(s * hx, self.HEAD_Z, self.HEAD_R, 12, ly, "lamp_head", 1, hb)
            rig.light("headlight_" + side, hb, (s * sum(self.HEAD_X) / 2, ly, self.HEAD_Z))
            # Front blinkers: amber blocks in the valance under the bumper.
            fb = MeshBuilder()
            fb.box((s * 0.62, ny - 0.01, 0.335), (0.20, 0.03, 0.08), "signal_blinker", skip=("-y",))
            rig.light("blinker_F" + side, fb, (s * 0.62, ny + 0.005, 0.335))
            # Two big square tail lamps; the brake lamps are the same squares 5 mm proud.
            tb, bb = MeshBuilder(), MeshBuilder()
            for x0, x1 in self.TAIL_X:
                a0, a1 = sorted((s * x0, s * x1))
                kit.rect_y(a0, a1, tz0, tz1, lt, "lamp_tail", -1, tb)
                kit.rect_y(a0, a1, tz0, tz1, lt - 0.005, "signal_brake", -1, bb)
            cx = s * (self.TAIL_X[0][0] + self.TAIL_X[1][1]) / 2
            rig.light("taillight_" + side, tb, (cx, lt, zc))
            rig.light("brake_" + side, bb, (cx, lt - 0.005, zc))
            # Rear blinkers: vertical amber strips at the outer corners, a gap from the squares.
            rb = MeshBuilder()
            a0, a1 = sorted((s * self.TAIL_BLINK_X[0], s * self.TAIL_BLINK_X[1]))
            kit.rect_y(a0, a1, tz0, tz1, lt, "signal_blinker", -1, rb)
            rig.light("blinker_R" + side, rb, (s * sum(self.TAIL_BLINK_X) / 2, lt, zc))
        # Reverse lamps: two small white lamps in the rear bumper face.
        rv = MeshBuilder()
        z0, z1 = self.BUMPER_R_Z
        by = ty - 0.065 - 0.015
        zm = (z0 + z1) / 2
        for s in (-1, 1):
            a0, a1 = sorted((s * 0.12, s * 0.28))
            kit.rect_y(a0, a1, zm - 0.03, zm + 0.03, by, "signal_reverse", -1, rv)
        rig.light("reverse", rv, (0.0, by, zm))

    def markers(self):
        m = super().markers()
        # Hood camera behind and above the shaker scoop so it sees the road over it.
        hood_y = self.SCOOP["y"][0] - 0.12
        hz = self.top_z(hood_y)
        m["cam_hood"] = (0.0, hood_y, self.SCOOP["top"] + 0.06)
        m["smoke_hood"] = (0.0, hood_y, hz)
        p = self.PIPE
        m["exhaust_L"] = (-p["x"], p["y"][0], p["z"])
        m["exhaust_R"] = (p["x"], p["y"][0], p["z"])
        return m

    # ---------------------------------------------------------------- interior

    def console(self, b):
        """Centre console with a pistol-grip shifter."""
        d = self.DASH
        fz = self.FLOOR_Z + 0.10
        top = fz + 0.24
        b.box((0.0, (d["y_rear"] + self.SEAT["y"]) / 2, (fz + top) / 2),
              (0.22, d["y_rear"] - self.SEAT["y"], top - fz), self.imat("console"), skip=("-z",))
        b.face([(-0.12, d["y_rear"] + 0.001, fz), (0.12, d["y_rear"] + 0.001, fz),
                (0.12, d["y_rear"] + 0.001, d["bottom"]), (-0.12, d["y_rear"] + 0.001, d["bottom"])],
               self.imat("dash_face"), (0, -1, 0))
        sy = (d["y_rear"] + self.SEAT["y"]) / 2 + 0.10
        # Chrome stick, then the pistol grip leaning back toward the driver.
        b.box((0.0, sy, top + 0.07), (0.018, 0.018, 0.14), "interior_steel", skip=("-z",))
        g = MeshBuilder()
        g.box((0, 0, 0), (0.045, 0.06, 0.13), "interior_bark")
        c, s = math.cos(-0.35), math.sin(-0.35)
        g = g.transformed(lambda p: (p[0], p[1] * c - p[2] * s, p[1] * s + p[2] * c))
        b.extend(g, (0.0, sy - 0.02, top + 0.19))
        b.box((0.0, sy, top + 0.005), (0.10, 0.14, 0.01), "interior_steel_dark", skip=("-z",))

    def interior_extras(self, b):
        # A row of small round-ish toggle plates on the metal dash face (right of the binnacle).
        d = self.DASH
        for i in range(3):
            x = 0.05 + i * 0.12
            b.face([(x, d["y_rear"] - 0.004, d["top"] - 0.12), (x + 0.07, d["y_rear"] - 0.004, d["top"] - 0.12),
                    (x + 0.07, d["y_rear"] - 0.004, d["top"] - 0.07), (x, d["y_rear"] - 0.004, d["top"] - 0.07)],
                   "interior_steel", (0, -1, 0))


CAR = BruteV8

if __name__ == "__main__":
    kit.run(CAR)
