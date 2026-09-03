#!/usr/bin/env python3
"""v2 campaign: per-opcode comparison of v1 / v2 / golden across the four
suites (wdc65c02, 6502, rockwell65c02, synertek65c02).

Inputs: build/sweep_<suite>_<core>.txt per-opcode summaries — derived on
demand from the raw results in evidence/ (auto-regenerated here if missing;
takes several minutes of wall time).
Outputs a ranked delta table and per-group rollups.
"""
import os, sys

B = 'module_tests/cpu_65c02/build'

FILES = {
    ('wdc65c02', 'v1'):      B + '/sweep_wdc_abxfix.txt',
    ('wdc65c02', 'v2'):      B + '/sweep_wdc_v2.txt',
    ('wdc65c02', 'gold'):    B + '/sweep_wdc_golden.txt',
    ('6502', 'v1'):          B + '/sweep_6502_abxfix.txt',
    ('6502', 'v2'):          B + '/sweep_6502_v2.txt',
    ('6502', 'gold'):        B + '/sweep_6502_golden.txt',
    ('rockwell65c02', 'v1'): B + '/sweep_rockwell_v1.txt',
    ('rockwell65c02', 'v2'): B + '/sweep_rockwell_v2.txt',
    ('rockwell65c02', 'gold'): B + '/sweep_rockwell_golden.txt',
    ('synertek65c02', 'v1'): B + '/sweep_synertek_v1.txt',
    ('synertek65c02', 'v2'): B + '/sweep_synertek_v2.txt',
    ('synertek65c02', 'gold'): B + '/sweep_synertek_golden.txt',
}


def parse(path):
    out = {}
    for line in open(path):
        line = line.strip()
        if not line or ':' not in line:
            continue
        op, rest = line.split(':', 1)
        op, rest = op.strip(), rest.strip()
        if rest == 'PASS':
            out[op] = (50, 50)
        elif rest.startswith('FAIL'):
            fl, n = rest.split()[1].split('/')
            out[op] = (int(n) - int(fl), int(n))
    return out


data = {}
_missing = [k for k, p in FILES.items() if not os.path.exists(p)]
if _missing:
    import subprocess
    print('regenerating %d missing summary file(s) from evidence/ (~15 min)...'
          % len(_missing))
    subprocess.check_call([r'C:\msys64\ucrt64\bin\python',
                           os.path.join(B, 'regen_all_summaries.py'),
                           '--apply'])
for k, p in FILES.items():
    data[k] = parse(p)

SUITES = ['wdc65c02', '6502', 'rockwell65c02', 'synertek65c02']
CORES = ['v1', 'v2', 'gold']

# ---- totals -----------------------------------------------------------------
print('=== suite totals (passes) ===')
print('%-15s %8s %8s %8s' % ('suite', 'v1', 'v2', 'gold'))
for s in SUITES:
    row = []
    for c in CORES:
        t = sum(v[0] for v in data[(s, c)].values())
        n = sum(v[1] for v in data[(s, c)].values())
        row.append('%d/%d' % (t, n))
    print('%-15s %8s %8s %8s' % (s, *row))

# ---- per-opcode deltas -------------------------------------------------------
def deltas(suite, a, b):
    """op -> passes_b - passes_a"""
    d = {}
    for op in data[(suite, a)]:
        if op in data[(suite, b)]:
            d[op] = data[(suite, b)][op][0] - data[(suite, a)][op][0]
    return d


for suite in SUITES:
    d21 = deltas(suite, 'v1', 'v2')
    up = sorted([(op, v) for op, v in d21.items() if v > 0], key=lambda x: (-x[1], x[0]))
    dn = sorted([(op, v) for op, v in d21.items() if v < 0], key=lambda x: (x[1], x[0]))
    print('\n=== %s: v2 vs v1 ===  improved: %d ops (+%d), regressed: %d ops (%d)' %
          (suite, len(up), sum(v for _, v in up), len(dn), sum(v for _, v in dn)))
    if up:
        print('  +: ' + ' '.join('%s%+d' % (op, v) for op, v in up))
    if dn:
        print('  -: ' + ' '.join('%s%+d' % (op, v) for op, v in dn))

# ---- groups of interest ------------------------------------------------------
GROUPS = {
    'BCD':      ['61', '65', '69', '6d', '71', '75', '7d', 'e1', 'e5', 'e9', 'ed', 'f1', 'f5', 'fd'],
    'RMW zp':   ['06', '16', '26', '36', 'c6', 'e6'],
    'RMW abs':  ['0e', '1e', '2e', '3e', 'ce', 'ee'],
    'RMW zpx':  ['f6', '76', 'd6', '56'],
    'RMW abx':  ['fe', '7e', 'de', '5e'],
    'NOP44':    ['44', '54', 'd4', 'f4'],
    'NOP x3':   ['03', '13', '23', '33', '43', '53', '63', '73', '83', '93', 'a3', 'b3', 'c3', 'd3', 'e3', 'f3'],
    'NOP xB':   ['0b', '1b', '2b', '3b', '4b', '5b', '6b', '7b', '8b', '9b', 'ab', 'bb', 'cb', 'db', 'eb', 'fb'],
    'pagecross': ['1d', '3d', '5d', 'bc', 'bd', 'dd', '9d', 'fd', '3c', '7d', '7c', '6c'],
    'jmpind':   ['34', 'fc'],
    'bbrbbs':   ['a0', 'a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7',
                 'b0', 'b1', 'b2', 'b3', 'b4', 'b5', 'b6', 'b7'],
    'NOP a8bf': ['a8', 'a9', 'aa', 'ab', 'ac', 'ad', 'ae', 'af',
                 'b8', 'b9', 'ba', 'bb', 'bc', 'bd', 'be', 'bf'],
    'undoc 4x/6x': ['46', '4e', '66', '6e', '5a', '7a', 'da', 'fa'],
}

print('\n=== group rollups: passes (v1 / v2 / gold) per suite ===')
for gname, ops in GROUPS.items():
    line = '%-12s' % gname
    for s in SUITES:
        cells = []
        for c in CORES:
            t = sum(data[(s, c)].get(op, (0, 0))[0] for op in ops)
            n = len(ops) * 50
            cells.append('%d/%d' % (t, n))
        line += ' | %-24s' % (' '.join(cells))
    print(line)
