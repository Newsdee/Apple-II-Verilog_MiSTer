#!/usr/bin/env python3
"""Derive the reference generator's addressing model for indexed modes.

For each opcode, group sampled tests by page-cross condition and print:
  cycle pattern, and for each read cycle which quantity it matches
  (pc+k instruction byte, mem[zp+X], mem[zp+1], ea bytes, ...).
"""
import json, os, random

REPO = r'E:/MiSTer/Apple-II_FPGAdev/65x02'

def sample(suite, op, n=50):
    d = json.load(open(os.path.join(REPO, suite, f'v1/{op:02x}.json')))
    rng = random.Random(1 * 1000 + op)
    return rng.sample(d, min(n, len(d)))

def analyze_absX(suite, op):
    """$BD LDA abs,X style: bytes b1 (lo), b2 (hi); ea = {b2,b1}+X."""
    print(f'--- {suite} {op:02x} (abs,X) ---')
    groups = {}
    for t in sample(suite, op):
        i = t['initial']
        pc = i['pc']
        ram = dict((a, v) for a, v in i['ram'])
        b1, b2 = ram.get(pc + 1), ram.get(pc + 2)
        X = i['x']
        cross = (b1 + X) >= 256
        pat = ''.join('R' if c[2] == 'read' else 'W' for c in t['cycles'])
        # which address did each cycle hit?
        desc = []
        for c in t['cycles']:
            a, v, ty = c
            if a == pc: d_ = 'op'
            elif a == pc + 1: d_ = 'b1'
            elif a == pc + 2: d_ = 'b2'
            else: d_ = f'mem[{a:04x}]={v:02x}'
            desc.append(f'{ty[0].upper()}{d_}')
        groups.setdefault((cross, pat), []).append(' '.join(desc))
    for (cross, pat), ex in sorted(groups.items()):
        print(f'  cross={int(cross)} {pat}  n={len(ex)}')
        print(f'     e.g. {ex[0]}')

def analyze_izy(suite, op):
    """$11 ORA (zp),Y style: byte b1 (zp); lo=mem[(zp+X)%256], hi=mem[zp+1]; ea+=Y."""
    print(f'--- {suite} {op:02x} ((zp),Y) ---')
    groups = {}
    for t in sample(suite, op):
        i = t['initial']
        pc = i['pc']
        ram = dict((a, v) for a, v in i['ram'])
        b1 = ram.get(pc + 1)
        X, Y = i['x'], i['y']
        lo_addr = (b1 + X) % 256
        cross = (b1 + X) >= 256
        pat = ''.join('R' if c[2] == 'read' else 'W' for c in t['cycles'])
        desc = []
        for c in t['cycles']:
            a, v, ty = c
            if a == pc: d_ = 'op'
            elif a == pc + 1: d_ = 'zp'
            elif a == pc + 2: d_ = 'b2'
            elif a == lo_addr: d_ = f'lo@{a:04x}'
            elif a == (b1 + 1) % 256: d_ = f'hi@{a:04x}'
            else: d_ = f'?[{a:04x}]={v:02x}'
            desc.append(f'{ty[0].upper()}{d_}')
        groups.setdefault((cross, pat), []).append(' '.join(desc))
    for (cross, pat), ex in sorted(groups.items()):
        print(f'  cross={int(cross)} {pat}  n={len(ex)}')
        print(f'     e.g. {ex[0]}')

for suite in ['wdc65c02', '6502']:
    analyze_absX(suite, 0xBD)     # LDA abs,X
    analyze_izy(suite, 0x11)      # ORA (zp),Y
    print()
