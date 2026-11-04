#!/usr/bin/env python3
"""Reference model of the TIA picture logic. Input: the CPU's register write log (colour-clock time, register, value).
Output: the 160x192 colour-index frame at the end of the K-th VSYNC release, and the collision latches.
Written independently of the RTL, object by object."""
import sys

W = {  # write register offsets
 'VSYNC':0,'VBLANK':1,'WSYNC':2,'NUSIZ0':4,'NUSIZ1':5,'COLUP0':6,'COLUP1':7,'COLUPF':8,'COLUBK':9,'CTRLPF':10,'REFP0':11,'REFP1':12,
 'PF0':13,'PF1':14,'PF2':15,'RESP0':16,'RESP1':17,'RESM0':18,'RESM1':19,'RESBL':20,'GRP0':27,'GRP1':28,'ENAM0':29,'ENAM1':30,'ENABL':31,
 'HMP0':32,'HMP1':33,'HMM0':34,'HMM1':35,'HMBL':36,'VDELP0':37,'VDELP1':38,'VDELBL':39,'RESMP0':40,'RESMP1':41,'HMOVE':42,'HMCLR':43,'CXCLR':44}

def sx(n):  # 4-bit two's complement
    return n - 16 if n & 8 else n

class TIA:
    def __init__(s):
        s.r = {k: 0 for k in W}
        s.pos = {'p0':0,'p1':0,'m0':0,'m1':0,'bl':0}
        s.g0o = s.g1o = 0; s.blo = 0
        s.ln = 0; s.hc = 0; s.cx = set(); s.hmblank = False
        s.fb = [[0]*160 for _ in range(192)]
        s.falls = 0; s.snap = None

    # ---- geometry helpers ----
    def player_hits(s, pos, nusiz, grp, refl, x):
        m = nusiz & 7
        size = 2 if m == 5 else 4 if m == 7 else 1
        offs = {0:[0],1:[0,16],2:[0,32],3:[0,16,32],4:[0,64],5:[0],6:[0,32,64],7:[0]}[m]
        for o in offs:
            for i in range(8 * size):
                if (pos + o + i) % 160 == x:
                    b = i // size
                    return bool((grp >> (b if refl else 7 - b)) & 1)
        return False
    def missile_hit(s, pos, nusiz, x):
        m = nusiz & 7; width = 1 << (nusiz >> 4 & 3)
        offs = {0:[0],1:[0,16],2:[0,32],3:[0,16,32],4:[0,64],5:[0],6:[0,32,64],7:[0]}[m]
        return any((pos + o + i) % 160 == x for o in offs for i in range(width))
    def ball_hit(s, x):
        width = 1 << (s.r['CTRLPF'] >> 4 & 3)
        en = s.blo if s.r['VDELBL'] & 1 else (s.r['ENABL'] >> 1 & 1)
        return bool(en) and any((s.pos['bl'] + i) % 160 == x for i in range(width))
    def pf_hit(s, x):
        k = x // 4
        bits = [(s.r['PF0'] >> (4 + i)) & 1 for i in range(4)] + [(s.r['PF1'] >> (7 - i)) & 1 for i in range(8)] + [(s.r['PF2'] >> i) & 1 for i in range(8)]
        if k < 20: return bool(bits[k])
        return bool(bits[39 - k] if s.r['CTRLPF'] & 1 else bits[k - 20])

    def pixel(s, x):
        r = s.r
        g0 = s.g0o if r['VDELP0'] & 1 else r['GRP0']
        g1 = s.g1o if r['VDELP1'] & 1 else r['GRP1']
        p0 = s.player_hits(s.pos['p0'], r['NUSIZ0'], g0, r['REFP0'] >> 3 & 1, x)
        p1 = s.player_hits(s.pos['p1'], r['NUSIZ1'], g1, r['REFP1'] >> 3 & 1, x)
        m0 = bool(r['ENAM0'] >> 1 & 1) and not (r['RESMP0'] >> 1 & 1) and s.missile_hit(s.pos['m0'], r['NUSIZ0'], x)
        m1 = bool(r['ENAM1'] >> 1 & 1) and not (r['RESMP1'] >> 1 & 1) and s.missile_hit(s.pos['m1'], r['NUSIZ1'], x)
        bl = s.ball_hit(x); pf = s.pf_hit(x)
        score = r['CTRLPF'] >> 1 & 1
        pfcol = (r['COLUP0'] if x < 80 else r['COLUP1']) if score else r['COLUPF']
        prio = r['CTRLPF'] >> 2 & 1
        col = r['COLUBK']
        if prio:
            if pf: col = pfcol
            elif bl: col = r['COLUPF']
            elif p0 or m0: col = r['COLUP0']
            elif p1 or m1: col = r['COLUP1']
        else:
            if p0 or m0: col = r['COLUP0']
            elif p1 or m1: col = r['COLUP1']
            elif pf: col = pfcol
            elif bl: col = r['COLUPF']
        return col, dict(p0=p0, p1=p1, m0=m0, m1=m1, bl=bl, pf=pf)

    def clock(s, t):
        """evaluate colour clock t (before any write at the same time)"""
        hc = t % 228
        if hc >= 68:
            x = hc - 68
            col, o = s.pixel(x)
            for a, b, bit in [('m0','p1',0),('m0','p0',1),('m1','p0',2),('m1','p1',3),('p0','pf',4),('p0','bl',5),('p1','pf',6),('p1','bl',7),
                              ('m0','pf',8),('m0','bl',9),('m1','pf',10),('m1','bl',11),('bl','pf',12),('p0','p1',13),('m0','m1',14)]:
                if o[a] and o[b]: s.cx.add(bit)
            if 37 <= s.ln < 229:
                blank = (s.r['VBLANK'] >> 1 & 1) or (s.hmblank and x < 8)
                s.fb[s.ln - 37][x] = 0 if blank else (col >> 1)
        s.hc = hc
        if hc == 227:
            s.hmblank = False
            if s.ln != 255: s.ln += 1

    def write(s, t, reg, v):
        hc = t % 228; r = s.r
        if reg == 'VSYNC':
            if (r['VSYNC'] >> 1 & 1) and not (v >> 1 & 1): s.ln = 0; s.falls += 1; s.snap = ([row[:] for row in s.fb], set(s.cx))
            r['VSYNC'] = v; return
        def put(k): r[k] = v
        if reg in ('RESP0','RESP1'):
            k = 'p0' if reg == 'RESP0' else 'p1'
            s.pos[k] = 3 if hc < 68 or hc - 65 < 3 else (hc - 65) % 160; return
        if reg in ('RESM0','RESM1','RESBL'):
            k = {'RESM0':'m0','RESM1':'m1','RESBL':'bl'}[reg]
            s.pos[k] = 2 if hc < 68 else (hc - 66) % 160; return
        if reg == 'GRP0': s.g1o = r['GRP1']; r['GRP0'] = v; return
        if reg == 'GRP1': s.g0o = r['GRP0']; s.blo = r['ENABL'] >> 1 & 1; r['GRP1'] = v; return
        if reg in ('RESMP0','RESMP1'):
            r[reg] = v
            if v >> 1 & 1:
                k, p = ('m0','p0') if reg == 'RESMP0' else ('m1','p1')
                s.pos[k] = (s.pos[p] + 4) % 160
            return
        if reg == 'HMOVE':
            for k, h in [('p0','HMP0'),('p1','HMP1'),('m0','HMM0'),('m1','HMM1'),('bl','HMBL')]:
                s.pos[k] = (s.pos[k] - sx(r[h] >> 4)) % 160
            if hc < 68: s.hmblank = True
            return
        if reg == 'HMCLR':
            for h in ('HMP0','HMP1','HMM0','HMM1','HMBL'): r[h] = 0
            return
        if reg == 'CXCLR': s.cx = set(); return
        if reg in r: r[reg] = v

def run(writes, t_end):
    """writes: list of (t, name, value) sorted by t; returns the TIA after colour clock t_end (inclusive)"""
    s = TIA(); i = 0
    for t in range(t_end + 1):
        s.clock(t)
        while i < len(writes) and writes[i][0] == t:
            s.write(t, writes[i][1], writes[i][2]); i += 1
    return s
