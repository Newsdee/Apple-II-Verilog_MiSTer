#!/usr/bin/env python3
"""v2 campaign: reconcile the four-way split (both-pass / both-fail /
golden-only-fail / new-only-fail) for v1 and v2 vs golden, per suite.

Crash-point issue (session 01a0601c): three throwaway scripts reported three
different MOS new-only-fail totals for v2 (782, 4530, 1987). Root cause under
investigation: the final_offset argument of sst_driver.compare() (register
snapshot offset; golden commits A/X/Y/S/P one cycle later) was used
inconsistently (0 vs 1). This script:

  1. auto-verifies the golden final_offset per suite by matching the
     gold-pass total against the retained per-opcode summary headers, and
  2. recomputes the full four-way split for v1 and v2 with the verified offset.

Inputs (all retained under build/):
  sweep_<suite>_<core>_results.txt   raw R-lines
  sweep_<suite>_<core>.txt           per-opcode summaries (headers hold totals)

Usage:  python v2_reconcile.py   (from Apple-II-Verilog_MiSTer/)
Output: stdout + build/v2_reconcile_report.txt
"""
import os, re, sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from sst_driver import parse_results, compare          # noqa: E402
from rebuild_summary import select_tests               # noqa: E402

ROOT = r'E:\MiSTer\Apple-II_FPGAdev\65x02'
B = os.path.join(os.path.dirname(__file__))
EVID = os.path.join(B, '..', 'evidence')   # long-generated raw results live here
OPS = ['%02x' % i for i in range(256)]

# (suite, v1 file, v2 file, golden file, summary header total 'pass/total')
SUITES = [
    ('wdc65c02',      'sweep_wdc_abxfix_results.txt',      'sweep_wdc_v2_results.txt',      'sweep_wdc_golden_results.txt',      (8093, 12700)),
    ('6502',          'sweep_6502_abxfix_results.txt',     'sweep_6502_v2_results.txt',     'sweep_6502_golden_results.txt',     (7869, 12800)),
    ('rockwell65c02', 'sweep_rockwell_v1_results.txt',     'sweep_rockwell_v2_results.txt', 'sweep_rockwell_golden_results.txt', (8132, 12800)),
    ('synertek65c02', 'sweep_synertek_v1_results.txt',     'sweep_synertek_v2_results.txt', 'sweep_synertek_golden_results.txt', (8125, 12800)),
]


def four_way(sel, res_new, res_g, goff):
    both_p = both_f = gold_only = new_only = 0
    new_only_ops = {}
    for idx, (op, t) in enumerate(sel):
        rn, rg = res_new.get(idx), res_g.get(idx)
        fn = compare(t, rn, 0) if rn else ['no line']
        fg = compare(t, rg, goff) if rg else ['no line']
        if fn and not fg:
            new_only += 1
            new_only_ops[op] = new_only_ops.get(op, 0) + 1
        elif fg and not fn:
            gold_only += 1
        elif fn and fg:
            both_f += 1
        else:
            both_p += 1
    return both_p, both_f, gold_only, new_only, new_only_ops


def main():
    out = []
    def p(s=''):
        out.append(s)
        print(s)

    for suite, v1f, v2f, gf, (hdr_pass, hdr_total) in SUITES:
        sel = select_tests(ROOT, suite, OPS, 50, 1)
        res_v1 = parse_results(os.path.join(EVID, v1f))
        res_v2 = parse_results(os.path.join(EVID, v2f))
        res_g = parse_results(os.path.join(EVID, gf))
        p('=== %s: sel=%d v1lines=%d v2lines=%d goldlines=%d (header %d/%d)' %
          (suite, len(sel), len(res_v1), len(res_v2), len(res_g), hdr_pass, hdr_total))

        # 1. verify golden offset against the summary header
        verified = None
        for goff in (0, 1):
            gp = 0
            for idx, (op, t) in enumerate(sel):
                rg = res_g.get(idx)
                if rg is not None and not compare(t, rg, goff):
                    gp += 1
            tag = '  <-- MATCHES header' if gp == hdr_pass else ''
            p('   golden pass total with final_offset=%d: %d%s' % (goff, gp, tag))
            if gp == hdr_pass:
                verified = goff
        if verified is None:
            p('   !! NO OFFSET REPRODUCES HEADER; using 1')
            verified = 1
        p('   verified golden final_offset = %d' % verified)

        # 2. four-way splits with verified offset
        for label, res in (('v1', res_v1), ('v2', res_v2)):
            bp, bf, go, no, ops = four_way(sel, res, res_g, verified)
            p('   %s: both-pass=%d both-fail=%d golden-only-fail=%d NEW-ONLY-FAIL=%d (ops=%d)' %
              (label, bp, bf, go, no, len(ops)))
            if no and suite == '6502':
                top = sorted(ops.items(), key=lambda kv: (-kv[1], kv[0]))[:12]
                p('      top ops: ' + ' '.join('%s:%d' % kv for kv in top))
        p()

    with open(os.path.join(B, 'v2_reconcile_report.txt'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(out) + '\n')


if __name__ == '__main__':
    main()
