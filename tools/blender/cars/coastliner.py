"""Coastliner, slot 5: the reward for reaching the coast (docs/ART_PRODUCTION.md §4.1.2, §4.1.5).

Early-60s grand-tourer speedster: long and low, a low raked windscreen with chrome
pillars, twin humps behind the seats, small tail fins with bullet taillights, lots of
chrome (bumpers, a side spear, lamp bezels, an oval grille), whitewall tires on
wire-look rims. Open cars are deferred (§7.6 Q3): closed with a low targa roof panel;
the rear window sits in the valley between the humps. Interior: a body-colour-look
(sky_pale) dash top, chrome gauge rings, a big ivory two-spoke wheel.

Proposed CarDef: 4.7 x 1.9 x 1.13 m, wheelbase 2.7, default paint sky_pale.

  blender -b --python tools/blender/cars/coastliner.py -- [--export] [--render] [--save]
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import wb_carkit as kit  # noqa: E402
from wb_carkit import MeshBuilder, disc_y, ring_pts  # noqa: E402

NY = 2.28     # nose
TY = -2.37    # tail


class Coastliner(kit.LoftCar):
    CAR_ID = "coastliner"
    CARDEF = {"length_m": 4.7, "width_m": 1.9, "height_m": 1.13, "wheelbase_m": 2.7,
              "default_paint": (0.698, 0.82, 0.878), "display_name": "Coastliner"}
    WHEELBASE = 2.7
    WHEEL_R = 0.31
    TIRE_W = 0.20
    RIM_IN = 0.195
    TRACK_F = 1.54
    TRACK_R = 1.54
    ARCH_R = 0.36
    WELL_X = 0.60
    NOSE_Y = NY
    TAIL_Y = TY
    # Rails: floorC floorE rocker lowSide shoulder belt roofSide pillarIn roofMid crown roofC.
    KEYS = [
        (TY, [(0, .36, .05), (.55, .36, .05), (.78, .38, .03), (.84, .44), (.88, .74), (.90, .95), (.74, .80),
              (.62, .80), (.36, .80), (.18, .80), (0, .80)]),
        (-2.27, [(0, .30), (.56, .30), (.82, .31), (.87, .42), (.905, .74), (.905, .945), (.76, .80), (.62, .80),
                 (.36, .805), (.18, .805), (0, .805)]),
        (-2.00, [(0, .22), (.58, .22), (.86, .24), (.91, .38), (.935, .74), (.915, .90), (.78, .815), (.62, .82),
                 (.36, .85), (.18, .83), (0, .825)]),
        (-1.70, [(0, .17), (.58, .17), (.87, .20), (.93, .36), (.95, .74), (.915, .86), (.80, .835), (.62, .845),
                 (.36, .91), (.18, .855), (0, .85)]),
        (-1.25, [(0, .17), (.58, .17), (.87, .20), (.93, .36), (.95, .735), (.905, .82), (.80, .83), (.60, .85),
                 (.36, 1.0), (.18, .895), (0, .875)]),
        (-0.95, [(0, .17), (.58, .17), (.865, .20), (.925, .36), (.94, .73), (.89, .80), (.76, .86), (.60, .90),
                 (.36, 1.06), (.18, .99), (0, .97)]),
        (-0.70, [(0, .17), (.58, .17), (.86, .20), (.915, .36), (.93, .73), (.88, .795), (.64, 1.075), (.58, 1.095),
                 (.36, 1.125), (.18, 1.13), (0, 1.13)]),
        (-0.10, [(0, .17), (.58, .17), (.86, .20), (.915, .36), (.93, .725), (.875, .795), (.66, 1.08), (.60, 1.10),
                 (.36, 1.125), (.18, 1.13), (0, 1.13)]),
        (0.40, [(0, .17), (.58, .17), (.86, .20), (.915, .36), (.93, .725), (.875, .80), (.82, .81), (.74, .82),
                (.36, .832), (.18, .835), (0, .835)]),
        (0.50, [(0, .17), (.58, .17), (.865, .20), (.915, .36), (.93, .725), (.878, .80), (.80, .805), (.66, .81),
                (.36, .825), (.18, .83), (0, .832)]),
        (1.20, [(0, .17), (.58, .17), (.87, .20), (.92, .37), (.935, .73), (.888, .80), (.80, .80), (.66, .79),
                (.36, .80), (.18, .808), (0, .81)]),
        (1.80, [(0, .20), (.58, .20), (.86, .22), (.91, .38), (.925, .72), (.88, .80), (.79, .795), (.66, .77),
                (.36, .76), (.18, .764), (0, .766)]),
        (2.12, [(0, .28), (.56, .28), (.80, .30), (.86, .40), (.875, .70), (.81, .755), (.72, .75), (.62, .72),
                (.36, .705), (.18, .705), (0, .705)]),
        (NY, [(0, .34, -.06), (.52, .34, -.06), (.72, .36, -.04), (.78, .42, -.02), (.80, .64), (.73, .69),
              (.64, .69), (.56, .67), (.34, .66), (.18, .66), (0, .66)]),
    ]
    REGIONS = {"windscreen": (-0.10, 0.40), "rear_glass": (-0.95, -0.70), "side_glass": (-0.70, 0.40)}
    MIRROR = (0.875, 0.22, 0.84)
    EYE = (-0.36, -0.42, 0.98)
    CABIN = (-1.0, 0.40)
    DASH = {"y_front": 0.40, "y_rear": 0.31, "top": 0.80, "bottom": 0.52}
    STEER = {"r": 0.21, "thick": 0.017, "spokes": 2, "tilt": -0.42, "sides": 22, "pos": (-0.36, 0.12, 0.69)}
    SEAT = {"y": -0.50, "cushion_z": 0.32, "back_top": 0.86, "w": 0.50}
    INTERIOR = dict(kit.LoftCar.INTERIOR, dash_top="sky_pale", dash_face="asphalt", door="asphalt",
                    seat="soil", seat_accent="soil_dark", wheel="cream", spoke="steel", hub="steel",
                    accent="ink", console="ink", liner="roof_slate")

    HEAD_Z = 0.565
    HEAD_R = 0.085
    HEAD_X = 0.64
    GRILLE = (0.0, 0.50, 0.33, 0.095)   # centre x, z, half-width, half-height (oval)
    BUMPER_F_Z = (0.33, 0.41)
    BUMPER_R_Z = (0.40, 0.48)
    FIN_LAMP = (0.83, 0.87, 0.075)      # x, z, r of the bullet taillights
    SPEAR_Z = (0.52, 0.575)

    # ---------------------------------------------------------------- body

    def body_material(self, y0, y1, j, arch):
        ym = (y0 + y1) / 2
        if j == kit.S_PILLAR and self.region("windscreen", ym):
            return "trim_steel"                     # chrome A-pillars
        if j in kit.TOP_STRIPS and self.region("rear_glass", ym):
            return "glass" if j in (kit.S_TOP_MID, kit.S_TOP_IN) else "paint"
        return super().body_material(y0, y1, j, arch)

    def details(self, b):
        fy = NY + 0.004
        # Chrome bezels around the round headlamps.
        hx, hz = self.HEAD_X, self.HEAD_Z
        outer = ring_pts(hx, hz, self.HEAD_R + 0.02, 14, fy + 0.012)
        inner = ring_pts(hx, hz, self.HEAD_R, 14, fy + 0.012)
        back = ring_pts(hx, hz, self.HEAD_R + 0.02, 14, fy - 0.01)
        for i in range(14):
            k = (i + 1) % 14
            b.face([outer[i], outer[k], inner[k], inner[i]], "trim_steel", (0, 1, 0))
            b.face([back[i], back[k], outer[k], outer[i]], "trim_steel", (outer[i][0] - hx, 0, outer[i][2] - hz))
        # Front bumper: a chrome blade wrapping round the corner.
        z0, z1 = self.BUMPER_F_Z
        b.box((0.36, NY + 0.025, (z0 + z1) / 2), (0.72, 0.05, z1 - z0), "trim_steel", skip=("-x", "-y"))
        b.face([(0.72, NY + 0.05, z0), (0.78, NY - 0.06, z0), (0.78, NY - 0.06, z1), (0.72, NY + 0.05, z1)],
               "trim_steel", (1, 0.4, 0))
        # Rear bumper blade (outer part; the plate sits in the middle).
        z0, z1 = self.BUMPER_R_Z
        b.box((0.55, TY - 0.025, (z0 + z1) / 2), (0.58, 0.05, z1 - z0), "trim_steel", skip=("-x", "+y"))
        b.face([(0.84, TY - 0.05, z0), (0.84, TY + 0.06, z0), (0.84, TY + 0.06, z1), (0.84, TY - 0.05, z1)],
               "trim_steel", (1, 0, 0))
        # Side spear: a chrome strip along the flank, pointed at the back.
        z0, z1 = self.SPEAR_Z
        ys = [0.93, 0.6, 0.2, -0.2, -0.55, -0.80]
        for ya, yb in zip(ys, ys[1:]):
            t_a = 1.0 if ya > -0.55 else 1.0
            t_b = 1.0 if yb > -0.55 else 0.0
            za0, za1 = z0 + (z1 - z0) * (1 - t_a) / 2, z1 - (z1 - z0) * (1 - t_a) / 2
            zb0, zb1 = z0 + (z1 - z0) * (1 - t_b) / 2, z1 - (z1 - z0) * (1 - t_b) / 2
            xa0, xa1 = self.side_x(ya, za0) + 0.006, self.side_x(ya, za1) + 0.006
            xb0, xb1 = self.side_x(yb, zb0) + 0.006, self.side_x(yb, zb1) + 0.006
            b.face([(xa0, ya, za0), (xb0, yb, zb0), (xb1, yb, zb1), (xa1, ya, za1)], "trim_steel", (1, 0, 0))
        # Chrome rim at the tail fin tips (a ring around each bullet lamp's base).
        fx, fz, fr = self.FIN_LAMP
        ring_o = ring_pts(fx, fz, fr + 0.018, 12, TY - 0.004)
        ring_i = ring_pts(fx, fz, fr, 12, TY - 0.004)
        for i in range(12):
            k = (i + 1) % 12
            b.face([ring_o[k], ring_o[i], ring_i[i], ring_i[k]], "trim_steel", (0, -1, 0))

    def center_details(self, b):
        # Oval grille: chrome ring, dark mouth, one chrome bar.
        cx, cz, hw, hh = self.GRILLE
        n = 16
        y = NY + 0.006
        outer = [(cx + (hw + 0.02) * math.cos(2 * math.pi * i / n), y, cz + (hh + 0.02) * math.sin(2 * math.pi * i / n))
                 for i in range(n)]
        inner = [(cx + hw * math.cos(2 * math.pi * i / n), y, cz + hh * math.sin(2 * math.pi * i / n)) for i in range(n)]
        for i in range(n):
            k = (i + 1) % n
            b.face([outer[i], outer[k], inner[k], inner[i]], "trim_steel", (0, 1, 0))
        b.face([(p[0], y - 0.002, p[2]) for p in inner], "trim_ink", (0, 1, 0))
        b.face([(-hw * 0.92, y + 0.004, cz - 0.012), (hw * 0.92, y + 0.004, cz - 0.012), (hw * 0.92, y + 0.004, cz + 0.012),
                (-hw * 0.92, y + 0.004, cz + 0.012)], "trim_steel", (0, 1, 0))
        # Rear plate and a chrome middle bumper piece under it.
        z0, z1 = self.BUMPER_R_Z
        ry = TY - 0.012
        b.face([(0.24, ry, z1 + 0.01), (-0.24, ry, z1 + 0.01), (-0.24, ry, z1 + 0.14), (0.24, ry, z1 + 0.14)],
               "trim_cream", (0, -1, 0))
        b.box((0, TY - 0.025, (z0 + z1) / 2), (0.52, 0.05, z1 - z0), "trim_steel", skip=("+y",))
        # Chrome strip across the tail under the deck lip.
        b.face([(0.72, TY - 0.006, 0.735), (-0.72, TY - 0.006, 0.735), (-0.72, TY - 0.006, 0.775),
                (0.72, TY - 0.006, 0.775)], "trim_steel", (0, -1, 0))
        # Twin exhaust pipes under the bumper.
        for sx in (-1, 1):
            pipe = MeshBuilder()
            pipe.cylinder_x((0, 0, 0), 0.03, -0.05, 0.08, 8, "trim_steel", cap_mat="trim_ink")
            b.extend(pipe.transformed(lambda p: (p[1], p[0], p[2])), (sx * 0.40, TY - 0.03, 0.29))

    def lod1_extras(self, b):
        z0, z1 = self.BUMPER_F_Z
        b.box((0.39, NY + 0.025, (z0 + z1) / 2), (0.78, 0.05, z1 - z0), "trim_steel", skip=("-x", "-y"))
        z0, z1 = self.BUMPER_R_Z
        b.box((0.42, TY - 0.025, (z0 + z1) / 2), (0.84, 0.05, z1 - z0), "trim_steel", skip=("-x", "+y"))
        cx, cz, hw, hh = self.GRILLE
        b.face([(0, NY + 0.006, cz - hh), (hw, NY + 0.006, cz - hh * 0.5), (hw, NY + 0.006, cz + hh * 0.5),
                (0, NY + 0.006, cz + hh)], "trim_ink", (0, 1, 0))

    # ---------------------------------------------------------------- wheels

    def tire(self, sides=None):
        """Whitewall: a white band on the outer (+X) sidewall."""
        t = MeshBuilder()
        w, R, ri = self.TIRE_W / 2, self.WHEEL_R, self.RIM_IN
        ch = 0.03
        prof = [(-w + 0.01, ri), (-w, ri + 0.03), (-w, R - ch), (-w + 0.03, R), (w - 0.03, R), (w, R - ch),
                (w, R - 0.045), (w, ri + 0.012), (w - 0.01, ri)]
        mats = ["trim_asphalt", "trim_asphalt", "trim_ink", "trim_ink", "trim_ink", "trim_asphalt", "trim_white",
                "trim_asphalt"]
        t.lathe_x(prof, sides or self.TIRE_SIDES, mats)
        return t

    def rim(self):
        """Wire-look: a chrome lip, a dark back plate, 16 laced spokes (1.2 cm) and a
        two-eared knock-off spinner."""
        r = MeshBuilder()
        xf = self.TIRE_W / 2 + 0.008
        lip_r = self.RIM_IN
        lip_in = lip_r * 0.9
        depth = 0.05
        r.lathe_x([(xf - 0.02, lip_r), (xf, lip_r), (xf, lip_in), (xf - depth, lip_in), (xf - depth, 0.045)], 20,
                  ["trim_steel", "trim_steel", "trim_steel_dark", "trim_ink"])
        n = 16
        w = 0.006
        for i in range(n):
            a0 = 2 * math.pi * i / n
            a1 = a0 + (0.42 if i % 2 == 0 else -0.42)
            r0, r1 = 0.05, lip_in - 0.004
            x0 = xf - 0.012 if i % 2 == 0 else xf - 0.024
            x1 = xf - depth + 0.006
            p0 = (x0, r0 * math.cos(a0), r0 * math.sin(a0))
            p1 = (x1, r1 * math.cos(a1), r1 * math.sin(a1))
            d = (p1[1] - p0[1], p1[2] - p0[2])
            ln = math.hypot(*d)
            perp = (-d[1] / ln * w, d[0] / ln * w)
            q = [(p0[0], p0[1] - perp[0], p0[2] - perp[1]), (p1[0], p1[1] - perp[0], p1[2] - perp[1]),
                 (p1[0], p1[1] + perp[0], p1[2] + perp[1]), (p0[0], p0[1] + perp[0], p0[2] + perp[1])]
            r.face(q, "trim_steel", (1, 0, 0))
            r.face([(p[0] - 0.008, p[1], p[2]) for p in reversed(q)], "trim_steel_dark", (-1, 0, 0))
        # Hub and spinner.
        r.lathe_x([(xf - 0.03, 0.05), (xf - 0.005, 0.05), (xf + 0.01, 0.03), (xf + 0.018, 0.0)], 10,
                  ["trim_steel", "trim_steel", "trim_steel"])
        for s in (-1, 1):
            r.box((xf + 0.01, 0.0, s * 0.055), (0.016, 0.018, 0.06), "trim_steel")
        return r

    # ---------------------------------------------------------------- lights

    def lights(self, rig):
        ly = NY + 0.018
        lt = TY - 0.004
        fx, fz, fr = self.FIN_LAMP
        for side, s in (("L", -1), ("R", 1)):
            rig.light("headlight_" + side, disc_y(s * self.HEAD_X, self.HEAD_Z, self.HEAD_R, 14, ly, "lamp_head", 1),
                      (s * self.HEAD_X, ly, self.HEAD_Z))
            fb = kit.lamp_box(s * 0.53, 0.445, 0.13, 0.06, NY, 0.015, "signal_blinker", 1)
            rig.light("blinker_F" + side, fb, (s * 0.53, NY + 0.0075, 0.445))
            # Bullet taillight: a short barrel from the fin tip, lens facing back.
            tb = MeshBuilder()
            ln = 0.07
            ring0 = ring_pts(s * fx, fz, fr, 12, lt)
            ring1 = ring_pts(s * fx, fz, fr * 0.92, 12, lt - ln)
            for i in range(12):
                k = (i + 1) % 12
                tb.face([ring0[i], ring0[k], ring1[k], ring1[i]], "lamp_tail",
                        (ring0[i][0] - s * fx, 0, ring0[i][2] - fz))
            tb.face(list(reversed(ring1)), "lamp_tail", (0, -1, 0))
            rig.light("taillight_" + side, tb, (s * fx, lt - ln / 2, fz))
            bb = disc_y(s * fx, fz, fr * 0.7, 12, lt - ln - 0.005, "signal_brake", -1)
            rig.light("brake_" + side, bb, (s * fx, lt - ln - 0.005, fz))
            rb = kit.lamp_box(s * 0.62, 0.60, 0.15, 0.07, TY, 0.015, "signal_blinker", -1)
            rig.light("blinker_R" + side, rb, (s * 0.62, TY - 0.0075, 0.60))
        rv = MeshBuilder()
        for s in (-1, 1):
            kit.lamp_box(s * 0.33, 0.55, 0.10, 0.05, TY, 0.015, "signal_reverse", -1, rv)
        rig.light("reverse", rv, (0.0, TY - 0.0075, 0.55))

    def markers(self):
        m = super().markers()
        m["exhaust_L"] = (-0.40, TY - 0.11, 0.29)
        m["exhaust_R"] = (0.40, TY - 0.11, 0.29)
        return m

    # ---------------------------------------------------------------- interior

    def interior_extras(self, b):
        """Chrome rings around the two dials (the gauge quad's left and right halves)."""
        d = self.DASH
        top = d["top"]
        gy, gz = d["y_rear"] - 0.04, top - 0.05
        ex, ey, ez = self.EYE
        tilt = math.atan2(ez - gz, gy - ey)
        c, s = math.cos(tilt), math.sin(tilt)
        h = self.GAUGE_W / 2.6
        for dx in (-self.GAUGE_W / 4, self.GAUGE_W / 4):
            outer = ring_pts(dx, 0.0, h / 2 + 0.012, 14, -0.006)
            inner = ring_pts(dx, 0.0, h / 2 - 0.004, 14, -0.006)
            for i in range(14):
                k = (i + 1) % 14
                q = [outer[k], outer[i], inner[i], inner[k]]
                q = [(ex + p[0], gy + p[1] * c + p[2] * s, gz - p[1] * s + p[2] * c) for p in q]
                b.face(q, "interior_steel", (0, -c, s))


CAR = Coastliner

if __name__ == "__main__":
    kit.run(CAR)
