#!/usr/bin/env python3
"""
semantic_compare.py — reproducible semantic comparison of two 6502/65C02
cycle-accurate traces (golden vs new core) produced by the r65-pair harness
(cpu65_r65_tb.sv / r65c02_verilog_tb.sv, 21-column CSV).

Implements Priority 1 of CPU_COMPARISON_RECOMMENDATIONS.md:

  1. Real opcode fetches are selected with SYNC=1. (Nuance, documented:
     interrupt-entry fetches carry SYNC_IRQ=1 in BOTH TBs; the reset-entry
     fetch carries SYNC_IRQ=1 only in the new-core TB. Using SYNC alone
     selects all real opcode fetches in both traces.)
  2. Equal fetch counts and equal (ADDR, DI) for every paired fetch.
  3. Instruction length (cycles between consecutive paired fetches), with
     per-opcode whitelisted deltas (LEN entries).
  4. Architectural state at each fetch boundary:
       - A, X, Y, P_N, P_V, P_D, P_I, P_Z, P_C: golden_fetchrow[i] must equal
         new_fetchrow[i-1]. The golden TB's state columns lag by one fetch —
         the known one-row observation skew.
       - SP: either the shifted or the unshifted value may match (stack
         operations and interrupt entry commit SP at different phases in the
         two TBs). Every unshifted occurrence is reported for review.
       - PC column at boundaries: dPC = N-G (mod 64K) must be 0 or 1; other
         values are allowed only for control-flow transfers (branches, JSR,
         JMP*, RTS) and interrupt-entry fetches, where both TBs sample the
         in-transition PC differently. Every such occurrence is reported.
         The architectural PC itself is proven by fetch-address equality
         (check 2) and final-row equality.
       - Final row: all state columns equal except P_B, which is a structural
         constant 1 in the new core (reg_p = {fl_n,fl_v,1'b1,1'b1,...}) and is
         reported, not compared.
  5. Ordered write events (address, data) including multiplicity, scoped per
     instruction. Whitelisted: golden RMW old-value pre-write
     (RMW_PREWRITE_GOLDEN entry).
  6. --report-reads: per-instruction ordered read events, report-only
     (reads cannot trigger I/O effects in this stimulus; the option exists
     for future side-effecting-I/O stimuli).
  7/8. Only named, reviewed whitelist entries are allowed; anything else
       fails the run.
  9. Machine-readable JSON summary: input paths, row counts, hashes, fetch
     counts, compared instruction counts, allowed differences used.

"Final write-map equality" (last-write-wins RAM reconstruction) is reported
as a separately named sub-check. It is NOT transaction equality.

Usage:
  python semantic_compare.py GOLDEN.csv NEW.csv \
      [--whitelist semantic_whitelist.txt] [--report-reads] \
      [--gate NAME=ADDR ...] [--json-out FILE]

Exit codes: 0 = pass, 2 = divergence found, 1 = usage/IO error.
"""

import argparse
import csv
import hashlib
import json
import os
import sys

REQUIRED_COLS = ['CYCLE', 'PC', 'SP', 'P_N', 'P_V', 'P_R', 'P_B', 'P_D',
                 'P_I', 'P_Z', 'P_C', 'Y', 'X', 'A', 'ADDR', 'DI', 'DO',
                 'RW', 'NMI_N', 'IRQ_N', 'SYNC', 'SYNC_IRQ']

STATE_COLS = ['A', 'X', 'Y', 'SP', 'P_N', 'P_V', 'P_D', 'P_I', 'P_Z', 'P_C']
FINAL_SKIP = {'P_B': 'structural constant 1 in new core (reg_p hardwires R=B=1)'}

# Control-flow transfers whose boundary PC column may show an in-transition
# value different from {G, G+1} (both TBs sample the jump mid-update).
CFLOW_OPS = ({0x20, 0x4C, 0x6C, 0x7C, 0x60, 0x40}             # JSR JMP* RTS RTI
             | {0x80, 0xF0, 0xD0, 0xB0, 0x90, 0x30, 0x10, 0x50, 0x70})  # BRA + branches


def fail(msg):
    print(f'ERROR: {msg}', file=sys.stderr)
    sys.exit(1)


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def load_trace(path):
    if not os.path.isfile(path):
        fail(f'trace not found: {path}')
    with open(path, newline='') as f:
        rows = list(csv.reader(f))
    if not rows:
        fail(f'empty trace: {path}')
    header, data = rows[0], rows[1:]
    missing = [c for c in REQUIRED_COLS if c not in header]
    if missing:
        fail(f'{path}: missing columns {missing}')
    idx = {c: header.index(c) for c in header}
    return header, data, idx, sha256(path)


def parse_whitelist(path):
    """Returns (len_delta {op:int -> g_minus_n}, rmw_prewrite set{op:int},
    entries [ids])."""
    len_delta = {}
    rmw = set()
    entries = []
    if not os.path.isfile(path):
        fail(f'whitelist not found: {path}')
    with open(path) as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split()
            kind = parts[0].upper()
            if kind == 'LEN':
                try:
                    delta = int(parts[1])
                    ops = [int(p, 16) for p in parts[2:]]
                except ValueError:
                    fail(f'whitelist line {lineno}: bad LEN entry')
                for op in ops:
                    if op in len_delta and len_delta[op] != delta:
                        fail(f'whitelist line {lineno}: conflicting LEN for 0x{op:02x}')
                    len_delta[op] = delta
                entries.append(line)
            elif kind == 'RMW_PREWRITE_GOLDEN':
                try:
                    ops = [int(p, 16) for p in parts[1:]]
                except ValueError:
                    fail(f'whitelist line {lineno}: bad RMW_PREWRITE_GOLDEN entry')
                rmw.update(ops)
                entries.append(line)
            else:
                fail(f'whitelist line {lineno}: unknown kind {kind!r}')
    return len_delta, rmw, entries


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument('golden')
    ap.add_argument('new')
    ap.add_argument('--whitelist', default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), 'semantic_whitelist.txt'))
    ap.add_argument('--report-reads', action='store_true',
                    help='per-instruction ordered read events (report-only)')
    ap.add_argument('--gate', action='append', default=[], metavar='NAME=ADDR',
                    help='coverage gate: both traces must fetch ADDR (repeatable)')
    ap.add_argument('--json-out', default=None, help='also write JSON summary here')
    args = ap.parse_args()

    gh, gr, gi, gsha = load_trace(args.golden)
    nh, nr, ni, nsha = load_trace(args.new)
    len_delta, rmw_ops, wl_entries = parse_whitelist(args.whitelist)

    result = {'pass': True}
    problems = []

    def problem(check, msg):
        result['pass'] = False
        problems.append(f'[{check}] {msg}')

    # ---- 1. fetch selection ------------------------------------------------
    gfi = [i for i, r in enumerate(gr) if r[gi['SYNC']] == '1']
    nfi = [i for i, r in enumerate(nr) if r[ni['SYNC']] == '1']
    gf = [gr[i] for i in gfi]
    nf = [nr[i] for i in nfi]

    def cyc(r, idx):
        return int(r[idx['CYCLE']])

    # ---- 2. fetch pairing --------------------------------------------------
    pair_ok = len(gf) == len(nf)
    pair_mismatch = []
    m = min(len(gf), len(nf))
    for i in range(m):
        if (gf[i][gi['ADDR']], gf[i][gi['DI']]) != (nf[i][ni['ADDR']], nf[i][ni['DI']]):
            pair_mismatch.append(
                f'fetch#{i}: G@{cyc(gf[i], gi)} {gf[i][gi["ADDR"]]}:{gf[i][gi["DI"]]}'
                f' N@{cyc(nf[i], ni)} {nf[i][ni["ADDR"]]}:{nf[i][ni["DI"]]}')
    if not pair_ok:
        problem('fetch_pair', f'fetch count differs: golden={len(gf)} new={len(nf)}')
    for p in pair_mismatch[:10]:
        problem('fetch_pair', p)
    if len(pair_mismatch) > 10:
        problem('fetch_pair', f'... and {len(pair_mismatch) - 10} more')

    # ---- 3. instruction length ---------------------------------------------
    wl_used = {e: 0 for e in wl_entries}
    len_bad = []
    for i in range(m - 1):
        lg = cyc(gf[i + 1], gi) - cyc(gf[i], gi)
        ln = cyc(nf[i + 1], ni) - cyc(nf[i], ni)
        op = int(gf[i][gi['DI']], 16)
        allowed = len_delta.get(op, 0)
        if lg - ln != allowed:
            len_bad.append(
                f'fetch#{i} op=0x{op:02x} @ {gf[i][gi["ADDR"]]}: '
                f'G={lg} N={ln} (allowed delta G-N={allowed})')
        elif allowed != 0:
            for e in wl_entries:
                if e.upper().startswith('LEN') and any(
                        int(p, 16) == op for p in e.split()[2:]):
                    wl_used[e] += 1
    for p in len_bad[:10]:
        problem('instruction_length', p)
    if len(len_bad) > 10:
        problem('instruction_length', f'... and {len(len_bad) - 10} more')

    # ---- 4. state at fetch boundaries --------------------------------------
    sp_unshifted = []
    cflow_pc = []
    state_bad = []
    for i in range(1, m):
        g, nprev, ncur = gf[i], nf[i - 1], nf[i]
        for col in STATE_COLS:
            if col == 'SP':
                if g[gi['SP']] == nprev[ni['SP']]:
                    continue
                if g[gi['SP']] == ncur[ni['SP']]:
                    sp_unshifted.append(
                        f'fetch#{i} @ {g[gi["ADDR"]]} (prev op 0x{gf[i-1][gi["DI"]]:s}): '
                        f'SP G={g[gi["SP"]]} == N-unshifted')
                    continue
                state_bad.append(f'fetch#{i} SP: G={g[gi["SP"]]} '
                                 f'N-shifted={nprev[ni["SP"]]} N-unshifted={ncur[ni["SP"]]}')
            elif g[gi[col]] != nprev[ni['col'] if False else ni[col]]:
                state_bad.append(
                    f'fetch#{i} {col}: G={g[gi[col]]} N-shifted={nprev[ni[col]]}')
        # PC column at the boundary row (last row of instruction i-1,
        # i.e. the row immediately before fetch#i)
        if i >= 2:
            grow = gr[gfi[i] - 1] if gfi[i] > 0 else None
            nrow = nr[nfi[i] - 1] if nfi[i] > 0 else None
            if grow is not None and nrow is not None:
                dpc = (int(nrow[ni['PC']], 16) - int(grow[gi['PC']], 16)) % 65536
                op = int(gf[i - 1][gi['DI']], 16)
                irq_entry = gf[i][gi['SYNC_IRQ']] == '1' or nf[i][ni['SYNC_IRQ']] == '1'
                if dpc not in (0, 1):
                    if irq_entry:
                        cflow_pc.append(f'fetch#{i} interrupt-entry @ {g[gi["ADDR"]]}: '
                                        f'dPC={dpc} (vector jump)')
                    elif op in CFLOW_OPS:
                        cflow_pc.append(f'fetch#{i} after 0x{op:02x} @ {gf[i-1][gi["ADDR"]]}: '
                                        f'dPC={dpc} (in-transition PC)')
                    else:
                        state_bad.append(
                            f'boundary before fetch#{i} (prev op 0x{op:02x}): '
                            f'dPC={dpc} not in {{0,1}} and not a control-flow transfer')
    for p in state_bad[:10]:
        problem('state_at_boundaries', p)
    if len(state_bad) > 10:
        problem('state_at_boundaries', f'... and {len(state_bad) - 10} more')

    # ---- 5. write events, per instruction ----------------------------------
    wl_rmw_used = 0
    write_bad = []
    g_writes_total = n_writes_total = 0
    for i in range(m):
        g_lo, g_hi = gfi[i], (gfi[i + 1] if i + 1 < len(gfi) else len(gr))
        n_lo, n_hi = nfi[i], (nfi[i + 1] if i + 1 < len(nfi) else len(nr))
        gw = [(r[gi['ADDR']], r[gi['DO']]) for r in gr[g_lo:g_hi] if r[gi['RW']] == '0']
        nw = [(r[ni['ADDR']], r[ni['DO']]) for r in nr[n_lo:n_hi] if r[ni['RW']] == '0']
        g_writes_total += len(gw)
        n_writes_total += len(nw)
        op = int(gf[i][gi['DI']], 16)
        if gw == nw:
            continue
        ok = False
        if op in rmw_ops and len(gw) == len(nw) + 1 and gw[1:] == nw:
            a, d = gw[0]
            # the pre-write must equal the value golden read at that address
            if any(r[gi['ADDR']] == a and r[gi['DI']] == d and r[gi['RW']] == '1'
                   for r in gr[g_lo:g_hi]):
                ok = True
                wl_rmw_used += 1
                for e in wl_entries:
                    if e.upper().startswith('RMW_PREWRITE_GOLDEN'):
                        wl_used[e] += 1
        if not ok:
            write_bad.append(
                f'fetch#{i} op=0x{op:02x} @ {gf[i][gi["ADDR"]]}: '
                f'G={gw} N={nw}')
    for p in write_bad[:10]:
        problem('write_events', p)
    if len(write_bad) > 10:
        problem('write_events', f'... and {len(write_bad) - 10} more')

    # ---- 6. optional read report -------------------------------------------
    read_report = None
    if args.report_reads:
        read_diffs = []
        for i in range(m):
            g_lo, g_hi = gfi[i], (gfi[i + 1] if i + 1 < len(gfi) else len(gr))
            n_lo, n_hi = nfi[i], (nfi[i + 1] if i + 1 < len(nfi) else len(nr))
            grd = [(r[gi['ADDR']], r[gi['DI']]) for r in gr[g_lo:g_hi] if r[gi['RW']] == '1']
            nrd = [(r[ni['ADDR']], r[ni['DI']]) for r in nr[n_lo:n_hi] if r[ni['RW']] == '1']
            if grd != nrd:
                read_diffs.append({'fetch': i, 'op': gf[i][gi['DI']],
                                   'addr': gf[i][gi['ADDR']],
                                   'golden': grd, 'new': nrd})
        read_report = {'instructions_compared': m,
                       'instructions_with_read_differences': len(read_diffs),
                       'first_10': read_diffs[:10]}

    # ---- 7. final row state -------------------------------------------------
    gl, nl = gr[-1], nr[-1]
    final_state = {}
    final_ok = True
    for col in ['PC', 'SP', 'A', 'X', 'Y', 'P_N', 'P_V', 'P_D', 'P_I', 'P_Z', 'P_C']:
        gv, nv = gl[gi[col]], nl[ni[col]]
        final_state[col] = {'golden': gv, 'new': nv, 'equal': gv == nv}
        if gv != nv:
            final_ok = False
    for col, why in FINAL_SKIP.items():
        final_state[col] = {'golden': gl[gi[col]], 'new': nl[ni[col]],
                            'skipped': why}
    if not final_ok:
        problem('final_state',
                'final row differs: ' +
                ', '.join(f'{c}={v["golden"]}/{v["new"]}'
                          for c, v in final_state.items()
                          if v.get('equal') is False))

    # ---- 8. final write-map equality (NOT transaction equality) -------------
    gmap = dict((r[gi['ADDR']], r[gi['DO']]) for r in gr if r[gi['RW']] == '0')
    nmap = dict((r[ni['ADDR']], r[ni['DO']]) for r in nr if r[ni['RW']] == '0')
    map_diffs = {a: (gmap.get(a), nmap.get(a))
                 for a in set(gmap) | set(nmap) if gmap.get(a) != nmap.get(a)}
    if map_diffs:
        problem('final_write_map_equality',
                f'final RAM values differ at {len(map_diffs)} addresses: '
                + ', '.join(f'{a}: G={v[0]} N={v[1]}' for a, v in
                            sorted(map_diffs.items())[:8]))

    # ---- 9. gates -----------------------------------------------------------
    gates = {}
    for spec in args.gate:
        if '=' not in spec:
            fail(f'bad --gate {spec!r} (want NAME=ADDR)')
        name, addr = spec.split('=', 1)
        addr = addr.upper()
        ghit = any(r[gi['ADDR']].upper() == addr for r in gf)
        nhit = any(r[ni['ADDR']].upper() == addr for r in nf)
        gates[name] = {'addr': addr, 'golden': ghit, 'new': nhit}
        if not (ghit and nhit):
            problem('gate', f'gate {name} ({addr}): golden={ghit} new={nhit}')

    # ---- summary -------------------------------------------------------------
    summary = {
        'checker': 'semantic_compare.py v1',
        'inputs': {
            'golden': {'path': os.path.abspath(args.golden), 'sha256': gsha,
                       'rows': len(gr)},
            'new': {'path': os.path.abspath(args.new), 'sha256': nsha,
                    'rows': len(nr)},
        },
        'whitelist': {
            'path': os.path.abspath(args.whitelist),
            'entries': wl_entries,
            'usage': {k: v for k, v in wl_used.items() if v},
            'rmw_prewrites_allowed': wl_rmw_used,
        },
        'checks': {
            'fetch_selection': {
                'rule': 'SYNC=1 (reset-entry fetch is SYNC_IRQ=1 only in new-core TB; '
                        'interrupt-entry fetches are SYNC_IRQ=1 in both)',
                'golden_fetches': len(gf), 'new_fetches': len(nf),
            },
            'fetch_pair_identity': {
                'compared': m, 'mismatches': len(pair_mismatch),
                'pass': pair_ok and not pair_mismatch,
            },
            'instruction_length': {
                'compared': max(0, m - 1), 'mismatches': len(len_bad),
                'pass': not len_bad,
            },
            'state_at_boundaries': {
                'rule': 'golden_fetchrow[i] vs new_fetchrow[i-1] (one-fetch skew); '
                        'SP also accepts unshifted; PC column dPC in {0,1} or cflow',
                'boundaries_compared': max(0, m - 1),
                'mismatches': len(state_bad),
                'sp_unshifted_reported': len(sp_unshifted),
                'sp_unshifted': sp_unshifted[:20],
                'cflow_pc_reported': len(cflow_pc),
                'cflow_pc': cflow_pc[:20],
                'pass': not state_bad,
            },
            'write_events': {
                'golden_write_rows': g_writes_total,
                'new_write_rows': n_writes_total,
                'instructions_compared': m,
                'unwhitelisted': len(write_bad),
                'pass': not write_bad,
            },
            'final_state': {'rows': final_state, 'pass': final_ok},
            'final_write_map_equality': {
                'note': 'last-write-wins RAM reconstruction; NOT transaction equality',
                'golden_distinct_addrs': len(gmap),
                'new_distinct_addrs': len(nmap),
                'differing': {a: {'golden': v[0], 'new': v[1]} for a, v in map_diffs.items()},
                'pass': not map_diffs,
            },
            'gates': gates,
        },
        'read_report': read_report,
        'problems': problems,
        'result': 'PASS' if result['pass'] else 'FAIL',
    }

    out = json.dumps(summary, indent=2)
    print(out)
    if args.json_out:
        with open(args.json_out, 'w') as f:
            f.write(out + '\n')
    sys.exit(0 if result['pass'] else 2)


if __name__ == '__main__':
    main()
