#!/usr/bin/env python3
"""Show per-cycle traces for given test indices from new-core and golden
result files, side by side (decoded)."""
import re, sys, os

HERE = os.path.dirname(os.path.abspath(__file__))
NEW = os.path.join(HERE, "sweep_wdc_results.txt")
GOLD = os.path.join(HERE, "sweep_wdc_golden_results.txt")

def load(path):
    """Parse result lines the same way sst_driver.py does: bus token and its
    register snapshot are space-separated, but the snapshot runs directly
    into the NEXT bus token."""
    W = 16
    d = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if not line.startswith("R "):
                continue
            parts = line.split()
            if len(parts) != 2 + W + 1:
                continue
            idx = int(parts[1])
            regs = [None] * W
            for c in range(1, W):
                regs[c - 1] = parts[2 + c][:14]
            regs[W - 1] = parts[2 + W - 1]
            bus = [parts[2]] + [parts[2 + c][-7:] for c in range(1, W)]
            d[idx] = list(zip(bus, regs))
    return d

new = load(NEW)
gold = load(GOLD)

def dec(b, r):
    if not b: return " " * 46
    m = re.match(r"^([0-9a-f]{4})([RW])([0-9a-f]{2})$", b)
    bus = f"{m.group(1)} {m.group(2)} {m.group(3)}" if m else b[:12]
    reg = ""
    if r and len(r) >= 14:
        reg = f"pc={r[0:4]} s={r[4:6]} a={r[6:8]} x={r[8:10]} y={r[10:12]} p={r[12:14]}"
    return f"{bus:<12} {reg}"

def show(idx, label="", nrows=16):
    nt, gt = new.get(idx), gold.get(idx)
    print(f"--- test #{idx} {label} ---")
    for c in range(nrows):
        nb = nt[c] if nt and c < len(nt) else ("", "")
        gb = gt[c] if gt and c < len(gt) else ("", "")
        print(f"c{c:<3} NEW : {dec(*nb)}")
        print(f"      GOLD: {dec(*gb)}")
    print()

for a in sys.argv[1:]:
    show(int(a, 0))
