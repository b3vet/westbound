"""Flat-shaded low-poly mesh building for Westbound assets (docs/ART_PRODUCTION.md §3.4).

MeshBuilder collects vertices and faces with a material NAME per face, then writes a
Blender mesh: flat shaded, merged by distance (0.1 mm), one material slot per name.
Winding is counter-clockwise seen from the front (outside) of each face, so normals
point outward by construction; `face(..., outward=v)` flips a face that disagrees.

Coordinates are Blender's car frame (§3.1): Z up, +Y forward (nose), +X right.
"""

import math

MERGE_DIST = 1e-4


def v_add(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def v_sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def v_scale(a, k):
    return (a[0] * k, a[1] * k, a[2] * k)


def v_cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def v_dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def v_len(a):
    return math.sqrt(v_dot(a, a))


def v_norm(a):
    n = v_len(a)
    return (a[0] / n, a[1] / n, a[2] / n) if n > 0 else (0.0, 0.0, 0.0)


def v_lerp(a, b, t):
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t)


def poly_normal(pts):
    """Newell normal of a polygon (unnormalised)."""
    n = [0.0, 0.0, 0.0]
    for i, a in enumerate(pts):
        b = pts[(i + 1) % len(pts)]
        n[0] += (a[1] - b[1]) * (a[2] + b[2])
        n[1] += (a[2] - b[2]) * (a[0] + b[0])
        n[2] += (a[0] - b[0]) * (a[1] + b[1])
    return tuple(n)


def mirror_x(p):
    return (-p[0], p[1], p[2])


class MeshBuilder:
    def __init__(self):
        self.verts = []
        self.faces = []
        self.mats = []
        self.uvs = []  # per face: list of (u, v) or None

    # ---------------------------------------------------------------- primitives

    def face(self, pts, mat, outward=None, uv=None):
        """Add polygon `pts` (points, CCW from outside). With `outward`, flip if needed."""
        pts = [tuple(float(c) for c in p) for p in pts]
        # Drop consecutive duplicates (collapsed loft points).
        clean = []
        for p in pts:
            if not clean or v_len(v_sub(p, clean[-1])) > MERGE_DIST:
                clean.append(p)
        if len(clean) > 1 and v_len(v_sub(clean[0], clean[-1])) <= MERGE_DIST:
            clean.pop()
        if len(clean) < 3 or v_len(poly_normal(clean)) < 1e-9:
            return
        if outward is not None and v_dot(poly_normal(clean), outward) < 0:
            clean.reverse()
            if uv:
                uv = list(reversed(uv))
        base = len(self.verts)
        self.verts.extend(clean)
        self.faces.append(list(range(base, base + len(clean))))
        self.mats.append(mat)
        self.uvs.append(uv if uv and len(uv) == len(clean) else None)

    def quad(self, a, b, c, d, mat, outward=None):
        self.face([a, b, c, d], mat, outward)

    def face_sym(self, pts, mat, outward=None):
        """Face on the right side (+X) and its mirror on the left."""
        self.face(pts, mat, outward)
        m = [mirror_x(p) for p in reversed(pts)]
        self.face(m, mat, mirror_x(outward) if outward else None)

    def box(self, center, size, mat, mats=None, skip=()):
        """Axis-aligned box. `mats` overrides per side: keys +x -x +y -y +z -z."""
        cx, cy, cz = center
        hx, hy, hz = size[0] / 2, size[1] / 2, size[2] / 2
        c = [(cx + sx * hx, cy + sy * hy, cz + sz * hz) for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
        # index = (sx>0)*4 + (sy>0)*2 + (sz>0)
        sides = {
            "+x": ([4, 6, 7, 5], (1, 0, 0)), "-x": ([0, 1, 3, 2], (-1, 0, 0)),
            "+y": ([2, 3, 7, 6], (0, 1, 0)), "-y": ([0, 4, 5, 1], (0, -1, 0)),
            "+z": ([1, 5, 7, 3], (0, 0, 1)), "-z": ([0, 2, 6, 4], (0, 0, -1)),
        }
        for k, (ids, out) in sides.items():
            if k in skip:
                continue
            self.face([c[i] for i in ids], (mats or {}).get(k, mat), out)

    def prism(self, profile, y0, y1, mat, cap_mat=None, caps=True):
        """Extrude a CCW (seen from +Y) XZ polygon `profile` [(x, z)] from y0 to y1."""
        n = len(profile)
        for i in range(n):
            (x0, z0), (x1, z1) = profile[i], profile[(i + 1) % n]
            self.face([(x0, y0, z0), (x1, y0, z1), (x1, y1, z1), (x0, y1, z0)], mat)
        if caps:
            self.face([(x, y1, z) for x, z in profile], cap_mat or mat, (0, 1, 0))
            self.face([(x, y0, z) for x, z in profile], cap_mat or mat, (0, -1, 0))

    def cylinder_x(self, center, radius, x0, x1, sides, mat, cap_mat=None, caps=(True, True), phase=0.0):
        """Cylinder around the X axis through `center` (y, z used), from x0 to x1."""
        _, cy, cz = center
        ring = [(cy + radius * math.cos(phase + 2 * math.pi * i / sides),
                 cz + radius * math.sin(phase + 2 * math.pi * i / sides)) for i in range(sides)]
        for i in range(sides):
            (y0, z0), (y1, z1) = ring[i], ring[(i + 1) % sides]
            mid = ((y0 + y1) / 2 - cy, (z0 + z1) / 2 - cz)
            self.face([(x0, y0, z0), (x0, y1, z1), (x1, y1, z1), (x1, y0, z0)], mat, (0, mid[0], mid[1]))
        if caps[1]:
            self.face([(x1, y, z) for y, z in ring], cap_mat or mat, (1, 0, 0))
        if caps[0]:
            self.face([(x0, y, z) for y, z in ring], cap_mat or mat, (-1, 0, 0))

    def lathe_x(self, profile, sides, mats, phase=0.0, center=(0.0, 0.0, 0.0)):
        """Surface of revolution about the X axis through `center`. `profile` = [(x, r)];
        the outside is on the LEFT walking the profile in the (x right, r up) plane, so
        a tire is (-w/2, r_in) -> (-w/2, R) -> (w/2, R) -> (w/2, r_in). Strip i uses
        mats[i] (or `mats` if a string)."""
        _, cy, cz = center
        for i in range(len(profile) - 1):
            (xa, ra), (xb, rb) = profile[i], profile[i + 1]
            nx, nr = -(rb - ra), (xb - xa)
            m = mats if isinstance(mats, str) else mats[i]
            for s in range(sides):
                a0 = phase + 2 * math.pi * s / sides
                a1 = phase + 2 * math.pi * (s + 1) / sides
                pts = [(xa, cy + ra * math.cos(a0), cz + ra * math.sin(a0)),
                       (xa, cy + ra * math.cos(a1), cz + ra * math.sin(a1)),
                       (xb, cy + rb * math.cos(a1), cz + rb * math.sin(a1)),
                       (xb, cy + rb * math.cos(a0), cz + rb * math.sin(a0))]
                am = (a0 + a1) / 2
                self.face(pts, m, (nx, nr * math.cos(am), nr * math.sin(am)))

    def loft(self, sections, mat_fn, closed=False):
        """Quad grid between `sections` (point lists of equal length). Face (i, j) spans
        sections i..i+1 and points j..j+1. mat_fn(i, j) returns None (skip), a material
        name, or (material, outward vector) to fix the winding."""
        n = len(sections[0])
        for i in range(len(sections) - 1):
            a, b = sections[i], sections[i + 1]
            for j in range(n - 1 + (1 if closed else 0)):
                j1 = (j + 1) % n
                r = mat_fn(i, j)
                if r is None:
                    continue
                mat, out = r if isinstance(r, tuple) else (r, None)
                self.face([a[j], b[j], b[j1], a[j1]], mat, out)

    def extend(self, other, offset=(0.0, 0.0, 0.0)):
        for f, m, uv in zip(other.faces, other.mats, other.uvs):
            self.face([v_add(other.verts[i], offset) for i in f], m, uv=uv)

    def mirrored(self):
        """A copy mirrored across X = 0 (winding reversed so normals stay outward)."""
        out = MeshBuilder()
        for f, m, uv in zip(self.faces, self.mats, self.uvs):
            out.face([mirror_x(self.verts[i]) for i in reversed(f)], m, uv=list(reversed(uv)) if uv else None)
        return out

    def transformed(self, fn):
        out = MeshBuilder()
        for f, m, uv in zip(self.faces, self.mats, self.uvs):
            out.face([fn(self.verts[i]) for i in f], m, uv=uv)
        return out

    def triangles(self):
        return sum(len(f) - 2 for f in self.faces)

    # ---------------------------------------------------------------- output

    def to_mesh(self, name, kind="car", paint=None):
        """A new bpy mesh datablock (flat, merged, one slot per material name)."""
        import bpy
        import bmesh
        import wb_palette
        me = bpy.data.meshes.new(name)
        me.from_pydata(self.verts, [], self.faces)
        names = []
        for m in self.mats:
            if m not in names:
                names.append(m)
        for n in names:
            me.materials.append(wb_palette.material(n, kind=kind, paint=paint))
        idx = {n: i for i, n in enumerate(names)}
        me.polygons.foreach_set("material_index", [idx[m] for m in self.mats])
        if any(self.uvs):
            layer = me.uv_layers.new(name="UVMap")
            for poly, uv in zip(me.polygons, self.uvs):
                if uv:
                    for li, (u, v) in zip(poly.loop_indices, uv):
                        layer.data[li].uv = (u, v)
        bm = bmesh.new()
        bm.from_mesh(me)
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=MERGE_DIST)
        bmesh.ops.dissolve_degenerate(bm, edges=bm.edges, dist=MERGE_DIST)
        bm.to_mesh(me)
        bm.free()
        for p in me.polygons:
            p.use_smooth = False
        me.update()
        return me
