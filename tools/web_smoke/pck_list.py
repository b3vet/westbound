#!/usr/bin/env python3
"""List the files in a Godot 4 .pck and sum their sizes (raw and gzip) by group.

    python3 tools/web_smoke/pck_list.py build/web/index.pck            # top groups + largest files
    python3 tools/web_smoke/pck_list.py build/web/index.pck --all      # every file
    python3 tools/web_smoke/pck_list.py build/web/index.pck --json out.json

Groups are the first two path components (res://assets/audio, res://src/dev, ...),
plus the .godot/imported cache split by source extension. The gzip column is each
file compressed alone at level 9 (a lower bound on what it adds to the gzip transfer
of the whole pack, which GitHub Pages serves gzip-encoded). docs/WEB.md.
"""
import argparse
import gzip
import json
import struct
import sys
from collections import defaultdict

PACK_DIR_ENCRYPTED = 1
PACK_REL_FILEBASE = 2


def read_pck(path):
    with open(path, 'rb') as f:
        data = f.read()
    if data[:4] != b'GDPC':
        sys.exit(f'{path}: not a Godot pack (magic {data[:4]!r})')
    version, major, minor, patch, flags, file_base = struct.unpack_from('<IIIIIQ', data, 4)
    pos = 4 + 4 * 5 + 8
    if version >= 3:
        (dir_offset,) = struct.unpack_from('<Q', data, pos)
        pos = dir_offset
    else:
        pos += 16 * 4
    if flags & PACK_DIR_ENCRYPTED:
        sys.exit(f'{path}: encrypted directory')
    (count,) = struct.unpack_from('<I', data, pos)
    pos += 4
    files = []
    for _ in range(count):
        (plen,) = struct.unpack_from('<I', data, pos)
        pos += 4
        name = data[pos:pos + plen].rstrip(b'\0').decode('utf-8')
        pos += plen
        offset, size = struct.unpack_from('<QQ', data, pos)
        pos += 16 + 16 + 4  # offset, size, md5, flags
        if flags & PACK_REL_FILEBASE:
            offset += file_base
        blob = data[offset:offset + size]
        files.append({
            'path': name if name.startswith('res://') else 'res://' + name,
            'size': size,
            'gzip': len(gzip.compress(blob, 9)),
        })
    return {'version': version, 'engine': f'{major}.{minor}.{patch}', 'files': files,
            'pck_size': len(data), 'pck_gzip': len(gzip.compress(data, 6))}


def group_of(p):
    rel = p[len('res://'):]
    if rel.startswith('.godot/imported/'):
        # foo.ogg-<md5>.oggvorbisstr -> imported: .ogg
        base = rel.split('/')[-1]
        src = base.rsplit('-', 1)[0]
        ext = src.rsplit('.', 1)[-1] if '.' in src else '?'
        return f'.godot/imported (*.{ext})'
    if rel.startswith('.godot/'):
        return '.godot (other)'
    parts = rel.split('/')
    return '/'.join(parts[:2]) if len(parts) > 2 else (parts[0] if len(parts) > 1 else '(root)')


def human(n):
    return f'{n / 1048576:.2f} MiB' if n >= 1048576 else f'{n / 1024:.1f} KiB'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('pck')
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--top', type=int, default=25)
    ap.add_argument('--json')
    a = ap.parse_args()
    info = read_pck(a.pck)
    files = info['files']
    groups = defaultdict(lambda: [0, 0, 0])
    for f in files:
        g = groups[group_of(f['path'])]
        g[0] += 1
        g[1] += f['size']
        g[2] += f['gzip']
    print(f"{a.pck}: pack v{info['version']} (Godot {info['engine']}), {len(files)} files, "
          f"{human(info['pck_size'])}, gzip -6 {human(info['pck_gzip'])}")
    print(f"\n{'group':44} {'files':>6} {'raw':>12} {'gzip':>12}")
    for name, (n, raw, gz) in sorted(groups.items(), key=lambda kv: -kv[1][2]):
        print(f'{name:44} {n:6d} {human(raw):>12} {human(gz):>12}')
    listed = sorted(files, key=lambda f: -f['gzip'])
    if not a.all:
        listed = listed[:a.top]
    print(f"\n{'file':80} {'raw':>12} {'gzip':>12}")
    for f in listed:
        print(f"{f['path'][:80]:80} {human(f['size']):>12} {human(f['gzip']):>12}")
    if a.json:
        with open(a.json, 'w') as out:
            json.dump(info, out, indent=1)


if __name__ == '__main__':
    main()
