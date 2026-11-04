#!/usr/bin/env python3
"""NTSC style palette for the 128 colour indices (hue 0..15, luminance 0..7), computed from YIQ. Writes rom/palette.hex (RRGGBB)."""
import math, sys
out = []
for idx in range(128):
    hue, lum = idx >> 3, idx & 7
    y = 0.05 + lum * 0.133
    s = 0.0 if hue == 0 else 0.27
    th = math.radians(-44 + (hue - 1) * 24)
    i, q = s * math.cos(th), s * math.sin(th)
    rgb = [y + 0.956 * i + 0.621 * q, y - 0.272 * i - 0.647 * q, y - 1.106 * i + 1.703 * q]
    out.append(''.join('%02x' % int(255 * max(0.0, min(1.0, c)) ** 0.85 + 0.5) for c in rgb))
open(sys.argv[1] if len(sys.argv) > 1 else 'rom/palette.hex', 'w').write('\n'.join(out) + '\n')
