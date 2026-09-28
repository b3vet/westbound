"""Westbound linter: enforces the rendering budget and the sim working rules.

Rules (ids are stable; docs/TOOLS.md has the table with escapes):
  WB001-WB004  rendering budget (.gd/.tscn/.tres under src/, assets/, data/)
  WB100        malformed `# lint:` directive
  WB101-WB103  magic numbers, determinism, purity (sim files)
  WB104        allocation in a tick function (sim files, warning)
  WB201        missing return type (src/, warning)
"""

from __future__ import annotations

import fnmatch
import os
import re
from dataclasses import dataclass
from pathlib import Path

from .gdscan import Line, split_gd

ERROR = "error"
WARNING = "warning"

# id -> (severity, summary). Order is the documentation order.
RULES: dict[str, tuple[str, str]] = {
    "WB001": (ERROR, "OmniLight3D/SpotLight3D (one DirectionalLight3D only)"),
    "WB002": (ERROR, "StandardMaterial3D/ORMMaterial3D outside debug/dev paths"),
    "WB003": (ERROR, "shadows enabled"),
    "WB004": (ERROR, "post effect enabled (glow, SSAO, SSR, SSIL, SDFGI, volumetric fog, DOF, auto exposure)"),
    "WB100": (ERROR, "malformed `# lint:` directive"),
    "WB101": (ERROR, "magic number in sim code"),
    "WB102": (ERROR, "nondeterminism in sim code"),
    "WB103": (ERROR, "impure sim code (Node, scene tree, autoload, Input)"),
    "WB104": (WARNING, "allocation in a sim tick function"),
    "WB201": (WARNING, "func without a return type"),
}

RENDER_ROOTS = ("src/", "assets/", "data/")
SIM_GLOBS = (
    "src/road/road_path*.gd",
    "src/vehicle/vehicle_physics.gd",
    "src/traffic/*.gd",
    "src/scoring/*.gd",
    "src/sun/sun_clock.gd",
)
DEBUG_DIRS = {"debug", "dev"}
SKIP_DIRS = {".git", ".godot", ".claude", "build", "node_modules", "__pycache__"}
SKIP_PATHS = {"tests/out"}
EXTENSIONS = (".gd", ".tscn", ".tres")
DEFAULT_AUTOLOADS = ("Events", "Game", "Settings", "Save")

# Numbers allowed anywhere in sim code: identities, doubling and halving.
ALLOWED_NUMBERS = {0.0, 1.0, 2.0, 0.5}

DIRECTIVE = re.compile(r"^#+\s*lint:\s*([\w-]+)[ \t]*(.*)$")
KNOWN_DIRECTIVES = {"sim", "not-sim", "allow-number", "allow-alloc"}
NEEDS_REASON = {"not-sim", "allow-number", "allow-alloc"}


@dataclass(frozen=True, order=True)
class Finding:
    path: str
    line: int
    rule: str
    message: str

    @property
    def severity(self) -> str:
        return RULES[self.rule][0]

    def format(self) -> str:
        tag = " (warning)" if self.severity == WARNING else ""
        return f"{self.path}:{self.line}: {self.rule}{tag} {self.message}"


# ------------------------------------------------------------------ rendering (WB001-WB004)

LIGHTS = re.compile(r"\b(OmniLight3D|SpotLight3D)\b")
MATERIALS = re.compile(r"\b(StandardMaterial3D|ORMMaterial3D)\b")
SHADOWS = re.compile(r"\bshadow_enabled\s*=\s*true\b|\bset_shadow\s*\(\s*true\b")
POST_FX = re.compile(
    r"\b(?:set_)?(glow|ssao|ssr|ssil|sdfgi|volumetric_fog|dof_blur_far|dof_blur_near|auto_exposure)"
    r"_enabled(?:\s*=\s*|\s*\(\s*)true\b"
)


def _render_rules(rel: str, lines: list[tuple[int, str]]) -> list[Finding]:
    out: list[Finding] = []
    debug_ok = bool(DEBUG_DIRS & set(rel.split("/")[:-1]))
    for lineno, text in lines:
        for m in LIGHTS.finditer(text):
            out.append(Finding(rel, lineno, "WB001", f"{m.group(1)} is over the lighting budget; fake it with emissive geometry or glow sprites"))
        if not debug_ok:
            for m in MATERIALS.finditer(text):
                out.append(Finding(rel, lineno, "WB002", f"{m.group(1)} (PBR) in gameplay; use the shared unlit/vertex-lit ShaderMaterial (debug-only files go under a debug/ or dev/ dir)"))
        if SHADOWS.search(text):
            out.append(Finding(rel, lineno, "WB003", "shadow maps are off by budget; use a blob shadow decal"))
        for m in POST_FX.finditer(text):
            out.append(Finding(rel, lineno, "WB004", f"{m.group(1)} post effect is over budget (color grade only)"))
    return out


# ------------------------------------------------------------------ sim rules (WB101-WB104)

NUMBER = re.compile(
    r"(?<![\w.])(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|(?:\d[\d_]*(?:\.[\d_]*)?|\.\d[\d_]*)(?:[eE][+-]?\d[\d_]*)?)(?!\w)"
)
CONST_DECL = re.compile(r"^\s*(?:static\s+)?const\s+\w+")
ENUM_OPEN = re.compile(r"\benum\b[^{]*\{")

NONDETERMINISM = [
    (re.compile(r"(?<![\w.])(randf|randi|randf_range|randi_range|randomize|randfn|seed|rand_from_seed)\s*\("),
     "global {0}() is not seeded per run; take an Rng stream (Rng.derive)"),
    (re.compile(r"\bRandomNumberGenerator\b"), "RandomNumberGenerator in sim; take an Rng stream (Rng.derive)"),
    (re.compile(r"(?<![\w.])(hash)\s*\(|\.(hash)\s*\("), "{0}() is not stable across platforms/versions; use Rng.fnv1a32"),
    (re.compile(r"(?<![\w.])(Time)\."), "wall-clock {0} in sim; time comes in as dt"),
    (re.compile(r"(?<![\w.])OS\.(get_(?:ticks|unix_time|system_time)\w*)"), "OS.{0} in sim; time comes in as dt"),
    (re.compile(r"(?<![\w.])Engine\.(get_\w*frames\w*)"), "Engine.{0} (frame timing) in sim"),
    (re.compile(r"\b(get_(?:physics_)?process_delta_time)\s*\("), "{0}() (frame timing) in sim; dt is a parameter"),
]

NODE_BASES = re.compile(
    r"^(Node|Control|CanvasItem|CanvasLayer|Viewport|SubViewport|Window|SceneTree|MainLoop|Timer"
    r"|AnimationPlayer|HTTPRequest|\w+2D|\w+3D)$"
)
EXTENDS = re.compile(r"^\s*(?:class\s+\w+\s+)?extends\s+(\w+)")
TREE_ACCESS = re.compile(
    r"\b(get_tree|get_node|get_node_or_null|get_parent|add_child|remove_child|find_child|get_viewport|get_window)\s*\("
)
DOLLAR = re.compile(r"\$[\w\"'/]")
SINGLETONS = re.compile(r"(?<![\w.])(Input|Engine\.get_main_loop|Engine\.get_singleton)\b")

HOT_FUNC = re.compile(r"^(step\w*|tick\w*|_physics_process|_process|\w+_into)$")
FUNC_DECL = re.compile(r"^(\s*)(?:static\s+)?func\s+(\w+)\s*\(")
ALLOCATIONS = [
    (re.compile(r"\{"), "Dictionary literal"),
    (re.compile(r"\.new\s*\("), "object .new()"),
    (re.compile(r"(?<![\w.])(Packed\w+Array|Array|Dictionary|String|StringName|NodePath)\s*\("), "{0}() constructor"),
    (re.compile(r"(?<![\w.])str\s*\("), "str()"),
    (re.compile(r'""\s*%'), "% string formatting"),
    (re.compile(r"\.(duplicate|slice|keys|values|split|join|format|map|filter)\s*\("), ".{0}() copy"),
    (re.compile(r"(?<![\w.])func\s*\("), "lambda (Callable)"),
    (re.compile(r"\.bind\s*\("), ".bind() (Callable)"),
]


def is_sim(rel: str, directives: dict[str, str]) -> bool:
    if "not-sim" in directives:
        return False
    return "sim" in directives or any(fnmatch.fnmatchcase(rel, g) for g in SIM_GLOBS)


def _directives(rel: str, lines: list[Line]) -> tuple[dict[int, dict[str, str]], list[Finding]]:
    """Per-line `# lint:` directives ({lineno: {name: reason}}) and WB100 findings."""
    by_line: dict[int, dict[str, str]] = {}
    bad: list[Finding] = []
    for ln in lines:
        m = DIRECTIVE.match(ln.comment)
        if not m:
            continue
        name, reason = m.group(1), m.group(2).split("#", 1)[0].strip()
        if name not in KNOWN_DIRECTIVES:
            bad.append(Finding(rel, ln.lineno, "WB100", f"unknown directive 'lint: {name}' (known: {', '.join(sorted(KNOWN_DIRECTIVES))})"))
        elif name in NEEDS_REASON and not re.search(r"[A-Za-z]", reason):
            bad.append(Finding(rel, ln.lineno, "WB100", f"'lint: {name}' needs a reason after it"))
        else:
            by_line.setdefault(ln.lineno, {})[name] = reason
    return by_line, bad


def _number_value(tok: str) -> float:
    t = tok.replace("_", "")
    if t[:2].lower() in ("0x", "0b"):
        return float(int(t, 0))
    return float(t)


def _is_int_literal(tok: str) -> bool:
    t = tok.lower()
    return t.startswith(("0x", "0b")) or not any(ch in t for ch in ".e")


def _is_subscript_index(code: str, start: int, end: int) -> bool:
    before = code[:start].rstrip()
    after = code[end:].lstrip()
    if not before.endswith("[") or not after.startswith("]"):
        return False
    prev = before[:-1].rstrip()[-1:]
    return bool(prev) and (prev.isalnum() or prev in "_)]")


BIT_OPS = ("<<", ">>", "&", "|", "^")


def _is_bit_operand(code: str, start: int, end: int) -> bool:
    """`h >> 16`, `x & 0xFF`, `1 << 3`: shift widths and masks are structural."""
    before = code[:start].rstrip()
    after = code[end:].lstrip()
    logical = ("&&", "||")
    return ((before.endswith(BIT_OPS) and not before.endswith(logical))
            or (after.startswith(BIT_OPS) and not after.startswith(logical)))


def _magic_numbers(rel: str, lines: list[Line], directives: dict[int, dict[str, str]]) -> list[Finding]:
    out: list[Finding] = []
    in_enum = False
    for ln in lines:
        code = ln.code
        opened = ENUM_OPEN.search(code)
        enum_line = in_enum or bool(opened)
        if opened:
            in_enum = "}" not in code[opened.end():]
        elif in_enum and "}" in code:
            in_enum = False
        int_ok = enum_line or bool(CONST_DECL.match(code))
        if "allow-number" in directives.get(ln.lineno, {}):
            continue
        for m in NUMBER.finditer(code):
            tok = m.group(0)
            if _number_value(tok) in ALLOWED_NUMBERS:
                continue
            if int_ok and _is_int_literal(tok):
                continue
            if _is_int_literal(tok) and (_is_subscript_index(code, m.start(), m.end())
                                         or _is_bit_operand(code, m.start(), m.end())):
                continue
            out.append(Finding(rel, ln.lineno, "WB101", f"magic number {tok}; move it to tuning data, or '# lint: allow-number <reason>'"))
    return out


def _determinism_and_purity(rel: str, lines: list[Line], autoloads: tuple[str, ...]) -> list[Finding]:
    out: list[Finding] = []
    autoload_re = re.compile(r"(?<![\w.])(" + "|".join(map(re.escape, autoloads)) + r")\.") if autoloads else None
    for ln in lines:
        code = ln.code
        for rx, msg in NONDETERMINISM:
            for m in rx.finditer(code):
                name = next((g for g in m.groups() if g), m.group(0)) if m.groups() else m.group(0)
                out.append(Finding(rel, ln.lineno, "WB102", msg.format(name)))
        m = EXTENDS.match(code)
        if m and NODE_BASES.match(m.group(1)):
            out.append(Finding(rel, ln.lineno, "WB103", f"sim code extends {m.group(1)}; extend RefCounted and use a thin Node adapter"))
        for m in TREE_ACCESS.finditer(code):
            out.append(Finding(rel, ln.lineno, "WB103", f"{m.group(1)}() touches the scene tree"))
        if DOLLAR.search(code):
            out.append(Finding(rel, ln.lineno, "WB103", "$node access touches the scene tree"))
        for m in SINGLETONS.finditer(code):
            out.append(Finding(rel, ln.lineno, "WB103", f"{m.group(1)} in sim; pass the value in"))
        if autoload_re:
            for m in autoload_re.finditer(code):
                out.append(Finding(rel, ln.lineno, "WB103", f"autoload {m.group(1)} in sim; write events to the caller's buffer"))
    return out


def _function_spans(lines: list[Line]):
    """Yields (name, signature_text, first_line_index, body_line_indices)."""
    i = 0
    while i < len(lines):
        m = FUNC_DECL.match(lines[i].code)
        if not m:
            i += 1
            continue
        indent = len(m.group(1).expandtabs(4))
        sig, j = "", i
        while j < len(lines):
            sig += lines[j].code + "\n"
            if sig.count("(") <= sig.count(")") and re.search(r"\)[^()]*:", sig):
                break
            j += 1
        body = list(range(i, j + 1))
        k = j + 1
        while k < len(lines):
            ln = lines[k]
            if ln.blank or len(ln.raw.expandtabs(4)) - len(ln.raw.expandtabs(4).lstrip()) > indent:
                body.append(k)
                k += 1
            else:
                break
        yield m.group(2), sig, i, body
        i = j + 1


def _allocations(rel: str, lines: list[Line], directives: dict[int, dict[str, str]]) -> list[Finding]:
    out: list[Finding] = []
    for name, _sig, _first, body in _function_spans(lines):
        if not HOT_FUNC.match(name):
            continue
        for idx in body:
            ln = lines[idx]
            if "allow-alloc" in directives.get(ln.lineno, {}):
                continue
            code = ln.code
            hits: list[str] = []
            for pos, ch in enumerate(code):
                if ch == "[":
                    prev = code[:pos].rstrip()[-1:]
                    if not (prev.isalnum() or prev in '_)]"'):
                        hits.append("Array literal")
                        break
            for rx, msg in ALLOCATIONS:
                for m in rx.finditer(code):
                    hits.append(msg.format(*(g for g in m.groups() if g)) if m.groups() else msg)
            for h in dict.fromkeys(hits):
                out.append(Finding(rel, ln.lineno, "WB104", f"{h} in tick function {name}(); preallocate at init or '# lint: allow-alloc <reason>'"))
    return out


def _return_types(rel: str, lines: list[Line]) -> list[Finding]:
    out: list[Finding] = []
    for name, sig, first, _body in _function_spans(lines):
        close = sig.rfind(")")
        if "->" not in sig[close:]:
            out.append(Finding(rel, lines[first].lineno, "WB201", f"func {name}() has no return type (add '-> void' or the type)"))
    return out


# ------------------------------------------------------------------ driver


def read_autoloads(root: Path) -> tuple[str, ...]:
    project = root / "project.godot"
    if not project.is_file():
        return DEFAULT_AUTOLOADS
    names, section = [], ""
    for line in project.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if s.startswith("["):
            section = s
        elif section == "[autoload]" and "=" in s and not s.startswith(";"):
            names.append(s.split("=", 1)[0].strip())
    return tuple(names) or DEFAULT_AUTOLOADS


def lint_file(root: Path, path: Path, autoloads: tuple[str, ...]) -> list[Finding]:
    rel = path.resolve().relative_to(root.resolve()).as_posix() if _inside(root, path) else path.as_posix()
    text = path.read_text(encoding="utf-8", errors="replace")
    findings: list[Finding] = []
    render_scope = rel.startswith(RENDER_ROOTS)
    if path.suffix in (".tscn", ".tres"):
        if render_scope:
            lines = [(n, t) for n, t in enumerate(text.split("\n"), start=1) if not t.lstrip().startswith(";")]
            findings += _render_rules(rel, lines)
        return findings

    lines = split_gd(text)
    per_line, bad = _directives(rel, lines)
    findings += bad
    file_directives: dict[str, str] = {}
    for d in per_line.values():
        file_directives.update(d)
    if render_scope:
        findings += _render_rules(rel, [(ln.lineno, ln.code) for ln in lines])
    if is_sim(rel, file_directives):
        findings += _magic_numbers(rel, lines, per_line)
        findings += _determinism_and_purity(rel, lines, autoloads)
        findings += _allocations(rel, lines, per_line)
    if rel.startswith("src/"):
        findings += _return_types(rel, lines)
    return findings


def _inside(root: Path, path: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def collect(root: Path, targets: list[Path]) -> list[Path]:
    """Files to lint. Directories are walked, skipping SKIP_DIRS, tests/out and
    any directory holding a .gdignore (Godot ignores those too) below the target."""
    files: list[Path] = []
    for target in targets:
        if target.is_file():
            files.append(target)
            continue
        for dirpath, dirnames, filenames in os.walk(target):
            here = Path(dirpath)
            rel = here.resolve().relative_to(root.resolve()).as_posix() if _inside(root, here) else ""
            dirnames[:] = sorted(
                d for d in dirnames
                if d not in SKIP_DIRS
                and (f"{rel}/{d}".lstrip("/") not in SKIP_PATHS)
                and not (here / d / ".gdignore").exists()
            )
            files += [here / f for f in sorted(filenames) if f.endswith(EXTENSIONS)]
    return files


def lint(root: Path, targets: list[Path]) -> list[Finding]:
    autoloads = read_autoloads(root)
    findings: list[Finding] = []
    for f in collect(root, targets):
        findings += lint_file(root, f, autoloads)
    return sorted(set(findings))
