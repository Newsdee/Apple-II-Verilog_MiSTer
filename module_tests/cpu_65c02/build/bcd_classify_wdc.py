#!/usr/bin/env python3
"""Classify v2 BCD failures on the WDC sweep.

For each sampled BCD test that v2 fails, determine which category:
  XCYC-ADDR : D=1, all failures confined to the extra (last) cycle's
              addr/data -> convention mismatch (WDC records EA re-read /
              $007F constant; v2 re-reads PC+2). Final state matches.
  P-NV      : final P differs only in N/V bits (or all fails are 'final p')
  OTHER     : anything else (list the first failure strings)
Also reports how golden fares on the same tests.
"""
import sys, os
sys.path.insert(0, 'module_tests/cpu_65c02')
from sst_driver import parse_results, compare
from rebuild_summary import select_tests
from collections import Counter

ROOT = r'E:\MiSTer\Apple-II_FPGAdev\65x02'
BCD = ['61', '65', '69', '6d', '71', '75', '7d', 'e1', 'e5', 'e9', 'ed', 'f1', 'f5', 'fd']

sel = select_tests(ROOT, 'wdc65c02', ['%02x' % i for i in range(256)], 50, 1)
res_v2 = parse_results('module_tests/cpu_65c02/build/sweep_wdc_v2_results.txt')
res_g = parse_results('module_tests/cpu_65c02/build/sweep_wdc_golden_results.txt')

cats = Counter()
per_op = {}
examples = {}
gold_same = Counter()  # for v2-failing tests: does golden also fail?

for idx, (op, t) in enumerate(sel):
    if op not in BCD:
        continue
    g2 = res_v2.get(idx)
    if g2 is None:
        continue
    fails = compare(t, g2, 0)
    if not fails:
        continue
    i = t['initial']
    D = (i['p'] >> 3) & 1
    ncyc = len(t['cycles'])
    gfails = compare(t, res_g.get(idx), 0) if res_g.get(idx) else ['no golden line']
    gold_fail = bool(gfails)

    # extra-cycle-address classification: every failure must reference the
    # last cycle (cyc{ncyc-1}) and only addr/data fields; no final-state fails.
    last = 'cyc%d' % (ncyc - 1)
    if D == 1 and ncyc >= 3:
        all_last_addr_data = all(
            (f.startswith(last + ': addr') or f.startswith(last + ': data'))
            for f in fails)
        no_final = not any(f.startswith('final') for f in fails)
        if all_last_addr_data and no_final:
            cats['XCYC-ADDR'] += 1
            per_op[op] = per_op.get(op, Counter())
            per_op[op]['XCYC-ADDR'] += 1
            gold_same['XCYC-ADDR:goldfail' if gold_fail else 'XCYC-ADDR:goldpass'] += 1
            continue
    # P-only N/V
    if all(f.startswith('final p') for f in fails):
        cats['P-NV'] += 1
        per_op[op] = per_op.get(op, Counter())
        per_op[op]['P-NV'] += 1
        gold_same['P-NV:goldfail' if gold_fail else 'P-NV:goldpass'] += 1
        continue
    cats['OTHER'] += 1
    per_op[op] = per_op.get(op, Counter())
    per_op[op]['OTHER'] += 1
    gold_same['OTHER:goldfail' if gold_fail else 'OTHER:goldpass'] += 1
    key = (op, tuple(fails[:3]))
    if key not in examples:
        examples[key] = t['name']

print('total v2 BCD failures (WDC sample):', sum(cats.values()))
print('categories:', dict(cats))
print()
print('per-opcode:')
for op in BCD:
    if op in per_op:
        print('  %s: %s' % (op, dict(per_op[op])))
print()
print('golden agreement on v2 failures:', dict(gold_same))
print()
print('OTHER examples (first 12):')
n = 0
for (op, fails), name in list(examples.items()):
    if n >= 12:
        break
    print('  %s [%s]: %s' % (op, name, ' | '.join(fails)))
    n += 1
