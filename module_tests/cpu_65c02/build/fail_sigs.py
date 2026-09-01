#!/usr/bin/env python3
"""Verify classification of golden-only-fail + analyze BOTH-FAIL opcodes.

For each opcode, collect the distinct failure messages from the new-core and
golden sweep summaries, and sample one raw trace row pair to confirm the
mechanism.
"""
import os, re

HERE = os.path.dirname(os.path.abspath(__file__))

def load_summary(path):
    """op -> list of (test_idx, [msgs])"""
    out = {}
    cur = None
    with open(path, encoding='utf-8', errors='replace') as f:
        lines = f.readlines()
    i = 0
    while i < len(lines):
        m = re.match(r"^  ([0-9a-f]{2}): (PASS|FAIL)", lines[i])
        if m and m.group(2) == 'FAIL':
            op = m.group(1)
            cur = []
            out[op] = cur
            i += 1
            while i < len(lines):
                l = lines[i].rstrip('\n')
                mm = re.match(r"^    #(\d+) \[(.*)\]$", l)
                if mm:
                    idx = int(mm.group(1))
                    msgs = []
                    i += 1
                    while i < len(lines) and lines[i].startswith('      '):
                        msgs.append(lines[i].strip())
                        i += 1
                    cur.append((idx, msgs))
                    continue
                break
        else:
            cur = None
            i += 1
    return out

def load_results(path):
    d = {}
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            if not line.startswith('R '):
                continue
            parts = line.split()
            if len(parts) != 18:
                continue
            idx = int(parts[1])
            bus = [parts[2]] + [parts[2+c][-7:] for c in range(1, 16)]
            regs = [None]*16
            for c in range(1, 16):
                regs[c-1] = parts[2+c][:14]
            regs[15] = parts[17]
            d[idx] = list(zip(bus, regs))
    return d

new_sum = load_summary(os.path.join(HERE, 'sweep_wdc.txt'))
gold_sum = load_summary(os.path.join(HERE, 'sweep_wdc_golden.txt'))
new_res = load_results(os.path.join(HERE, 'sweep_wdc_results.txt'))
gold_res = load_results(os.path.join(HERE, 'sweep_wdc_golden_results.txt'))

def msgsig(msgs):
    # signature: first mismatch kind only (drop addresses/data)
    sigs = set()
    for m in msgs:
        mm = re.match(r"^(cyc\d+: )(\w+)(.*)$", m)
        if mm:
            sigs.add(mm.group(2))
        else:
            sigs.add(m.split(' !=')[0])
    return sorted(sigs)

print("=== GOLDEN-ONLY-FAIL verification (golden failure signatures) ===")
gold_only = [op for op in gold_sum if op not in new_sum]
for op in sorted(gold_only):
    sigs = set()
    for idx, msgs in gold_sum[op]:
        sigs.add(tuple(msgsig(msgs)))
    print(f"  {op}: {[' '.join(s) for s in sorted(sigs)]}")

print()
print("=== BOTH-FAIL: new-core failure signatures per opcode ===")
both = [op for op in gold_sum if op in new_sum]
for op in sorted(both):
    nsigs = set()
    for idx, msgs in new_sum[op]:
        nsigs.add(tuple(msgsig(msgs)))
    gsigs = set()
    for idx, msgs in gold_sum[op]:
        gsigs.add(tuple(msgsig(msgs)))
    print(f"  {op}: NEW {[' '.join(s) for s in sorted(nsigs)]} | GOLD {[' '.join(s) for s in sorted(gsigs)]}")
