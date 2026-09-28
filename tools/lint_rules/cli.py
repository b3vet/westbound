"""Command line for tools/lint. See docs/TOOLS.md."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from . import RULES, WARNING, lint

REPO = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).resolve().parent / "fixtures"
EXPECT = re.compile(r"expect:\s*(WB\d{3}(?:\s*,\s*WB\d{3})*)")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="tools/lint", description="Westbound budget and working-rule linter.")
    ap.add_argument("paths", nargs="*", help="files or directories (default: the whole repo)")
    ap.add_argument("--strict", action="store_true", help="warnings fail too")
    ap.add_argument("--self-test", action="store_true", help="check the rules against the seeded fixtures")
    ap.add_argument("--rules", action="store_true", help="list the rule ids")
    args = ap.parse_args(argv)

    if args.rules:
        for rid, (sev, summary) in RULES.items():
            print(f"{rid}  {sev:7}  {summary}")
        return 0
    if args.self_test:
        return self_test()

    targets = [Path(p) for p in args.paths] or [REPO]
    missing = [str(t) for t in targets if not t.exists()]
    if missing:
        print(f"lint: no such path: {', '.join(missing)}", file=sys.stderr)
        return 2
    findings = lint(REPO, targets)
    for f in findings:
        print(f.format())
    errors = sum(f.severity != WARNING for f in findings)
    warnings = len(findings) - errors
    failed = errors > 0 or (args.strict and warnings > 0)
    if findings or failed:
        print(f"lint: {errors} error(s), {warnings} warning(s)", file=sys.stderr)
    return 1 if failed else 0


def self_test() -> int:
    """Lints tools/lint_rules/fixtures (a mini repo) and compares the findings with
    the `expect: WBxxx[, WByyy]` annotations on the fixture lines. Every rule must be
    exercised, and the files without annotations must stay clean."""
    got = {(f.path, f.line, f.rule) for f in lint(FIXTURES, [FIXTURES])}
    want: set[tuple[str, int, str]] = set()
    files = sorted(p for p in FIXTURES.rglob("*") if p.suffix in (".gd", ".tscn", ".tres"))
    for p in files:
        rel = p.relative_to(FIXTURES).as_posix()
        for n, line in enumerate(p.read_text(encoding="utf-8").split("\n"), start=1):
            m = EXPECT.search(line)
            if m:
                want |= {(rel, n, r.strip()) for r in m.group(1).split(",")}

    ok = True
    for path, line, rule in sorted(want - got):
        print(f"MISSED   {path}:{line}: {rule}")
        ok = False
    for path, line, rule in sorted(got - want):
        print(f"EXTRA    {path}:{line}: {rule}")
        ok = False
    uncovered = sorted(set(RULES) - {r for _, _, r in want})
    if uncovered:
        print(f"UNCOVERED rules with no fixture: {', '.join(uncovered)}")
        ok = False
    clean = [p for p in files if not any(p.relative_to(FIXTURES).as_posix() == w[0] for w in want)]
    if not clean:
        print("NO CLEAN fixture (a file with no expectations)")
        ok = False
    print(f"lint self-test: {'ok' if ok else 'FAILED'}  {len(want)} expected findings, "
          f"{len(RULES) - len(uncovered)}/{len(RULES)} rules, {len(clean)} clean file(s)")
    return 0 if ok else 1
