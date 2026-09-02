#!/usr/bin/env python3
"""MOS-suite sweep analysis (step 6 of the SST plan).

Re-derives per-test verdicts for the two retained MOS raw-results files
(sweep_6502_abxfix_results.txt = new core, sweep_6502_golden_results.txt =
golden R65Cx2) using the exact sst_driver.py compare() and selection, then:

  * splits every MOS failure into FUNCTIONAL (any 'final ...' message) vs
    TIMING-ONLY (bus-trace mismatch, final state correct),
  * compares the per-opcode MOS pass counts against the retained WDC
    summaries (sweep_wdc_abxfix.txt / sweep_wdc_golden.txt),
  * reports opcodes where the new core does BETTER/WORSE on MOS than on
    WDC, and the golden-vs-new split on MOS.

Run from the Apple-II-Verilog_MiSTer repo root:
  python module_tests/cpu_65c02/build/mos_analysis.py \
      [--out module_tests/cpu_65c02/build/mos_analysis_report.txt]
"""
import argparse, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(HERE)
sys.path.insert(0, MOD)
from sst_driver import load_tests, parse_results, compare  # noqa: E402
from rebuild_summary import select_tests  # noqa: E402

ROOT = r'E:\MiSTer\Apple-II_FPGAdev\65x02'
BUILD = HERE


def parse_wdc_summary(path):
    """per-op pass count from a rebuild_summary.py-style file."""
    per = {}
    with open(path) as f:
        for line in f:
            m = re.match(r'^  ([0-9a-f]{2}): (PASS|FAIL (\d+)/(\d+))', line)
            if not m:
                continue
            op = m.group(1)
            if m.group(2) == 'PASS':
                per[op] = (50, 50)      # WDC sweep was sample=50; empty-file ops absent
            else:
                # rebuild_summary.py writes 'FAIL {fl}/{n}' where fl is the
                # FAILURE count -> passes = n - fl.
                fl, n = int(m.group(3)), int(m.group(4))
                per[op] = (n - fl, n)
    return per


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=os.path.join(BUILD, 'mos_analysis_report.txt'))
    args = ap.parse_args()

    ops = ['%02x' % i for i in range(256)]
    selected = select_tests(ROOT, '6502', ops, 50, 1)   # (op, test), idx = position
    res_new = parse_results(os.path.join(BUILD, 'sweep_6502_abxfix_results.txt'))
    res_gold = parse_results(os.path.join(BUILD, 'sweep_6502_golden_results.txt'))

    wdc_new = parse_wdc_summary(os.path.join(BUILD, 'sweep_wdc_abxfix.txt'))
    wdc_gold = parse_wdc_summary(os.path.join(BUILD, 'sweep_wdc_golden.txt'))

    per_op = {}   # op -> dict of counters for new and golden
    for idx, (op, t) in enumerate(selected):
        d = per_op.setdefault(op, {k: 0 for k in (
            'n', 'new_pass', 'new_func', 'new_time',
            'gold_pass', 'gold_func', 'gold_time')})
        d['n'] += 1

        def verdict(res, off):
            groups = res.get(idx)
            if groups is None:
                return 'missing'
            fails = compare(t, groups, off)
            if not fails:
                return 'pass'
            return 'func' if any(m.startswith('final ') for m in fails) else 'time'

        vn = verdict(res_new, 0)
        vg = verdict(res_gold, 1)
        d['new_pass'] += vn == 'pass'
        d['new_func'] += vn == 'func'
        d['new_time'] += vn == 'time'
        d['gold_pass'] += vg == 'pass'
        d['gold_func'] += vg == 'func'
        d['gold_time'] += vg == 'time'

    L = []
    L.append('CAVEAT: the functional/timing-only split below is misleading —')
    L.append('when a core takes more or fewer cycles than the suite expects, the')
    L.append('snapshot at row[ncyc] is mid-instruction and "final" mismatches are')
    L.append('artifacts. Trust the per-opcode tables and FINAL_VERDICT.md §2.')
    tot_new = sum(d['new_pass'] for d in per_op.values())
    tot_gold = sum(d['gold_pass'] for d in per_op.values())
    ntot = sum(d['n'] for d in per_op.values())
    L.append('MOS (6502) suite sweep analysis — sample=50 seed=1, 256 ops')
    L.append(f'new core : {tot_new}/{ntot} pass')
    nf = sum(d['new_func'] for d in per_op.values())
    nt = sum(d['new_time'] for d in per_op.values())
    L.append(f'  failures: {nf} functional (final state wrong) / {nt} timing-only (bus trace, final OK)')
    L.append(f'golden   : {tot_gold}/{ntot} pass')
    gf = sum(d['gold_func'] for d in per_op.values())
    gt = sum(d['gold_time'] for d in per_op.values())
    L.append(f'  failures: {gf} functional / {gt} timing-only')
    L.append('')

    L.append('per-opcode pass counts (of 50):  op   wdc_new mos_new mos_gold | delta mos-wdc(new)')
    better, worse, same = [], [], []
    for op in ops:
        d = per_op.get(op)
        if not d or d['n'] == 0:
            continue
        wn = wdc_new.get(op, (0, 50))[0]
        mn = d['new_pass']
        mg = d['gold_pass']
        delta = mn - wn
        L.append(f'  {op}   {wn:3d}     {mn:3d}     {mg:3d}      {delta:+d}')
        (better if delta > 0 else worse if delta < 0 else same).append(op)

    L.append('')
    L.append(f'new core BETTER on MOS than WDC ({len(better)} ops): ' + ' '.join(better))
    L.append('')
    L.append(f'new core WORSE on MOS than WDC ({len(worse)} ops): ' + ' '.join(worse))
    L.append('')

    # functional-fail detail: opcodes where the new core gets final state wrong
    L.append('new-core FUNCTIONAL failures on MOS (final A/P/S/PC/RAM wrong):')
    anyf = False
    for op in ops:
        d = per_op.get(op)
        if d and d['new_func']:
            anyf = True
            L.append(f'  {op}: {d["new_func"]}/50 functional (plus {d["new_time"]} timing-only, '
                     f'{d["new_pass"]} pass)')
    if not anyf:
        L.append('  none')
    L.append('')

    # golden-vs-new on MOS: where do they disagree?
    L.append('golden passes / new core fails (MOS):')
    go = [op for op in ops if op in per_op and per_op[op]['gold_pass'] > per_op[op]['new_pass']]
    L.append('  ' + (' '.join(go) if go else 'none'))
    L.append('new core passes / golden fails (MOS):')
    no = [op for op in ops if op in per_op and per_op[op]['new_pass'] > per_op[op]['gold_pass']]
    L.append('  ' + (' '.join(no) if no else 'none'))

    with open(args.out, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(L) + '\n')
    print(f'written {args.out}')
    print(f'new {tot_new}/{ntot} (func {nf}, time {nt}); golden {tot_gold}/{ntot} (func {gf}, time {gt})')


if __name__ == '__main__':
    main()
