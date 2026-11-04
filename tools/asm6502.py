#!/usr/bin/env python3
"""Tiny two-pass 6502 assembler (own implementation). Official opcodes only.
usage: asm6502.py in.s out.hex [base]   -> writes one hex byte per line for $readmemh
Syntax: labels `name:`, `.org $F000`, `.byte $41, 'A', "text"`, `.word label`, `name = $D010`, `<label`/`>label`,
immediate `#$41`, `#<label`, zero page / absolute / indexed / indirect modes. Comments start with ';'."""
import re, sys

BASE = {  # mnemonic -> {mode: opcode}
 'ADC': {'imm':0x69,'zp':0x65,'zpx':0x75,'abs':0x6D,'abx':0x7D,'aby':0x79,'inx':0x61,'iny':0x71},
 'AND': {'imm':0x29,'zp':0x25,'zpx':0x35,'abs':0x2D,'abx':0x3D,'aby':0x39,'inx':0x21,'iny':0x31},
 'ASL': {'acc':0x0A,'zp':0x06,'zpx':0x16,'abs':0x0E,'abx':0x1E},
 'BIT': {'zp':0x24,'abs':0x2C},
 'CMP': {'imm':0xC9,'zp':0xC5,'zpx':0xD5,'abs':0xCD,'abx':0xDD,'aby':0xD9,'inx':0xC1,'iny':0xD1},
 'CPX': {'imm':0xE0,'zp':0xE4,'abs':0xEC},
 'CPY': {'imm':0xC0,'zp':0xC4,'abs':0xCC},
 'DEC': {'zp':0xC6,'zpx':0xD6,'abs':0xCE,'abx':0xDE},
 'EOR': {'imm':0x49,'zp':0x45,'zpx':0x55,'abs':0x4D,'abx':0x5D,'aby':0x59,'inx':0x41,'iny':0x51},
 'INC': {'zp':0xE6,'zpx':0xF6,'abs':0xEE,'abx':0xFE},
 'JMP': {'abs':0x4C,'ind':0x6C},
 'JSR': {'abs':0x20},
 'LDA': {'imm':0xA9,'zp':0xA5,'zpx':0xB5,'abs':0xAD,'abx':0xBD,'aby':0xB9,'inx':0xA1,'iny':0xB1},
 'LDX': {'imm':0xA2,'zp':0xA6,'zpy':0xB6,'abs':0xAE,'aby':0xBE},
 'LDY': {'imm':0xA0,'zp':0xA4,'zpx':0xB4,'abs':0xAC,'abx':0xBC},
 'LSR': {'acc':0x4A,'zp':0x46,'zpx':0x56,'abs':0x4E,'abx':0x5E},
 'ORA': {'imm':0x09,'zp':0x05,'zpx':0x15,'abs':0x0D,'abx':0x1D,'aby':0x19,'inx':0x01,'iny':0x11},
 'ROL': {'acc':0x2A,'zp':0x26,'zpx':0x36,'abs':0x2E,'abx':0x3E},
 'ROR': {'acc':0x6A,'zp':0x66,'zpx':0x76,'abs':0x6E,'abx':0x7E},
 'SBC': {'imm':0xE9,'zp':0xE5,'zpx':0xF5,'abs':0xED,'abx':0xFD,'aby':0xF9,'inx':0xE1,'iny':0xF1},
 'STA': {'zp':0x85,'zpx':0x95,'abs':0x8D,'abx':0x9D,'aby':0x99,'inx':0x81,'iny':0x91},
 'STX': {'zp':0x86,'zpy':0x96,'abs':0x8E},
 'STY': {'zp':0x84,'zpx':0x94,'abs':0x8C},
}
IMPL = {'BRK':0x00,'CLC':0x18,'CLD':0xD8,'CLI':0x58,'CLV':0xB8,'DEX':0xCA,'DEY':0x88,'INX':0xE8,'INY':0xC8,'NOP':0xEA,
        'PHA':0x48,'PHP':0x08,'PLA':0x68,'PLP':0x28,'RTI':0x40,'RTS':0x60,'SEC':0x38,'SED':0xF8,'SEI':0x78,
        'TAX':0xAA,'TAY':0xA8,'TSX':0xBA,'TXA':0x8A,'TXS':0x9A,'TYA':0x98}
BR = {'BPL':0x10,'BMI':0x30,'BVC':0x50,'BVS':0x70,'BCC':0x90,'BCS':0xB0,'BNE':0xD0,'BEQ':0xF0}

def parse_num(tok, syms, pc=None, final=True):
    tok = tok.strip()
    m = re.fullmatch(r'([<>])(.+)', tok)
    if m:
        v = parse_num(m.group(2), syms, pc, final)
        return (v & 255) if m.group(1) == '<' else (v >> 8) & 255
    if tok == '*': return pc
    if tok.startswith('$'): return int(tok[1:], 16)
    if tok.startswith('%'): return int(tok[1:], 2)
    if re.fullmatch(r'\d+', tok): return int(tok)
    if re.fullmatch(r"'.'", tok): return ord(tok[1])
    m = re.fullmatch(r'(.+?)\s*([+-])\s*(\d+|\$[0-9A-Fa-f]+)', tok)
    if m: a = parse_num(m.group(1), syms, pc, final); b = parse_num(m.group(3), syms); return a + b if m.group(2) == '+' else a - b
    if tok in syms: return syms[tok]
    if final: raise SystemExit('undefined symbol: ' + tok)
    return 0

def classify(arg):
    a = arg.strip()
    if a == '' : return 'impl', ''
    if a.upper() == 'A': return 'acc', ''
    if a.startswith('#'): return 'imm', a[1:]
    m = re.fullmatch(r'\(\s*(.+?)\s*,\s*[xX]\s*\)', a)
    if m: return 'inx', m.group(1)
    m = re.fullmatch(r'\(\s*(.+?)\s*\)\s*,\s*[yY]', a)
    if m: return 'iny', m.group(1)
    m = re.fullmatch(r'\(\s*(.+?)\s*\)', a)
    if m: return 'ind', m.group(1)
    m = re.fullmatch(r'(.+?)\s*,\s*([xXyY])', a)
    if m: return ('x' if m.group(2).lower() == 'x' else 'y'), m.group(1)
    return 'mem', a

def assemble(lines):
    syms = {}
    out = {}
    for final in (False, False, False, False, True):
        pc = 0; out = {}
        for raw in lines:
            line = raw.split(';')[0].rstrip()
            if not line.strip(): continue
            m = re.match(r'\s*([A-Za-z_][\w]*)\s*=\s*(.+)$', line)
            if m: syms[m.group(1)] = parse_num(m.group(2), syms, pc, final); continue
            m = re.match(r'\s*([A-Za-z_][\w]*):(.*)$', line)
            if m: syms[m.group(1)] = pc; line = m.group(2)
            line = line.strip()
            if not line: continue
            parts = line.split(None, 1); mn = parts[0].upper(); arg = parts[1] if len(parts) > 1 else ''
            def emit(b):
                nonlocal pc
                out[pc] = b & 255; pc += 1
            if mn == '.ORG': pc = parse_num(arg, syms, pc, final); continue
            if mn == '.BYTE':
                for t in re.findall(r'"[^"]*"|[^,]+', arg):
                    t = t.strip()
                    if t.startswith('"'):
                        for ch in t[1:-1]: emit(ord(ch))
                    else: emit(parse_num(t, syms, pc, final))
                continue
            if mn == '.WORD':
                for t in arg.split(','):
                    v = parse_num(t, syms, pc, final); emit(v); emit(v >> 8)
                continue
            if mn in IMPL: emit(IMPL[mn]); continue
            if mn in BR:
                v = parse_num(arg, syms, pc, final); emit(BR[mn]); off = v - (pc + 1)
                if final and not -128 <= off <= 127: raise SystemExit('branch out of range at %04x -> %s' % (pc, arg))
                emit(off); continue
            if mn not in BASE: raise SystemExit('unknown mnemonic ' + mn)
            kind, expr = classify(arg)
            tbl = BASE[mn]
            if kind == 'acc' or (kind == 'impl' and 'acc' in tbl): emit(tbl['acc']); continue
            if kind == 'imm': emit(tbl['imm']); emit(parse_num(expr, syms, pc, final)); continue
            v = parse_num(expr, syms, pc, final) if expr else 0
            zp_known = (0 <= v < 256)
            if kind == 'mem':
                if mn in ('JMP', 'JSR') : mode = 'abs'
                else: mode = 'zp' if zp_known and 'zp' in tbl else 'abs'
            elif kind == 'x': mode = 'zpx' if zp_known and 'zpx' in tbl else 'abx'
            elif kind == 'y': mode = 'zpy' if zp_known and 'zpy' in tbl else 'aby'
            else: mode = kind
            if mode not in tbl: raise SystemExit('bad addressing mode %s for %s' % (mode, mn))
            emit(tbl[mode])
            if mode in ('zp', 'zpx', 'zpy', 'inx', 'iny'): emit(v)
            else: emit(v); emit(v >> 8)
    return out

if __name__ == '__main__':
    src = open(sys.argv[1]).read().splitlines()
    mem = assemble(src)
    base = int(sys.argv[3], 0) if len(sys.argv) > 3 else min(mem)
    top = max(mem)
    open(sys.argv[2], 'w').write('\n'.join('%02x' % mem.get(a, 0) for a in range(base, top + 1)) + '\n')
    print('%04x-%04x (%d bytes)' % (min(mem), top, len(mem)))
