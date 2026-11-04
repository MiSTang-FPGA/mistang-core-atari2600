#!/usr/bin/env python3
"""System test: run the RTL (cpu6502c + tia + riot + rom), log TIA writes, rebuild the frame with tools/reftia.py and compare.
usage: difftest_sys.py ROM.hex FALLS"""
import subprocess, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import reftia
rom, falls = sys.argv[1], int(sys.argv[2])
subprocess.run(['iverilog','-g2012','-DROM="%s"'%rom,'-DFALLS=%d'%falls,'-o','build/tbsys.vvp','sim/tb_sys.sv','rtl/atari_sys.sv','rtl/cpu6502c.sv','rtl/tia.sv'], check=True, stderr=subprocess.DEVNULL)
subprocess.run(['vvp','build/tbsys.vvp'], check=True, stdout=subprocess.DEVNULL, timeout=900)
names = {v: k for k, v in reftia.W.items()}
wr = []
for l in open('build/tia_writes.txt'):
    t, a, d = map(int, l.split())
    if a in names: wr.append((t, names[a], d))
tend, cxv = map(int, open('build/rtl_cx.txt').read().split())
ref = reftia.run(wr, tend)
snap_fb, snap_cx = ref.snap
rtl = [int(v, 16) for v in open('build/rtl_fb.txt').read().split()]
bad = [(i % 160, i // 160, rtl[i], snap_fb[i // 160][i % 160]) for i in range(30720) if rtl[i] != snap_fb[i // 160][i % 160]]
cxr = sum(1 << b for b in snap_cx)
print('writes %d, colour clocks %d, frames in reference %d' % (len(wr), tend, ref.falls))
if not bad and cxr == cxv and ref.falls == falls: print('PASS: RTL frame and collision latches match the reference'); sys.exit(0)
print('MISMATCH: %d pixels differ, first (x,y,rtl,ref): %s; cx rtl %x ref %x' % (len(bad), bad[:6], cxv, cxr)); sys.exit(1)
