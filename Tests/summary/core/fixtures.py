#!/usr/bin/env python3
"""Create three nested square regions for production RegionIndex.load/Assigner."""
import struct
from pathlib import Path


def create(destination: Path):
    names = b'Country\0State\0City\0'
    offsets = [0, 8, 14]
    payload = bytearray(struct.pack('<4sIIIII', b'RGN1', 1, 3, 3, 12, 360 * 180))
    for i, half in enumerate([1., .8, .5]):
        payload.extend(struct.pack('<HBH2sfffffIHIIII', i, i, 0xFFFF if i == 0 else i - 1,
                                   b'AA', 1., -half, -half, half, half, i, 1, *([offsets[i]] * 4)))
    for i, half in enumerate([1., .8, .5]):
        payload.extend(struct.pack('<IIBffff', 4 * i, 4, 0, -half, -half, half, half))
    for half in [1_000_000, 800_000, 500_000]:
        for lat, lon in [(-half, -half), (-half, half), (half, half), (half, -half)]:
            payload.extend(struct.pack('<ii', lat, lon))
    region_list = []
    for y in range(180):
        for x in range(360):
            candidates = [2, 1, 0] if 88 <= y <= 91 and 178 <= x <= 181 else []
            payload.extend(struct.pack('<IH', len(region_list), len(candidates)))
            region_list.extend(candidates)
    payload.extend(struct.pack('<I', len(region_list)))
    payload.extend(struct.pack('<' + 'H' * len(region_list), *region_list))
    payload.extend(struct.pack('<I', len(names)))
    payload.extend(names)
    destination.write_bytes(payload)


if __name__ == '__main__':
    import sys
    create(Path(sys.argv[1]))
