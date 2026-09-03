#!/usr/bin/env python3
"""Decompose the 6502-suite BOTH-FAIL set (v2 WDC_MODE=0 vs golden R65Cx2).

both-fail = tests where both cores fail the suite expectation. Question:
is it (a) broken suite references (no core could pass), (b) 65C02-vs-MOS
decode divergences (expected in a 65C02 core), or (c) genuine shared
defects worth chasing?

Classifies by opcode, cross-references the 64 known broken-reference files
(FINAL_VERDICT.md §2.4) and the xF-column / JAM quirk ops, and samples
failure signatures for everything else.

Usage:  python mos_bothfail_decomp.py
Output: stdout + build/mos_bothfail_report.txt
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..'))
from sst_driver import parse_results, compare      # noqa: E402
from rebuild_summary import select_tests           # noqa: E402

ROOT = r'E:\MiSTer\Apple-II_FPGAdev\65x02'
B = HERE
EVID = os.path.join(HERE, '..', 'evidence')   # long-generated raw results live here
OPS = ['%02x' % i for i in range(256)]
SUITE = '6502'

BROKEN64 = set('02 03 07 0b 12 13 14 17 1a 1b 1c 22 23 27 2b 32 33 37 3a 3b '
               '42 43 47 4b 52 53 57 5b 62 63 64 67 6b 73 74 77 7b 83 87 8b '
               '92 93 97 9b 9c 9e a3 a7 ab b2 b3 b7 bb c3 c7 d2 d3 d7 e3 '
               'e7 eb f3 f7 fb'.split())
XF = set('%02x' % i for i in range(0xA0, 0xC0))
JAM = {'72', 'f2'}


def main():
    sel = select_tests(ROOT, SUITE, OPS, 50, 1)
    res_n = parse_results(os.path.join(EVID, 'sweep_6502_v2nmos_results.txt'))
    res_g = parse_results(os.path.join(EVID, 'sweep_6502_golden_results.txt'))

    out = []
    def p(s=''):
        out.append(s)
        print(s)

    # sanity: verify totals against headers (8273 / 7869)
    npass = gpass = 0
    both_fail_by_op = {}
    new_only_by_op = {}
    sigs = {}
    for idx, (op, t) in enumerate(sel):
        rn, rg = res_n.get(idx), res_g.get(idx)
        fn = compare(t, rn, 0) if rn else ['no line']
        fg = compare(t, rg, 1) if rg else ['no line']
        if not fn:
            npass += 1
        if not fg:
            gpass += 1
        if fn and fg:
            both_fail_by_op.setdefault(op, []).append((idx, fn))
        elif fn and not fg:
            new_only_by_op.setdefault(op, []).append((idx, fn))

    p('sanity: v2nmos pass=%d (header 8273)  golden pass=%d (header 7869)'
      % (npass, gpass))
    total_bf = sum(len(v) for v in both_fail_by_op.values())
    p('total both-fail = %d across %d opcodes' %
      (total_bf, len(both_fail_by_op)))
    p()

    # classification
    broken = sum(len(v) for op, v in both_fail_by_op.items()
                 if op in BROKEN64)
    xfnobrok = sum(len(v) for op, v in both_fail_by_op.items()
                   if op in XF and op not in BROKEN64)
    jam = sum(len(v) for op, v in both_fail_by_op.items() if op in JAM)
    rest = {op: v for op, v in both_fail_by_op.items()
            if op not in BROKEN64 and op not in XF and op not in JAM}
    rest_n = sum(len(v) for v in rest.values())
    p('classification:')
    p('  64 broken-reference files:     %5d  (%d ops)' %
      (broken, sum(1 for op in both_fail_by_op if op in BROKEN64)))
    p('  xF column (A0-BF, 65C02 BBR/BBS vs MOS undefined): %5d  (%d ops)' %
      (xfnobrok, sum(1 for op in both_fail_by_op if op in XF and op not in BROKEN64)))
    p('  JAM (72/f2):                    %5d' % jam)
    p('  everything else:                %5d  (%d ops)' % (rest_n, len(rest)))
    p()
    p('per-opcode both-fail (op: n/50, class):')
    for op in sorted(both_fail_by_op, key=lambda o: (-len(both_fail_by_op[o]), o)):
        v = both_fail_by_op[op]
        cls = ('broken-ref' if op in BROKEN64 else
               'xF' if op in XF else 'JAM' if op in JAM else 'OTHER')
        p('  %s: %2d  %s' % (op, len(v), cls))
    p()
    p('sampled failure signatures for OTHER ops (both cores fail the same way?):')
    for op in sorted(rest, key=lambda o: (-len(rest[o]), o)):
        for idx, fn in rest[op][:2]:
            p('  %s idx %04X: %s' % (op, idx, '; '.join(fn[:4])))
    p()
    # new-only-fail per op for context (should be just 7c:20)
    p('new-only-fail by op (v2nmos):')
    for op, v in sorted(new_only_by_op.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        p('  %s: %d   e.g. %s' % (op, len(v), '; '.join(v[0][1][:3])))

    with open(os.path.join(B, 'mos_bothfail_report.txt'), 'w',
              encoding='utf-8') as f:
        f.write('\n'.join(out) + '\n')


if __name__ == '__main__':
    main()
