#!/usr/bin/env python3
"""Four-way reference comparison for every divergent opcode:

  WDC suite pattern   (wdc65c02/v1/*.json)  -- what the suite expects
  6502 suite pattern  (6502/v1/*.json)      -- original MOS behavior reference
  new-core observed   (sweep_wdc_results.txt, rows 0..ncyc-1 of WDC test)
  golden observed     (sweep_wdc_golden_results.txt, same rows)

Pattern = per-cycle R/W string, e.g. 'RRRRW'. ncyc taken from the WDC suite
test's cycle list (the window the driver checks).
"""
import json, os, random, re
from collections import Counter

REPO = r'E:/MiSTer/Apple-II_FPGAdev'
HERE = os.path.dirname(os.path.abspath(__file__))

def suite_samples(suite, op):
    path = os.path.join(REPO, f'65x02/{suite}/v1/{op:02x}.json')
    if not os.path.exists(path):
        return None
    d = json.load(open(path))
    rng = random.Random(1 * 1000 + op)
    return rng.sample(d, min(50, len(d)))

def patterns_of(sel):
    pats = Counter()
    for t in sel:
        pats[''.join('R' if c[2] == 'read' else 'W' for c in t['cycles'])] += 1
    return pats

def load_results(path):
    """Line layout: 'R idx' bus0 (regs0+bus1) (regs1+bus2) ... (regs14+bus15) regs15
    -> 19 tokens; token k>=3 fuses the previous register run with bus k."""
    d = {}
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            if not line.startswith('R '):
                continue
            parts = line.split()
            if len(parts) != 19:
                continue
            idx = int(parts[1])
            bus = [parts[2]] + [parts[2+c][-7:] for c in range(1, 16)]
            d[idx] = bus
    return d

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

def core_patterns(results, op, wdc_sel):
    """R/W string over rows 0..ncyc-1 (the driver's check window)."""
    base = batch_base(op)
    pats = Counter()
    for i, t in enumerate(wdc_sel):
        bus = results.get(base + i)
        if not bus:
            continue
        ncyc = len(t['cycles'])
        s = ''.join('W' if bus[c][4] == 'W' else 'R' for c in range(min(ncyc, 16)))
        pats[s] += 1
    return pats

def top(pats):
    if not pats:
        return 'n/a'
    items = pats.most_common()
    s = f'{items[0][0]}:{items[0][1]}'
    if len(items) > 1:
        s += f' +{len(items)-1}'
    return s

div = []
with open(os.path.join(HERE, 'three_way_report.txt'), encoding='utf-8') as f:
    for line in f:
        m = re.match(r"^\s*([0-9a-f]{2})\s*\|", line)
        if m and '<==' in line:
            div.append(int(m.group(1), 16))

new_res = load_results(os.path.join(HERE, 'sweep_wdc_results.txt'))
gold_res = load_results(os.path.join(HERE, 'sweep_wdc_golden_results.txt'))

print(f"{'op':>3} | {'WDC suite':<12} | {'6502 suite':<12} | {'new obs':<12} | {'golden obs':<12} | WDC-vs-6502")
print('-' * 84)
n_div = 0
for op in div:
    ws = suite_samples('wdc65c02', op)
    ms = suite_samples('6502', op)
    wp, mp = patterns_of(ws), (patterns_of(ms) if ms else Counter())
    wtop = wp.most_common(1)[0][0] if wp else None
    mtop = mp.most_common(1)[0][0] if mp else None
    agree = 'same' if wtop == mtop else 'DIFF'
    if wtop != mtop:
        n_div += 1
    print(f"{op:02x} | {top(wp):<12} | {top(mp):<12} | "
          f"{top(core_patterns(new_res, op, ws)):<12} | "
          f"{top(core_patterns(gold_res, op, ws)):<12} | {agree}")

print()
print(f"opcodes where WDC suite diverges from 6502 suite: {n_div}/{len(div)}")
