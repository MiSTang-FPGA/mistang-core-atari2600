#!/usr/bin/env python3
"""Reference 6502 (one call = one instruction). Official opcodes only; every other opcode is a 1-byte NOP (same policy as the RTL)."""
class CPU:
    def __init__(s, mem):
        s.m = mem; s.A=s.X=s.Y=0; s.S=0xFD; s.N=s.V=s.Z=s.C=0; s.D=0; s.I=1
        s.PC = mem[0xFFFC] | mem[0xFFFD] << 8
    def rd(s,a): return s.m[a & 0xFFFF]
    def wr(s,a,v): s.m[a & 0xFFFF] = v & 255
    def fetch(s): v = s.rd(s.PC); s.PC = (s.PC+1) & 0xFFFF; return v
    def nz(s,v): s.N = v>>7 & 1; s.Z = int(v == 0); return v
    def P(s, b=1): return s.N<<7 | s.V<<6 | 0x20 | b<<4 | s.D<<3 | s.I<<2 | s.Z<<1 | s.C
    def setP(s,v): s.N=v>>7&1; s.V=v>>6&1; s.D=v>>3&1; s.I=v>>2&1; s.Z=v>>1&1; s.C=v&1
    def push(s,v): s.wr(0x100|s.S, v); s.S = (s.S-1) & 255
    def pull(s): s.S = (s.S+1) & 255; return s.rd(0x100|s.S)
    def ea(s, mode):
        if mode=='zp': return s.fetch()
        if mode=='zpx': return (s.fetch()+s.X) & 255
        if mode=='zpy': return (s.fetch()+s.Y) & 255
        if mode=='abs': lo=s.fetch(); return lo | s.fetch()<<8
        if mode=='abx': lo=s.fetch(); return ((lo | s.fetch()<<8)+s.X) & 0xFFFF
        if mode=='aby': lo=s.fetch(); return ((lo | s.fetch()<<8)+s.Y) & 0xFFFF
        if mode=='inx': p=(s.fetch()+s.X)&255; return s.rd(p) | s.rd((p+1)&255)<<8
        if mode=='iny': p=s.fetch(); return ((s.rd(p) | s.rd((p+1)&255)<<8)+s.Y) & 0xFFFF
    def adc(s,b):
        a=s.A; c=s.C
        t=a+b+c
        if not s.D:
            s.V = int(((~(a^b)) & (a^t) & 0x80) != 0); s.C = t>>8 & 1; s.A = s.nz(t & 255); return
        al=(a&15)+(b&15)+c
        if al>=10: al=((al+6)&15)+16
        x=(a&0xF0)+(b&0xF0)+al
        sa=((a&0xF0)-(256 if a&0x80 else 0))+((b&0xF0)-(256 if b&0x80 else 0))+al
        s.N = x>>7 & 1; s.V = int(sa<-128 or sa>127); s.Z = int((t&255)==0)
        if x>=0xA0: x+=0x60
        s.A = x & 255; s.C = int(x>=0x100)
    def sbc(s,b):
        a=s.A; c=s.C
        t=a+(b^255)+c
        s.C = t>>8 & 1; s.V = int(((a^b)&(a^t)&0x80)!=0); s.nz(t&255)
        if not s.D: s.A = t&255; return
        al=(a&15)-(b&15)+c-1
        if al<0: al=((al-6)&15)-16
        x=(a&0xF0)-(b&0xF0)+al
        if x<0: x-=0x60
        s.A = x & 255
    def cmp(s,r,v): s.C=int(r>=v); s.nz((r-v)&255)
    def step(s):
        op=s.fetch(); cc=op&3; bbb=op>>2&7; aaa=op>>5
        if op&0x1F==0x10:       # branch
            off=s.fetch(); t=[s.N,s.V,s.C,s.Z][op>>6]
            if t==(op>>5&1): s.PC=(s.PC+(off-256 if off&128 else off))&0xFFFF
            return
        if op==0x00: s.fetch(); s.push(s.PC>>8); s.push(s.PC&255); s.push(s.P(1)); s.I=1; s.PC=s.rd(0xFFFE)|s.rd(0xFFFF)<<8; return
        if op==0x20: lo=s.fetch(); s.push(s.PC>>8); s.push(s.PC&255); s.PC=lo|s.rd(s.PC)<<8; return
        if op==0x40: s.setP(s.pull()); lo=s.pull(); s.PC=lo|s.pull()<<8; return
        if op==0x60: lo=s.pull(); s.PC=((lo|s.pull()<<8)+1)&0xFFFF; return
        if op==0x08: s.push(s.P(1)); return
        if op==0x28: s.setP(s.pull()); return
        if op==0x48: s.push(s.A); return
        if op==0x68: s.A=s.nz(s.pull()); return
        if op==0x4C: lo=s.fetch(); s.PC=lo|s.fetch()<<8; return
        if op==0x6C:
            lo=s.fetch(); p=lo|s.fetch()<<8; s.PC=s.rd(p)|s.rd((p&0xFF00)|((p+1)&255))<<8; return
        imp={0x18:lambda:setattr(s,'C',0),0x38:lambda:setattr(s,'C',1),0x58:lambda:setattr(s,'I',0),0x78:lambda:setattr(s,'I',1),
             0xB8:lambda:setattr(s,'V',0),0xD8:lambda:setattr(s,'D',0),0xF8:lambda:setattr(s,'D',1)}
        if op in imp: imp[op](); return
        tr={0xAA:('X','A'),0xA8:('Y','A'),0x8A:('A','X'),0x98:('A','Y'),0xBA:('X','S')}
        if op in tr: d,sr=tr[op]; setattr(s,d,s.nz(getattr(s,sr))); return
        if op==0x9A: s.S=s.X; return
        if op==0xE8: s.X=s.nz((s.X+1)&255); return
        if op==0xC8: s.Y=s.nz((s.Y+1)&255); return
        if op==0xCA: s.X=s.nz((s.X-1)&255); return
        if op==0x88: s.Y=s.nz((s.Y-1)&255); return
        if op in (0x0A,0x2A,0x4A,0x6A):
            s.A=s.shift(aaa,s.A); return
        if cc==1:
            if op==0x89: return
            mode=['inx','zp','imm','abs','iny','zpx','aby','abx'][bbb]
            if aaa==4:
                if mode=='imm': return
                s.wr(s.ea(mode), s.A); return
            if mode=='imm': v=s.fetch()
            else: v=s.rd(s.ea(mode))
            if aaa==0: s.A=s.nz(s.A|v)
            elif aaa==1: s.A=s.nz(s.A&v)
            elif aaa==2: s.A=s.nz(s.A^v)
            elif aaa==3: s.adc(v)
            elif aaa==5: s.A=s.nz(v)
            elif aaa==6: s.cmp(s.A,v)
            else: s.sbc(v)
            return
        if cc==2:
            ok={0:(1,3,5,7),1:(1,3,5,7),2:(1,3,5,7),3:(1,3,5,7),4:(1,3,5),5:(0,1,3,5,7),6:(1,3,5,7),7:(1,3,5,7)}
            if bbb not in ok[aaa]: return
            mode={0:'imm',1:'zp',3:'abs',5:'zpx',7:'abx'}[bbb]
            if aaa in (4,5):
                if bbb==5: mode='zpy'
                if bbb==7: mode='aby'
            if mode=='imm': v=s.fetch(); s.X=s.nz(v); return
            a=s.ea(mode)
            if aaa==4: s.wr(a,s.X); return
            if aaa==5: s.X=s.nz(s.rd(a)); return
            v=s.rd(a)
            if aaa<4: v=s.shift(aaa,v)
            elif aaa==6: v=s.nz((v-1)&255)
            else: v=s.nz((v+1)&255)
            s.wr(a,v); return
        if cc==0:
            ok={1:(1,3),4:(1,3,5),5:(0,1,3,5,7),6:(0,1,3),7:(0,1,3)}
            if aaa not in ok or bbb not in ok[aaa]: return
            mode={0:'imm',1:'zp',3:'abs',5:'zpx',7:'abx'}[bbb]
            if aaa==4: s.wr(s.ea(mode),s.Y); return
            v=s.fetch() if mode=='imm' else s.rd(s.ea(mode))
            if aaa==1: s.Z=int((s.A&v)==0); s.N=v>>7&1; s.V=v>>6&1
            elif aaa==5: s.Y=s.nz(v)
            elif aaa==6: s.cmp(s.Y,v)
            else: s.cmp(s.X,v)
    def shift(s,aaa,v):
        if aaa==0: c=v>>7; v=(v<<1)&255
        elif aaa==1: c=v>>7; v=((v<<1)|s.C)&255
        elif aaa==2: c=v&1; v=v>>1
        else: c=v&1; v=(v>>1)|(s.C<<7)
        s.C=c; return s.nz(v)
