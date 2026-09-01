#!/usr/bin/env python3
"""Verify: for indexed opcodes, do cores pass exactly the no-page-cross tests?

For each candidate opcode, sample the WDC suite (same seed as the sweep),
split tests by page-cross condition(s), and compare per-group pass/fail
against the new-core sweep results.
"""
import json, os, random, sys

REPO = r'E:/MiSTer/Apple-II_FPGAdev/65x02'
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from sst_driver import load_tests, parse_results, compare

newr = parse_results(os.path.join(HERE, 'sweep_wdc_results.txt'))
goldr = parse_results(os.path.join(HERE, 'sweep_wdc_golden_results.txt'))

# wdc65c02 ships empty cb.json (WAI) and db.json (STP); verified empirically
# against both sweep result files:
#   00..ca: base = op*50      cc..da: base = op*50 - 50
#   dc..ff: base = op*50 - 100

def batch_base(op):
    if 0xcb < op < 0xdb:
        return op * 50 - 50
    if op >= 0xdc:
        return op * 50 - 100
    return op * 50

def sample(op):
    d = load_tests(REPO, 'wdc65c02', '%02x' % op)
    rng = random.Random(1 * 1000 + op)
    return rng.sample(d, min(50, len(d)))

ABSX = {0x1D, 0x3D, 0x5D, 0x7D, 0xBD, 0xBC}
ABSY = {0x19, 0x39, 0x59, 0x79, 0xB9, 0xD9, 0xF9, 0xBE}
IZX  = {0x91, 0xB1, 0xD1, 0xF1}
IZY  = {0x11, 0x31, 0x51, 0x71, 0xDE}

def groups_for(op, t):
    """Return subgroup key(s) for a test."""
    i = t['initial']
    pc = i['pc']
    ram = dict((a, v) for a, v in i['ram'])
    X, Y = i['x'], i['y']
    if op in ABSX:
        b1, b2 = ram[pc + 1], ram[pc + 2]
        return ('absX', 'cross' if b1 + X >= 256 else 'nocross')
    if op in ABSY:
        b1, b2 = ram[pc + 1], ram[pc + 2]
        ea = (b2 << 8) | b1
        return ('absY', 'cross' if (ea & 0xFF) + Y >= 256 else 'nocross')
    if op in IZX:
        zp = ram[pc + 1]
        return ('izx', 'cross' if zp + X >= 256 else 'nocross')
    if op in IZY:
        zp = ram[pc + 1]
        lo = (zp + X) % 256
        cross = zp + X >= 256
        hi = ram.get(zp + 1, 0)
        ea = (hi << 8) | lo
        ycross = (ea & 0xFF) + Y >= 256
        return ('izy', 'Ycross' if ycross else 'noYcross',
                'zpXcross' if cross else 'nozpXcross')
    return ('?', 'unknown')

CANDIDATES = sorted(ABSX | ABSY | IZX | IZY)

print(f"{'op':>4} | {'group':<28} | {'n':>3} | {'new pass':>8} | {'gold pass':>9}")
print('-' * 66)
for op in CANDIDATES:
    sel = sample(op)
    base = batch_base(op)
    agg = {}
    for i, t in enumerate(sel):
        key = groups_for(op, t)
        fn = compare(t, newr.get(base + i), 0)
        fg = compare(t, goldr.get(base + i), 1)
        a = agg.setdefault(key, [0, 0, 0])
        a[0] += 1
        if not fn: a[1] += 1
        if not fg: a[2] += 1
    for key, (n, pn, pg) in sorted(agg.items()):
        print(f"{op:02x}   | {str(key):<28} | {n:>3} | {pn:>4}/{n:<3} | {pg:>4}/{n:<3}")
