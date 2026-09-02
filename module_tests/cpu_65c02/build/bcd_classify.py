#!/usr/bin/env python3
"""Classify new-core BCD failures on the MOS sweep (verification for
FINAL_VERDICT.md section 2.3). Uses GLOBAL selection indices (full 256-op
selection) to index the retained raw results files."""
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


_MISSING = object()


def operand_value(op, t):
    """M (the BCD data operand) computed from initial state + addressing mode.
    Returns _MISSING if any required byte is absent from initial.ram."""
    i = t['initial']
    ram = dict(i['ram'])

    def R(a):
        return ram.get(a, _MISSING)

    pc, x, y = i['pc'], i['x'], i['y']
    lo = R(pc + 1)
    hi = R(pc + 2)
    if op in ('69', 'e9'):                      # immediate
        return lo
    if lo is _MISSING:
        return _MISSING
    if op in ('65', 'e5'):                      # zp
        return R(lo)
    if hi is _MISSING:
        return _MISSING
    if op in ('6d', 'ed'):                      # abs
        return R((hi << 8) | lo)
    if op in ('75', 'f5'):                      # (zp,X)
        return R((lo + x) & 0xFF)
    if op in ('7d', 'fd'):                      # (abs,X) with page wrap
        eano = (hi << 8) | lo
        ea = eano + x + (0 if (lo + x) < 256 else -256)
        return R(ea)
    if op in ('61', 'e1'):                      # (zp),Y
        plo, phi = R(lo), R((lo + 1) & 0xFF)
        if plo is _MISSING or phi is _MISSING:
            return _MISSING
        ptr = plo | (phi << 8)
        ea = ptr + y + (0 if (ptr & 0xFF) + y < 256 else -256)
        return R(ea)
    if op in ('71', 'f1'):                      # (abs),Y
        base = (hi << 8) | lo
        plo, phi = R(base), R(base + 1)
        if plo is _MISSING or phi is _MISSING:
            return _MISSING
        ptr = plo | (phi << 8)
        ea = ptr + y + (0 if (ptr & 0xFF) + y < 256 else -256)
        return R(ea)
    return None


def fields_of(fails):
    f = set()
    for m in fails:
        if m.startswith('final '):
            f.add(m.split()[1])
        elif m.startswith('cyc'):
            f.add('bus')
    return f


cls = Counter()
ponly_bad_digit = 0
ponly_good_digit_examples = []
awrong_shared = 0
awrong_shared_ops = Counter()
awrong_newonly = []
other = []
tot = 0

for idx, (op, t) in enumerate(sel):
    if op not in BCD:
        continue
    fails = compare(t, res_n.get(idx), 0)
    if not fails:
        continue
    tot += 1
    f = fields_of(fails)
    if f == {'p'}:
        cls['P-only (A correct)'] += 1
        a = t['initial']['a']
        # M = operand value: last expected read data (EA read for memory
        # modes, immediate byte for imm mode); skip the opcode fetch.
        m = operand_value(op, t)   # M: the BCD memory/immediate operand
        bad_a = any(((a >> n) & 15) > 9 for n in (0, 4))
        if m is _MISSING or m is None:
            cls['P-only, M unknown'] += 1
            bad_m = False
        else:
            bad_m = any(((m >> n) & 15) > 9 for n in (0, 4))
        if bad_a or bad_m:
            ponly_bad_digit += 1
        elif len(ponly_good_digit_examples) < 8:
            ponly_good_digit_examples.append((op, t['name'], a, m))
    elif 'a' in f:
        gfails = compare(t, res_g.get(idx), 1)
        if gfails:
            cls['A-wrong, golden fails too'] += 1
            awrong_shared += 1
            awrong_shared_ops[op] += 1
        else:
            cls['A-wrong, golden PASSES'] += 1
            awrong_newonly.append((op, t['name']))
    elif 'bus' in f:
        cls['bus-trace mismatch involved'] += 1
        gfails = compare(t, res_g.get(idx), 1)
        if len(other) < 12:
            other.append((op, t['name'], sorted(f), 'golden:' + ('fail' if gfails else 'PASS')))
    else:
        cls[str(sorted(f))] += 1

print('total new-core BCD failures (MOS sample):', tot)
for k, v in cls.most_common():
    print('  %s: %d' % (k, v))
print('P-only with invalid BCD digit in A:', ponly_bad_digit)
print('P-only with VALID A digits (examples op,name,A):')
for e in ponly_good_digit_examples:
    print('   ', e)
print('A-wrong shared per-op:', dict(awrong_shared_ops))
print('A-wrong new-core-only:', awrong_newonly[:10])
print('bus-mismatch examples (op,name,fields,golden):')
for e in other:
    print('   ', e)
