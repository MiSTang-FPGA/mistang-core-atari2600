#!/usr/bin/env python3
"""Random TIA stress cartridge: every picture line performs a few random register writes at random cycles. usage: gen_rand.py SEED out.s"""
import random, sys
r = random.Random(int(sys.argv[1]))
regs = [4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44]
wt = {16:4,17:4,18:3,19:3,20:3,42:2,27:3,28:3}
pool = [x for x in regs for _ in range(wt.get(x,1))]
L = ['    .org $F000','start:','    SEI','    CLD','    LDX #$FF','    TXS','    LDA #0','clr:','    STA $00,X','    DEX','    BNE clr','frame:',
     '    LDA #2','    STA $02','    STA $00','    STA $02','    STA $02','    LDA #0','    STA $02','    STA $00','    LDX #30','vb:','    STA $02','    DEX','    BNE vb','    STA $02','    LDA #0','    STA $01','    STA $02']
for ln in range(192):
    for _ in range(r.randrange(1, 5)):
        for _ in range(r.randrange(0, 6)): L.append('    NOP')
        reg = r.choice(pool); v = r.randrange(256)
        if reg == 10 and r.random() < 0.7: v = v & 0x37      # keep ball sizes / flags mixed
        L += ['    LDA #$%02X' % v, '    STA $%02X' % reg]
    L.append('    STA $02')
L += ['    LDA #2','    STA $01','    LDX #28','os:','    STA $02','    DEX','    BNE os','    JMP frame','    .org $FFFC','    .word start','    .word start']
open(sys.argv[2], 'w').write('\n'.join(L) + '\n')
