#!/usr/bin/env python3
"""Cross-design trace analysis for the cpu_65c02 divergence test.

Part 1 (r65 pair): prove/disprove pure pipeline phase offset by comparing
event-aligned sequences (opcode fetches) and shifted bus/register sequences
instead of row-aligned fields.
Part 2 (t65 pairs): find the first REAL execution divergence by
cross-correlating register-state sequences over small shifts.

Shift convention: k = number of cycles the GOLDEN trace lags the new trace,
i.e. compare golden[i+k] with new[i] for k>0 (golden's cycle i+k content
appears in the new trace at cycle i).
"""
import os

REPO = r"E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer"

def load(path):
    with open(os.path.join(REPO, path), "r") as f:
        lines = [l.strip() for l in f if l.strip()]
    return lines[0].split(","), [l.split(",") for l in lines[1:]]

def shifted_diff(g, n, k):
    """Mismatch count comparing golden[i+k] vs new[i] (k>0) or
    golden[i] vs new[i-j] (k<0, j=-k). Returns (mismatches, compared)."""
    if k >= 0:
        cnt = min(len(n), len(g) - k)
        if cnt <= 0:
            return 0, 0
        return sum(1 for i in range(cnt) if g[i + k] != n[i]), cnt
    j = -k
    cnt = min(len(g), len(n) - j)
    if cnt <= 0:
        return 0, 0
    return sum(1 for i in range(cnt) if g[i] != n[i + j]), cnt

# ---------------------------------------------------------------- part 1
gH, gR = load("module_tests/r65c02/build/verilog_trace.csv")
nH, nR = load("module_tests/cpu_65c02/build/r65_trace.csv")
ci = {name: i for i, name in enumerate(gH)}

print("=== PART 1: r65c02 stimulus — event-aligned comparison ===")

# (a) opcode fetch events: SYNC=1 and SYNC_IRQ=0 -> (opcode, fetch addr)
def fetch_events(rows):
    return [(r[ci["DI"]].upper(), r[ci["ADDR"]].upper()) for r in rows
            if r[ci["SYNC"]] == "1" and r[ci["SYNC_IRQ"]] == "0"]

gf, nf = fetch_events(gR), fetch_events(nR)
print(f"opcode-fetch events: golden={len(gf)} new={len(nf)}")
mism = [(i, a, b) for i, (a, b) in enumerate(zip(gf, nf)) if a != b]
if len(gf) != len(nf):
    print(f"COUNT DIFFERS: golden={len(gf)} new={len(nf)}")
if mism:
    print(f"fetch-sequence mismatches: {len(mism)}; first 8:")
    for i, a, b in mism[:8]:
        print(f"  event {i}: golden op={a[0]} @ {a[1]} | new op={b[0]} @ {b[1]}")
else:
    print("FETCH SEQUENCE IDENTICAL (every opcode at every fetch address matches)")

# (b) bus transaction sequences, row-aligned and shifted
gb = [tuple(r[ci[c]] for c in ("ADDR", "RW", "DO")) for r in gR]
nb = [tuple(r[ci[c]] for c in ("ADDR", "RW", "DO")) for r in nR]
print("bus (ADDR,RW,DO) by shift:")
for k in (-2, -1, 0, 1, 2):
    d, c = shifted_diff(gb, nb, k)
    print(f"  k={k:+d}: {d}/{c} rows differ")

# (c) register-state sequences, shifted
gr_ = [tuple(r[ci[c]] for c in ("PC", "SP", "A", "X", "Y")) for r in gR]
nr_ = [tuple(r[ci[c]] for c in ("PC", "SP", "A", "X", "Y")) for r in nR]
print("regs (PC,SP,A,X,Y) by shift:")
for k in (-2, -1, 0, 1, 2):
    d, c = shifted_diff(gr_, nr_, k)
    print(f"  k={k:+d}: {d}/{c} rows differ")

# ---------------------------------------------------------------- part 2
def xcorr(path_g, path_n, label):
    gH2, gR2 = load(path_g)
    nH2, nR2 = load(path_n)
    ci2 = {name: i for i, name in enumerate(gH2)}
    cols = ["PC", "SP", "P", "Y", "X", "A"]
    gseq = [tuple(r[ci2[c]] for c in cols) for r in gR2]
    nseq = [tuple(r[ci2[c]] for c in cols) for r in nR2]
    print(f"\n=== {label} ===")
    best = None
    for k in range(-4, 5):
        d, c = shifted_diff(gseq, nseq, k)
        if c < 10:
            continue
        rate = (c - d) / c
        print(f"  shift k={k:+d}: {c-d}/{c} register rows match ({rate:.1%})")
        if best is None or rate > best[1]:
            best = (k, rate)
    k, _ = best
    # first row where even the best-shift comparison fails
    if k >= 0:
        cnt = min(len(nseq), len(gseq) - k)
        idx = next((i for i in range(cnt) if gseq[i + k] != nseq[i]), None)
    else:
        j = -k
        cnt = min(len(gseq), len(nseq) - j)
        idx = next((i for i in range(cnt) if gseq[i] != nseq[i + j]), None)
    if idx is None:
        print(f"best shift k={k:+d}: NO divergence under best shift")
        return
    gi = idx + (k if k >= 0 else 0)
    ni_ = idx + (-k if k < 0 else 0)
    print(f"best shift k={k:+d}; first real divergence at new-trace row {ni_} (cycle {nR2[ni_][0]})")
    lo_g, hi_g = max(0, gi - 3), min(len(gR2), gi + 4)
    for i in range(lo_g, hi_g):
        j = i - k                        # corresponding new-trace row (both signs)
        if 0 <= j < len(nR2):
            mark = " >>>" if i == gi else "    "
            print(f"{mark} G[{gR2[i][0]}]: {gR2[i]}")
            print(f"     N[{nR2[j][0]}]: {nR2[j]}")

xcorr("module_tests/t65/build/verilog_prog.csv", "module_tests/cpu_65c02/build/t65_prog_trace.csv",
      "PART 2a: t65 phase 0 (directed program)")
xcorr("module_tests/t65/build/verilog_boot.csv", "module_tests/cpu_65c02/build/t65_boot_trace.csv",
      "PART 2b: t65 phase 1 (apple2e boot walk)")
