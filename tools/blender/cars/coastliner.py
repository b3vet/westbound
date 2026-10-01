"""Coastliner, slot 5: the reward for reaching the coast (docs/ART_PRODUCTION.md §4.1.2, §4.1.5).

Early-60s grand-tourer speedster, the smoothest car of the roster: long and low, fully
rounded flanks with fender bulges over both axles, a long crowned hood between rounded
fender crowns, a soft rounded nose with an oval grille and chromed headlamp buckets,
smooth twin humps behind the cabin that flow into the deck, small fins that rise out of
the rear fenders into bullet-lamp pods, a rounded tail, swept chrome tube bumpers, a
chrome side spear, whitewall tires on wire-look rims. Open cars are deferred (§7.6 Q3):
closed with a low targa roof; the rear window sits in the valley between the humps.
Interior: a body-colour-look (sky_pale) dash top, chrome gauge rings, a big ivory
two-spoke wheel.

Proposed CarDef: 4.7 x 1.9 x 1.13 m, wheelbase 2.7, default paint sky_pale.

  blender -b --python tools/blender/cars/coastliner.py -- [--export] [--render] [--save]
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import wb_carkit as kit  # noqa: E402
import wb_mesh  # noqa: E402
from wb_carkit import MeshBuilder, disc_y, ring_pts  # noqa: E402

NY = 2.28     # nose (the fascia plane)
TY = -2.37    # tail (the tail panel plane)
SAMPLE_SUB = 8   # curve samples per strip for surface lookups


def _sweep_ring(b, path, half_w, half_h, mat, sides, group, cap_start=False, cap_end=False):
    """A smooth tube along `path` (points), elliptic section: half_w across the path
    horizontally, half_h vertically. Outward faces."""
    rings = []
    n = len(path)
    for i, p in enumerate(path):
        a = path[max(0, i - 1)]
        c = path[min(n - 1, i + 1)]
        t = wb_mesh.v_norm(wb_mesh.v_sub(c, a))
        side = wb_mesh.v_norm(wb_mesh.v_cross(t, (0.0, 0.0, 1.0)))
        if wb_mesh.v_len(side) < 1e-6:
            side = (1.0, 0.0, 0.0)
        ring = []
        for k in range(sides):
            th = 2 * math.pi * k / sides
            ring.append(wb_mesh.v_add(p, wb_mesh.v_add(wb_mesh.v_scale(side, half_w * math.cos(th)),
                                                       (0.0, 0.0, half_h * math.sin(th)))))
        rings.append((p, ring))
    for (pa, ra), (pb, rb) in zip(rings, rings[1:]):
        for k in range(sides):
            k1 = (k + 1) % sides
            q = [ra[k], ra[k1], rb[k1], rb[k]]
            mid = wb_mesh.v_scale(wb_mesh.v_add(wb_mesh.v_add(q[0], q[1]), wb_mesh.v_add(q[2], q[3])), 0.25)
            ctr = wb_mesh.v_scale(wb_mesh.v_add(pa, pb), 0.5)
            b.face(q, mat, wb_mesh.v_sub(mid, ctr), smooth=True, group=group)
    if cap_start:
        p0, r0 = rings[0]
        b.face(r0, mat, wb_mesh.v_sub(p0, rings[1][0]))
    if cap_end:
        p1, r1 = rings[-1]
        b.face(r1, mat, wb_mesh.v_sub(p1, rings[-2][0]))


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
    ARCH_R = 0.355
    WELL_X = 0.60
    NOSE_Y = NY
    TAIL_Y = TY
    # Smooth everywhere but the floor edge, the rocker and the door bottom: the
    # shoulder, the window line and the fender crowns are all one rounded surface.
    SHARP_RAILS = (1, 2, 3)
    LOFT_STEP = 0.14
    LOFT_SEG = 0.10
    # Creases across the car: the windscreen base and the roof's front edge.
    CREASE_Y = (-0.10, 0.40)
    # Rails: floorC floorE rocker lowSide shoulder belt roofSide pillarIn roofMid crown roofC.
    # Over the hood: belt = where the flank turns onto the top, roofSide = the fender
    # crown, pillarIn = the valley beside the hood, roofMid..roofC = the crowned hood.
    # Behind the cabin: roofMid = the hump crest, crown/roofC = the valley between.
    KEYS = [
        (TY, [(0, .40), (.40, .40), (.52, .42), (.58, .48), (.62, .62), (.58, .74), (.50, .765), (.42, .775),
              (.26, .78), (.13, .78), (0, .78)]),
        (-2.28, [(0, .33), (.50, .33), (.70, .35), (.76, .44), (.80, .66), (.76, .80), (.64, .81), (.52, .805),
                 (.30, .80), (.15, .80), (0, .80)]),
        (-2.10, [(0, .25), (.56, .25), (.82, .27), (.88, .38), (.92, .68), (.86, .85), (.74, .835), (.60, .815),
                 (.34, .82), (.17, .812), (0, .81)]),
        (-1.80, [(0, .19), (.58, .18), (.86, .21), (.92, .34), (.95, .70), (.885, .87), (.76, .845), (.60, .83),
                 (.36, .86), (.18, .838), (0, .832)]),
        (-1.35, [(0, .17), (.58, .17), (.86, .19), (.92, .32), (.952, .72), (.89, .865), (.77, .855), (.60, .865),
                 (.36, .945), (.18, .895), (0, .885)]),
        (-0.95, [(0, .17), (.58, .17), (.85, .19), (.90, .30), (.935, .68), (.885, .825), (.76, .865), (.60, .915),
                 (.36, 1.05), (.18, .995), (0, .98)]),
        (-0.70, [(0, .17), (.58, .17), (.84, .19), (.89, .30), (.925, .665), (.875, .79), (.66, 1.07), (.59, 1.095),
                 (.36, 1.123), (.18, 1.13), (0, 1.13)]),
        (-0.10, [(0, .17), (.58, .17), (.84, .19), (.89, .30), (.925, .66), (.872, .795), (.66, 1.08), (.60, 1.10),
                 (.36, 1.125), (.18, 1.13), (0, 1.13)]),
        (0.40, [(0, .17), (.58, .17), (.845, .19), (.89, .30), (.93, .67), (.875, .80), (.82, .81), (.74, .815),
                (.36, .83), (.18, .835), (0, .835)]),
        (0.55, [(0, .17), (.58, .17), (.85, .19), (.895, .31), (.935, .69), (.885, .80), (.78, .825), (.62, .80),
                (.36, .81), (.18, .82), (0, .825)]),
        (1.35, [(0, .17), (.58, .17), (.86, .19), (.91, .32), (.952, .72), (.895, .80), (.78, .835), (.60, .795),
                (.36, .80), (.18, .81), (0, .815)]),
        (1.85, [(0, .20), (.58, .20), (.85, .22), (.90, .34), (.935, .68), (.88, .78), (.76, .805), (.58, .77),
                (.36, .77), (.18, .776), (0, .778)]),
        (2.10, [(0, .27), (.56, .27), (.80, .29), (.85, .38), (.875, .65), (.82, .74), (.70, .755), (.54, .735),
                (.33, .735), (.17, .74), (0, .742)]),
        (NY, [(0, .36), (.40, .36), (.52, .37), (.58, .44), (.60, .58), (.55, .66), (.48, .68), (.40, .685),
              (.24, .69), (.12, .695), (0, .70)]),
    ]
    REGIONS = {"windscreen": (-0.10, 0.40), "rear_glass": (-0.95, -0.70), "side_glass": (-0.70, 0.40)}
    MIRROR = (0.872, 0.22, 0.83)
    EYE = (-0.36, -0.42, 0.98)
    CABIN = (-1.0, 0.40)
    DASH = {"y_front": 0.40, "y_rear": 0.31, "top": 0.80, "bottom": 0.52}
    STEER = {"r": 0.21, "thick": 0.017, "spokes": 2, "tilt": -0.42, "sides": 22, "pos": (-0.36, 0.12, 0.69)}
    SEAT = {"y": -0.50, "cushion_z": 0.32, "back_top": 0.86, "w": 0.50}
    INTERIOR = dict(kit.LoftCar.INTERIOR, dash_top="sky_pale", dash_face="asphalt", door="asphalt",
                    seat="soil", seat_accent="soil_dark", wheel="cream", spoke="steel", hub="steel",
                    accent="ink", console="ink", liner="roof_slate")

    HEAD_X = 0.475
    HEAD_Z = 0.565
    HEAD_R = 0.078
    GRILLE = (0.0, 0.47, 0.29, 0.075)   # centre x, z, half-width, half-height (oval)
    BUMPER_F_Z = 0.335                  # centre height of the front tube
    BUMPER_R_Z = 0.43
    BUMPER_HW, BUMPER_HH = 0.032, 0.036
    # Fin: (y, x, z, half-width, half-height) of an elliptic section, tail last; it
    # grows from a thin blade on the rear fender into the bullet-lamp pod.
    FIN = [(-1.05, .845, .848, .010, .008), (-1.45, .845, .872, .020, .032), (-1.85, .842, .893, .032, .052),
           (-2.12, .832, .903, .058, .072), (-2.28, .816, .905, .085, .086), (-2.33, .812, .905, .092, .092)]
    SPEAR_Z = (0.50, 0.555)

    # ---------------------------------------------------------------- surface lookups

    def main_loft(self):
        lo = super().main_loft()
        lo.caps = ("paint", "paint")
        return lo

    def section(self, y):
        """The body's half section at y as a dense point list (arches applied)."""
        lo = self.main_loft()
        rails, _arch = self.arch_rails(y, lo.station(y))
        P = [(x, y + dy, z) for (x, z, dy) in rails]
        return lo._curve(P, [SAMPLE_SUB] * (len(P) - 1))

    def surf_x(self, y, z):
        """The flank's x at (y, z) on the actual (curved) surface, rocker to belt."""
        c = self.section(y)
        side = c[2 * SAMPLE_SUB:5 * SAMPLE_SUB + 1]
        if z <= side[0][2]:
            return side[0][0]
        for a, b in zip(side, side[1:]):
            lo, hi = sorted((a[2], b[2]))
            if lo - 1e-9 <= z <= hi + 1e-9 and hi > lo:
                t = (z - a[2]) / (b[2] - a[2])
                return a[0] + (b[0] - a[0]) * t
        return max(p[0] for p in side)

    # ---------------------------------------------------------------- body

    def body_material(self, y0, y1, j, arch):
        ym = (y0 + y1) / 2
        if j == kit.S_PILLAR and self.region("windscreen", ym):
            return "trim_steel"                     # chrome A-pillars
        if j in kit.TOP_STRIPS and self.region("rear_glass", ym):
            return "glass" if j in (kit.S_TOP_MID, kit.S_TOP_IN) else "paint"
        return super().body_material(y0, y1, j, arch)

    def door_mirror(self, b):
        """A small chromed bullet mirror on a stalk at the door top."""
        mx, my, mz = self.MIRROR
        pod = MeshBuilder()
        pod.lathe_x([(-0.07, 0.0), (-0.055, 0.022), (-0.02, 0.032), (0.03, 0.03), (0.04, 0.0)], 10,
                    ["paint", "paint", "paint", "trim_ink"])
        pod = pod.transformed(lambda p: (p[1], p[0], p[2])).smoothed("mirror")
        b.extend(pod, (mx + 0.045, my, mz + 0.035))
        b.box((mx + 0.02, my - 0.01, mz + 0.012), (0.04, 0.025, 0.025), "trim_steel")

    def fin(self, b):
        """Smooth fin blade growing into the bullet-lamp pod (right side)."""
        keys = self.FIN
        ys = [k[0] for k in keys][::-1]
        cols = [[k[c] for k in keys][::-1] for c in range(1, 5)]
        slopes = [kit.pchip_slopes(ys, col) for col in cols]
        samples = []
        y = ys[0]
        while y < ys[-1] - 1e-6:
            samples.append(y)
            y += 0.07
        samples.append(ys[-1])
        sides = 14
        rings = []
        for y in samples:
            for s in range(len(ys) - 1):
                if ys[s] - 1e-9 <= y <= ys[s + 1] + 1e-9:
                    h = ys[s + 1] - ys[s]
                    t = (y - ys[s]) / h
                    cx, cz, a, bb = (kit.hermite(cols[c][s], cols[c][s + 1], slopes[c][s], slopes[c][s + 1], h, t)
                                     for c in range(4))
                    break
            rings.append(((cx, y, cz), [(cx + a * math.cos(2 * math.pi * k / sides), y,
                                          cz + bb * math.sin(2 * math.pi * k / sides)) for k in range(sides)]))
        for (ca, ra), (cb, rb) in zip(rings, rings[1:]):
            for k in range(sides):
                k1 = (k + 1) % sides
                q = [ra[k], rb[k], rb[k1], ra[k1]]
                mid = wb_mesh.v_scale(wb_mesh.v_add(wb_mesh.v_add(q[0], q[1]), wb_mesh.v_add(q[2], q[3])), 0.25)
                out = (mid[0] - (ca[0] + cb[0]) / 2, 0.0, mid[2] - (ca[2] + cb[2]) / 2)
                b.face(q, "paint", out, smooth=True, group="fin")
        # Thin front tip (inside the fender) and the pod mouth: a chrome ring around
        # the lamp barrel, a dark recess behind it.
        b.face(rings[-1][1], "paint", (0, 1, 0))
        (cx, y0, cz), ring = rings[0]
        fx, fz, fr = self.fin_lamp()
        outer = ring_pts(fx, fz, fr + 0.011, sides, y0)
        inner = ring_pts(fx, fz, fr, sides, y0 - 0.002)
        for k in range(sides):
            k1 = (k + 1) % sides
            b.face([ring[k1], ring[k], outer[k], outer[k1]], "trim_steel", (0, -1, 0))
            b.face([outer[k1], outer[k], inner[k], inner[k1]], "trim_steel", (0, -1, 0))
        b.face(list(reversed(inner)), "trim_ink", (0, -1, 0))

    def fin_lamp(self):
        y, x, z, a, bb = self.FIN[-1]
        return x, z, 0.077

    def headlamp_buckets(self, b):
        """Chromed buckets standing out of the fascia around each round lamp."""
        hx, hz, r = self.HEAD_X, self.HEAD_Z, self.HEAD_R
        n = 16
        y0, y1 = NY - 0.01, NY + 0.035
        ro, ri = r + 0.018, r + 0.002
        back = ring_pts(hx, hz, ro, n, y0)
        front_o = ring_pts(hx, hz, ro, n, y1)
        front_i = ring_pts(hx, hz, ri, n, y1)
        inner_b = ring_pts(hx, hz, ri, n, NY + 0.012)
        for i in range(n):
            k = (i + 1) % n
            b.face([back[i], back[k], front_o[k], front_o[i]], "trim_steel",
                   (back[i][0] - hx, 0, back[i][2] - hz), smooth=True, group="bucket")
            b.face([front_o[i], front_o[k], front_i[k], front_i[i]], "trim_steel", (0, 1, 0))
            b.face([front_i[i], front_i[k], inner_b[k], inner_b[i]], "trim_steel_dark",
                   (hx - front_i[i][0], 0, hz - front_i[i][2]))

    def bumper_path(self, front):
        """Right half of a wrapping bumper: along the flank, round the corner, across."""
        z_ref = 0.42 if front else self.BUMPER_R_Z
        out = 0.038
        if front:
            ys = [2.0, 2.08, 2.15, 2.21, 2.25]
            end, face_y = NY, NY + out
        else:
            ys = [-2.02, -2.10, -2.18, -2.25, -2.32]
            end, face_y = TY, TY - out
        sign = 1 if front else -1
        z = self.BUMPER_F_Z if front else self.BUMPER_R_Z
        # Tucked against the flank where it starts, standing out round the corner.
        pts = [(self.surf_x(y, z_ref) + 0.012 + (out - 0.012) * i / (len(ys) - 1), y, z) for i, y in enumerate(ys)]
        xe = self.surf_x(end, z_ref)
        pts += [(xe + out * 0.55, end + sign * out * 0.55, z), (xe - 0.03, face_y, z), (xe * 0.5, face_y, z),
                (0.0, face_y, z)]
        return pts

    def details(self, b):
        self.headlamp_buckets(b)
        self.fin(b)
        # Wrapping chrome tube bumpers (the left halves come from the mirror; the
        # centre points meet at x = 0).
        _sweep_ring(b, self.bumper_path(True), self.BUMPER_HW, self.BUMPER_HH, "trim_steel", 8, "bumper_f",
                    cap_start=True)
        _sweep_ring(b, self.bumper_path(False), self.BUMPER_HW, self.BUMPER_HH, "trim_steel", 8, "bumper_r",
                    cap_start=True)
        # Side spear: a chrome strip on the curved flank, tapering to a point at the back.
        z0, z1 = self.SPEAR_Z
        ys = [0.90, 0.62, 0.32, 0.02, -0.28, -0.55, -0.80]
        for ya, yb in zip(ys, ys[1:]):
            ta = 1.0 if ya > -0.55 else 0.0
            tb = 1.0 if yb > -0.55 else 0.0
            zm = (z0 + z1) / 2
            za0, za1 = zm - (z1 - z0) / 2 * max(ta, 0.08), zm + (z1 - z0) / 2 * max(ta, 0.08)
            zb0, zb1 = zm - (z1 - z0) / 2 * max(tb, 0.08), zm + (z1 - z0) / 2 * max(tb, 0.08)
            q = [(self.surf_x(ya, za0) + 0.005, ya, za0), (self.surf_x(yb, zb0) + 0.005, yb, zb0),
                 (self.surf_x(yb, zb1) + 0.005, yb, zb1), (self.surf_x(ya, za1) + 0.005, ya, za1)]
            b.face(q, "trim_steel", (1, 0, 0), smooth=True, group="spear")
        # Chrome strip across the tail under the deck lip.
        b.face([(0.54, TY - 0.004, 0.725), (0, TY - 0.004, 0.725), (0, TY - 0.004, 0.755), (0.54, TY - 0.004, 0.755)],
               "trim_steel", (0, -1, 0))

    def center_details(self, b):
        # Oval grille: chrome ring, dark mouth, one chrome bar.
        cx, cz, hw, hh = self.GRILLE
        n = 20
        y = NY + 0.006
        outer = [(cx + (hw + 0.02) * math.cos(2 * math.pi * i / n), y, cz + (hh + 0.02) * math.sin(2 * math.pi * i / n))
                 for i in range(n)]
        inner = [(cx + hw * math.cos(2 * math.pi * i / n), y, cz + hh * math.sin(2 * math.pi * i / n)) for i in range(n)]
        for i in range(n):
            k = (i + 1) % n
            b.face([outer[i], outer[k], inner[k], inner[i]], "trim_steel", (0, 1, 0))
        b.face([(p[0], y - 0.002, p[2]) for p in inner], "trim_ink", (0, 1, 0))
        b.face([(-hw * 0.92, y + 0.004, cz - 0.011), (hw * 0.92, y + 0.004, cz - 0.011),
                (hw * 0.92, y + 0.004, cz + 0.011), (-hw * 0.92, y + 0.004, cz + 0.011)], "trim_steel", (0, 1, 0))
        # Rear plate above the bumper tube.
        ry = TY - 0.008
        b.face([(0.24, ry, 0.49), (-0.24, ry, 0.49), (-0.24, ry, 0.62), (0.24, ry, 0.62)], "trim_cream", (0, -1, 0))
        # Twin exhaust pipes under the tail.
        for sx in (-1, 1):
            pipe = MeshBuilder()
            pipe.cylinder_x((0, 0, 0), 0.03, -0.06, 0.08, 10, "trim_steel", cap_mat="trim_ink")
            pipe = pipe.transformed(lambda p: (p[1], p[0], p[2]))
            b.extend(pipe, (sx * 0.40, TY - 0.02, 0.30))

    def lod1_extras(self, b):
        cx, cz, hw, hh = self.GRILLE
        b.face([(0, NY + 0.006, cz - hh), (hw, NY + 0.006, cz - hh * 0.5), (hw, NY + 0.006, cz + hh * 0.5),
                (0, NY + 0.006, cz + hh)], "trim_ink", (0, 1, 0))
        b.box((0.30, NY + 0.035, self.BUMPER_F_Z), (0.60, 0.05, 0.07), "trim_steel", skip=("-x", "-y"))
        b.box((0.30, TY - 0.035, self.BUMPER_R_Z), (0.60, 0.05, 0.07), "trim_steel", skip=("-x", "+y"))

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
        return t.smoothed("tire")

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
        r.lathe_x([(xf - 0.03, 0.05), (xf - 0.005, 0.05), (xf + 0.01, 0.03), (xf + 0.018, 0.0)], 10,
                  ["trim_steel", "trim_steel", "trim_steel"])
        for s in (-1, 1):
            r.box((xf + 0.01, 0.0, s * 0.055), (0.016, 0.018, 0.06), "trim_steel")
        return r

    # ---------------------------------------------------------------- lights

    def lights(self, rig):
        ly = NY + 0.027                      # inside the bucket, 1.5 cm proud of the fascia
        fx, fz, fr = self.fin_lamp()
        mouth = self.FIN[-1][0]
        for side, s in (("L", -1), ("R", 1)):
            rig.light("headlight_" + side, disc_y(s * self.HEAD_X, self.HEAD_Z, self.HEAD_R, 16, ly, "lamp_head", 1),
                      (s * self.HEAD_X, ly, self.HEAD_Z))
            fb = kit.lamp_box(s * 0.475, 0.425, 0.12, 0.05, NY, 0.015, "signal_blinker", 1)
            rig.light("blinker_F" + side, fb, (s * 0.475, NY + 0.0075, 0.425))
            # Bullet taillight: a short barrel out of the fin pod's mouth, lens facing back.
            tb = MeshBuilder()
            ln = 0.03
            ring0 = ring_pts(s * fx, fz, fr, 14, mouth - 0.002)
            ring1 = ring_pts(s * fx, fz, fr * 0.95, 14, mouth - 0.002 - ln)
            for i in range(14):
                k = (i + 1) % 14
                tb.face([ring0[i], ring0[k], ring1[k], ring1[i]], "lamp_tail",
                        (ring0[i][0] - s * fx, 0, ring0[i][2] - fz))
            tb.face(list(reversed(ring1)), "lamp_tail", (0, -1, 0))
            lens_y = mouth - 0.002 - ln
            rig.light("taillight_" + side, tb, (s * fx, lens_y + ln / 2, fz))
            rig.light("brake_" + side, disc_y(s * fx, fz, fr * 0.7, 14, lens_y - 0.005, "signal_brake", -1),
                      (s * fx, lens_y - 0.005, fz))
            rb = kit.lamp_box(s * 0.46, 0.60, 0.12, 0.06, TY, 0.015, "signal_blinker", -1)
            rig.light("blinker_R" + side, rb, (s * 0.46, TY - 0.0075, 0.60))
        rv = MeshBuilder()
        for s in (-1, 1):
            kit.lamp_box(s * 0.31, 0.55, 0.08, 0.05, TY, 0.015, "signal_reverse", -1, rv)
        rig.light("reverse", rv, (0.0, TY - 0.0075, 0.55))

    def markers(self):
        m = super().markers()
        m["exhaust_L"] = (-0.40, TY - 0.08, 0.30)
        m["exhaust_R"] = (0.40, TY - 0.08, 0.30)
        return m

    # ---------------------------------------------------------------- interior

    def interior_extras(self, b):
        """Chrome rings around the two dials (the gauge quad's left and right halves), and
        a cowl seal: a panel under the hood from the dash top's front edge forward, so a
        glance just over the dash never sees into the body (the hood's faces are culled
        from below)."""
        d = self.DASH
        yf = d["y_front"]
        z_front = self.top_z(yf, 7) - 0.01
        xs = [-0.86, -0.6, -0.3, 0.0, 0.3, 0.6, 0.86]
        y1 = yf + 0.30
        for xa, xb in zip(xs, xs[1:]):
            za = min(z_front, self.top_z(y1, 7) - 0.02)
            b.face([(xa, yf + 0.02, z_front), (xa, y1, za), (xb, y1, za), (xb, yf + 0.02, z_front)],
                   self.imat("dash_top"), (0, 0, 1))
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
