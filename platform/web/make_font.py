#!/usr/bin/env python3
"""Build platform/web/wordmark.woff: Chakra Petch Bold subset to the loading screen's
characters (WP9.2, docs/WEB.md → Loading screen).

    python3 platform/web/make_font.py        # needs fontTools (pip install fonttools)

The web shell (platform/web/shell.html) draws the WESTBOUND wordmark and its status
line before the engine loads, in the title's face. The full TTF is 78 KiB; this subset
(A-Z, digits and a few signs) is a few KiB and ships next to index.html
(tools/export_web.sh copies it). WOFF (zlib), not WOFF2, so no brotli module is
needed. The name table is kept whole: it carries the copyright and the OFL notice
(SIL Open Font License 1.1, no Reserved Font Name; assets/fonts/OFL.txt,
assets/LICENSES.md).
"""
import os
import sys

from fontTools import subset

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
SRC = os.path.join(ROOT, 'assets', 'fonts', 'ChakraPetch-Bold.ttf')
OUT = os.path.join(HERE, 'wordmark.woff')
TEXT = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 %./-·'


def main() -> int:
    opts = subset.Options()
    opts.flavor = 'woff'
    opts.name_IDs = ['*']
    opts.name_languages = ['*']
    opts.layout_features = ['kern']
    opts.hinting = False
    opts.desubroutinize = True
    font = subset.load_font(SRC, opts)
    sub = subset.Subsetter(opts)
    sub.populate(text=TEXT)
    sub.subset(font)
    subset.save_font(font, OUT, opts)
    print(f'{os.path.relpath(OUT, ROOT)}: {os.path.getsize(OUT)} bytes ({len(TEXT)} characters)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
