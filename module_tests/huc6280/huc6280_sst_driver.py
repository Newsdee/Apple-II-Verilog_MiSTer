#!/usr/bin/env python3
"""HUC6280 vs canonical 65C02 — single-step cross-comparison driver.

Loads WDC 65C02 (SingleStepTests/65x02, suite "wdc65c02") scenarios, writes ONE
batch file, runs BOTH test benches on it:
  * HUC6280 (VHDL/GHDL)   -> huc6280_results.txt   (module_tests/huc6280)
  * canonical 65C02 (Verilator) -> canonical_results.txt
Both benches emit the same result-line format, so the same parser serves both.

For each test the driver cross-compares the two cores:
  * completion row (next-opcode fetch at the suite's final PC, found by the
    (fpc, fpc+1) read-pair heuristic) per core,
  * final register state at each core's completion row (P masked),
  * the bus access sequence up to completion (idle sentinels excluded),
    with the HUC6280 stack page ($21xx) mapped to $01xx so the two sequences
    are directly comparable.

Classification per test:
  IDENTICAL   same cycle count, same final state, same (normalized) bus seq
  TIMING      different cycle count, same final state + same non-idle accesses
  STATE       different final register state
  BUS         different bus access sequence (addr/rw/data)
  (a test can hit several; the first mismatching dimension is reported)

Also reports a suite-compare for the canonical core (sanity: it should mostly
pass WDC) and, for the HUC6280, counts stack-page and timing deltas.

Usage:
  py module_tests/huc6280/huc6280_sst_driver.py --ops all --sample 20 --seed 1
  py module_tests/huc6280/huc6280_sst_driver.py --ops a9,8d,ea,48,68,20 --sample 50
"""
import argparse, gzip, json, os, random, subprocess, sys, collections

REPO_DEFAULT = r'E:\MiSTer\Apple-II_FPGAdev\65x02'
WORK = r'E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer'
MASK_PB = 0x77          # keep N,V,D,I,Z,C for cross-compare (mask R=7,B=4, and T=5)
W = 16
GHDL_BIN = r'C:\msys64\ucrt64\bin\ghdl.exe'
VERI_BIN = os.path.join(WORK, 'module_tests', 'huc6280', 'build', 'sst_verilog',
                        'huc6280_65c02_tb.exe')
HUC_DIR = os.path.join(WORK, 'module_tests', 'huc6280')
BUILD = os.path.join(HUC_DIR, 'build')
BATCH = os.path.join(BUILD, 'sst_batch.txt')
# The sims write plain-text .txt to build/ (intermediate, git-ignored); we gzip
# them to .txt.gz at the benchmark root (committed). parse_results() auto-detects
# gzip, so both --no-sim (reuse .gz) and a fresh run (sims write .txt, then we
# gzip) work.
HUC_TXT = os.path.join(BUILD, 'huc6280_results.txt')
CAN_TXT = os.path.join(BUILD, 'canonical_results.txt')
HUC_RES = os.path.join(HUC_DIR, 'huc6280_results.txt.gz')
CAN_RES = os.path.join(HUC_DIR, 'canonical_results.txt.gz')
REPORT = os.path.join(HUC_DIR, 'cross_report.txt')


def gzip_file(src, dst):
    with open(src, 'rb') as f_in, gzip.open(dst, 'wb') as f_out:
        f_out.write(f_in.read())

# GHDL build/run source list (from PROGRESS.md)
GHDL_SRC = [
    r'E:\MiSTer\Apple-II_FPGAdev\TurboGrafx16_MiSTer\rtl\HUC6280\HUC6280_PKG.vhd',
    r'E:\MiSTer\Apple-II_FPGAdev\TurboGrafx16_MiSTer\rtl\HUC6280\AddSubBCD.vhd',
    r'E:\MiSTer\Apple-II_FPGAdev\TurboGrafx16_MiSTer\rtl\HUC6280\HUC6280_MC.vhd',
    os.path.join(WORK, 'module_tests/huc6280/rtl_tb/alu_tb.vhd'),
    os.path.join(WORK, 'module_tests/huc6280/rtl_tb/huc6280_ag_tb.vhd'),
    os.path.join(WORK, 'module_tests/huc6280/rtl_tb/huc6280_cpu_tb.vhd'),
    os.path.join(WORK, 'module_tests/huc6280/huc6280_sst_tb.vhd'),
]


def load_tests(root, suite, op):
    path = os.path.join(root, suite, 'v1', f'{op}.json')
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []


def make_batch(tests, out_path):
    with open(out_path, 'w', newline='\n') as f:
        for idx, t in enumerate(tests):
            ram = t['initial']['ram']
            if len(ram) > 64:
                continue
            i = t['initial']
            patch = ''.join(f'{a:04X}{v:02X}' for a, v in ram)
            f.write(f"{idx:08d} {i['pc']:04X} {i['s']:02X} {i['a']:02X} "
                    f"{i['x']:02X} {i['y']:02X} {i['p']:02X} "
                    f"{len(t['cycles']):3d} {len(ram):3d} {patch}\n")


def parse_results(path):
    res = {}
    opener = gzip.open if path.endswith('.gz') else open
    with opener(path, 'rt') as f:
        for line in f:
            if not line.startswith('R '):
                continue
            parts = line.split()
            if len(parts) != 2 + W + 1:
                continue
            idx = int(parts[1])
            bus0 = parts[2]
            regs = [None] * W
            for c in range(1, W):
                regs[c - 1] = parts[2 + c][:14]
            regs[W - 1] = parts[2 + W - 1]
            bus = [bus0] + [parts[2 + c][-7:] for c in range(1, W)]
            res[idx] = list(zip(bus, regs))
    return res


def is_idle(bus):
    return bus[0:4] == 'ffff' and bus[4] == 'r'


def bus_addr(bus):
    return int(bus[0:4], 16)


def completion_row(groups, fpc):
    """Row where the next instruction's first byte (fpc) is fetched. Primary:
    the (fpc, fpc+1) read pair. Fallback (when the next instruction is e.g. a
    JSR that interleaves stack writes with operand reads, breaking the pair):
    the first non-idle read of fpc. -1 if neither found."""
    fpc &= 0xFFFF
    for r in range(len(groups) - 1):
        b0, b1 = groups[r][0], groups[r + 1][0]
        if b0[4] == 'R' and bus_addr(b0) == fpc and not is_idle(b0) \
                and b1[4] == 'R' and bus_addr(b1) == (fpc + 1) & 0xFFFF and not is_idle(b1):
            return r
    for r in range(len(groups)):
        b0 = groups[r][0]
        if b0[4] == 'R' and bus_addr(b0) == fpc and not is_idle(b0):
            return r
    return -1


def parse_regs(regs):
    pc = int(regs[0:4], 16); sp = int(regs[4:6], 16); a = int(regs[6:8], 16)
    x = int(regs[8:10], 16); y = int(regs[10:12], 16); p = int(regs[12:14], 16)
    return pc, sp, a, x, y, p


def bus_seq(groups, row):
    """Non-idle bus accesses rows [0, row): (addr, rw, data). Raw addresses."""
    out = []
    for c in range(row):
        bus = groups[c][0]
        if is_idle(bus):
            continue
        out.append((bus_addr(bus), bus[4], int(bus[5:7], 16)))
    return out


def bus_remap_match(hseq, cseq):
    """True if the HUC6280 sequence equals the canonical sequence where each
    HUC6280 access matches the canonical access on rw+data and on address
    either exactly (absolute) or offset by +$2000 (the HUC6280 zero-page/stack
    remap). Returns (match, used_remap)."""
    if len(hseq) != len(cseq):
        return (False, False)
    used = False
    for (ha, hrw, hd), (ca, crw, cd) in zip(hseq, cseq):
        if hrw != crw or hd != cd:
            return (False, used)
        if ha == ca:
            continue
        if ha == (ca + 0x2000) & 0xFFFF and ca < 0x0200:
            used = True
            continue
        return (False, used)
    return (True, used)


def cross_compare(t, huc, can):
    """Return (category, detail) comparing the two cores on one test.
    Priority: STATE > BUS > REMAP > TIMING > IDENTICAL."""
    fpc = t['final']['pc'] & 0xFFFF
    hrow = completion_row(huc, fpc)
    crow = completion_row(can, fpc)
    if hrow < 0 or crow < 0:
        return 'NOFETCH', f'huc_row={hrow} can_row={crow} (no fetch pair in window)'
    # The ALU result (A/flags) is registered one cycle AFTER the next-opcode
    # fetch, so sample the final state at completion_row + 1 (clamped).
    hstate_row = min(hrow + 1, len(huc) - 1)
    crow_state = min(crow + 1, len(can) - 1)
    hpc, hsp, ha, hx, hy, hp = parse_regs(huc[hstate_row][1])
    cpc, csp, ca, cx, cy, cp = parse_regs(can[crow_state][1])
    hstate = (hpc, hsp, ha, hx, hy, hp & MASK_PB)
    cstate = (cpc, csp, ca, cx, cy, cp & MASK_PB)
    hseq = bus_seq(huc, hrow)
    cseq = bus_seq(can, crow)
    d = hrow - crow
    match, used = bus_remap_match(hseq, cseq)
    if hstate != cstate:
        return 'STATE', (f'cyc huc={hrow} can={crow} | '
                         f'huc({hpc:04x},{hsp:02x},{ha:02x},{hx:02x},{hy:02x},{hp:02x}) '
                         f'can({cpc:04x},{csp:02x},{ca:02x},{cx:02x},{cy:02x},{cp:02x})')
    if not match:
        return 'BUS', f'cyc huc={hrow} can={crow} | huc={hseq} can={cseq}'
    if used:
        return 'REMAP', f'cyc {"huc=%d can=%d (delta %+d)" % (hrow, crow, d)} | zp/stack remap only'
    if d != 0:
        return 'TIMING', f'huc={hrow}cyc can={crow}cyc (delta {d:+d})'
    return 'IDENTICAL', ''


def suite_compare_canonical(t, groups):
    """Lightweight WDC suite-compare for the canonical core (sanity check)."""
    exp = t['cycles']; ncyc = len(exp)
    if ncyc > W:
        return [f'ncyc {ncyc} > window']
    fails = []
    for c in range(ncyc):
        bus = groups[c][0]
        ea, ev, et = exp[c]
        if bus_addr(bus) != ea:
            fails.append(f'c{c} addr {bus_addr(bus):04X}!={ea:04X}')
        if (bus[4] == 'W') != (et == 'write'):
            fails.append(f'c{c} rw {bus[4]}!={et}')
        if int(bus[5:7], 16) != ev:
            fails.append(f'c{c} data {int(bus[5:7],16):02X}!={ev:02X}')
    return fails


def run_sim(cmd, cwd, timeout):
    env = dict(os.environ)
    env['PATH'] = r'C:\msys64\ucrt64\bin' + os.pathsep + env.get('PATH', '')
    return subprocess.run(cmd, capture_output=True, text=True, env=env, cwd=cwd,
                          timeout=timeout)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--suite', default='wdc65c02')
    ap.add_argument('--ops', default='all')
    ap.add_argument('--sample', type=int, default=20)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--root', default=REPO_DEFAULT)
    ap.add_argument('--no-sim', action='store_true', help='reuse existing result files')
    ap.add_argument('--ghdl-timeout', type=int, default=1800)
    ap.add_argument('--veri-timeout', type=int, default=600)
    args = ap.parse_args()

    ops = ['%02x' % i for i in range(256)] if args.ops == 'all' else \
          [o.strip().lower() for o in args.ops.split(',')]

    selected = []
    for op in ops:
        tests = load_tests(args.root, args.suite, op)
        if not tests:
            continue
        rng = random.Random(args.seed * 1000 + int(op, 16))
        sel = rng.sample(tests, min(args.sample, len(tests)))
        selected.extend((op, t) for t in sel)
    print(f'selected {len(selected)} tests across {len(ops)} opcodes')

    make_batch([t for _, t in selected], BATCH)
    print(f'batch -> {BATCH}')

    if not args.no_sim:
        # --- HUC6280 (GHDL) ---
        print('building + running HUC6280 (GHDL)...')
        for s in GHDL_SRC:
            r = run_sim([GHDL_BIN, '-a', s], WORK, 300)
            if r.returncode != 0:
                print('GHDL analyze failed:', r.stderr[-500:]); sys.exit(1)
        r = run_sim([GHDL_BIN, '-e', 'huc6280_sst_tb'], WORK, 300)
        if r.returncode != 0:
            print('GHDL elaborate failed:', r.stderr[-500:]); sys.exit(1)
        r = run_sim([GHDL_BIN, '-r', 'huc6280_sst_tb'], WORK, args.ghdl_timeout)
        if r.returncode != 0:
            print('GHDL run failed:', r.stderr[-500:]); sys.exit(1)
        # --- canonical (Verilator) ---
        print('running canonical 65C02 (Verilator)...')
        r = run_sim([VERI_BIN, f'+TESTS={BATCH}', f'+OUT={CAN_TXT}'], WORK,
                    args.veri_timeout)
        if r.returncode != 0:
            print('Verilator run failed:', r.stdout[-500:], r.stderr[-500:]); sys.exit(1)
        # gzip the (large) plain-text results for a small commit
        for txt, gz in ((HUC_TXT, HUC_RES), (CAN_TXT, CAN_RES)):
            if os.path.exists(txt):
                gzip_file(txt, gz)

    huc = parse_results(HUC_RES)
    can = parse_results(CAN_RES)
    print(f'parsed: huc={len(huc)} can={len(can)}')

    cat = collections.Counter()
    per_op = collections.defaultdict(collections.Counter)
    examples = collections.defaultdict(list)
    can_pass = can_fail = 0
    can_fail_detail = []
    timing_deltas = collections.Counter()

    for idx, (op, t) in enumerate(selected):
        hg = huc.get(idx); cg = can.get(idx)
        if hg is None or cg is None:
            cat['NORESULT'] += 1; per_op[op]['NORESULT'] += 1
            continue
        c, detail = cross_compare(t, hg, cg)
        cat[c] += 1; per_op[op][c] += 1
        if c in ('TIMING', 'REMAP'):
            # extract the cycle delta from the detail string
            try:
                d = int(detail.split('delta ')[1].split(')')[0])
                timing_deltas[d] += 1
            except Exception:
                pass
        if c != 'IDENTICAL' and len(examples[c]) < 6:
            examples[c].append((idx, op, t.get('name', ''), detail,
                                t['initial']['pc'], t['final']['pc']))
        # canonical suite-compare (sanity)
        sf = suite_compare_canonical(t, cg)
        if sf:
            can_fail += 1
            if len(can_fail_detail) < 8:
                can_fail_detail.append((idx, op, t.get('name', ''), sf[:4]))
        else:
            can_pass += 1

    total = len(selected)
    lines = []
    lines.append(f'HUC6280 vs canonical 65C02 — cross-comparison')
    lines.append(f'tests={total} ops={len(ops)} sample={args.sample} seed={args.seed}')
    lines.append('')
    lines.append('=== category totals ===')
    for k in ('IDENTICAL', 'REMAP', 'TIMING', 'STATE', 'BUS', 'NOFETCH', 'NORESULT'):
        if cat[k]:
            lines.append(f'  {k:10s} {cat[k]:5d}  ({100*cat[k]/total:5.1f}%)')
    lines.append('')
    lines.append('=== per-opcode (id/remap/time/state/bus/nofetch of total) ===')
    for op in ops:
        if op not in per_op:
            continue
        e = per_op[op]
        lines.append(f'  {op}: {e.get("IDENTICAL",0)}/{sum(e.values())} id, '
                     f'remap={e.get("REMAP",0)} time={e.get("TIMING",0)} '
                     f'state={e.get("STATE",0)} bus={e.get("BUS",0)} '
                     f'nofetch={e.get("NOFETCH",0)}')
    lines.append('')
    lines.append('=== timing deltas (huc - can cycles) ===')
    for d in sorted(timing_deltas):
        lines.append(f'  {d:+d}: {timing_deltas[d]}')
    lines.append('')
    lines.append('=== examples of differences ===')
    for c in ('REMAP', 'TIMING', 'STATE', 'BUS', 'NOFETCH'):
        if not examples[c]:
            continue
        lines.append(f'-- {c} --')
        for idx, op, name, detail, ipc, fpc in examples[c]:
            lines.append(f'  #{idx} op={op} [{name}] pc {ipc:04X}->{fpc:04X}')
            lines.append(f'     {detail}')
    lines.append('')
    lines.append(f'=== canonical core vs WDC (sanity): {can_pass}/{can_pass+can_fail} pass ===')
    for idx, op, name, sf in can_fail_detail:
        lines.append(f'  #{idx} op={op} [{name}]')
        for m in sf:
            lines.append(f'     {m}')

    report = '\n'.join(lines)
    with open(REPORT, 'w', newline='\n') as f:
        f.write(report + '\n')
    print('\n' + report)
    print(f'\nreport -> {REPORT}')


if __name__ == '__main__':
    main()
