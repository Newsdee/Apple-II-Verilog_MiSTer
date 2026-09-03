#!/usr/bin/env python3
"""v2 WDC_MODE=0 (NMOS bus-convention mode) report for the MOS 6502 suite.

Regenerates build/v2nmos_report.txt entirely from the retained raw results
(sweep_6502_v2nmos_results.txt vs sweep_6502_golden_results.txt vs
sweep_6502_v2_results.txt) — no simulation. Replaces the ad-hoc heredoc
script whose traceback was captured into the old report.

Uses the current sst_driver.compare() (including the instruction-complete
check), so the numbers here agree with the regenerated sweep summaries.

Usage:
    python build/v2nmos_report.py [output.txt]
"""
import io, os, sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
MT = os.path.join(HERE, '..')
EVID = os.path.join(HERE, '..', 'evidence')   # long-generated raw results live here
sys.path.insert(0, MT)
from rebuild_summary import select_tests          # noqa: E402
from sst_driver import parse_results, compare     # noqa: E402

ROOT = r'E:\MiSTer\Apple-II_FPGAdev\65x02'
SUITE = '6502'
OPS = ['%02x' % i for i in range(256)]
SEL = select_tests(ROOT, SUITE, OPS, 50, 1)
NMOS = parse_results(os.path.join(EVID, 'sweep_6502_v2nmos_results.txt'))
GOLD = parse_results(os.path.join(EVID, 'sweep_6502_golden_results.txt'))
WDC1 = parse_results(os.path.join(EVID, 'sweep_6502_v2_results.txt'))


def fails_of(t, groups, off):
    if groups is None:
        return ['no result line']
    return compare(t, groups, off)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.join(HERE, 'v2nmos_report.txt')
    buf = io.StringIO()

    def p(*a):
        line = ' '.join(str(x) for x in a)
        print(line)
        buf.write(line + '\n')

    both_pass = both_fail = gold_only = new_only = 0
    no_ops = Counter()
    both_ops = Counter()
    new_examples = {}
    new_kind = Counter()
    for idx, (op, t) in enumerate(SEL):
        fn = fails_of(t, NMOS.get(idx), 0)
        fg = fails_of(t, GOLD.get(idx), 1)
        if not fn and not fg:
            both_pass += 1
        elif fn and fg:
            both_fail += 1
            both_ops[op] += 1
        elif fn:
            new_only += 1
            no_ops[op] += 1
            new_kind[fn[0][:6]] += 1
            if op not in new_examples:
                new_examples[op] = (idx, t['name'], fn[:2])
        else:
            gold_only += 1

    p('# v2 WDC_MODE=0 (NMOS bus-convention mode) — MOS 6502 suite report')
    p('# regenerated from retained raw results with the current sst_driver.compare()')
    p('# (includes the instruction-complete check); raw results untouched.')
    p('v2 WDC_MODE=0 vs golden (6502): both-pass=%d both-fail=%d '
      'v2nmos-only-pass=%d NEW-ONLY-FAIL(v2nmos loses)=%d'
      % (both_pass, both_fail, gold_only, new_only))
    p('  new-only-fail ops (%d): %s'
      % (len(no_ops),
         ' '.join('%s:%d' % (o, n) for o, n in sorted(no_ops.items()))))

    # ---- WDC_MODE=0 vs WDC_MODE=1 (same v2 RTL, MOS suite) -----------------
    fixed = []
    regressed = []
    for idx, (op, t) in enumerate(SEL):
        fn = fails_of(t, NMOS.get(idx), 0)
        fw = fails_of(t, WDC1.get(idx), 0)
        if fn and not fw:
            regressed.append((op, idx, t['name']))
        elif not fn and fw:
            fixed.append(op)
    c = Counter(fixed)
    p('WDC_MODE=0 vs WDC_MODE=1 (same v2 RTL, MOS suite): '
      'fixed=%d regressed=%d' % (len(fixed), len(regressed)))
    if c:
        p('  fixed ops:   ' + ' '.join(
            '%s:%d' % (o, n) for o, n in sorted(c.items(), key=lambda x: (-x[1], x[0]))))
    if regressed:
        p('  regressed:   ' + ' '.join(
            '%s[%s]' % (o, n) for o, _, n in regressed[:10]))
    else:
        p('  regressed:   none')

    # ---- new-only-fail signatures ------------------------------------------
    p()
    p('remaining new-only-fail kinds (v2nmos):')
    for kind, n in new_kind.most_common(6):
        p('    %4d  %-10s' % (n, repr(kind)))
    for op in sorted(new_examples):
        idx, name, fns = new_examples[op]
        p('  ex %s [%s]: %s' % (op, name, ' | '.join(fns)))

    with open(out, 'w', encoding='utf-8', newline='\n') as f:
        f.write(buf.getvalue())
    p()
    p('wrote', out)


if __name__ == '__main__':
    main()
