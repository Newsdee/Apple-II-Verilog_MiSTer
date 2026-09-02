#!/usr/bin/env python3
"""Rebuild the per-opcode PASS/FAIL summary from a retained raw results file.

The sweep driver (sst_driver.py) prints its per-opcode summary to stdout only;
the persistent artifacts are the raw `R ...` result lines. This tool
re-derives the summary without re-running the simulation by reconstructing the
exact same test selection the driver used (deterministic: suite root, seed,
per-op sample) and re-comparing each retained trace against the suite JSON.

Selection algorithm (must match sst_driver.py main()):
  for op in 00..ff (all 256):
      tests = <suite>/v1/<op>.json   ([] if missing/empty)
      rng = random.Random(seed*1000 + int(op,16))
      selected.extend(rng.sample(tests, min(sample, len(tests))))
Batch index = position in that flattened list.

Usage (from the Apple-II-Verilog_MiSTer repo root):
  python module_tests/cpu_65c02/rebuild_summary.py \
      --results module_tests/cpu_65c02/build/sweep_wdc_abxfix_results.txt \
      --suite wdc65c02 --sample 50 --seed 1 \
      --out module_tests/cpu_65c02/build/sweep_wdc_abxfix.txt \
      [--final-offset 0] [--root E:/MiSTer/Apple-II_FPGAdev/65x02]

Exit 0 on success. The summary format matches sst_driver.py stdout so the two
are interchangeable for downstream tools (fail_sigs.py).
"""
import argparse, json, os, random, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from sst_driver import load_tests, parse_results, compare  # noqa: E402


def select_tests(root, suite, ops, sample, seed):
    selected = []   # (op, test), batch index = position
    for op in ops:
        tests = load_tests(root, suite, op)
        rng = random.Random(seed * 1000 + int(op, 16))
        sel = rng.sample(tests, min(sample, len(tests)))
        selected.extend((op, t) for t in sel)
    return selected


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--results', required=True, help='raw R-line results file')
    ap.add_argument('--suite', default='wdc65c02')
    ap.add_argument('--ops', default='all')
    ap.add_argument('--sample', type=int, default=50)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--root', default=r'E:\MiSTer\Apple-II_FPGAdev\65x02')
    ap.add_argument('--final-offset', type=int, default=0)
    ap.add_argument('--max-fail-detail', type=int, default=3)
    ap.add_argument('--out', required=True)
    args = ap.parse_args()

    ops = ['%02x' % i for i in range(256)] if args.ops == 'all' else \
          [o.strip().lower() for o in args.ops.split(',')]

    selected = select_tests(args.root, args.suite, ops, args.sample, args.seed)
    res = parse_results(args.results)
    missing = [i for i, _ in enumerate(selected) if i not in res]
    if missing:
        print(f'!! {len(missing)} selected tests have no result line '
              f'(first idx {missing[0]}); results file may not match these '
              f'selection parameters', file=sys.stderr)

    total = passed = 0
    per_op = {}
    for idx, (op, t) in enumerate(selected):
        total += 1
        groups = res.get(idx)
        if groups is None:
            per_op.setdefault(op, [0, 0, []])[2].append((idx, ['no result line']))
            continue
        fails = compare(t, groups, args.final_offset)
        entry = per_op.setdefault(op, [0, 0, []])
        if fails:
            entry[1] += 1
            if len(entry[2]) < args.max_fail_detail:
                entry[2].append((idx, fails[:8]))
        else:
            entry[0] += 1
            passed += 1

    lines = [f'batch: {total} tests (reconstructed; see rebuild_summary.py)',
             f'results parsed: {len(res)}', '',
             f'=== {args.suite}: {passed}/{total} pass ===']
    for op in ops:
        if op not in per_op:
            continue
        p, fl, details = per_op[op]
        n = p + fl
        tag = 'PASS' if fl == 0 else f'FAIL {fl}/{n}'
        lines.append(f'  {op}: {tag}')
        for idx, fails in details:
            t = selected[idx][1]
            lines.append(f'    #{idx} [{t["name"]}]')
            for msg in fails:
                lines.append(f'      {msg}')

    with open(args.out, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines) + '\n')
    print(f'=== {args.suite}: {passed}/{total} pass === (written to {args.out})')


if __name__ == '__main__':
    main()
