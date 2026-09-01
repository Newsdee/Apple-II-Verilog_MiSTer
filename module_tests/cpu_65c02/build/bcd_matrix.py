#!/usr/bin/env python3
"""BCD (D=1) per-mode matrix: WDC suite expectation vs golden vs new core.

For each ADC/SBC opcode, picks one D=1 test from the seed=1/sample=50 sweep
sample and prints the expected bus sequence (suite) against the observed
bus sequences of both cores (from the persistent sweep result files).
"""
import json, os, random, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from sst_driver import load_tests, parse_results, REPO_DEFAULT

newr = parse_results(os.path.join(HERE, 'sweep_wdc_results.txt'))
goldr = parse_results(os.path.join(HERE, 'sweep_wdc_golden_results.txt'))

def batch_base(op):
    if 0xcb < op < 0xdb:
        return op * 50 - 50
    if op >= 0xdc:
        return op * 50 - 100
    return op * 50

ADC = [0x61, 0x65, 0x69, 0x6D, 0x71, 0x72, 0x75, 0x79, 0x7D]
SBC = [0xE1, 0xE5, 0xE9, 0xED, 0xF1, 0xF2, 0xF5, 0xF9, 0xFD]

def bus_seq(groups, n):
    if groups is None:
        return ['<missing>'] * n
    out = []
    for c in range(min(n, len(groups))):
        bus, _ = groups[c]
        out.append(f'{bus[0:4]}{bus[4]}')
    return out

def main():
    fams = [('ADC', ADC), ('SBC', SBC)]
    for fam, ops in fams:
        print(f'===== {fam} =====')
        print(f"{'op':>4} | {'suite (D=1 expected)':<44} | {'golden obs':<44} | {'new-core obs':<44}")
        print('-' * 140)
        for op in ops:
            sel = []
            d = load_tests(REPO_DEFAULT, 'wdc65c02', '%02x' % op)
            rng = random.Random(1 * 1000 + op)
            sel = rng.sample(d, min(50, len(d)))
            base = batch_base(op)
            t = next((t for t in sel if t['initial']['p'] & 8), None)
            if t is None:
                print(f'{op:02x}   | (no D=1 test in sample)')
                continue
            i = sel.index(t)
            ncyc = len(t['cycles'])
            exp = [f'{c[0]:04X}{c[2][0].upper()}' for c in t['cycles']]
            gn = bus_seq(goldr.get(base + i), ncyc + 1)
            nn = bus_seq(newr.get(base + i), ncyc + 1)
            # mark the final-fetch row (beyond ncyc) distinctly
            def fmt(seq):
                s = ' '.join(seq[:ncyc])
                if len(seq) > ncyc:
                    s += f' [+{seq[ncyc]}]'
                return s
            print(f'{op:02x}   | {fmt(exp):<44} | {fmt(gn):<44} | {fmt(nn):<44}')

if __name__ == '__main__':
    main()
