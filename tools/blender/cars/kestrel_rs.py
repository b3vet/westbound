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


def tube(b, p0, p1, hw, mat):
    """A square tube (half-width hw) from p0 to p1."""
    d = wb_mesh.v_norm(wb_mesh.v_sub(p1, p0))
    ref = (0.0, 0.0, 1.0) if abs(d[2]) < 0.9 else (1.0, 0.0, 0.0)
    u = wb_mesh.v_norm(wb_mesh.v_cross(d, ref))
    v = wb_mesh.v_cross(d, u)
    offs = [wb_mesh.v_add(wb_mesh.v_scale(u, hw * su), wb_mesh.v_scale(v, hw * sv))
            for su, sv in ((1, 1), (-1, 1), (-1, -1), (1, -1))]
    for i in range(4):
        a, c = offs[i], offs[(i + 1) % 4]
        out = wb_mesh.v_add(a, c)
        b.face([wb_mesh.v_add(p0, a), wb_mesh.v_add(p0, c), wb_mesh.v_add(p1, c), wb_mesh.v_add(p1, a)], mat, out)


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
    FLARE = 0.07
    FLARE_REACH = 0.12
    NOSE_Y = 2.16
    TAIL_Y = -2.04
    KEYS = [
        (-2.04, [(0, .30, .04), (.55, .30, .04), (.80, .32, .02), (.85, .40), (.86, .80), (.84, .92), (.77, .96),
                 (.70, .965), (.35, .97), (.18, .97), (0, .97)]),
        (-1.96, [(0, .24), (.57, .24), (.83, .26), (.87, .38), (.88, .80), (.855, .93), (.77, .975), (.70, .98),
                 (.35, .985), (.18, .985), (0, .985)]),
        (-1.50, [(0, .16), (.58, .16), (.83, .19), (.87, .34), (.88, .79), (.86, .915), (.73, 1.30), (.67, 1.32),
                 (.35, 1.335), (.18, 1.34), (0, 1.34)]),
        (0.15, [(0, .16), (.58, .16), (.83, .19), (.87, .34), (.88, .785), (.86, .905), (.72, 1.29), (.66, 1.31),
                (.35, 1.325), (.18, 1.33), (0, 1.33)]),
        (0.80, [(0, .16), (.58, .16), (.83, .19), (.87, .34), (.88, .78), (.86, .90), (.83, .91), (.76, .915),
                (.35, .925), (.18, .93), (0, .93)]),
        (0.88, [(0, .16), (.58, .16), (.83, .19), (.87, .34), (.88, .78), (.865, .895), (.80, .90), (.68, .902),
                (.35, .905), (.18, .908), (0, .91)]),
        (1.86, [(0, .18), (.58, .18), (.83, .20), (.87, .36), (.875, .765), (.86, .86), (.80, .865), (.68, .866),
                (.35, .868), (.18, .87), (0, .87)]),
        (2.08, [(0, .27), (.57, .27), (.81, .29), (.85, .40), (.86, .75), (.84, .85), (.78, .855), (.68, .856),
                (.35, .858), (.18, .86), (0, .86)]),
        (2.16, [(0, .33, -.04), (.55, .33, -.04), (.78, .34, -.02), (.82, .40), (.83, .74), (.81, .84), (.75, .845),
                (.66, .848), (.35, .85), (.18, .85), (0, .85)]),
    ]
    REGIONS = {"windscreen": (0.15, 0.80), "rear_glass": (-1.96, -1.50), "side_glass": (-1.30, 0.80),
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
    HEAD = (0.64, 0.67, 0.28, 0.12)          # x, z, w, h
    POD_Z = (0.45, 0.57)
    POD_X = 0.56
    POD_LAMPS = (0.15, 0.41)
    POD_Y = 0.09                             # pod depth ahead of the nose face
    BLINK_F = (0.72, 0.50, 0.15, 0.08)
    TAIL_BAND_Z = (0.69, 0.87)
    TAIL_LAMPS = (0.52, 0.72)
    TAIL_R = 0.075
    BLINK_R = (0.70, 0.52, 0.18, 0.08)

    def rim(self):
        return kit.star_rim(self.TIRE_W / 2 + 0.008, self.RIM_IN, spokes=8, spoke_w=(0.016, 0.012), face="trim_white",
                            lip="trim_white", dark="trim_steel_dark", hub="trim_ink")

    def body_material(self, y0, y1, j, arch):
        ym = (y0 + y1) / 2
        if j == kit.S_WINDOW and self.region("b_pillar", ym):
            return "paint"
        if j == kit.S_SIDE and arch:
            return "trim_asphalt"   # the bolted-on flare band over each opening
        return super().body_material(y0, y1, j, arch)

    # ---------------------------------------------------------------- details

    def _front(self, b, lod=False):
        ny = self.NOSE_Y + 0.004
        gz0, gz1 = self.GRILLE_Z
        # Black grille band across the nose (grille + headlamp housings).
        b.face([(0, ny, gz0), (0.80, ny, gz0), (0.80, ny, gz1), (0, ny, gz1)], "trim_ink", (0, 1, 0))
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
        # Chunky black bumper.
        b.box((0.43, self.NOSE_Y + 0.02, 0.35), (0.86, 0.10, 0.14), "trim_asphalt", skip=("-x", "-y"))

    def _rear(self, b, lod=False):
        ty = self.TAIL_Y - 0.004
        tz0, tz1 = self.TAIL_BAND_Z
        b.face([(0.84, ty, tz0), (0, ty, tz0), (0, ty, tz1), (0.84, ty, tz1)], "trim_ink", (0, -1, 0))
        b.box((0.43, self.TAIL_Y - 0.03, 0.36), (0.86, 0.10, 0.16), "trim_asphalt", skip=("-x", "+y"))
        # Tall rear wing on the hatch: main plane, endplates, two struts.
        wy, wz = self.TAIL_Y + 0.13, 1.30
        b.box((0.39, wy, wz), (0.78, 0.24, 0.045), "paint_shade", {"+z": "paint", "-z": "paint_dark"}, skip=("-x",))
        b.box((0.786, wy - 0.01, wz), (0.012, 0.30, 0.15), "trim_ink")
        if not lod:
            zb = 1.02
            b.box((0.45, wy + 0.02, (zb + wz) / 2), (0.04, 0.06, wz - zb), "trim_ink", skip=("-z", "+z"))

    def details(self, b):
        self._front(b)
        self._rear(b)
        # Mud flaps behind every wheel.
        for ay in self.axles:
            y = ay - self.ARCH_R - 0.03
            b.box((0.81, y, 0.21), (0.22, 0.012, 0.30), "trim_ink")
        # Hood vents.
        for x0, x1 in ((0.20, 0.40),):
            y0, y1 = 1.40, 1.66
            z0 = self.top_z(y0, 9) + 0.004
            z1 = self.top_z(y1, 9) + 0.004
            b.face([(x0, y0, z0), (x1, y0, z0), (x1, y1, z1), (x0, y1, z1)], "trim_ink", (0, 0, 1))

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
