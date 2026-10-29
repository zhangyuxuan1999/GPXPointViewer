#!/usr/bin/env python3
"""调试：列出 Regions.bin 里包含某点的所有地区（不经过 app 的裁决规则），看数据本身。用法：regions_debug.py <Regions.bin> lat lon [lat lon …]"""
import struct, sys
b = open(sys.argv[1], "rb").read()
n, nr, nv, nc = struct.unpack_from("<IIII", b, 8); o = 24
recs = []
for i in range(n):
    rid, level, parent, iso, area, a, bb, c, d, rs, rc, n0, n1, n2, n3 = struct.unpack_from("<HBH2sfffffIHIIII", b, o); o += 49
    recs.append((rid, level, parent, iso.decode().strip(), area, (a, bb, c, d), rs, rc, n0, n1, n2, n3))
rings = [struct.unpack_from("<IIBffff", b, o + 25 * i) for i in range(nr)]; o += 25 * nr
verts = struct.unpack_from("<%di" % (2 * nv), b, o); o += 8 * nv
o += 6 * nc; nl = struct.unpack_from("<I", b, o)[0]; o += 4 + 2 * nl
nn = struct.unpack_from("<I", b, o)[0]; o += 4; pool = b[o:o + nn]
def nm(off): e = pool.index(b"\0", off); return pool[off:e].decode()
def pip(y, x, s, cnt):
    inside = False; j = s + cnt - 1
    for i in range(s, s + cnt):
        yi, yj = verts[2 * i], verts[2 * j]
        if (yi > y) != (yj > y):
            xi, xj = verts[2 * i + 1], verts[2 * j + 1]
            side = (xj - xi) * (y - yi) - (x - xi) * (yj - yi)
            if (side > 0) if yj > yi else (side < 0): inside = not inside
        j = i
    return inside
args = sys.argv[2:]
for k in range(0, len(args) - 1, 2):
    lat, lon = float(args[k]), float(args[k + 1]); y, x = round(lat * 1e6), round(lon * 1e6)
    print(f"== {lat},{lon}")
    for rid, level, parent, iso, area, bb, rs, rc, n0, n1, n2, n3 in recs:
        if not (bb[0] - 0.01 <= lat <= bb[2] + 0.01 and bb[1] - 0.01 <= lon <= bb[3] + 0.01): continue
        hits = []
        for ri in range(rs, rs + rc):
            vs, vc, hole, *_ = rings[ri]
            if vc >= 3 and pip(y, x, vs, vc): hits.append(("hole" if hole else "outer") + f"#{ri}(n={vc})")
        if hits:
            par = nm(recs[parent][8]) if parent != 0xFFFF else "-"
            print(f"  L{level} {nm(n0)} [en={nm(n1)} de={nm(n2)} hant={nm(n3)}] ({iso or '--'}) parent={par} area={area:.1f} km² rings-containing: {hits}")
