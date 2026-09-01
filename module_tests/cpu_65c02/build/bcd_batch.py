#!/usr/bin/env python3
"""Build a targeted batch of D=1 (BCD) tests for the BCD root-cause work.

One test per opcode, all with the D flag set in the initial P byte.
Test idx 0 is the WDC 69 test from sst_progress.md (pc=6204, 69 90,
s=9E a=6B x=87 y=41 p=68) when present, else the first D=1 test.
"""
import json, os, sys

ROOT = r'E:\MiSTer\Apple-II_FPGAdev\65x02'
SUITE = 'wdc65c02'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'bcd_batch.txt')

OPS = ['69', 'e9', 'b6', '7d', 'de']

def load(op):
    with open(os.path.join(ROOT, SUITE, 'v1', f'{op}.json')) as f:
        return json.load(f)

picked = []   # (op, test)
for op in OPS:
    tests = [t for t in load(op) if t['initial']['p'] & 0x08]
    if not tests:
        print(f'!! no D=1 test for {op}'); continue
    if op == '69':
        hit = [t for t in tests if t['initial']['pc'] == 0x6204]
        t = hit[0] if hit else tests[0]
    else:
        t = tests[0]
    picked.append((op, t))

with open(OUT, 'w', newline='\n') as f:
    for idx, (op, t) in enumerate(picked):
        ram = t['initial']['ram']
        i = t['initial']
        patch = ''.join(f'{a:04X}{v:02X}' for a, v in ram)
        f.write(f"{idx:08d} {i['pc']:04X} {i['s']:02X} {i['a']:02X} "
                f"{i['x']:02X} {i['y']:02X} {i['p']:02X} "
                f"{len(t['cycles']):3d} {len(ram):3d} {patch}\n")
        print(f"idx {idx}: op={op} name={t['name']} pc={i['pc']:04X} "
              f"s={i['s']:02X} a={i['a']:02X} x={i['x']:02X} y={i['y']:02X} "
              f"p={i['p']:02X} ncyc={len(t['cycles'])} npatch={len(ram)}")

print(f'batch -> {OUT}')
