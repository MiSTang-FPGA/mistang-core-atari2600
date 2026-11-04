#!/usr/bin/env python3
"""Bus-cycle reference for the 6502: for one instruction returns the list of (addr, 'R'/'W', value-for-W) the real chip puts on
the bus, including dummy reads / writes. Functional behaviour comes from ref6502.CPU; the cycle sequence is built here from the
published addressing-mode timing."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ref6502

class Rec(ref6502.CPU):
    def __init__(s, mem):
        super().__init__(mem); s.w = []
    def wr(s, a, v): s.w.append((a & 0xFFFF, v & 255)); super().wr(a, v)

def classify(op):
    """-> (mode, kind) ; mode in imp imm zp zpx zpy abs abx aby inx iny rel ; kind in none read write rmw"""
    cc, bbb, aaa = op & 3, op >> 2 & 7, op >> 5
    if op & 0x1F == 0x10: return 'rel', 'none'
    if op == 0x4C: return 'jmpabs', 'none'
    if op == 0x6C: return 'jmpind', 'none'
    if op in (0x00, 0x20, 0x40, 0x60, 0x08, 0x28, 0x48, 0x68): return {0x00:'brk',0x20:'jsr',0x40:'rti',0x60:'rts',0x08:'php',0x28:'plp',0x48:'pha',0x68:'pla'}[op], 'none'
    if cc == 1:
        if op == 0x89: return 'imp', 'none'
        return ['inx','zp','imm','abs','iny','zpx','aby','abx'][bbb], ('write' if aaa == 4 else 'read')
    if cc == 2:
        ok = {0:(1,3,5,7),1:(1,3,5,7),2:(1,3,5,7),3:(1,3,5,7),4:(1,3,5),5:(0,1,3,5,7),6:(1,3,5,7),7:(1,3,5,7)}
        if op in (0x0A,0x2A,0x4A,0x6A) or bbb not in ok[aaa]: return 'imp', 'none'
        mode = {0:'imm',1:'zp',3:'abs',5:'zpx',7:'abx'}[bbb]
        if aaa in (4,5):
            if bbb == 5: mode = 'zpy'
            if bbb == 7: mode = 'aby'
        return mode, ('write' if aaa == 4 else 'read' if aaa == 5 else 'rmw')
    if cc == 0:
        ok = {1:(1,3),4:(1,3,5),5:(0,1,3,5,7),6:(0,1,3),7:(0,1,3)}
        if aaa not in ok or bbb not in ok[aaa]: return 'imp', 'none'
        mode = {0:'imm',1:'zp',3:'abs',5:'zpx',7:'abx'}[bbb]
        return mode, ('write' if aaa == 4 else 'read')
    return 'imp', 'none'

def step_trace(c):
    """Run one instruction on Rec `c`; return the expected cycle list."""
    m = c.m; pc = c.PC; op = m[pc]
    b1 = m[(pc+1)&0xFFFF]; b2 = m[(pc+2)&0xFFFF]
    X, Y, S = c.X, c.Y, c.S
    pre = bytes(m) if False else None
    mode, kind = classify(op)
    cyc = [(pc, 'R', None)]
    def R(a): cyc.append((a & 0xFFFF, 'R', None))
    def W(a, v=None): cyc.append((a & 0xFFFF, 'W', v))
    old = lambda a: m[a & 0xFFFF]
    c.w = []
    if mode == 'rel':
        take = [c.N,c.V,c.C,c.Z][op>>6] == (op>>5 & 1)
        R(pc+1)
        if take:
            tgt = (pc + 2 + (b1 - 256 if b1 & 128 else b1)) & 0xFFFF
            R(pc+2)
            if (tgt ^ (pc+2)) & 0xFF00: R(((pc+2) & 0xFF00) | (tgt & 0xFF))
    elif mode == 'brk': R(pc+1); W(0x100|S); W(0x100|((S-1)&255)); W(0x100|((S-2)&255)); R(0xFFFE); R(0xFFFF)
    elif mode == 'jsr': R(pc+1); R(0x100|S); W(0x100|S); W(0x100|((S-1)&255)); R(pc+2)
    elif mode == 'rti': R(pc+1); R(0x100|S); R(0x100|((S+1)&255)); R(0x100|((S+2)&255)); R(0x100|((S+3)&255))
    elif mode == 'rts': R(pc+1); R(0x100|S); R(0x100|((S+1)&255)); R(0x100|((S+2)&255)); R(m[0x100|((S+1)&255)] | m[0x100|((S+2)&255)] << 8)
    elif mode in ('php','pha'): R(pc+1); W(0x100|S)
    elif mode in ('plp','pla'): R(pc+1); R(0x100|S); R(0x100|((S+1)&255))
    elif mode == 'jmpabs': R(pc+1); R(pc+2)
    elif mode == 'jmpind':
        p = b1 | b2 << 8; R(pc+1); R(pc+2); R(p); R((p & 0xFF00) | ((p+1) & 255))
    elif mode == 'imp': R(pc+1)
    elif mode == 'imm': R(pc+1)
    else:
        if mode == 'zp': R(pc+1); ea = b1
        elif mode in ('zpx','zpy'): R(pc+1); R(b1); ea = (b1 + (X if mode == 'zpx' else Y)) & 255
        elif mode == 'abs': R(pc+1); R(pc+2); ea = b1 | b2 << 8
        elif mode in ('abx','aby'):
            R(pc+1); R(pc+2); base = b1 | b2 << 8; ea = (base + (X if mode == 'abx' else Y)) & 0xFFFF
            wrong = (base & 0xFF00) | (ea & 0xFF)
            if kind == 'read':
                if wrong != ea: R(wrong)
            else: R(wrong)
        elif mode == 'inx':
            R(pc+1); R(b1); p = (b1 + X) & 255; R(p); R((p+1)&255); ea = m[p] | m[(p+1)&255] << 8
        elif mode == 'iny':
            R(pc+1); R(b1); R((b1+1)&255); base = m[b1] | m[(b1+1)&255] << 8; ea = (base + Y) & 0xFFFF
            wrong = (base & 0xFF00) | (ea & 0xFF)
            if kind == 'read':
                if wrong != ea: R(wrong)
            else: R(wrong)
        if kind == 'read': R(ea)
        elif kind == 'write': W(ea)
        else: R(ea); W(ea, old(ea)); W(ea)
    # real functional execution (state + memory)
    c.step()
    # fill unknown write values from what the functional model wrote
    ws = list(c.w); out = []
    for (a, k, v) in cyc:
        if k == 'W' and v is None:
            # find matching write by address in order
            i = next(i for i, (wa, _) in enumerate(ws) if wa == a); v = ws.pop(i)[1]
        elif k == 'W':
            ws_i = next((i for i, (wa, _) in enumerate(ws) if wa == a), None)
        out.append((a, k, v))
    return out
