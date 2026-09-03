#!/usr/bin/env python3
"""Analyze op 7c on the 6502 MOS suite for v2 WDC_MODE=0.

Established context (verified 2026-09-03):
  * WDC 65C02 suite models $7C as JMP (abs,X): 6-cycle model
    [fetch, lo, hi, re-read pc+1, EA-lo, EA+1-hi], final pc = jump target.
    v2 passes 50/50 there; v1 and golden R65Cx2 fail 50/50.
  * R65Cx2 (golden) also decodes 7C as JMP (abs,X)  (R65Cx2.sv:421).
  * v1 and v2 cores decode 7C as C_JMP/M_IAX unconditionally (WDC_MODE
    does not gate the decode) — cpu_65c02.sv line 312 (v2) / 307 (v1).
  * MOS 6502 suite models $7C as the 3-byte UNDEFINED opcode:
    4-cycle model [fetch, lo, hi, dummy read at EA], final pc = pc+3,
    A/P/S unchanged.

So the 20 v2nmos new-only-fail 7c tests are a DECODE/SEMANTICS mismatch
(core does JMP (abs,X); MOS reference does a 3-byte undefined op), NOT a
page-cross dummy convention issue. This script quantifies:

  1. which of the 50 sampled tests fail for v2nmos / v1 / golden;
  2. the MOS suite model shape across the 50 (4 cyc? state unchanged?);
  3. the suite's internal consistency (final state == initial with pc+3;
     trace data == ram);
  4. for the failing tests: first diverging cycle, expected vs actual addr,
     and what golden actually does on the same tests.

Usage:  python analyze_7c_nmos.py
Output: stdout + build/analyze_7c_nmos_report.txt
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


def trace_addrs(groups, n):
    out = []
    for c in range(min(n, len(groups))):
        bus = groups[c][0]
        out.append((int(bus[0:4], 16), bus[4], int(bus[5:7], 16)))
    return out


def main():
    sel = select_tests(ROOT, SUITE, OPS, 50, 1)
    sel7c = [(idx, t) for idx, (op, t) in enumerate(sel) if op == '7c']
    res_v2n = parse_results(os.path.join(EVID, 'sweep_6502_v2nmos_results.txt'))
    res_v1 = parse_results(os.path.join(EVID, 'sweep_6502_abxfix_results.txt'))
    res_g = parse_results(os.path.join(EVID, 'sweep_6502_golden_results.txt'))

    out = []
    def p(s=''):
        out.append(s)
        print(s)

    rows = []
    for idx, t in sel7c:
        rn, rv, rg = res_v2n.get(idx), res_v1.get(idx), res_g.get(idx)
        fn = compare(t, rn, 0) if rn else ['no line']
        fv = compare(t, rv, 0) if rv else ['no line']
        fg = compare(t, rg, 1) if rg else ['no line']
        i, f = t['initial'], t['final']
        pc = i['pc']
        ram = {a: v for a, v in i['ram']}
        m = ((ram.get(pc + 2, 0) << 8) | ram.get(pc + 1, 0))
        ea = (m + i['x']) & 0xFFFF
        cross = ((m & 0xFF) + i['x'] > 0xFF)
        # MOS-suite model checks
        ncyc = len(t['cycles'])
        exp = [(a, v, rw) for a, v, rw in t['cycles']]
        dataok = all(ram.get(a) == v for a, v, _ in exp)
        state_unchanged = (f['a'] == i['a'] and f['p'] == i['p']
                           and f['s'] == i['s'] and f['x'] == i['x']
                           and f['y'] == i['y'])
        pc3 = (f['pc'] == pc + 3)
        exp_last = exp[-1][0] if exp else None
        rows.append(dict(idx=idx, name=t['name'], pc=pc, x=i['x'], m=m,
                         ea=ea, cross=cross, ncyc=ncyc,
                         fn=fn, fv=fv, fg=fg, dataok=dataok,
                         state_unchanged=state_unchanged, pc3=pc3,
                         exp_last=exp_last))

    no_fail = [r for r in rows if r['fn'] and not r['fg']]
    go_fail = [r for r in rows if r['fg'] and not r['fn']]
    both_fail = [r for r in rows if r['fn'] and r['fg']]
    both_pass = [r for r in rows if not r['fn'] and not r['fg']]
    p('7c on 6502 (sampled 50): both-pass=%d both-fail=%d '
      'golden-only-fail=%d new-only-fail(v2nmos)=%d' %
      (len(both_pass), len(both_fail), len(go_fail), len(no_fail)))
    p()
    p('MOS suite model shape across the 50:')
    p('  ncyc distribution:        %s' %
      sorted(((r['ncyc'], sum(1 for x in rows if x['ncyc'] == r['ncyc']))
              for r in rows)))
    p('  trace data matches ram:   %d/50' % sum(1 for r in rows if r['dataok']))
    p('  final state unchanged:    %d/50' %
      sum(1 for r in rows if r['state_unchanged']))
    p('  final pc == pc+3:         %d/50' % sum(1 for r in rows if r['pc3']))
    p()
    p('per-test table (new-only-fail first, then go/both/both-pass):')
    p('idx  cross  v1 v2n gold  data stateU pc3 | fails (v2nmos)')
    for r in sorted(no_fail + go_fail + both_fail + both_pass,
                    key=lambda r: (r in both_pass, r in both_fail,
                                   r in go_fail, r['idx'])):
        v1 = 'P' if not r['fv'] else 'F'
        v2 = 'P' if not r['fn'] else 'F'
        g = 'P' if not r['fg'] else 'F'
        fails = r['fn'] if r['fn'] else r['fg']
        p('%04x  %s      %s   %s    %s   %d    %d     %d | %s' %
          (r['idx'], 'X' if r['cross'] else '-', v1, v2, g,
           r['dataok'], r['state_unchanged'], r['pc3'],
           '; '.join(fails[:4]) if fails else '-'))
    p()
    for r in no_fail[:4]:
        idx = r['idx']
        t = dict(sel7c)[idx]
        i = t['initial']
        p('--- detail %s (idx %04X):' % (t['name'], idx))
        p('    init pc=%04X x=%02X abs=%04X ea=%04X cross=%s ncyc=%d' %
          (i['pc'], i['x'], r['m'], r['ea'], r['cross'], r['ncyc']))
        p('    suite expected: ' +
          ' '.join('%04X/%s' % (a, 'W' if rw == 'write' else 'R')
                  for a, v, rw in t['cycles']))
        for label, res, off in (('v2nmos', res_v2n, 0), ('v1', res_v1, 0),
                                ('golden', res_g, 1)):
            gr = res.get(idx)
            if gr:
                tr = trace_addrs(gr, len(t['cycles']) + 3)
                p('    %-8s actual:   ' % label +
                  ' '.join('%04X%s/%02X' % (a, rw, d) for a, rw, d in tr))
                # register snapshot at the compared final row
                regrow = min(len(t['cycles']) + off, len(gr) - 1)
                p('    %-8s final row[%d]: %s' %
                  (label, regrow, gr[regrow][1]))
        p()

    with open(os.path.join(B, 'analyze_7c_nmos_report.txt'), 'w',
              encoding='utf-8') as f:
        f.write('\n'.join(out) + '\n')


if __name__ == '__main__':
    main()
