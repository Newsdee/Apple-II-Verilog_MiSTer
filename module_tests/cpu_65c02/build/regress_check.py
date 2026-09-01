#!/usr/bin/env python3
"""Per-test regression gate: pre-Option-C sweep vs post-Option-C sweep.

Both inputs are raw sst_results.txt-format files (one line per test:
`R <idx> <bus tokens...>`), generated with the same deterministic batch
(ops=all, sample=50, seed=1) so idx aligns 1:1.

Exit code 0 = no regression (no previously-passing test now fails).
"""
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..'))
from sst_driver import load_tests, parse_results, compare  # noqa: E402

ROOT = r'E:\MiSTer\Apple-II_FPGAdev\65x02'
SUITE = 'wdc65c02'
PRE = os.path.join(HERE, 'sweep_wdc_nobcdfix_results.txt')   # baseline (pre Option C)
POST = os.path.join(HERE, 'sweep_wdc_abxfix_results.txt')    # Option C build

def main():
    pre = parse_results(PRE)
    post = parse_results(POST)

    # regenerate the identical deterministic selection
    selected = []
    for op in ('%02x' % i for i in range(256)):
        try:
            tests = load_tests(ROOT, SUITE, op)
        except FileNotFoundError:
            continue
        rng = random.Random(1 * 1000 + int(op, 16))
        selected.extend((op, t) for t in rng.sample(tests, min(50, len(tests))))

    assert len(selected) == len(pre) == len(post) == 12700, \
        (len(selected), len(pre), len(post))

    regressions = []
    improvements = []
    per_op = {}   # op -> [pre_pass, post_pass]
    for idx, (op, t) in enumerate(selected):
        p_ok = not compare(t, pre.get(idx), 0)
        q_ok = not compare(t, post.get(idx), 0)
        e = per_op.setdefault(op, [0, 0])
        e[0] += p_ok
        e[1] += q_ok
        if p_ok and not q_ok:
            regressions.append((idx, op, t))
        if q_ok and not p_ok:
            improvements.append((op, t['name']))

    pre_pass = sum(v[0] for v in per_op.values())
    post_pass = sum(v[1] for v in per_op.values())
    print(f'pre  pass: {pre_pass}/12700')
    print(f'post pass: {post_pass}/12700')
    print(f'improvements (fail->pass): {len(improvements)}')
    print(f'REGRESSIONS (pass->fail):  {len(regressions)}')

    # per-opcode deltas, only changed opcodes
    changed = [(op, v[0], v[1]) for op, v in sorted(per_op.items()) if v[0] != v[1]]
    print('\nopcode: pre -> post (changed only)')
    for op, a, b in changed:
        print(f'  {op}: {a}/50 -> {b}/50')

    # improvement breakdown by opcode
    if improvements:
        import collections
        c = collections.Counter(op for op, _ in improvements)
        print('\nimprovements by opcode:')
        for op, n in sorted(c.items()):
            print(f'  {op}: +{n}')

    if regressions:
        print('\nregression detail (first 20):')
        for idx, op, t in regressions[:20]:
            fails = compare(t, post.get(idx), 0)
            print(f'  #{idx} [{op} {t["name"]}]')
            for m in fails[:6]:
                print(f'    {m}')

    sys.exit(1 if regressions else 0)

if __name__ == '__main__':
    main()
