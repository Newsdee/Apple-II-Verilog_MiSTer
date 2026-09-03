#!/usr/bin/env python3
"""Run cpu_6502 suite test cases on the perfect6502 transistor-level NMOS
6502 netlist (oracle/p6502_oracle.c) and compare the result against the
suite's expected traces and against the five retained core sweeps.

This is the ground-truth oracle path for the open expert questions in
build/new6502_diff_documentation.md: the netlist is the NMOS 6502 at
transistor level, so its traces answer what the Verilog models (and the
reconstructed suite) cannot.

Usage:
    python run_oracle.py --phase 1            # 13 opcodes: 9 illegal + 5c/80/7c
    python run_oracle.py --phase 2            # all 256 opcodes (12800 tests)
    python run_oracle.py --ops 5c,80,7c       # explicit opcode list

Output:
    oracle/sweep_6502_oracle_results_<tag>.txt   raw R/U/F lines (retained)
    oracle/oracle_report_<tag>.txt               analysis report
"""
import argparse
import os
import subprocess
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
MT = os.path.join(HERE, '..')
EVID = os.path.join(MT, 'evidence')
sys.path.insert(0, MT)
from rebuild_summary import select_tests          # noqa: E402
from sst_driver import parse_results, compare     # noqa: E402

ROOT = r'E:\MiSTer\Apple-II_FPGAdev\65x02'
SUITE = '6502'
SAMPLE = 50
SEED = 1
VECTOR_AREA = {0xFFFC, 0xFFFD, 0xFFF0, 0xFFF1, 0xFFF2, 0xFFF3,
               0xFFF4, 0xFFF5, 0xFFF6, 0xFFF7, 0xFFF8, 0xFFF9,
               0xFFFA, 0xFFFB, 0xFFFC, 0xFFFD, 0xFFFE, 0xFFFF}

CORES = {
    'new6502': 'sweep_6502_new6502_results.txt',
    'golden':  'sweep_6502_golden_results.txt',
    'v2nmos':  'sweep_6502_v2nmos_results.txt',
    'v2wdc1':  'sweep_6502_v2_results.txt',
    'v1':      'sweep_6502_abxfix_results.txt',
}

PHASE1_OPS = ['23', '3b', '63', '73', '7b', '9b', 'c3', 'db', 'f3',
              '5c', '80', '7c']

# (failure prefix, regs-string offset, which suite final field)
LC_FIELDS = (('final sp', 4), ('final a', 6), ('final x', 8), ('final y', 10))


def late_commit_rescue(t, g, f):
    """Netlist late-commit rescue (see OV51_NOTES.md, commit convention).

    For some instructions (observed: $E8 INX, $E9 SBC-imm, $C8, $88 and
    the wider B=1-row family) the netlist's PC node reaches the final PC
    at row ncyc-1 while A/X/Y/SP commit one row later, at row ncyc. A
    register failure is explained by the late-commit signature when row
    ncyc-1 still shows the initial (row-0) value and row ncyc shows
    exactly the suite's expected final value. Such register failures
    are dropped: the netlist agrees with the suite semantically and
    differs only in the observable cycle of the register commit. PC
    failures are never rescued (the PC check already pins the row)."""
    ncyc = len(t['cycles'])
    if ncyc < 1 or ncyc >= len(g):
        return f, 0
    r0 = g[0][1]
    ra = g[ncyc - 1][1]
    rb = g[ncyc][1]
    fin = t['final']
    fmap = {'final sp': (LC_FIELDS[0][1], fin['s']),
            'final a':  (LC_FIELDS[1][1], fin['a']),
            'final x':  (LC_FIELDS[2][1], fin['x']),
            'final y':  (LC_FIELDS[3][1], fin['y'])}
    out = []
    rescued = 0
    for x in f:
        hit = None
        for key, (off, fv) in fmap.items():
            if x.startswith(key + ' '):
                hit = (off, fv)
                break
        if hit:
            off, fv = hit
            if (int(ra[off:off + 2], 16) == int(r0[off:off + 2], 16)
                    and int(rb[off:off + 2], 16) == fv):
                rescued += 1
                continue
        out.append(x)
    return out, rescued


def build_spec(idx, op, t):
    """Return a spec line for p6502_oracle, or (None, reason)."""
    i = t['initial']
    pc, sp, a, x, y, p = i['pc'], i['s'], i['a'], i['x'], i['y'], i['p']
    ram = {aa: vv for aa, vv in i['ram']}

    # simulate in-window writes to get the data each read must return
    supply = {}
    for ea, ev, et in t['cycles']:
        if et == 'write':
            ram[ea] = ev
        else:
            if ea in ram and ram[ea] != ev:
                return None, ('suite-inconsistent: read %04X expects %02X '
                              'but simulated RAM has %02X'
                              % (ea, ev, ram[ea]))
            supply[ea] = ev

    if 0xFFFC in ram or 0xFFFD in ram:
        return None, 'vector-area collision with initial ram'

    forbidden = set(ram) | {ea for ea, _ev, _et in t['cycles']} \
        | {aa for aa, _v in t['final']['ram']} | VECTOR_AREA
    prebase = None
    for b in range(0x1000, 0xE000, 0x40):
        if not ({b + i for i in range(12)} & forbidden):
            prebase = b
            break
    if prebase is None:
        return None, 'no free prelude slot'

    # v5.1: the 12-byte prelude touches no memory outside the prebase
    # area (TXS sets SP without a stack access), so there are no
    # stack-byte collision constraints. sp0 == spec sp.
    sp0 = sp

    pairs = dict(ram)
    pairs.update(supply)
    pairs[0xFFFC] = prebase & 0xFF
    pairs[0xFFFD] = prebase >> 8

    body = ' '.join('%04x=%02x' % (aa, vv)
                    for aa, vv in sorted(pairs.items()))
    return ('%d %02x %02x %02x %02x %02x %04x %04x %02x %s'
            % (idx, sp, a, x, y, p, pc, prebase, sp0, body)), None


def fpe_check(f):
    """P-exempt failures: everything except the final-P line."""
    return [x for x in f if not x.startswith('final p ')]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--phase', type=int, choices=[1, 2], default=1)
    ap.add_argument('--ops', default=None,
                    help='comma list of opcodes (overrides --phase)')
    ap.add_argument('--seed', type=int, default=1,
                    help='suite sample seed (default 1; tag gets _s<N> suffix)')
    args = ap.parse_args()

    if args.ops:
        ops = [o.strip().lower() for o in args.ops.split(',')]
        tag = 'custom'
    elif args.phase == 1:
        ops = PHASE1_OPS
        tag = 'phase1'
    else:
        ops = ['%02x' % i for i in range(256)]
        tag = 'full'
    if args.seed != 1:
        tag += '_s%d' % args.seed

    SEL = select_tests(ROOT, SUITE, ops, SAMPLE, args.seed)
    print('selected %d tests for ops %s' % (len(SEL),
          ','.join(ops[:6]) + ('...' if len(ops) > 6 else '')))

    spec_lines = []
    skips = Counter()
    keep_idx = []
    for idx, (op, t) in enumerate(SEL):
        line, why = build_spec(idx, op, t)
        if line is None:
            skips[why.split(':')[0]] += 1
            print('  skip idx %d op %s: %s' % (idx, op, why))
            continue
        spec_lines.append(line)
        keep_idx.append(idx)

    spec_path = os.path.join(HERE, 'spec_%s.txt' % tag)
    raw_path = os.path.join(HERE, 'sweep_6502_oracle_results_%s.txt' % tag)
    rep_path = os.path.join(HERE, 'oracle_report_%s.txt' % tag)
    with open(spec_path, 'w') as f:
        f.write('\n'.join(spec_lines) + '\n')

    print('running p6502_oracle on %d tests...' % len(spec_lines))
    exe = os.path.join(HERE, 'p6502_oracle.exe')
    with open(raw_path, 'w') as f:
        rc = subprocess.call([exe, spec_path], stdout=f, cwd=HERE)
    if rc != 0:
        print('!! oracle exited rc=%d' % rc)
        return 1

    # parse raw output: R lines go through parse_results; U/F are skipped
    oracle = parse_results(raw_path)
    u_f = {}
    with open(raw_path) as f:
        for line in f:
            if line.startswith('U ') or line.startswith('F '):
                parts = line.split()
                u_f[int(parts[1])] = parts[0] + ' ' + ' '.join(parts[2:])

    # ---------------- compare against the suite ----------------
    # NOTE (v5.1): in this netlist build the P readout (p0..p7 nodes) is
    # an alias of A — not the P storage (see p6502_oracle.c header, P
    # REGISTER section). The suite's final-P check is therefore invalid
    # for the netlist oracle; the report carries a P-exempt pass count
    # (all checks except the final-P line) as the netlist-valid metric,
    # and classifies P-only failing tests as p-limited.
    #
    # NOTE (v5.1, commit convention): the group regs of row c are the
    # POST-state of row c (the TB snapshot runs into the next bus
    # token). The netlist commits A/X/Y/SP/P at the end of the
    # instruction, so its true final state is the post-state of row
    # ncyc-1 = groups[ncyc-1] = final_offset=-1. (The TB cores commit
    # on the next opcode fetch, hence their offset 0/1; those offsets
    # are one row too late for the netlist and were the source of the
    # apparent "final pc +1" failures in the first post-fix run.)
    pass_neg1 = fail_neg1 = pass0pe = p_limited = 0
    rescued_total = 0
    detail = []
    per_op = {}
    for idx in keep_idx:
        op, t = SEL[idx]
        g = oracle.get(idx)
        if g is None:
            print('  !! idx %d op %s: no oracle R line (%s)'
                  % (idx, op, u_f.get(idx, 'MISSING')))
            continue
        f_raw = compare(t, g, final_offset=-1)
        f, nres = late_commit_rescue(t, g, f_raw)
        rescued_total += nres
        if not f:
            pass_neg1 += 1
        else:
            fail_neg1 += 1
            if len(detail) < 12:
                detail.append((idx, op, 'off-1', f[:3]))
        if not fpe_check(f):
            pass0pe += 1
            if f_raw:
                p_limited += 1  # failed only on the final-P line / rescue
        po = per_op.setdefault(op, [0, 0, 0, 0, 0])
        po[0 if not f else 1] += 1
        po[2 if not fpe_check(f) else 3] += 1
        po[4] += nres

    n = len(keep_idx)
    with open(rep_path, 'w') as f:
        w = f.write
        w('perfect6502 netlist oracle report (tag=%s, %d tests)\n'
          % (tag, n))
        w('skipped specs: %s\n' % (dict(skips) or 'none'))
        w('oracle R lines: %d, U/F: %d\n' % (len(oracle), len(u_f)))
        for k in sorted(u_f):
            w('  %s (idx %d)\n' % (u_f[k], k))
        w('suite pass (final_offset=-1, netlist commit convention): '
          '%d/%d\n' % (pass_neg1, n))
        w('suite pass P-exempt (final_offset=-1): %d/%d '
          '(netlist-valid; P readout is an A alias in this netlist)\n'
          % (pass0pe, n))
        w('p-limited (failed only on the final-P line): %d\n' % p_limited)
        w('late-commit rescues (register failures dropped, see '
          'late_commit_rescue): %d\n' % rescued_total)
        w('per-op full pass/fail (offset -1): %s\n'
          % ' '.join('%s:%d/%d' % (o, per_op[o][0], per_op[o][0] + per_op[o][1])
                     for o in sorted(per_op)))
        w('per-op P-exempt pass/fail: %s\n'
          % ' '.join('%s:%d/%d' % (o, per_op[o][2], per_op[o][2] + per_op[o][3])
                     for o in sorted(per_op)))
        w('per-op late-commit rescues: %s\n'
          % ' '.join('%s:%d' % (o, per_op[o][4]) for o in sorted(per_op)
                     if per_op[o][4]))
        w('\nfirst failing details (offset -1, post-rescue):\n')
        for idx, op, off, ff in detail:
            w('  idx %d op %s %s: %s\n' % (idx, op, off, ff[0]))

    # NOTE (empirically resolved 2026-09-04, see build/new6502_three_way_join.md):
    # the retained core sweeps ARE the current suite's tests. Premise check
    # over the 12796 common idx: fetch rows 0-1 agree 12799/12800 (single
    # golden row-0 prelude artifact, idx 1507); v2nmos row-0 post-state
    # equals the suite initial state on 12800/12800. The golden TB's row-N
    # register snapshot is the PRE-state of row N (the spec initial-state
    # load lands during row 0), so golden row-0 registers look like the
    # previous test's residual, but from row 1 onward the golden trace
    # carries the correct suite initial state - and the campaign's
    # golden final_offset=1 convention (group[ncyc+1]) reads the committed
    # final state correctly. What DID change between the sweep-generation
    # suite state (65x02 commit 2f6980a) and the current data: the
    # expected FINAL values on a subset of tests (sweep-header pass totals
    # 8273/7869 vs current-suite compare() totals 7973/7749). That is the
    # suite-A-model population measured by the T1 join, not a test-
    # misalignment. The oracle's verdict comes from compare() against the
    # current suite data.

        # ---------------- $5C fetch-start ----------------
        w('\n$5C next-fetch start row (first READ at final PC, 1-based row):')
        fc = Counter()
        for idx in keep_idx:
            op, t = SEL[idx]
            if op != '5c':
                continue
            g = oracle.get(idx)
            if g is None:
                continue
            fpc = t['final']['pc']
            for r, (bus, _rg) in enumerate(g, start=1):
                if bus[4] == 'R' and int(bus[0:4], 16) == fpc:
                    fc['row %d' % r] += 1
                    break
        w(' %s\n' % (dict(fc) or 'n/a'))

        # ---------------- $80 / $7C answers ----------------
        for opc in ('80', '7c'):
            w('\nop %s behaviour (16-cycle window, per test):' % opc)
            c8 = Counter()
            for idx in keep_idx:
                op, t = SEL[idx]
                if op != opc:
                    continue
                g = oracle.get(idx)
                if g is None:
                    continue
                i = t['initial']
                pc = i['pc']
                ramdict = {aa: vv for aa, vv in i['ram']}
                off = t['cycles'][1][0] if opc == '80' and len(t['cycles']) > 1 \
                    else (ramdict.get(pc + 1, 0))
                fpc = t['final']['pc']
                # where does the next fetch land?
                nxt = None
                for r, (bus, _rg) in enumerate(g, start=1):
                    if bus[4] == 'R' and int(bus[0:4], 16) == fpc:
                        nxt = r
                        break
                kind = 'nop' if fpc == (pc + 2) & 0xFFFF else \
                    ('branch' if opc == '80' else 'other')
                c8['finalPC=%04X nxtRow=%s %s' % (fpc, nxt, kind)] += 1
            for k in sorted(c8):
                w('\n  %s x%d' % (k, c8[k]))

    print('report: %s' % rep_path)
    print('raw:    %s' % raw_path)
    with open(rep_path) as f:
        print(f.read())
    return 0


if __name__ == '__main__':
    sys.exit(main())
