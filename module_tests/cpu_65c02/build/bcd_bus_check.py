#!/usr/bin/env python3
"""Break down the new-core BCD bus-trace failures on MOS: which opcodes,
are they all page-cross tests, and does golden pass them?"""
import sys, os
sys.path.insert(0, 'module_tests/cpu_65c02')
from sst_driver import parse_results, compare
from rebuild_summary import select_tests
from collections import Counter

ROOT = r'E:\MiSTer\Apple-II_FPGAdev\65x02'
BCD = ['61', '65', '69', '6d', '71', '75', '7d', 'e1', 'e5', 'e9', 'ed', 'f1', 'f5', 'fd']

sel = select_tests(ROOT, '6502', ['%02x' % i for i in range(256)], 50, 1)
res_n = parse_results('module_tests/cpu_65c02/build/sweep_6502_abxfix_results.txt')
res_g = parse_results('module_tests/cpu_65c02/build/sweep_6502_golden_results.txt')


def fields_of(fails):
    f = set()
    for m in fails:
        if m.startswith('final '):
            f.add(m.split()[1])
        elif m.startswith('cyc'):
            f.add('bus')
    return f


def crosses_page(op, t):
    """True if the test's addressing causes a page-crossing dummy cycle."""
    i = t['initial']
    ram = dict(i['ram'])
    pc, x, y = i['pc'], i['x'], i['y']

    def R(a):
        return ram.get(a)

    lo = R(pc + 1)
    hi = R(pc + 2)
    if op in ('69', 'e9', '65', 'e5'):
        return False
    if op in ('7d', 'fd'):                      # (abs,X)
        return (lo + x) >= 256
    if op in ('75', 'f5'):                      # (zp,X): no abs page cross
        return False
    if op in ('61', 'e1'):                      # (zp),Y
        ptr = R(lo) | ((R((lo + 1) & 0xFF) or 0) << 8)
        return (ptr & 0xFF) + y >= 256
    if op in ('71', 'f1'):                      # (abs),Y
        base = (hi << 8) | lo
        ptr = R(base) | ((R(base + 1) or 0) << 8)
        return (ptr & 0xFF) + y >= 256
    if op in ('6d', 'ed'):                      # abs: no page cross on 6502
        return False
    return None


by_op = Counter()
cross = Counter()
gold_pass = Counter()
noncross = []
for idx, (op, t) in enumerate(sel):
    if op not in BCD:
        continue
    fails = compare(t, res_n.get(idx), 0)
    if not fails or 'bus' not in fields_of(fails):
        continue
    by_op[op] += 1
    c = crosses_page(op, t)
    cross[op + ('_cross' if c else '_flat')] += 1
    gfails = compare(t, res_g.get(idx), 1)
    gold_pass[op + ('_goldPASS' if not gfails else '_goldFAIL')] += 1
    if c is False:
        noncross.append((op, t['name']))

print('bus-mismatch BCD failures by opcode:', dict(by_op))
print('page-cross split (op_cross / op_flat):')
for k in sorted(cross):
    print('   %s: %d' % (k, cross[k]))
print('golden outcome split:')
for k in sorted(gold_pass):
    print('   %s: %d' % (k, gold_pass[k]))
print('non-cross bus failures (should be ~0 if all are Category C):', noncross)
