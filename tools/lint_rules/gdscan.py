"""Line splitter for GDScript: separates code from comments and blanks strings.

`split_gd(text)` returns one `Line` per source line. `code` has every string
literal replaced by an empty `""` placeholder (so a formatting `"x %d" % v`
becomes `"" % v`) and the comment removed; `comment` is the `#...` tail.
Handles '...', "...", triple-quoted multi-line strings, r"raw" strings and
the &"StringName" / ^"NodePath" prefixes (which stay in `code`).
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class Line:
    lineno: int
    raw: str
    code: str
    comment: str

    @property
    def blank(self) -> bool:
        """No code on this line (empty, comment-only, or inside a multi-line string)."""
        return not self.code.strip()


def split_gd(text: str) -> list[Line]:
    out: list[Line] = []
    in_str: str | None = None  # the closing delimiter while inside a string
    raw = False
    for lineno, line in enumerate(text.split("\n"), start=1):
        code: list[str] = []
        comment = ""
        i, n = 0, len(line)
        while i < n:
            c = line[i]
            if in_str is not None:
                if c == "\\" and not raw:
                    i += 2
                    continue
                if line.startswith(in_str, i):
                    i += len(in_str)
                    in_str = None
                    code.append('""')
                    continue
                i += 1
                continue
            if c == "#":
                comment = line[i:]
                break
            if c in "\"'":
                raw = False
                if code and code[-1] == "r" and (len(code) < 2 or not _is_word(code[-2])):
                    code.pop()
                    raw = True
                if line.startswith(c * 3, i):
                    in_str = c * 3
                    i += 3
                else:
                    in_str = c
                    i += 1
                continue
            code.append(c)
            i += 1
        if in_str is not None and len(in_str) == 1:
            # Unterminated single-quoted string: GDScript would not parse it; recover.
            in_str = None
            code.append('""')
        out.append(Line(lineno, line, "".join(code), comment))
    return out


def _is_word(s: str) -> bool:
    return s.isalnum() or s == "_"
