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
    # Sculpted, not boxy: barrel sides that tuck under (lowSide well inside the
    # shoulder), coke-bottle haunches swelling over the rear wheels, a crowned hood and
    # roof with rounded edges, rounded plan-view corners at both ends, a smooth
    # semi-fastback. Crisp lines only at the window line / fender tops (belt) and the
    # windscreen base.
    KEYS = [
        (TAIL_Y, [(0, .40, .05), (.55, .40, .05), (.80, .40, .03), (.85, .46, .01), (.885, .82), (.865, .985),
                  (.76, 1.005), (.66, 1.012), (.38, 1.018), (.19, 1.02), (0, 1.02)]),
        (-2.38, [(0, .34), (.58, .34), (.86, .33), (.905, .44), (.94, .83), (.91, .99), (.79, 1.0), (.68, 1.004),
                 (.37, 1.008), (.19, 1.01), (0, 1.01)]),
        (-1.90, [(0, .20), (.60, .19), (.88, .21), (.925, .40), (.972, .85), (.925, 1.0), (.81, 1.01), (.71, 1.014),
                 (.37, 1.018), (.19, 1.02), (0, 1.02)]),
        (-1.55, [(0, .18), (.60, .18), (.88, .20), (.925, .38), (.975, .84), (.92, .99), (.78, 1.01),
                 (.70, 1.018), (.37, 1.025), (.19, 1.027), (0, 1.027)]),
        (-0.95, [(0, .18), (.60, .18), (.87, .20), (.91, .37), (.958, .81), (.905, .955), (.735, 1.30),
                 (.67, 1.325), (.37, 1.345), (.19, 1.35), (0, 1.35)]),
        (-0.20, [(0, .18), (.60, .18), (.855, .20), (.885, .37), (.945, .80), (.90, .95), (.725, 1.30),
                 (.665, 1.325), (.37, 1.345), (.19, 1.35), (0, 1.35)]),
        (0.45, [(0, .18), (.60, .18), (.855, .20), (.885, .37), (.948, .80), (.905, .945), (.85, .952), (.76, .958),
                (.37, .965), (.19, .968), (0, .968)]),
        (0.55, [(0, .18), (.60, .18), (.87, .20), (.905, .37), (.952, .80), (.91, .94), (.83, .948), (.73, .953),
                (.37, .96), (.19, .963), (0, .963)]),
        (1.40, [(0, .18), (.60, .18), (.875, .21), (.91, .39), (.955, .80), (.91, .935), (.83, .942), (.73, .946),
                (.37, .954), (.19, .957), (0, .957)]),
        (2.15, [(0, .24), (.60, .24), (.86, .28), (.895, .42), (.94, .78), (.90, .905), (.82, .91), (.72, .913),
                (.37, .922), (.19, .925), (0, .926)]),
        (2.28, [(0, .29), (.58, .29), (.83, .31), (.87, .41), (.91, .775), (.875, .89), (.80, .895), (.71, .898),
                (.37, .906), (.19, .909), (0, .91)]),
        (NOSE_Y, [(0, .32, -.04), (.55, .32, -.04), (.79, .33, -.02), (.83, .40), (.865, .77), (.835, .878),
                  (.77, .884), (.69, .887), (.36, .894), (.19, .897), (0, .898)]),
    ]
    CREASE_Y = (0.45,)                 # the windscreen base
    SHARP_RAILS = (1, 2, kit.R_BELT)   # floor edge, rocker, the window line / fender tops
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
    GRILLE_X = 0.82
    HEAD_Z = 0.66
    HEAD_R = 0.078
    HEAD_X = (0.50, 0.70)
    BUMPER_F_Z = (0.38, 0.50)
    BUMPER_R_Z = (0.44, 0.56)
    TAIL_Z = (0.68, 0.88)
    TAIL_X = ((0.26, 0.47), (0.51, 0.72))
    TAIL_BLINK_X = (0.76, 0.84)
    TAIL_PANEL_X = 0.86
    # Shaker scoop: a closed, low solid (height above the hood at its rear end). Its top
    # stays HOOD_CAM_CLEAR below the hood camera even with the body pitched nose-up
    # (body_pitch_max_deg) and rolled (body_roll_max_deg): see markers().
    SCOOP = {"y": (1.18, 1.52), "w": 0.25, "height": 0.05}
    HOOD_CAM_CLEAR = 0.08
    BODY_PITCH_DEG = 2.0       # data/tuning/vehicle.tres body_pitch_max_deg
    BODY_ROLL_DEG = 4.0        # body_roll_max_deg
    BODY_PIVOT_Z = 0.5
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
        b.box((0.44, ty - 0.03, (z0 + z1) / 2), (0.88, 0.07, z1 - z0), "trim_steel", skip=("-x",))
        tz0, tz1 = self.TAIL_Z
        px = self.TAIL_PANEL_X
        b.face([(px, ty - 0.004, tz0 - 0.04), (0, ty - 0.004, tz0 - 0.04), (0, ty - 0.004, tz1 + 0.04),
                (px, ty - 0.004, tz1 + 0.04)], "trim_ink", (0, -1, 0))
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
            lip.face([(0, ya, za), (0.82, ya, za), (0.82, yb, zb), (0, yb, zb)], "trim_ink",
                     (0, (ya + yb) / 2 - cy, (za + zb) / 2 - cz))
        lip.face([(0.82, 0, 0), (0.82, 0, 0.075), (0.82, 0.17, 0)], "trim_ink", (1, 0, 0))
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
        b.extend(self.scoop())
        # Rear licence plate in the middle of the tail panel.
        tz0, tz1 = self.TAIL_Z
        ry = self.TAIL_Y - 0.012
        zc = (tz0 + tz1) / 2
        b.face([(0.24, ry, zc - 0.075), (-0.24, ry, zc - 0.075), (-0.24, ry, zc + 0.075), (0.24, ry, zc + 0.075)],
               "trim_cream", (0, -1, 0))

    def scoop_top(self):
        s = self.SCOOP
        return self.top_z(s["y"][1]) + s["height"]

    def scoop(self, detail=True):
        """The shaker scoop as a CLOSED solid: a chamfered prism along Y (both end caps
        and the base present, outward normals) whose base sinks 2 cm into the hood, so
        no camera angle can look inside it. The intake is a dark recessed panel framed
        in chrome on the front cap, not an opening."""
        s = self.SCOOP
        y0, y1 = s["y"]
        w = s["w"]
        top = self.scoop_top()
        base = min(self.top_z(y0), self.top_z(y1)) - 0.02
        ch = 0.02
        prof = [(-w, base), (w, base), (w, top - ch), (w - ch, top), (-w + ch, top), (-w, top - ch)]
        sc = MeshBuilder()
        n = len(prof)
        cx, cz = 0.0, (base + top) / 2
        for i in range(n):
            (xa, za), (xb, zb) = prof[i], prof[(i + 1) % n]
            m = "trim_asphalt" if za >= top - 1e-6 and zb >= top - 1e-6 else "trim_ink"
            sc.face([(xa, y0, za), (xb, y0, zb), (xb, y1, zb), (xa, y1, za)], m,
                    ((xa + xb) / 2 - cx, 0, (za + zb) / 2 - cz))
        sc.face([(x, y1, z) for x, z in prof], "trim_ink", (0, 1, 0))
        sc.face([(x, y0, z) for x, z in prof], "trim_ink", (0, -1, 0))
        if detail:
            # Intake: a black panel 3 mm proud of the front cap, framed in chrome.
            yf = y1 + 0.003
            zm0, zm1 = base + 0.03, top - 0.012
            xm = w - 0.03
            sc.face([(-xm, yf, zm0), (xm, yf, zm0), (xm, yf, zm1), (-xm, yf, zm1)], "trim_ink", (0, 1, 0))
            e = 0.012
            for (a0, a1, c0, c1) in ((-xm - e, xm + e, zm1, zm1 + e), (-xm - e, xm + e, zm0 - e, zm0),
                                     (-xm - e, -xm, zm0, zm1), (xm, xm + e, zm0, zm1)):
                sc.face([(a0, yf + 0.002, c0), (a1, yf + 0.002, c0), (a1, yf + 0.002, c1), (a0, yf + 0.002, c1)],
                        "trim_steel", (0, 1, 0))
            # Chrome base plate on the hood around the scoop.
            plate = MeshBuilder()
            hz = self.top_z((y0 + y1) / 2)
            plate.box((0, (y0 + y1) / 2, hz + 0.004), (2 * w + 0.06, y1 - y0 + 0.06, 0.012), "trim_steel",
                      skip=("-z",))
            sc.extend(plate)
        return sc

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
        px = self.TAIL_PANEL_X
        b.face([(px, ty, tz0 - 0.04), (0, ty, tz0 - 0.04), (0, ty, tz1 + 0.04), (px, ty, tz1 + 0.04)], "trim_ink",
               (0, -1, 0))
        s = self.SCOOP
        base = self.top_z(s["y"][1]) - 0.02
        top = self.scoop_top()
        b.box((s["w"] / 2, sum(s["y"]) / 2, (base + top) / 2), (s["w"], s["y"][1] - s["y"][0], top - base),
              "trim_ink", skip=("-x",))
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
        # Hood camera just behind the shaker scoop. The camera is rigid on the car root
        # while the body pitches nose-up and rolls, so the scoop's highest corner rises
        # toward the view; keep it HOOD_CAM_CLEAR below the camera at full pitch + roll.
        s = self.SCOOP
        hood_y = s["y"][0] - 0.38
        hz = self.top_z(hood_y)
        top = self.scoop_top()
        pitch, roll = math.radians(self.BODY_PITCH_DEG), math.radians(self.BODY_ROLL_DEG)
        rise = max(y * math.sin(pitch) + (top - self.BODY_PIVOT_Z) * (math.cos(pitch) - 1.0) for y in s["y"])
        rise += s["w"] * math.sin(roll)
        m["cam_hood"] = (0.0, hood_y, round(top + rise + self.HOOD_CAM_CLEAR, 3))
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
