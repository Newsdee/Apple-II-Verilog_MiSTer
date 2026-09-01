#!/usr/bin/env python3
"""3-way comparison: WDC suite vs new core (cpu_65c02.sv) vs golden R65Cx2.

Inputs (opcode-level summaries emitted by sst_driver.py):
  build/sweep_wdc.txt            new core, wdc65c02, sample=50 seed=1
  build/sweep_wdc_golden.txt     golden R65Cx2, same batch params

Output: per-opcode table + divergence categories.
"""
import re, sys, os

HERE = os.path.dirname(os.path.abspath(__file__))

def parse_summary(path):
    """Return {opcode: (passed, failed)} and total pass line."""
    ops = {}
    total = None
    cur = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = re.match(r"^=== \w+: (\d+)/(\d+) pass ===", line)
            if m:
                total = (int(m.group(1)), int(m.group(2)))
                continue
            m = re.match(r"^  ([0-9a-f]{2}): (PASS|FAIL (\d+)/(\d+))", line)
            if m:
                op = m.group(1)
                if m.group(2) == "PASS":
                    ops[op] = (50, 0)
                else:
                    ops[op] = (50 - int(m.group(3)), int(m.group(3)))
    return ops, total

new_ops, new_tot = parse_summary(os.path.join(HERE, "sweep_wdc.txt"))
gold_ops, gold_tot = parse_summary(os.path.join(HERE, "sweep_wdc_golden.txt"))

rows = []
for op in sorted(set(new_ops) | set(gold_ops)):
    n = new_ops.get(op, (0, 50))
    g = gold_ops.get(op, (0, 50))
    np_, nf = n
    gp, gf = g
    if nf == 0 and gf == 0:
        cat = "OK"
    elif nf > 0 and gf > 0 and nf == gf:
        cat = "BOTH-FAIL-same-count"
    elif nf > 0 and gf > 0:
        cat = "BOTH-FAIL-diff-count"
    elif nf > 0:
        cat = "NEW-CORE-ONLY-FAIL"
    else:
        cat = "GOLDEN-ONLY-FAIL"
    rows.append((op, np_, gp, cat))

print(f"new core : {new_tot[0]}/{new_tot[1]} pass")
print(f"golden   : {gold_tot[0]}/{gold_tot[1]} pass")
print()
hdr = f"{'op':>4} | {'new':>5} | {'golden':>6} | class"
print(hdr)
print("-" * len(hdr))
for op, np_, gp, cat in rows:
    mark = "" if cat == "OK" else "  <=="
    print(f"{op:>4} | {np_:>3}/50 | {gp:>4}/50 | {cat}{mark}")

from collections import Counter
c = Counter(r[3] for r in rows)
print()
for k, v in sorted(c.items()):
    print(f"{k}: {v} opcodes")
div = [r[0] for r in rows if r[3] != "OK"]
print()
print("diverging opcodes:", " ".join(div))
