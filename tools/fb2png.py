#!/usr/bin/env python3
"""frame dump (30720 hex colour indices) -> PNG using rom/palette.hex. usage: fb2png.py fb.txt out.png [scale-x scale-y]"""
import sys, zlib, struct, os
pal = [bytes.fromhex(l) for l in open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'rom', 'palette.hex')).read().split()]
fb = [int(v, 16) for v in open(sys.argv[1]).read().split()]
sx = int(sys.argv[3]) if len(sys.argv) > 3 else 6; sy = int(sys.argv[4]) if len(sys.argv) > 4 else 3
raw = bytearray()
for y in range(192):
    row = b''.join(pal[fb[y*160+x]] * sx for x in range(160))
    for _ in range(sy): raw += b'\x00' + row
w, h = 160*sx, 192*sy
def chunk(t, d): c = struct.pack('>I', len(d)) + t + d; return c + struct.pack('>I', zlib.crc32(t + d))
open(sys.argv[2], 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(bytes(raw), 9)) + chunk(b'IEND', b''))
