"""Kestrel RS, roster slot 4 (docs/ART_PRODUCTION.md §4.1.2, §4.1.5).

Late-80s rally-homologation hot hatch: short, tall and boxy, with big bolted-on fender
flares, a roof scoop, a tall rear wing on the hatch, a front light-pod bar with four
round lamps (trim: they are not light nodes), mud flaps and a wide track. Taillights:
two round lamps per side in a black band. Interior: an upright rally dash with a
tripmeter, a roll cage (main hoop, A-pillar bars, door bars), a small three-spoke wheel.

Proposed CarDef: 4.3 x 1.9 x 1.38 m, wheelbase 2.5, default paint brand_teal.

  blender -b --python tools/blender/cars/kestrel_rs.py -- [--export] [--render] [--save]
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import wb_carkit as kit  # noqa: E402
import wb_mesh  # noqa: E402
from wb_carkit import MeshBuilder, disc_y  # noqa: E402


def tube(b, p0, p1, hw, mat, sides=6):
    """A round (smooth-shaded, `sides`-sided) tube of radius hw from p0 to p1."""
    d = wb_mesh.v_norm(wb_mesh.v_sub(p1, p0))
    ref = (0.0, 0.0, 1.0) if abs(d[2]) < 0.9 else (1.0, 0.0, 0.0)
    u = wb_mesh.v_norm(wb_mesh.v_cross(d, ref))
    v = wb_mesh.v_cross(d, u)
    offs = [wb_mesh.v_add(wb_mesh.v_scale(u, hw * math.cos(2 * math.pi * i / sides)),
                          wb_mesh.v_scale(v, hw * math.sin(2 * math.pi * i / sides))) for i in range(sides)]
    for i in range(sides):
        a, c = offs[i], offs[(i + 1) % sides]
        out = wb_mesh.v_add(a, c)
        b.face([wb_mesh.v_add(p0, a), wb_mesh.v_add(p0, c), wb_mesh.v_add(p1, c), wb_mesh.v_add(p1, a)], mat, out,
               smooth=True, group="cage")


def wrap_bar(b, path, z0, z1, depth, mat):
    """A bumper bar following a plan-view `path` [(x, y)] on the right half (from the
    centre line outward): a smooth outer face, flat top and bottom, `depth` thick
    toward the car, an end cap at the outer end."""
    n = len(path)
    norms = []
    for i in range(n):
        a = path[max(0, i - 1)]
        c = path[min(n - 1, i + 1)]
        tx, ty = c[0] - a[0], c[1] - a[1]
        ln = math.hypot(tx, ty)
        nx, ny = ty / ln, -tx / ln
        if nx * path[i][0] + ny * path[i][1] < 0:
            nx, ny = -nx, -ny
        norms.append((nx, ny))
    outer = path
    inner = [(p[0] - nm[0] * depth, p[1] - nm[1] * depth) for p, nm in zip(path, norms)]
    for i in range(n - 1):
        (ax, ay), (cx, cy) = outer[i], outer[i + 1]
        (ix, iy), (jx, jy) = inner[i], inner[i + 1]
        out = (norms[i][0] + norms[i + 1][0], norms[i][1] + norms[i + 1][1], 0.0)
        b.face([(ax, ay, z0), (cx, cy, z0), (cx, cy, z1), (ax, ay, z1)], mat, out, smooth=True, group="bar")
        b.face([(ax, ay, z1), (cx, cy, z1), (jx, jy, z1), (ix, iy, z1)], mat, (0, 0, 1))
        b.face([(ax, ay, z0), (ix, iy, z0), (jx, jy, z0), (cx, cy, z0)], mat, (0, 0, -1))
    (ex, ey), (fx, fy) = outer[-1], inner[-1]
    tdir = (outer[-1][0] - outer[-2][0], outer[-1][1] - outer[-2][1], 0.0)
    b.face([(ex, ey, z0), (fx, fy, z0), (fx, fy, z1), (ex, ey, z1)], mat, tdir)


class KestrelRS(kit.LoftCar):
    CAR_ID = "kestrel_rs"
    CARDEF = {"length_m": 4.3, "width_m": 1.9, "height_m": 1.38, "wheelbase_m": 2.5,
              "default_paint": (0x1a / 255, 0x94 / 255, 0x99 / 255), "display_name": "Kestrel RS"}
    WHEELBASE = 2.5
    WHEEL_R = 0.32
    RIM_IN = 0.20
    TIRE_W = 0.24
    TRACK_F = 1.60
    TRACK_R = 1.60
    ARCH_R = 0.38
    WELL_X = 0.62
    FLOOR_Z = 0.16
    FLARE = 0.08
    FLARE_REACH = 0.22
    NOSE_Y = 2.16
    TAIL_Y = -2.04
    # Rails: floorC floorE rocker lowSide shoulder belt roofSide pillarIn roofMid crown roofC.
    # Curved door sides (widest at the shoulder, tumblehome to the window line), a
    # crowned roof with rounded edges, a crowned hood, and the nose and tail pulled in
    # so the corners round off in plan view.
    KEYS = [
        (-2.04, [(0, .30, .04), (.55, .30, .04), (.74, .32, .02), (.78, .40), (.80, .72), (.78, .88, .012),
                 (.70, .925, .02), (.62, .935, .02), (.35, .943, .02), (.18, .946, .02), (0, .947, .02)]),
        (-1.97, [(0, .24), (.57, .24), (.80, .26), (.835, .38), (.855, .72), (.835, .92), (.74, .975), (.66, .982),
                 (.35, .988), (.18, .99), (0, .99)]),
        (-1.55, [(0, .16), (.58, .16), (.83, .19), (.855, .34), (.88, .70), (.855, .91), (.725, 1.22), (.665, 1.26),
                 (.38, 1.29), (.19, 1.30), (0, 1.302)]),
        (-1.40, [(0, .16), (.58, .16), (.83, .19), (.855, .34), (.885, .70), (.855, .91), (.72, 1.255), (.66, 1.29),
                 (.38, 1.325), (.19, 1.335), (0, 1.338)]),
        (0.15, [(0, .16), (.58, .16), (.83, .19), (.855, .34), (.885, .70), (.855, .905), (.72, 1.25), (.66, 1.285),
                (.38, 1.32), (.19, 1.33), (0, 1.333)]),
        (0.80, [(0, .16), (.58, .16), (.83, .19), (.855, .34), (.885, .70), (.855, .90), (.82, .905), (.75, .91),
                (.38, .925), (.19, .93), (0, .932)]),
        (0.88, [(0, .16), (.58, .16), (.83, .19), (.855, .34), (.885, .70), (.858, .895), (.80, .90), (.68, .905),
                (.38, .92), (.19, .927), (0, .929)]),
        (1.86, [(0, .18), (.58, .18), (.83, .20), (.855, .36), (.88, .69), (.855, .86), (.79, .866), (.67, .872),
                (.38, .887), (.19, .893), (0, .895)]),
        (2.06, [(0, .25), (.57, .25), (.81, .27), (.84, .38), (.86, .69), (.84, .85), (.77, .856), (.66, .861),
                (.37, .872), (.19, .876), (0, .877)]),
        (2.12, [(0, .29), (.56, .29), (.78, .31), (.815, .39), (.835, .69), (.815, .842), (.75, .848), (.645, .852),
                (.36, .862), (.185, .866), (0, .867)]),
        (2.16, [(0, .33, -.04), (.55, .33, -.04), (.74, .34, -.02), (.78, .40), (.80, .69), (.78, .80, -.015),
                (.72, .81, -.02), (.62, .815, -.02), (.35, .823, -.02), (.18, .826, -.02), (0, .827, -.02)]),
    ]
    CREASE_Y = (0.80,)
    REGIONS = {"windscreen": (0.15, 0.80), "rear_glass": (-1.97, -1.55), "side_glass": (-1.30, 0.80),
               "b_pillar": (-0.42, -0.32)}
    MIRROR = (0.865, 0.66, 0.97)
    EYE = (-0.36, -0.30, 1.05)
    CABIN = (-1.60, 0.80)
    DASH = {"y_front": 0.80, "y_rear": 0.45, "top": 0.95, "bottom": 0.62}
    STEER = {"r": 0.165, "thick": 0.022, "spokes": 3, "tilt": -0.38, "sides": 18, "pos": (-0.36, 0.27, 0.75)}
    SEAT = {"y": -0.62, "cushion_z": 0.40, "back_top": 1.05, "w": 0.50}
    INTERIOR = dict(kit.LoftCar.INTERIOR, liner="roof_slate", door="asphalt", seat="asphalt", seat_accent="brand_teal",
                    wheel="ink", spoke="steel_dark", hub="ink", accent="hazard_yellow", dash_face="asphalt")

    # Front and rear layout (right half; m).
    GRILLE_Z = (0.58, 0.76)
    GRILLE_X = 0.76
    HEAD = (0.62, 0.67, 0.25, 0.12)          # x, z, w, h
    POD_Z = (0.45, 0.57)
    POD_X = 0.56
    POD_LAMPS = (0.15, 0.41)
    POD_Y = 0.09                             # pod depth ahead of the nose face
    BLINK_F = (0.66, 0.50, 0.15, 0.08)
    TAIL_BAND_Z = (0.69, 0.87)
    TAIL_X = 0.76
    TAIL_LAMPS = (0.49, 0.67)
    TAIL_R = 0.072
    BLINK_R = (0.64, 0.52, 0.16, 0.08)

    def rim(self):
        return kit.star_rim(self.TIRE_W / 2 + 0.008, self.RIM_IN, spokes=8, spoke_w=(0.016, 0.012), face="trim_white",
                            lip="trim_white", dark="trim_steel_dark", hub="trim_ink")

    def body_material(self, y0, y1, j, arch):
        ym = (y0 + y1) / 2
        if j == kit.S_WINDOW and self.region("b_pillar", ym):
            return "paint"
        return super().body_material(y0, y1, j, arch)

    # ---------------------------------------------------------------- details

    def _front(self, b, lod=False):
        ny = self.NOSE_Y + 0.004
        gz0, gz1 = self.GRILLE_Z
        # Black grille band across the nose (grille + headlamp housings).
        b.face([(0, ny, gz0), (self.GRILLE_X, ny, gz0), (self.GRILLE_X, ny, gz1), (0, ny, gz1)], "trim_ink", (0, 1, 0))
        # Light-pod bar: a black housing standing proud, four round trim lamps.
        pz0, pz1 = self.POD_Z
        py = self.NOSE_Y + self.POD_Y
        b.box((self.POD_X / 2, (self.NOSE_Y + py) / 2, (pz0 + pz1) / 2), (self.POD_X, self.POD_Y, pz1 - pz0), "trim_ink",
              skip=("-x", "-y"))
        for lx in self.POD_LAMPS:
            disc_y(lx, (pz0 + pz1) / 2, 0.052, 10, py + 0.004, "trim_cream", 1, b)
            if not lod:
                ring = kit.ring_pts(lx, (pz0 + pz1) / 2, 0.058, 10, py + 0.002)
                inner = kit.ring_pts(lx, (pz0 + pz1) / 2, 0.052, 10, py + 0.002)
                for i in range(10):
                    k = (i + 1) % 10
                    b.face([ring[i], ring[k], inner[k], inner[i]], "trim_steel", (0, 1, 0))
        # Chunky black bumper wrapping round the corners.
        ny = self.NOSE_Y
        wrap_bar(b, [(0.0, ny + 0.07), (0.50, ny + 0.07), (0.66, ny + 0.055), (0.77, ny + 0.01), (0.84, ny - 0.07),
                     (0.875, ny - 0.18)], 0.28, 0.42, 0.10, "trim_asphalt")

    def _rear(self, b, lod=False):
        ty = self.TAIL_Y - 0.004
        tz0, tz1 = self.TAIL_BAND_Z
        b.face([(self.TAIL_X, ty, tz0), (0, ty, tz0), (0, ty, tz1), (self.TAIL_X, ty, tz1)], "trim_ink", (0, -1, 0))
        t = self.TAIL_Y
        wrap_bar(b, [(0.0, t - 0.07), (0.50, t - 0.07), (0.66, t - 0.055), (0.76, t - 0.01), (0.82, t + 0.07),
                     (0.85, t + 0.17)], 0.28, 0.44, 0.10, "trim_asphalt")
        # Tall rear wing on the hatch: main plane, endplates, two struts.
        wy, wz = self.TAIL_Y + 0.13, 1.30
        b.box((0.38, wy, wz), (0.76, 0.24, 0.045), "paint_shade", {"+z": "paint", "-z": "paint_dark"}, skip=("-x",))
        b.box((0.766, wy - 0.01, wz), (0.012, 0.30, 0.15), "trim_ink")
        if not lod:
            zb = 1.02
            b.box((0.45, wy + 0.02, (zb + wz) / 2), (0.04, 0.06, wz - zb), "trim_ink", skip=("-z", "+z"))

    def arch_lips(self, b):
        """A dark lip round each opening: the edge of the bolted-on flare, standing on
        the swollen (smooth) fender."""
        n = 16
        for ay in self.axles:
            inner, outer = [], []
            for i in range(n + 1):
                a = math.pi * i / n
                ca, sa = math.cos(a), math.sin(a)
                for rad, lst in ((self.ARCH_R + 0.004, inner), (self.ARCH_R + 0.06, outer)):
                    y, z = ay + rad * ca, self.WHEEL_R + rad * sa
                    lst.append((self.side_x(y, z) + 0.014, y, z))
            for i in range(n):
                b.face([inner[i], inner[i + 1], outer[i + 1], outer[i]], "trim_asphalt", (1, 0, 0), smooth=True,
                       group="arch_lip")
            # The lip's edge facing the opening (its thickness).
            for i in range(n):
                p0, p1 = inner[i], inner[i + 1]
                q0, q1 = (p0[0] - 0.05, p0[1], p0[2]), (p1[0] - 0.05, p1[1], p1[2])
                mid = ((p0[1] + p1[1]) / 2 - ay, (p0[2] + p1[2]) / 2 - self.WHEEL_R)
                b.face([p0, q0, q1, p1], "trim_asphalt", (0, -mid[0], -mid[1]))

    def surface_z(self, y, x):
        """Top surface height at (x, y): along the top rails (hood and roof)."""
        r = self.station(y)
        pts = sorted((r[i][0], r[i][1]) for i in range(kit.R_ROOFSIDE, 11))
        for (x0, z0), (x1, z1) in zip(pts, pts[1:]):
            if x0 <= x <= x1:
                return z0 + (z1 - z0) * ((x - x0) / (x1 - x0) if x1 > x0 else 0.0)
        return pts[-1][1]

    def details(self, b):
        self._front(b)
        self._rear(b)
        self.arch_lips(b)
        # Mud flaps behind every wheel.
        for ay in self.axles:
            y = ay - self.ARCH_R - 0.03
            b.box((0.80, y, 0.21), (0.20, 0.012, 0.30), "trim_ink")
        # Two hood vents following the crowned hood.
        y0, y1 = 1.38, 1.62
        for x0, x1 in ((0.12, 0.30), (0.42, 0.58)):
            pts = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
            b.face([(x, y, self.surface_z(y, x) + 0.006) for x, y in pts], "trim_ink", (0, 0, 1))

    def lod1_extras(self, b):
        self._front(b, lod=True)
        self._rear(b, lod=True)

    def center_details(self, b):
        # Plate on the tailgate.
        ty = self.TAIL_Y - 0.008
        b.face([(0.25, ty, 0.47), (-0.25, ty, 0.47), (-0.25, ty, 0.60), (0.25, ty, 0.60)], "trim_cream", (0, -1, 0))
        # Roof scoop at the front of the roof: dark mouth facing forward.
        y0, y1 = -0.25, 0.05
        z_r = self.top_z(y1)
        b.box((0.0, (y0 + y1) / 2, z_r + 0.02), (0.40, y1 - y0, 0.05), "paint",
              {"+y": "trim_ink", "-z": "trim_ink"})
        # Single exhaust on the right, under the bumper.
        pipe = MeshBuilder()
        pipe.cylinder_x((0, 0, 0), 0.04, -0.05, 0.10, 8, "trim_steel", cap_mat="trim_ink")
        b.extend(pipe.transformed(lambda p: (p[1], p[0], p[2])), (0.50, self.TAIL_Y - 0.03, 0.24))

    # ---------------------------------------------------------------- lights

    def lights(self, rig):
        ny = self.NOSE_Y + 0.004
        ty = self.TAIL_Y - 0.004
        tz = sum(self.TAIL_BAND_Z) / 2
        for side, s in (("L", -1), ("R", 1)):
            hx, hz, hw, hh = self.HEAD
            rig.light("headlight_" + side, kit.lamp_box(s * hx, hz, hw, hh, ny, 0.015, "lamp_head", 1),
                      (s * hx, ny + 0.0075, hz))
            bx, bz, bw, bh = self.BLINK_F
            rig.light("blinker_F" + side, kit.lamp_box(s * bx, bz, bw, bh, ny, 0.012, "signal_blinker", 1),
                      (s * bx, ny + 0.006, bz))
            tb, bb = MeshBuilder(), MeshBuilder()
            for lx in self.TAIL_LAMPS:
                disc_y(s * lx, tz, self.TAIL_R, 12, ty - 0.015, "lamp_tail", -1, tb)
                disc_y(s * lx, tz, self.TAIL_R, 12, ty - 0.020, "signal_brake", -1, bb)
            cx = s * sum(self.TAIL_LAMPS) / 2
            rig.light("taillight_" + side, tb, (cx, ty - 0.015, tz))
            rig.light("brake_" + side, bb, (cx, ty - 0.020, tz))
            rx, rz, rw, rh = self.BLINK_R
            rig.light("blinker_R" + side, kit.lamp_box(s * rx, rz, rw, rh, ty, 0.012, "signal_blinker", -1),
                      (s * rx, ty - 0.006, rz))
        rv = MeshBuilder()
        for s in (-1, 1):
            x0, x1 = sorted((s * 0.06, s * 0.18))
            kit.rect_y(x0, x1, tz - 0.04, tz + 0.04, ty - 0.012, "signal_reverse", -1, rv)
        rig.light("reverse", rv, (0.0, ty - 0.012, tz))

    def markers(self):
        m = super().markers()
        m["exhaust_L"] = m["exhaust_R"] = (0.50, self.TAIL_Y - 0.08, 0.24)
        return m

    # ---------------------------------------------------------------- interior

    def interior_extras(self, b):
        steel = "interior_steel"
        hw = 0.018
        hy = self.SEAT["y"] - 0.36
        for s in (-1, 1):
            # Main hoop legs (following the tumblehome) and the A-pillar bars.
            tube(b, (s * 0.78, hy, 0.27), (s * 0.78, hy, 0.90), hw, steel)
            tube(b, (s * 0.78, hy, 0.90), (s * 0.63, hy, 1.25), hw, steel)
            tube(b, (s * 0.63, hy, 1.25), (s * 0.62, 0.10, 1.25), hw, steel)
            tube(b, (s * 0.62, 0.10, 1.25), (s * 0.75, 0.74, 0.94), hw, steel)
            # Door bar.
            tube(b, (s * 0.77, hy, 0.62), (s * 0.77, 0.62, 0.62), hw, steel)
        tube(b, (-0.63, hy, 1.25), (0.63, hy, 1.25), hw, steel)
        tube(b, (-0.78, hy, 0.27), (0.63, hy, 1.25), hw, steel)
        # Rally tripmeter on the passenger side of the dash.
        b.box((0.36, 0.52, 0.99), (0.16, 0.08, 0.07), "interior_ink", {"-y": "interior_screen"})


CAR = KestrelRS

if __name__ == "__main__":
    kit.run(CAR)
