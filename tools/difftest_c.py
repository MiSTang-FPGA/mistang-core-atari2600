#!/usr/bin/env python3
"""Cycle-exact differential test: RTL cpu6502c bus trace (+ final state, memory) vs tools/ref6502c.py. usage: difftest_c.py SEED INSTR [dec]"""
import random, subprocess, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import ref6502c
seed, n = int(sys.argv[1]), int(sys.argv[2]); dec = len(sys.argv) > 3
r = random.Random(seed)
mem = [r.randrange(256) for _ in range(65536)]
mem[0xFFFC], mem[0xFFFD] = 0x00, 0x02; mem[0xFFFE], mem[0xFFFF] = 0x00, 0x03
if dec: mem[0x200] = 0xF8
open('build/rand_mem.hex','w').write('\n'.join('%02x'%b for b in mem)+'\n')
ref = ref6502c.Rec(list(mem)); exp = []
for _ in range(n): exp += ref6502c.step_trace(ref)
subprocess.run(['iverilog','-g2012','-DINSTR=%d'%n,'-o','build/tbcc.vvp','sim/tb_cpuc.sv','rtl/cpu6502c.sv'], check=True, stderr=subprocess.DEVNULL)
subprocess.run(['vvp','build/tbcc.vvp'], check=True, stdout=subprocess.DEVNULL, timeout=120)
got = []
for l in open('build/rtl_trace.txt'):
    a, w, d = l.split(); got.append((int(a,16), 'W' if w == '1' else 'R', int(d,16) if w == '1' else None))
bad = None
for i in range(max(len(got), len(exp))):
    e = exp[i] if i < len(exp) else None; g = got[i] if i < len(got) else None
    if e != g: bad = (i, e, g); break
L = open('build/rtl_state.txt').read().split('\n')
pc,a,x,y,s,p = [int(v,16) for v in L[0].split()]
rm = [int(v,16) for v in L[1:65537]]
st_e = (ref.PC, ref.A, ref.X, ref.Y, ref.S, ref.N<<7|ref.V<<6|0x30|ref.D<<3|ref.I<<2|ref.Z<<1|ref.C)
mdiff = [i for i in range(65536) if rm[i] != ref.m[i]]
if bad is None and st_e == (pc,a,x,y,s,p) and not mdiff: print('seed %d: OK (%d instr, %d cycles)' % (seed, n, len(exp))); sys.exit(0)
print('seed %d: MISMATCH' % seed)
if bad: print(' first trace diff at cycle %d: expected %s got %s' % bad)
print(' state exp', [hex(v) for v in st_e], 'got', [hex(v) for v in (pc,a,x,y,s,p)], 'mem diffs', [hex(i) for i in mdiff[:6]])
sys.exit(1)
