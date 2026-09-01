#!/usr/bin/env python3
"""Classify the GOLDEN-ONLY-FAIL opcodes:
   A = RMW protocol diff (same op; golden writes old value where WDC expects re-read)
   B = unassigned-opcode convention (golden NOP vs suite ZP-ish op)
   C = other
"""
import json, os, re, random

REPO = r'E:/MiSTer/Apple-II_FPGAdev'
RTL  = os.path.join(REPO, 'Apple-II-Verilog_MiSTer')

# --- R65Cx2 table: opcode -> (mnemonic comment, mode token) -----------------
r65 = {}
with open(os.path.join(RTL, 'rtl/R65Cx2.sv'), encoding='utf-8', errors='replace') as f:
    for line in f:
        m = re.match(r"\s*\{4'b\d+, 6'b\d+, (\w+),\s*aluIn\w+,\s*alu\w+\}, // ([0-9a-fA-F]{2}) (.*)$", line)
        if m:
            op = int(m.group(2), 16)
            r65[op] = (m.group(3).strip(), m.group(1))

# --- WDC suite sample cycles -----------------------------------------------
def suite_cycles(op):
    path = os.path.join(REPO, '65x02/wdc65c02/v1/%02x.json' % op)
    d = json.load(open(path))
    rng = random.Random(1 * 1000 + op)
    sel = rng.sample(d, 50)
    return [ (t['name'], t['cycles'], t['initial'], t['final']) for t in sel ]

GOLDEN_ONLY = """04 06 07 0c 0e 14 16 17 1c 26 27 2e 36 37 44 46 47 4e
54 56 57 66 67 6e 76 77 87 97 a7 b7 c6 c7 ce d4 d6 d7
e6 e7 ee f4 f6 f7""".split()

print(f"{'op':>3} | {'r65cx2 entry':<28} | suite cycle pattern")
for s in GOLDEN_ONLY:
    op = int(s, 16)
    mn, mode = r65.get(op, ('??', '??'))
    samples = suite_cycles(op)
    pats = {}
    for name, cyc, init, fin in samples:
        pat = ''.join('R' if c[2] == 'read' else 'W' for c in cyc)
        pats.setdefault(pat, 0)
        pats[pat] += 1
    pstr = ' '.join(f'{k}:{v}' for k, v in sorted(pats.items()))
    print(f"{s:>3} | {mn[:28]:<28} | {pstr}")
