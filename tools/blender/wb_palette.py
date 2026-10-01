"""Westbound palette and material names for Blender (docs/ART_PRODUCTION.md §2.2, §3.3).

Reads the three palette sources the game reads (tools/art/art_palette.gd does the same):
  style              assets/palette/palette.tres        (WBPalette text)
  coast_city_valley  tools/props/palette_biomes_4_6.tres (WBPalette text)
  desert_canyon      tools/props/biome_colors.gd         (BiomeColors.COLORS)
plus the fixed vehicle colours in src/vehicle/car_model.gd (CarModel.COLOR_*).

Parses material names like tools/art/art_materials.gd (car, traffic, prop) so the
validator catches a name the game would reject, and creates Blender materials whose
preview colour is the named sRGB value (the game only reads the NAME).

Usable without bpy (parsing) and inside Blender (material()).
"""

import os
import re

REPO = os.environ.get("WB_REPO") or os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

SET_STYLE = "style"
SET_COAST_CITY_VALLEY = "coast_city_valley"
SET_DESERT_CANYON = "desert_canyon"
ORDER = [SET_STYLE, SET_COAST_CITY_VALLEY, SET_DESERT_CANYON]
DESERT_CANYON_BIOMES = ("desert", "canyon")
COAST_CITY_VALLEY_BIOMES = ("coast", "city", "valley", "valley_fog")

# ArtMaterials constants.
PAINT_SHADES = {"paint": 1.0, "paint_shade": 0.8, "paint_dark": 0.55}
PROP_SUFFIXES = {"reflector": 1, "lamp": 2, "window": 4, "flash": 4}
BAD_CHARS = [".", " ", ":", "@", "/", "%", '"']

# Car material kinds and slots (CarModel.Slot).
SLOT_PAINT, SLOT_TRIM, SLOT_GLASS, SLOT_LAMP, SLOT_SIGNAL = range(5)
SLOT_NAMES = ["paint", "trim", "glass", "lamp", "signal"]

_cache = {}


def _read(rel):
    with open(os.path.join(REPO, rel), encoding="utf-8") as f:
        return f.read()


def _wb_palette(rel):
    text = _read(rel)
    names = re.search(r'^names = PackedStringArray\((.*)\)$', text, re.M).group(1)
    nums = re.search(r'^colors = PackedColorArray\((.*)\)$', text, re.M).group(1)
    names = [n.strip().strip('"') for n in names.split(",")]
    nums = [float(v) for v in nums.split(",")]
    assert len(nums) == len(names) * 4, rel
    return {n: tuple(nums[i * 4:i * 4 + 3]) for i, n in enumerate(names)}


def _biome_colors():
    out = {}
    for m in re.finditer(r'&"(\w+)":\s*Color\(([^)]*)\)', _read("tools/props/biome_colors.gd")):
        out[m.group(1)] = tuple(float(v) for v in m.group(2).split(",")[:3])
    return out


def sets():
    """Set id -> {name: (r, g, b) sRGB 0-1}."""
    if "sets" not in _cache:
        _cache["sets"] = {
            SET_STYLE: _wb_palette("assets/palette/palette.tres"),
            SET_COAST_CITY_VALLEY: _wb_palette("tools/props/palette_biomes_4_6.tres"),
            SET_DESERT_CANYON: _biome_colors(),
        }
    return _cache["sets"]


def vehicle_colors():
    """CarModel.COLOR_* -> {"headlight": (r, g, b), ...} (sRGB)."""
    if "vehicle" not in _cache:
        out = {}
        for m in re.finditer(r'^const COLOR_(\w+) := Color\(([^)]*)\)', _read("src/vehicle/car_model.gd"), re.M):
            out[m.group(1).lower()] = tuple(float(v) for v in m.group(2).split(",")[:3])
        _cache["vehicle"] = out
    return _cache["vehicle"]


def search_order(prefer=""):
    if not prefer or prefer == SET_STYLE or prefer not in ORDER:
        return ORDER
    return [SET_STYLE, prefer] + [s for s in ORDER if s not in (SET_STYLE, prefer)]


def prefer_set_for_biome(biome):
    if biome in DESERT_CANYON_BIOMES:
        return SET_DESERT_CANYON
    if biome in COAST_CITY_VALLEY_BIOMES:
        return SET_COAST_CITY_VALLEY
    return ""


def has_name(name, prefer=""):
    return any(name in sets()[s] for s in search_order(prefer))


def color(name, prefer=""):
    for s in search_order(prefer):
        if name in sets()[s]:
            return sets()[s][name]
    raise KeyError("not a palette colour: " + name)


def all_names(prefer=""):
    out = []
    for s in search_order(prefer):
        out += [n for n in sets()[s] if n not in out]
    return out


def hex_to_srgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4))


def srgb_to_linear(c):
    return tuple(v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in c)


# ------------------------------------------------------------------ name parsing

def _bad(name):
    for ch in BAD_CHARS:
        if ch in name:
            return "material %s: '%s' is not allowed in names (Blender duplicate?)" % (name, ch)
    return ""


def parse_car(name):
    """A player-car material -> dict(kind='slot'|'interior'|'gauges', slot, color, error)."""
    n = name.strip().lower()
    err = _bad(name)
    if err:
        return {"error": err}
    vc = vehicle_colors()
    if n in PAINT_SHADES:
        k = PAINT_SHADES[n]
        return {"kind": "slot", "slot": SLOT_PAINT, "color": (k, k, k), "shade": k}
    fixed = {
        "glass": (SLOT_GLASS, vc["glass"]), "lamp_head": (SLOT_LAMP, vc["headlight"]),
        "lamp_tail": (SLOT_LAMP, vc["taillight"]), "signal_brake": (SLOT_SIGNAL, vc["brake"]),
        "signal_blinker": (SLOT_SIGNAL, vc["blinker"]), "signal_reverse": (SLOT_SIGNAL, vc["reverse"]),
    }
    if n in fixed:
        return {"kind": "slot", "slot": fixed[n][0], "color": fixed[n][1]}
    if n == "gauges":
        return {"kind": "gauges", "color": (0.85, 0.82, 0.7)}  # preview only (cockpit_gauges.gdshader)
    if n == "interior_screen":
        return {"kind": "interior", "color": (0.1, 0.17, 0.26), "emissive": 3}
    for prefix, slot in (("trim_", SLOT_TRIM), ("glass_", SLOT_GLASS)):
        if n.startswith(prefix):
            c = n[len(prefix):]
            if has_name(c):
                return {"kind": "slot", "slot": slot, "color": color(c)}
            return {"error": "material %s: %s is not a palette colour" % (name, c)}
    if n.startswith("interior_"):
        c = n[len("interior_"):]
        if has_name(c):
            return {"kind": "interior", "color": color(c)}
        return {"error": "material %s: %s is not a palette colour" % (name, c)}
    return {"error": "material %s: not a car material name" % name}


TRAFFIC_PREFIXES = [("fixed_", 0), ("glass_", 2), ("wheel_", 3), ("head_", 4), ("rear_", 5),
                    ("brake_", 6), ("blinkl_", 7), ("blinkr_", 8)]
TRAFFIC_PART_NAMES = ["fixed", "paint", "glass", "wheel", "head", "rear", "brake", "blinkL", "blinkR"]


def parse_traffic(name):
    """A traffic material -> dict(part, color, error). Part ids are TrafficLights.PART_*."""
    n = name.strip().lower()
    err = _bad(name)
    if err:
        return {"error": err}
    if n in PAINT_SHADES:
        k = PAINT_SHADES[n]
        return {"part": 1, "color": (k, k, k)}
    for prefix, part in TRAFFIC_PREFIXES:
        if n.startswith(prefix) and has_name(n[len(prefix):]):
            return {"part": part, "color": color(n[len(prefix):])}
    if has_name(n):
        return {"part": 0, "color": color(n)}
    return {"error": "material %s: not a traffic material name" % name}


def parse_prop(name, prefer=""):
    """A world-mesh material -> dict(color, emissive, window, error)."""
    n = name.strip().lower()
    err = _bad(name)
    if err:
        return {"error": err}
    base, emissive, window = n, 0, False
    if "__" in n:
        base, suffix = n.split("__", 1)
        if suffix not in PROP_SUFFIXES:
            return {"error": "material %s: unknown suffix __%s" % (name, suffix)}
        emissive, window = PROP_SUFFIXES[suffix], suffix == "window"
    if not has_name(base, prefer):
        return {"error": "material %s: %s is not a palette colour" % (name, base)}
    return {"color": color(base, prefer), "emissive": emissive, "window": window}


# ------------------------------------------------------------------ Blender materials

PREVIEW_PAINT = (0.9, 0.2, 0.15)


def material(name, kind="car", paint=None, prefer=""):
    """Get or create the Blender material `name`, previewing the colour it stands for.

    The game replaces the material by name; the preview colour only keeps the viewport
    honest. `paint` (sRGB) previews paint* materials (default: the Falcon GT red).
    """
    import bpy
    parsed = {"car": parse_car, "traffic": parse_traffic}.get(kind, lambda n: parse_prop(n, prefer))(name)
    if parsed.get("error"):
        raise ValueError(parsed["error"])
    rgb = parsed["color"]
    if name.lower() in PAINT_SHADES:
        p = paint or PREVIEW_PAINT
        k = PAINT_SHADES[name.lower()]
        rgb = (p[0] * k, p[1] * k, p[2] * k)
    lin = srgb_to_linear(rgb)
    mat = bpy.data.materials.get(name)
    if mat is None:
        mat = bpy.data.materials.new(name)
    mat.diffuse_color = (*lin, 1.0)
    mat.roughness = 0.6
    mat.metallic = 0.0
    if mat.node_tree is None:
        try:
            mat.use_nodes = True
        except AttributeError:
            pass
    if mat.node_tree is not None:
        bsdf = mat.node_tree.nodes.get("Principled BSDF")
        if bsdf is not None:
            bsdf.inputs["Base Color"].default_value = (*lin, 1.0)
            bsdf.inputs["Roughness"].default_value = 0.6
            emissive = name.lower().startswith(("lamp_", "signal_")) or name.lower() == "interior_screen"
            if "Emission Color" in bsdf.inputs:
                bsdf.inputs["Emission Color"].default_value = (*lin, 1.0)
                bsdf.inputs["Emission Strength"].default_value = 1.5 if emissive else 0.0
    return mat


def set_paint_preview(paint):
    """Re-tint every paint* material's preview to `paint` (sRGB), e.g. to try garage paints."""
    import bpy
    for n, k in PAINT_SHADES.items():
        if bpy.data.materials.get(n) is not None:
            material(n, paint=paint)
