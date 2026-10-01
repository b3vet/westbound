"""Player-car kit: loft bodies, wheels, lights, interiors and LOD1 (docs/ART_PRODUCTION.md §3.6, §4.1).

A car module (tools/blender/cars/<id>.py) subclasses LoftCar and sets its shape data:

  KEYS     key stations along Y (tail -> nose): y -> 11 rails (x, z) or (x, z, dy), right half.
           Rails: floorC floorE rocker lowSide shoulder belt roofSide pillarIn roofMid crown roofC.
           Strip j lies between rail j and j+1 (S_* below); body_material() names each strip.
  REGIONS  y-ranges for glass: windscreen, rear_glass, side_glass (+ any the car's
           body_material() reads).
  wheels   WHEELBASE, WHEEL_R, TIRE_W, TRACK_F/R, ARCH_R, WELL_X, FLARE (extra x at the arches).
  cabin    EYE, CABIN (y range of the inner shell), DASH, STEER, SEAT, INTERIOR colours.

and overrides details(b) (right half, mirrored), center_details(b), rim(), lights(rig).
build() makes the §3.6 tree (Body, wheels, lights, Interior, markers) and <id>_lod1.

Blender frame: Z up, nose +Y, right +X, origin on the ground between the axles.
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import wb_mesh  # noqa: E402
import wb_palette  # noqa: E402
from wb_mesh import MeshBuilder, v_add, v_len, v_scale, v_sub  # noqa: E402

REPO = wb_palette.REPO
RAILS = ["floorC", "floorE", "rocker", "lowSide", "shoulder", "belt", "roofSide", "pillarIn", "roofMid",
         "crown", "roofC"]
S_FLOOR, S_TUCK, S_SILL, S_SIDE, S_UPPER, S_WINDOW, S_PILLAR, S_TOP_OUT, S_TOP_MID, S_TOP_IN = range(10)
TOP_STRIPS = (S_TOP_OUT, S_TOP_MID, S_TOP_IN)
R_LOWSIDE, R_SHOULDER, R_BELT, R_ROOFSIDE = 3, 4, 5, 6
ARCH_SAMPLES = (-1.0, -0.94, -0.77, -0.5, -0.17, 0.17, 0.5, 0.77, 0.94, 1.0)


def _interp(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(len(a)))


def _key3(p):
    return (p[0], p[1], p[2] if len(p) > 2 else 0.0)


def ring_pts(cx, cz, r, n, y, phase=0.0, sx=1.0):
    """Points of a circle in the XZ plane at `y` (CCW seen from +Y)."""
    return [(cx + sx * r * math.cos(phase + 2 * math.pi * i / n), y, cz + r * math.sin(phase + 2 * math.pi * i / n))
            for i in range(n)]


def rect_y(x0, x1, z0, z1, y, mat, facing, b=None):
    """A rectangle in the XZ plane at `y` facing ±Y."""
    b = b or MeshBuilder()
    b.face([(x0, y, z0), (x1, y, z0), (x1, y, z1), (x0, y, z1)], mat, (0, facing, 0))
    return b


def disc_y(cx, cz, r, n, y, mat, facing, b=None, phase=0.0):
    b = b or MeshBuilder()
    b.face(ring_pts(cx, cz, r, n, y, phase), mat, (0, facing, 0))
    return b


def lamp_box(cx, cz, w, h, y, depth, mat, facing, b=None):
    """A lamp lens standing `depth` proud of a face at `y` (its sides included)."""
    b = b or MeshBuilder()
    yf = y + facing * depth
    b.box((cx, (y + yf) / 2, cz), (w, abs(depth), h), mat, skip=("-y",) if facing > 0 else ("+y",))
    return b


def uv_box(b):
    """Planar UVs per face orientation, each of the six directions in its own sixth of
    the 0-1 square (no overlap between differently facing sides: a livery mask can
    be painted later without remodelling)."""
    lo = [min(v[i] for v in b.verts) for i in range(3)]
    hi = [max(v[i] for v in b.verts) for i in range(3)]
    ext = [max(hi[i] - lo[i], 1e-6) for i in range(3)]
    for fi, f in enumerate(b.faces):
        pts = [b.verts[i] for i in f]
        n = wb_mesh.poly_normal(pts)
        axis = max(range(3), key=lambda i: abs(n[i]))
        u_ax, v_ax = [i for i in range(3) if i != axis]
        slot = axis * 2 + (0 if n[axis] >= 0 else 1)
        b.uvs[fi] = [((slot + (p[u_ax] - lo[u_ax]) / ext[u_ax]) / 6.0, (p[v_ax] - lo[v_ax]) / ext[v_ax]) for p in pts]


def pchip_slopes(xs, ys):
    """Fritsch-Carlson slopes: a C1 cubic through every point with no overshoot."""
    n = len(xs)
    if n < 2:
        return [0.0] * n
    h = [xs[i + 1] - xs[i] for i in range(n - 1)]
    d = [(ys[i + 1] - ys[i]) / h[i] if h[i] else 0.0 for i in range(n - 1)]
    m = [0.0] * n
    m[0], m[-1] = d[0], d[-1]
    for i in range(1, n - 1):
        if d[i - 1] * d[i] <= 0:
            m[i] = 0.0
        else:
            w1, w2 = 2 * h[i] + h[i - 1], h[i] + 2 * h[i - 1]
            m[i] = (w1 + w2) / (w1 / d[i - 1] + w2 / d[i])
    # One-sided ends: keep them inside the monotone range.
    for e, k in ((0, 0), (n - 1, n - 2)):
        if d[k] == 0 or m[e] * d[k] < 0:
            m[e] = 0.0
    return m


def hermite(p0, p1, m0, m1, h, t):
    t2, t3 = t * t, t * t * t
    return ((2 * t3 - 3 * t2 + 1) * p0 + (t3 - 2 * t2 + t) * h * m0 + (-2 * t3 + 3 * t2) * p1
            + (t3 - t2) * h * m1)


class Loft:
    """A smooth loft: stations through shared rails, material per strip from
    `mat_fn(y0, y1, j, arch)`.

    Along Y every rail coordinate (x, z, dy) follows a shape-preserving cubic through
    the key stations (no overshoot: the body never grows past its keys), split at
    `creases_y` (a crease across the car, e.g. the windscreen base). Stations are
    sampled at most `step` apart. Across, each section runs on a Hermite curve
    through the rails; `sharp_rails` are corners (a crease along the car), and each
    strip j is cut into a fixed number of segments (from its longest chord / `seg`).
    Faces are smooth; groups change at sharp rails and Y creases, so to_mesh keeps
    those edges hard. `smooth=False` gives the old faceted loft."""

    def __init__(self, keys, mat_fn, arch_fn=None, extra_ys=(), closed=False, caps=("paint_shade", "paint_shade"),
                 center=None, creases_y=(), sharp_rails=(), step=0.10, seg=0.075, max_sub=5, smooth=True,
                 sub=None, group="body"):
        self.keys = keys
        self.mat_fn = mat_fn
        self.arch_fn = arch_fn
        self.extra_ys = extra_ys
        self.closed = closed          # a full ring profile (pods), not a half section
        self.caps = caps
        self.center = center          # (x, z) the outward direction points away from (pods)
        self.creases_y = sorted(creases_y)
        self.sharp_rails = set(sharp_rails)
        self.step = step
        self.seg = seg
        self.max_sub = max_sub
        self.smooth = smooth
        self.sub = sub                # fixed segments per strip (list) instead of from `seg`
        self.group = group
        self._runs = self._make_runs()

    # ---------------------------------------------------------------- along Y

    def _make_runs(self):
        """Key stations split at the creases; per run, per rail, per coordinate slopes."""
        keys = [(y, [_key3(p) for p in r]) for y, r in self.keys]
        cuts = [c for c in self.creases_y if keys[0][0] < c < keys[-1][0]]
        runs, cur = [], [keys[0]]
        for k in keys[1:]:
            cur.append(k)
            if any(abs(k[0] - c) < 1e-6 for c in cuts):
                runs.append(cur)
                cur = [k]
        if len(cur) > 1:
            runs.append(cur)
        out = []
        for run in runs:
            ys = [k[0] for k in run]
            nr = len(run[0][1])
            slopes = [[pchip_slopes(ys, [k[1][i][c] for k in run]) for c in range(3)] for i in range(nr)]
            out.append((ys, run, slopes))
        return out

    def station(self, y):
        """Rails at `y`: [(x, z, dy)]."""
        k = self.keys
        if y <= k[0][0]:
            return [_key3(p) for p in k[0][1]]
        if y >= k[-1][0]:
            return [_key3(p) for p in k[-1][1]]
        for ys, run, slopes in self._runs:
            if ys[0] - 1e-9 <= y <= ys[-1] + 1e-9:
                for s in range(len(ys) - 1):
                    if ys[s] - 1e-9 <= y <= ys[s + 1] + 1e-9:
                        h = ys[s + 1] - ys[s]
                        t = (y - ys[s]) / h if h else 0.0
                        out = []
                        for i in range(len(run[0][1])):
                            out.append(tuple(hermite(run[s][1][i][c], run[s + 1][1][i][c], slopes[i][c][s],
                                                     slopes[i][c][s + 1], h, t) for c in range(3)))
                        return out
        return [_key3(p) for p in k[-1][1]]

    def _run_index(self, y):
        for i, c in enumerate(self.creases_y):
            if y < c - 1e-6:
                return i
        return len(self.creases_y)

    def stations(self, extra=None):
        y0, y1 = self.keys[0][0], self.keys[-1][0]
        ys = {round(k[0], 5) for k in self.keys}
        for y in list(self.extra_ys) + list(extra or ()):
            if y0 < y < y1:
                ys.add(round(y, 5))
        ys = sorted(ys)
        if self.step:
            fill = []
            for a, b in zip(ys, ys[1:]):
                n = int(math.ceil((b - a) / self.step - 1e-9))
                fill += [a + (b - a) * i / n for i in range(1, n)]
            ys = sorted(set(ys) | {round(y, 5) for y in fill})
        out = []
        for y in ys:
            rails = self.station(y)
            arch = False
            if self.arch_fn is not None:
                rails, arch = self.arch_fn(y, rails)
            out.append((y, [(x, y + dy, z) for (x, z, dy) in rails], arch))
        return out

    # ---------------------------------------------------------------- across

    def _tangents(self, P):
        """Per rail: (tangent into the strip before it, tangent into the strip after it)."""
        n = len(P)
        out = []
        for i in range(n):
            if self.closed:
                prev, nxt = P[(i - 1) % n], P[(i + 1) % n]
            else:
                prev = P[i - 1] if i > 0 else None
                nxt = P[i + 1] if i < n - 1 else None
                if nxt is None and abs(P[i][0]) < 1e-6 and prev is not None:
                    nxt = (-prev[0], prev[1], prev[2])     # the centre line: mirror symmetry
            sharp = (not self.closed and (i == 0 or i == n - 1 and nxt is None)) or i in self.sharp_rails
            if prev is None or nxt is None or sharp:
                tin = v_sub(P[i], prev) if prev is not None else None
                tout = v_sub(nxt, P[i]) if nxt is not None else None
                out.append((tin, tout))
            else:
                d = v_sub(nxt, prev)
                out.append((d, d))
        return out

    def _curve(self, P, subs):
        """The section as a point list: strip j sampled into subs[j] segments."""
        n = len(P)
        T = self._tangents(P)
        pts = [P[0]]
        for j in range(n - (0 if self.closed else 1)):
            j1 = (j + 1) % n
            a, b = P[j], P[j1]
            chord = v_len(v_sub(b, a))
            ta, tb = T[j][1], T[j1][0]
            ma = v_scale(wb_mesh.v_norm(ta), chord) if ta is not None and v_len(ta) > 1e-9 else v_sub(b, a)
            mb = v_scale(wb_mesh.v_norm(tb), chord) if tb is not None and v_len(tb) > 1e-9 else v_sub(b, a)
            k = subs[j]
            for s in range(1, k + 1):
                t = s / k
                pts.append(tuple(hermite(a[c], b[c], ma[c], mb[c], 1.0, t) for c in range(3)))
        if self.closed:
            pts.pop()
        return pts

    def _subs(self, st):
        n = len(st[0][1])
        strips = n if self.closed else n - 1
        if self.sub is not None:
            return list(self.sub)
        out = []
        for j in range(strips):
            j1 = (j + 1) % n
            longest = max(v_len(v_sub(s[1][j1], s[1][j])) for s in st)
            out.append(max(1, min(self.max_sub, int(math.ceil(longest / self.seg - 1e-9)))) if self.smooth else 1)
        return out

    def build(self, b, extra=None):
        st = self.stations(extra)
        n = len(st[0][1])
        strips = n if self.closed else n - 1
        subs = self._subs(st)
        curves = [self._curve(s[1], subs) if self.smooth else s[1] for s in st]
        # Strip j covers curve points [start[j], start[j] + subs[j]].
        start = [sum(subs[:j]) for j in range(strips)]
        across = 0
        sgroup = []
        for j in range(strips):
            if j in self.sharp_rails and j > 0:
                across += 1
            sgroup.append(across)
        m_total = len(curves[0])
        for (ya, _a, arch0), (yb, _c, arch1), ca, cb in zip(st, st[1:], curves, curves[1:]):
            arch = arch0 and arch1
            run = self._run_index((ya + yb) / 2)
            for j in range(strips):
                m = self.mat_fn(ya, yb, j, arch)
                if m is None:
                    continue
                for s in range(subs[j]):
                    i0 = start[j] + s
                    i1 = (i0 + 1) % m_total if self.closed else i0 + 1
                    p = [ca[i0], cb[i0], cb[i1], ca[i1]]
                    out = None
                    if self.center is not None:
                        mid = v_scale(v_add(v_add(p[0], p[1]), v_add(p[2], p[3])), 0.25)
                        out = (mid[0] - self.center[0], 0.0, mid[2] - self.center[1])
                    # Half sections need no hint: stations run toward +Y and rails run
                    # floor -> side -> roof, so the winding already faces out everywhere.
                    b.face(p, m, out, smooth=self.smooth, group=(self.group, run, sgroup[j]))
        tail, nose = curves[0], curves[-1]
        if self.caps[0]:
            pts = list(tail) if self.closed else list(tail) + [(0.0, tail[-1][1], tail[-1][2])]
            b.face(pts, self.caps[0], (0, -1, 0))
        if self.caps[1]:
            pts = list(nose) if self.closed else list(nose) + [(0.0, nose[-1][1], nose[-1][2])]
            b.face(pts, self.caps[1], (0, 1, 0))
        return st


class LoftCar:
    CAR_ID = ""
    # New cars (no data/cars/<id>.tres yet) carry their proposed CarDef body here:
    # {"length_m", "width_m", "height_m", "wheelbase_m", "default_paint": (r, g, b) sRGB}.
    CARDEF = None
    WHEELBASE = 2.65
    WHEEL_R = 0.33
    TIRE_W = 0.235
    TIRE_SIDES = 20
    RIM_IN = 0.215           # tire inner radius (rim edge)
    TRACK_F = 1.56
    TRACK_R = 1.56
    ARCH_R = 0.385
    WELL_X = 0.60
    FLOOR_Z = 0.17
    FLARE = 0.0              # extra x of lowSide/shoulder around the arches (bolt-on flares)
    FLARE_REACH = 0.18       # how far past the opening the flare fades out (m)
    NOSE_Y = 2.2
    TAIL_Y = -2.3
    KEYS = []
    # Smooth body (docs: the owner asked for smooth surfaces over flat facets).
    # CREASE_Y: key stations where the surface creases across the car (e.g. the
    # windscreen base); SHARP_RAILS: rails that stay a crease along the car (floor
    # edge, rocker, door bottom, the window line). Everything else is a smooth curve.
    CREASE_Y = ()
    SHARP_RAILS = (1, 2, 3, R_BELT)
    LOFT_STEP = 0.13          # station spacing along Y (m)
    LOFT_SEG = 0.09           # target segment length across a section (m)
    LOFT_MAX_SUB = 5
    REGIONS = {"windscreen": (0, 0), "rear_glass": (0, 0), "side_glass": (0, 0)}
    MIRROR = (0.905, 0.30, 0.94)     # door mirror (x of the door skin, y, z); None = none
    # Interior
    EYE = (-0.36, -0.36, 1.05)
    CABIN = (-1.1, 0.52)             # y range of the inner shell (rear bulkhead .. windscreen base)
    DASH = {"y_front": 0.52, "y_rear": 0.36, "top": 0.88, "bottom": 0.55, "lip": 0.02}
    STEER = {"r": 0.19, "thick": 0.028, "spokes": 3, "tilt": -0.40, "hub": None, "sides": 18}
    SEAT = {"y": -0.45, "cushion_z": 0.36, "back_top": 0.98, "w": 0.50}
    INTERIOR = {"liner": "roof_slate", "door": "asphalt", "floor": "ink", "dash_top": "ink", "dash_face": "asphalt",
                "seat": "asphalt", "seat_accent": "roof_slate", "wheel": "ink", "spoke": "steel", "hub": "steel_dark",
                "accent": "cream", "console": "ink", "strip": None}
    GAUGE_W = 0.30

    def __init__(self):
        self.axles = (self.WHEELBASE / 2, -self.WHEELBASE / 2)

    # ---------------------------------------------------------------- body

    def arch_open(self, y):
        """(z of the wheel opening at y, axle y) or (None, None)."""
        for ay in self.axles:
            dy = y - ay
            if abs(dy) <= self.ARCH_R + 1e-9:
                return self.WHEEL_R + math.sqrt(max(0.0, self.ARCH_R ** 2 - dy * dy)), ay
        return None, None

    def flare_at(self, y):
        if self.FLARE <= 0:
            return 0.0
        best = 0.0
        for ay in self.axles:
            d = abs(y - ay)
            full = self.ARCH_R
            if d <= full:
                best = max(best, 1.0)
            elif d <= full + self.FLARE_REACH:
                best = max(best, 1.0 - (d - full) / self.FLARE_REACH)
        return self.FLARE * best

    def arch_rails(self, y, rails):
        rails = list(rails)
        fl = self.flare_at(y)
        if fl > 0:
            for i in (R_LOWSIDE, R_SHOULDER):
                x, z, dy = rails[i]
                rails[i] = (x + fl * (1.0 if i == R_LOWSIDE else 0.55), z, dy)
        z_open, _ = self.arch_open(y)
        if z_open is None:
            return rails, False
        z_open = min(z_open, rails[R_SHOULDER][1] - 0.05)
        x_side = rails[R_LOWSIDE][0]
        rails[2] = (self.WELL_X, z_open, 0.0)
        rails[R_LOWSIDE] = (x_side, max(rails[R_LOWSIDE][1], z_open), 0.0)
        return rails, True

    def arch_ys(self):
        ys = []
        for ay in self.axles:
            ys += [ay + s * self.ARCH_R for s in ARCH_SAMPLES]
            ys += [ay - self.ARCH_R - 0.012, ay + self.ARCH_R + 0.012]
            if self.FLARE > 0:
                ys += [ay - self.ARCH_R - self.FLARE_REACH, ay + self.ARCH_R + self.FLARE_REACH]
        return ys

    def region(self, name, y):
        r = self.REGIONS.get(name)
        return r is not None and r[0] - 1e-6 <= y <= r[1] + 1e-6

    def body_material(self, y0, y1, j, arch):
        ym = (y0 + y1) / 2
        if j in (S_FLOOR, S_TUCK):
            return "trim_ink"
        if j == S_SILL:
            return "trim_ink" if arch else "paint_shade"
        if j in (S_SIDE, S_UPPER):
            return "paint"
        if j == S_WINDOW:
            return "glass" if self.region("side_glass", ym) else "paint"
        if j == S_PILLAR:
            return "paint"
        if self.region("windscreen", ym) or self.region("rear_glass", ym):
            return "glass"
        return "paint"

    def main_loft(self):
        edges = [r[k] for r in self.REGIONS.values() for k in (0, 1)]
        return Loft(self.KEYS, self.body_material, self.arch_rails, extra_ys=self.arch_ys() + edges,
                    creases_y=self.CREASE_Y, sharp_rails=self.SHARP_RAILS, step=self.LOFT_STEP, seg=self.LOFT_SEG,
                    max_sub=self.LOFT_MAX_SUB)

    def station(self, y):
        return self.main_loft().station(y)

    def side_x(self, y, z):
        """Body side x at (y, z) on the lowSide..shoulder strip (flush details)."""
        r = self.station(y)
        (x0, z0, _), (x1, z1, _) = r[R_LOWSIDE], r[R_SHOULDER]
        t = (z - z0) / (z1 - z0) if z1 != z0 else 0.0
        return x0 + (x1 - x0) * t + self.flare_at(y) * (1.0 - 0.45 * t)

    def top_z(self, y, rail=10):
        return self.station(y)[rail][1]

    def wheel_wells(self, b):
        for ay in self.axles:
            pts = []
            for s in [i / 8 for i in range(-8, 9)]:
                y = ay + s * self.ARCH_R
                z, _ = self.arch_open(y)
                z = min(z, self.station(y)[R_SHOULDER][1] - 0.05)
                pts.append((self.WELL_X, y, z))
            pts = [(self.WELL_X, ay + self.ARCH_R, self.FLOOR_Z)] + list(reversed(pts)) + \
                  [(self.WELL_X, ay - self.ARCH_R, self.FLOOR_Z)]
            b.face(pts, "trim_ink", (1, 0, 0))

    def details(self, b):
        """Right-half details (mirrored)."""

    def center_details(self, b):
        """Centre-line details (not mirrored)."""

    def extra_lofts(self, b):
        """Right-half extra shapes built as lofts (pods, fins)."""

    def door_mirror(self, b):
        if not self.MIRROR:
            return
        mx, my, mz = self.MIRROR
        m = MeshBuilder()
        m.box((0.035, 0, 0), (0.07, 0.11, 0.06), "paint", {"-y": "trim_ink"})
        m.box((-0.01, 0.025, -0.035), (0.04, 0.045, 0.03), "trim_ink")
        b.extend(m, (mx, my, mz))

    def body(self):
        half = MeshBuilder()
        self.main_loft().build(half)
        self.wheel_wells(half)
        self.extra_lofts(half)
        self.door_mirror(half)
        self.details(half)
        full = MeshBuilder()
        full.extend(half)
        full.extend(half.mirrored())
        self.center_details(full)
        uv_box(full)
        return full

    # ---------------------------------------------------------------- wheels

    def tire(self, sides=None):
        t = MeshBuilder()
        w, R, ri = self.TIRE_W / 2, self.WHEEL_R, self.RIM_IN
        ch = min(0.035, (R - ri) * 0.3)
        prof = [(-w + 0.01, ri), (-w, ri + 0.03), (-w, R - ch), (-w + 0.03, R), (w - 0.03, R), (w, R - ch),
                (w, ri + 0.03), (w - 0.01, ri)]
        mats = ["trim_asphalt", "trim_asphalt", "trim_ink", "trim_ink", "trim_ink", "trim_asphalt", "trim_asphalt"]
        t.lathe_x(prof, sides or self.TIRE_SIDES, mats)
        return t.smoothed("tire")

    def rim(self):
        """Default: a five-spoke star with a polished lip, face toward +X."""
        return star_rim(self.TIRE_W / 2 + 0.008, self.RIM_IN, spokes=5)

    # ---------------------------------------------------------------- lights and markers

    def lights(self, rig):
        raise NotImplementedError

    def markers(self):
        L = self.NOSE_Y - self.TAIL_Y
        hood_y = self.NOSE_Y - 0.22 * L
        hz = self.top_z(hood_y)
        return {"cam_cockpit": self.EYE, "cam_hood": (0.0, hood_y, hz + 0.12), "smoke_hood": (0.0, hood_y, hz),
                "exhaust_L": (-0.46, self.TAIL_Y - 0.05, 0.27), "exhaust_R": (0.46, self.TAIL_Y - 0.05, 0.27),
                "shadow": (0.0, 0.0, 0.0)}

    # ---------------------------------------------------------------- interior

    def imat(self, key):
        return "interior_" + self.INTERIOR[key]

    def interior_material(self, y0, y1, j, arch):
        """Inner-shell strips: window openings stay open, the rest is trimmed."""
        ym = (y0 + y1) / 2
        m = self.body_material(y0, y1, j, False)
        if m is None or m.startswith("glass"):
            return None
        if j in (S_FLOOR, S_TUCK):
            return self.imat("floor")
        if j in (S_SILL, S_SIDE, S_UPPER):
            return self.imat("door")
        if j == S_WINDOW:
            return self.imat("liner") if ym < self.EYE[1] else self.imat("door")
        return self.imat("liner")

    def inner_keys(self):
        """The body rails over the cabin, inset (walls 5 cm, roof 3 cm, floor 10 cm up)."""
        y0, y1 = self.CABIN
        lo = Loft(self.KEYS, None)
        keys = []
        ys = sorted({y0, y1} | {k[0] for k in self.KEYS if y0 < k[0] < y1} |
                    {r[k] for r in self.REGIONS.values() for k in (0, 1) if y0 < r[k] < y1})
        for y in ys:
            rails = []
            for i, (x, z, dy) in enumerate(lo.station(y)):
                if i <= 1:
                    rails.append((max(0.0, x - 0.05), z + 0.10, 0.0))
                elif i <= R_BELT:
                    rails.append((max(0.0, x - 0.055), max(z, self.FLOOR_Z + 0.10), 0.0))
                else:
                    rails.append((max(0.0, x - 0.04), z - 0.03, 0.0))
            keys.append((y, rails))
        return keys

    def cabin_shell(self, b):
        lo = Loft(self.inner_keys(), self.interior_material, caps=(None, None), creases_y=self.CREASE_Y,
                  sharp_rails=self.SHARP_RAILS, step=0.2, seg=0.15, max_sub=2, group="cabin")
        st = lo.stations()
        inward = MeshBuilder()
        lo.build(inward)
        # Flip every face to face the cabin (the loft emits outward faces).
        for f, m in zip(inward.faces, inward.mats):
            b.face([inward.verts[i] for i in reversed(f)], m)
        # Rear bulkhead (faces forward).
        y, rails, _ = st[0]
        pts = [(0.0, rails[0][1], rails[0][2])] + list(rails)
        b.face(pts, self.imat("liner"), (0, 1, 0))

    def dash(self, b):
        d = self.DASH
        yf, yr, top, bot = d["y_front"], d["y_rear"], d["top"], d["bottom"]
        xw = self.station(yr)[R_BELT][0] - 0.06
        ws_z = self.top_z(yf, 7)
        # Top (from the windscreen base back), driver face, a lip, the side ends.
        b.face([(0, yf + 0.02, ws_z - 0.01), (0, yr, top), (xw, yr, top), (xw, yf + 0.02, ws_z - 0.01)],
               self.imat("dash_top"), (0, 0, 1))
        b.face([(0, yr, top), (0, yr, bot), (xw, yr, bot), (xw, yr, top)], self.imat("dash_face"), (0, -1, 0))
        b.face([(xw, yr, top), (xw, yr, bot), (xw, yf, bot), (xw, yf + 0.02, ws_z - 0.01)], self.imat("dash_face"),
               (1, 0, 0))
        b.face([(0, yr, bot), (0, yf, bot), (xw, yf, bot), (xw, yr, bot)], self.imat("dash_face"), (0, 0, -1))
        if self.INTERIOR.get("strip"):
            s = self.INTERIOR["strip"]
            b.face([(0, yr - 0.006, top - 0.10), (xw - 0.02, yr - 0.006, top - 0.10),
                    (xw - 0.02, yr - 0.006, top - 0.05), (0, yr - 0.006, top - 0.05)], "interior_" + s, (0, -1, 0))

    def binnacle(self, b, ex):
        """A hooded pod standing proud of the dash face in front of the driver; returns
        the gauge quad centre."""
        d = self.DASH
        yr, top = d["y_rear"], d["top"]
        w = self.GAUGE_W / 2 + 0.035
        hood_top = top + 0.05
        bot = top - 0.13
        yb, yf = yr - 0.10, yr  # pod back (toward the driver) and front (the dash face)
        x0, x1 = ex - w, ex + w
        mat, face = self.imat("dash_top"), self.imat("dash_face")
        b.face([(x0, yb, hood_top), (x1, yb, hood_top), (x1, yf, hood_top), (x0, yf, hood_top)], mat, (0, 0, 1))
        b.face([(x0, yb, hood_top), (x0, yb, hood_top - 0.02), (x1, yb, hood_top - 0.02), (x1, yb, hood_top)], mat,
               (0, -1, 0))
        b.face([(x0, yb + 0.03, bot), (x1, yb + 0.03, bot), (x1, yb + 0.03, bot + 0.015), (x0, yb + 0.03, bot + 0.015)],
               mat, (0, -1, 0))
        b.face([(x0, yb + 0.03, bot), (x0, yf, bot), (x1, yf, bot), (x1, yb + 0.03, bot)], mat, (0, 0, -1))
        for x, sgn in ((x0, -1), (x1, 1)):
            b.face([(x, yb, hood_top), (x, yf, hood_top), (x, yf, bot), (x, yb + 0.03, bot)], mat, (sgn, 0, 0))
        b.face([(x0, yf - 0.03, bot), (x1, yf - 0.03, bot), (x1, yf - 0.03, hood_top - 0.02),
                (x0, yf - 0.03, hood_top - 0.02)], face, (0, -1, 0))
        return (ex, yf - 0.04, (bot + hood_top - 0.02) / 2)

    def gauges(self, center):
        """One quad, UV 0-1, 2.6 : 1, facing the eye."""
        w = self.GAUGE_W
        h = w / 2.6
        g = MeshBuilder()
        g.face([(-w / 2, 0, -h / 2), (w / 2, 0, -h / 2), (w / 2, 0, h / 2), (-w / 2, 0, h / 2)], "gauges", (0, -1, 0),
               uv=[(0, 0), (1, 0), (1, 1), (0, 1)])
        ex, ey, ez = self.EYE
        tilt = math.atan2(ez - center[2], center[1] - ey)  # lean back to face the eye (baked in)
        c, s = math.cos(tilt), math.sin(tilt)
        return g.transformed(lambda p: (p[0], p[1] * c + p[2] * s, -p[1] * s + p[2] * c)), (0.0, 0.0, 0.0)

    def steering_wheel(self):
        """Rim, spokes, hub and a 12 o'clock mark; built in the XZ plane, facing -Y (the driver)."""
        s = self.STEER
        r, t, n = s["r"], s["thick"], s["sides"]
        b = MeshBuilder()
        rim_m, spoke_m, hub_m, acc_m = (self.imat(k) for k in ("wheel", "spoke", "hub", "accent"))
        # Rim: a ring with a square section.
        for i in range(n):
            a0, a1 = 2 * math.pi * i / n, 2 * math.pi * (i + 1) / n
            m = acc_m if abs(math.remainder((a0 + a1) / 2 - math.pi / 2, 2 * math.pi)) < math.pi / n else rim_m
            for (r0, y0), (r1, y1) in (((r - t, -t / 2), (r + t, -t / 2)), ((r + t, -t / 2), (r + t, t / 2)),
                                       ((r + t, t / 2), (r - t, t / 2)), ((r - t, t / 2), (r - t, -t / 2))):
                pts = [(r0 * math.cos(a0), y0, r0 * math.sin(a0)), (r1 * math.cos(a0), y1, r1 * math.sin(a0)),
                       (r1 * math.cos(a1), y1, r1 * math.sin(a1)), (r0 * math.cos(a1), y0, r0 * math.sin(a1))]
                mid = ((r0 + r1) / 2 * math.cos((a0 + a1) / 2), (y0 + y1) / 2, (r0 + r1) / 2 * math.sin((a0 + a1) / 2))
                rad = (math.cos((a0 + a1) / 2), 0.0, math.sin((a0 + a1) / 2))
                out = v_sub(mid, v_scale(rad, r))
                b.face(pts, m, out, smooth=True, group="steer_rim")
        # Hub.
        hr = s.get("hub") or r * 0.28
        hub = MeshBuilder()
        hub.lathe_x([(-0.03, hr), (0.02, hr), (0.03, hr * 0.6), (0.03, 0.0)], 10, hub_m)
        b.extend(hub.transformed(lambda p: (p[1], -p[0], p[2])))
        # Spokes: 3 (9, 3 and 6 o'clock) or 2 (9 and 3) or 4.
        angles = {2: (0.0, math.pi), 3: (0.0, math.pi, -math.pi / 2), 4: (0.6, math.pi - 0.6, -0.6, math.pi + 0.6)}
        for a in angles.get(s["spokes"], angles[3]):
            ca, sa = math.cos(a), math.sin(a)
            px, pz = -sa, ca
            w = 0.022 if s["spokes"] != 2 else 0.03
            r0, r1 = hr * 0.9, r - t * 0.6
            pts = [(r0 * ca + w * px, -0.012, r0 * sa + w * pz), (r1 * ca + w * px, -0.004, r1 * sa + w * pz),
                   (r1 * ca - w * px, -0.004, r1 * sa - w * pz), (r0 * ca - w * px, -0.012, r0 * sa - w * pz)]
            b.face(pts, spoke_m, (0, -1, 0))
            b.face([(p[0], p[1] + 0.012, p[2]) for p in reversed(pts)], spoke_m, (0, 1, 0))
        return b

    def seat(self, b, x):
        s = self.SEAT
        w, y, cz, bt = s["w"], s["y"], s["cushion_z"], s["back_top"]
        m, acc = self.imat("seat"), self.imat("seat_accent")
        fz = self.FLOOR_Z + 0.10
        # Cushion.
        b.box((x, y + 0.20, (fz + cz) / 2), (w, 0.48, cz - fz), m, {"+z": acc}, skip=("-z",))
        # Backrest leaning back.
        lean = 0.18
        yb = y - 0.04
        prof = [(x - w / 2, yb, cz), (x + w / 2, yb, cz), (x + w / 2, yb - lean, bt), (x - w / 2, yb - lean, bt)]
        b.face(prof, acc, (0, 1, 0.2))
        back = [(p[0], p[1] - 0.10, p[2]) for p in prof]
        b.face(list(reversed(back)), m, (0, -1, 0))
        for i0, i1 in ((0, 3), (1, 2)):
            side = [prof[i0], prof[i1], back[i1], back[i0]]
            b.face(side, m, (1 if i0 == 1 else -1, 0, 0))
        b.face([prof[3], prof[2], back[2], back[3]], m, (0, 0, 1))
        # Side bolsters on the backrest.
        for sx in (-1, 1):
            bx = x + sx * (w / 2 - 0.04)
            b.face([(bx - 0.04, yb + 0.03, cz + 0.05), (bx + 0.04, yb + 0.03, cz + 0.05),
                    (bx + 0.04, yb - lean * 0.8 + 0.03, bt - 0.12), (bx - 0.04, yb - lean * 0.8 + 0.03, bt - 0.12)],
                   m, (0, 1, 0.2))

    def console(self, b):
        d = self.DASH
        fz = self.FLOOR_Z + 0.10
        top = fz + 0.24
        b.box((0.0, (d["y_rear"] + self.SEAT["y"]) / 2, (fz + top) / 2),
              (0.20, d["y_rear"] - self.SEAT["y"], top - fz), self.imat("console"), skip=("-z",))
        # Front stack under the dash.
        b.face([(-0.12, d["y_rear"] + 0.001, fz), (0.12, d["y_rear"] + 0.001, fz), (0.12, d["y_rear"] + 0.001, d["bottom"]),
                (-0.12, d["y_rear"] + 0.001, d["bottom"])], self.imat("dash_face"), (0, -1, 0))
        # Shifter.
        sy = (d["y_rear"] + self.SEAT["y"]) / 2 + 0.12
        b.box((0.0, sy, top + 0.08), (0.02, 0.02, 0.16), self.imat("hub"), skip=("-z",))
        b.box((0.0, sy, top + 0.18), (0.05, 0.05, 0.05), self.imat("wheel"))

    def rear_mirror(self, b):
        y = self.REGIONS["windscreen"][0] + 0.06
        z = self.top_z(y, 7) - 0.10
        b.box((0.0, y, z), (0.19, 0.025, 0.055), self.imat("console"), {"-y": "interior_steel_dark"})
        b.box((0.0, y + 0.02, z + 0.05), (0.015, 0.015, 0.05), self.imat("console"))

    def interior_extras(self, b):
        """Car-specific cabin parts (roll cage, screen strips, ...)."""

    def interior(self, rig):
        cab = MeshBuilder()
        self.cabin_shell(cab)
        full = MeshBuilder()
        full.extend(cab)
        full.extend(cab.mirrored())
        half = MeshBuilder()
        self.dash(half)
        full.extend(half)
        full.extend(half.mirrored())
        g_center = self.binnacle(full, self.EYE[0])
        self.seat(full, self.EYE[0])
        self.seat(full, -self.EYE[0])
        self.console(full)
        self.rear_mirror(full)
        self.interior_extras(full)
        rig.interior_object("Cabin", full)
        # Steering wheel: hub on the line from the eye, ~0.62 m ahead of it.
        ex, ey, ez = self.EYE
        hub = self.STEER.get("pos") or (ex, ey + 0.62, ez - 0.31)
        rig.interior_object("SteeringWheel", self.steering_wheel(), location=hub,
                            rotation=(self.STEER["tilt"], 0.0, 0.0))
        g, rot = self.gauges(g_center)
        rig.interior_object("Gauges", g, location=g_center, rotation=rot)

    # ---------------------------------------------------------------- LOD1

    def lod1(self):
        """One Body with the same slots: key stations only, wheels merged at rest,
        lamps as trim faces (no light nodes in a LOD1 file)."""
        car = self
        lo = Loft(self.KEYS, self.body_material, self.arch_rails,
                  extra_ys=[ay + s * self.ARCH_R for ay in self.axles for s in (-1.0, -0.7, 0.0, 0.7, 1.0)] +
                  [r[k] for r in self.REGIONS.values() for k in (0, 1)],
                  creases_y=self.CREASE_Y, sharp_rails=self.SHARP_RAILS, step=0.3, seg=0.2, max_sub=2)
        half = MeshBuilder()
        lo.build(half)
        car.lod1_extras(half)
        full = MeshBuilder()
        full.extend(half)
        full.extend(half.mirrored())
        # Wheels at rest: a low tire and a rim disc each.
        for ay, track in ((self.axles[0], self.TRACK_F), (self.axles[1], self.TRACK_R)):
            for s in (-1, 1):
                t = MeshBuilder()
                w, R = self.TIRE_W / 2, self.WHEEL_R
                t.lathe_x([(-w, R * 0.6), (-w, R), (w, R), (w, R * 0.6)], 10, "trim_ink")
                t.face([(w + 0.005, R * 0.62 * math.cos(2 * math.pi * i / 10), R * 0.62 * math.sin(2 * math.pi * i / 10))
                        for i in range(10)], "trim_steel", (1, 0, 0))
                if s < 0:
                    t = t.transformed(lambda p: (-p[0], -p[1], p[2]))
                full.extend(t, (s * track / 2, ay, R))
        # Lamps as trim.
        lamps = MeshBuilder()
        self.lamp_faces(lamps)
        full.extend(lamps)
        uv_box(full)
        return full

    def lod1_extras(self, b):
        """Right-half big shapes kept in LOD1 (wings, scoops)."""

    def lamp_faces(self, b):
        """LOD1 stand-ins for the head and tail lamps (trim colours)."""
        rig = _Collector()
        self.lights(rig)
        colour = {"lamp_head": "trim_cream", "lamp_tail": "trim_reflector_red"}
        for name, mb in rig.parts.items():
            if not name.startswith(("headlight", "taillight")):
                continue
            for f, m in zip(mb.faces, mb.mats):
                b.face([mb.verts[i] for i in f], colour.get(m, "trim_ink"))

    # ---------------------------------------------------------------- assembly

    def build(self):
        import wb_scaffold_car as scaffold
        cd = dict(self.CARDEF, id=self.CAR_ID) if self.CARDEF else None
        rig = scaffold.CarRig(self.CAR_ID, cd).build_tree()
        rig.set_mesh("Body", self.body())
        rig.wheels(self.tire(), self.rim(), self.WHEEL_R, self.TRACK_F, self.TRACK_R, wheelbase=self.WHEELBASE)
        self.lights(rig)
        self.interior(rig)
        for n, loc in self.markers().items():
            rig.marker(n, loc)
        lc = scaffold.collection(self.CAR_ID + "_lod1", clear=True)
        lroot = scaffold.empty(lc, scaffold.root_name(self.CAR_ID) + "_LOD1", size=0.3)
        scaffold.mesh_object(lc, "Body_lod1",
                             self.lod1().to_mesh("lod1_" + self.CAR_ID, paint=rig.cardef["default_paint"]), lroot)
        lc.hide_render = True
        return rig


class _Collector:
    """Stands in for CarRig when lights() is replayed for LOD1: keeps each light's faces."""

    def __init__(self):
        self.parts = {}

    def light(self, name, builder, center):
        self.parts[name] = builder


# -------------------------------------------------------------------- rims

def star_rim(xf, lip_r, spokes=5, lip_in_frac=0.88, hub_r=0.06, spoke_w=(0.032, 0.02), face="trim_steel",
             dark="trim_steel_dark", hub="trim_ink", lip="trim_steel", sides=20, depth=0.045):
    """A spoked alloy: polished lip ring on the face plane (x = xf), a dark barrel,
    straight spokes from the hub to the lip, and a hub cap. Face toward +X."""
    r = MeshBuilder()
    lip_in = lip_r * lip_in_frac
    r.lathe_x([(xf - 0.02, lip_r), (xf, lip_r), (xf, lip_in), (xf - depth, lip_in), (xf - depth, hub_r)], sides,
              [lip, lip, dark, dark])
    r.lathe_x([(xf - 0.02, hub_r), (xf + 0.005, hub_r * 0.9), (xf + 0.012, 0.0)], 10, [face, hub])
    for i in range(spokes):
        a = 2 * math.pi * i / spokes + math.pi / 2
        ca, sa = math.cos(a), math.sin(a)
        pa, pb = -sa, ca

        def P(rad, half, x):
            return (x, rad * ca + half * pa, rad * sa + half * pb)
        x0, x1 = xf - depth + 0.005, xf - 0.004
        r0, r1 = hub_r * 0.9, lip_in + 0.005
        wi, wo = spoke_w
        r.face([P(r0, -wi, x1), P(r1, -wo, x1), P(r1, wo, x1), P(r0, wi, x1)], face, (1, 0, 0))
        r.face([P(r0, -wi, x0), P(r1, -wo, x0), P(r1, -wo, x1), P(r0, -wi, x1)], dark, (0, -pa, -pb))
        r.face([P(r0, wi, x1), P(r1, wo, x1), P(r1, wo, x0), P(r0, wi, x0)], dark, (0, pa, pb))
    return r


def dish_rim(xf, lip_r, face="trim_steel", dark="trim_steel_dark", hub="trim_ink", holes=0, sides=20):
    """A flat dish / wheel cover (turbine-like discs, closed covers): stepped rings."""
    r = MeshBuilder()
    r.lathe_x([(xf - 0.02, lip_r), (xf, lip_r), (xf, lip_r * 0.82), (xf - 0.015, lip_r * 0.78),
               (xf - 0.015, lip_r * 0.35), (xf + 0.005, lip_r * 0.3), (xf + 0.012, 0.0)], sides,
              [face, face, dark, face, dark, hub])
    return r


# -------------------------------------------------------------------- CLI helper for car modules

def run(car_cls, argv=None):
    """Build a car module's car; flags: --export --render --save --lod1."""
    import bpy
    import wb_export
    import wb_render
    import wb_validate
    argv = argv if argv is not None else (sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
    bpy.ops.wm.read_homefile(use_empty=True)
    car = car_cls()
    car.build()
    cd = dict(car.CARDEF, id=car.CAR_ID) if car.CARDEF else None
    rep = wb_validate.validate_car(car.CAR_ID, lod1=True, cardef=cd)
    print(rep.summary())
    if "--export" in argv:
        wb_export.export_car(car.CAR_ID, cardef=cd)
    if "--render" in argv:
        wb_render.render_car(car.CAR_ID, height=540)
    if "--save" in argv:
        path = os.path.join(REPO, "art", "blender", "cars", car.CAR_ID + ".blend")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        bpy.ops.wm.save_as_mainfile(filepath=path, compress=True)
    return rep
