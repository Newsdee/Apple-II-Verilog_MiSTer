import csv
from collections import Counter

def load(p):
    with open(p) as f:
        rows = list(csv.reader(f))
    return rows[0], rows[1:]

gh, gr = load('module_tests/r65c02/build/verilog_trace.csv')
nh, nr = load('module_tests/cpu_65c02/build/r65_trace.csv')
gi = {n: i for i, n in enumerate(gh)}
ni = {n: i for i, n in enumerate(nh)}

def fetches(rows, idx):
    return [(int(r[idx['CYCLE']]), r[idx['ADDR']], r[idx['DI']]) for r in rows if r[idx['SYNC']] == '1']

gf = fetches(gr, gi)
nf = fetches(nr, ni)
m = min(len(gf), len(nf))

# 6502 opcode -> (mnemonic, size) classic encoding (per harness %OP table)
OP = {
    0xA9:('LDA.i',1), 0xA5:('LDA.z',1), 0xB5:('LDA.zx',1), 0xAD:('LDA.a',2), 0xBD:('LDA.ax',2),
    0xB9:('LDA.ay',2), 0xA1:('LDA.ix',1), 0xB1:('LDA.iy',2),
    0xA2:('LDX.i',1), 0xA6:('LDX.z',1), 0xB6:('LDX.zy',1), 0xAE:('LDX.a',2), 0xBE:('LDX.ay',2),
    0xA0:('LDY.i',1), 0xA4:('LDY.z',1), 0xB4:('LDY.zx',1), 0xAC:('LDY.a',2), 0xBC:('LDY.ax',2),
    0x09:('ORA.i',1), 0x29:('AND.i',1), 0x49:('EOR.i',1), 0x69:('ADC.i',1), 0xE9:('SBC.i',1),
    0xC9:('CMP.i',1), 0xC5:('CMP.z',1), 0xCD:('CMP.a',2),
    0xE0:('CPX.i',1), 0xE4:('CPX.z',1), 0xEC:('CPX.a',2),
    0xC0:('CPY.i',1), 0xC4:('CPY.z',1), 0xCC:('CPY.a',2),
    0x89:('BIT.i',1), 0x24:('BIT.z',1), 0x2C:('BIT.a',2),
    0x85:('STA.z',1), 0x95:('STA.zx',1), 0x8D:('STA.a',2), 0x9D:('STA.ax',2), 0x99:('STA.ay',2),
    0x81:('STA.ix',1),
    0x86:('STX.z',1), 0x96:('STX.zy',1), 0x8E:('STX.a',2),
    0x84:('STY.z',1), 0x94:('STY.zx',1), 0x8C:('STY.a',2),
    0x64:('STZ.z',1), 0x74:('STZ.zx',1), 0x9C:('STZ.a',2), 0x9E:('STZ.ax',2),
    0x0A:('ASL.A',0), 0x06:('ASL.z',1), 0x16:('ASL.zx',1), 0x0E:('ASL.a',2), 0x1E:('ASL.ax',2),
    0x4A:('LSR.A',0), 0x46:('LSR.z',1), 0x56:('LSR.zx',1), 0x4E:('LSR.a',2), 0x5E:('LSR.ax',2),
    0x2A:('ROL.A',0), 0x26:('ROL.z',1), 0x36:('ROL.zx',1), 0x2E:('ROL.a',2), 0x3E:('ROL.ax',2),
    0x6A:('ROR.A',0), 0x66:('ROR.z',1), 0x76:('ROR.zx',1), 0x6E:('ROR.a',2), 0x7E:('ROR.ax',2),
    0x1A:('INC.A',0), 0xE6:('INC.z',1), 0xF6:('INC.zx',1), 0xEE:('INC.a',2), 0xFE:('INC.ax',2),
    0x3A:('DEC.A',0), 0xC6:('DEC.z',1), 0xD6:('DEC.zx',1), 0xCE:('DEC.a',2), 0xDE:('DEC.ax',2),
    0x04:('TSB.z',1), 0x0C:('TSB.a',2),
    0x14:('TRB.z',1), 0x1C:('TRB.a',2),
    0xF0:('BEQ',1), 0xD0:('BNE',1), 0xB0:('BCS',1), 0x90:('BCC',1), 0x30:('BMI',1),
    0x10:('BPL',1), 0x50:('BVC',1), 0x70:('BVS',1), 0x80:('BRA',1),
    0x4C:('JMP.a',2), 0x6C:('JMP.i',2), 0x7C:('JMP.ix',2), 0x20:('JSR',2), 0x60:('RTS',0),
    0x48:('PHA',0), 0x68:('PLA',0), 0x08:('PHP',0), 0x28:('PLP',0),
    0xDA:('PHX',0), 0xFA:('PLX',0), 0x5A:('PHY',0), 0x7A:('PLY',0),
    0xAA:('TAX',0), 0xA8:('TAY',0), 0x8A:('TXA',0), 0x98:('TYA',0), 0xBA:('TSX',0), 0x9A:('TXS',0),
    0xE8:('INX',0), 0xCA:('DEX',0), 0xC8:('INY',0), 0x88:('DEY',0),
    0x18:('CLC',0), 0x38:('SEC',0), 0x58:('CLI',0), 0x78:('SEI',0),
    0xB8:('CLV',0), 0xF8:('SED',0), 0xD8:('CLD',0),
    0xEA:('NOP',0),
}

diffs = Counter()
same = Counter()
examples = {}
for i in range(m - 1):
    op = int(gf[i][2], 16)
    name, size = OP.get(op, (f'op_{op:02x}', None))
    # operand bytes from trace rows following the opcode fetch
    lg = gf[i + 1][0] - gf[i][0]
    ln = nf[i + 1][0] - nf[i][0]
    key = (name, op)
    if lg != ln:
        diffs[key] += 1
        if key not in examples:
            examples[key] = (gf[i][0], gf[i][1], lg, ln)
    else:
        same[key] += 1

print('instruction classes with DIFFERING cycle counts (G vs N):')
for (name, op), cnt in sorted(diffs.items(), key=lambda kv: examples[kv[0]][0]):
    gcyc, addr, lg, ln = examples[(name, op)]
    print(f'  {name:10s} ({op:02x}): {cnt:3d}x   G={lg} N={ln}   first @cyc {gcyc} (addr {addr})')
print()
print('classes matching in cycle count:')
for (name, op), cnt in sorted(same.items()):
    length = None
    for i in range(m - 1):
        if int(gf[i][2], 16) == op:
            length = gf[i + 1][0] - gf[i][0]
            break
    print(f'  {name:10s} ({op:02x}): {cnt:3d}x   G=N len={length}')
