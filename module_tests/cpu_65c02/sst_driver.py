#!/usr/bin/env python3
"""65x02 single-step test driver for cpu_65c02 (new GameKing 65C02 core).

Loads SingleStepTests/65x02 scenarios, writes a batch file for
cpu65_sst_tb.sv, runs the Verilator binary, and compares:
  * per-cycle bus operations (address, read/write, data) for the expected
    cycle count of each test,
  * illegal memory accesses (addresses outside initial.ram | final.ram),
  * instruction completion (next opcode fetch at the expected final PC),
  * final register state (P compared with bits 7/4 masked).

Usage:
  python sst_driver.py --suite wdc65c02 --ops a9,f0 --sample 100 --seed 1 \
      --bin module_tests/cpu_65c02/build/sst_verilog/Vcpu65_sst_tb.exe \
      [--root E:/MiSTer/Apple-II_FPGAdev]
"""
import argparse, json, os, random, subprocess, sys

REPO_DEFAULT = r'E:\MiSTer\Apple-II_FPGAdev\65x02'   # local checkout of SingleStepTests/65x02
MASK_PB = 0x6F          # keep N,V,D,I,Z,C; mask R(bit7)/B(bit4)
W = 16                  # must match TB capture window

def load_tests(root, suite, op):
    path = os.path.join(root, suite, 'v1', f'{op}.json')
    try:
        with open(path) as f:
            data = json.load(f)
        return data
    except (FileNotFoundError, json.JSONDecodeError):
        return []   # some opcodes ship empty files (e.g. wdc cb/db)

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
    # line: R <idx> <bus0> <regs0><bus1> <regs1><bus2> ... <regs14><bus15> <regs15>
    # (bus token and its register snapshot are space-separated; the snapshot
    #  runs directly into the next bus token)
    res = {}
    with open(path) as f:
        for line in f:
            if not line.startswith('R '):
                continue
            parts = line.split()
            if len(parts) != 2 + W + 1:       # R, idx, bus0, (regsN+busN+1)x15, regs15
                continue
            idx = int(parts[1])
            groups = []
            bus0 = parts[2]
            regs = [None] * W
            for c in range(1, W):
                tok = parts[2 + c]
                regs[c - 1] = tok[:14]
            regs[W - 1] = parts[2 + W - 1]
            bus = [bus0] + [parts[2 + c][-7:] for c in range(1, W)]
            groups = list(zip(bus, regs))
            res[idx] = groups
    return res

def compare(test, groups, final_offset=0):
    """Return list of failure strings (empty = pass).

    Checks, per test:
      * per-cycle bus operations (addr, read/write, data) for the expected
        cycle count,
      * illegal memory accesses (addresses outside initial.ram | final.ram),
      * instruction completion: row ncyc (the row of the next opcode
        fetch, independent of final_offset, which only shifts the register
        sampling row for R65Cx2's late A/flag commit) must be a READ at
        the expected final PC. Catches instructions that overrun the
        suite's expected cycle count (stray post-instruction activity the
        per-cycle comparison never sees) and confirms the bus actually
        reached the final PC,
      * final register state (P compared with bits 7/4 masked),
      * final RAM at the listed addresses.
    """
    fails = []
    exp_cyc = test['cycles']
    ncyc = len(exp_cyc)
    allowed = {a for a, _ in test['initial']['ram']} | {a for a, _ in test['final']['ram']}

    if ncyc > W:
        return [f'cycle count {ncyc} exceeds capture window {W}']

    # simulate final RAM from initial + observed writes
    ram = {a: v for a, v in test['initial']['ram']}

    for c in range(ncyc):
        bus, _ = groups[c]
        addr = int(bus[0:4], 16)
        rw = bus[4]
        data = int(bus[5:7], 16)
        ea, ev, et = exp_cyc[c]
        if addr != ea:
            fails.append(f'cyc{c}: addr {addr:04X} != expected {ea:04X}')
        if (rw == 'W') != (et == 'write'):
            fails.append(f'cyc{c}: rw {rw} != expected {et}')
        if data != ev:
            fails.append(f'cyc{c}: data {data:02X} != expected {ev:02X}')
        if addr not in allowed:
            fails.append(f'cyc{c}: illegal access {addr:04X}')
        if rw == 'W':
            ram[addr] = data

    # final register state at snapshot[ncyc + final_offset]
    # (R65Cx2 commits A/X/Y/S/P on the next opcodeFetch -> offset 1)
    _, regs = groups[min(ncyc + final_offset, W - 1)]
    f = test['final']
    # regs string: pc(4) sp(2) a(2) x(2) y(2) p(2)
    pc = int(regs[0:4], 16); sp = int(regs[4:6], 16); a = int(regs[6:8], 16)
    x = int(regs[8:10], 16); y = int(regs[10:12], 16); p = int(regs[12:14], 16)
    if pc != f['pc']: fails.append(f'final pc {pc:04X} != {f["pc"]:04X}')
    if sp != f['s']:  fails.append(f'final sp {sp:02X} != {f["s"]:02X}')
    if a  != f['a']:  fails.append(f'final a  {a:02X} != {f["a"]:02X}')
    if x  != f['x']:  fails.append(f'final x  {x:02X} != {f["x"]:02X}')
    if y  != f['y']:  fails.append(f'final y  {y:02X} != {f["y"]:02X}')
    if (p & MASK_PB) != (f['p'] & MASK_PB):
        fails.append(f'final p {p:02X} != {f["p"]:02X} (masked)')

    # instruction-complete check (see docstring): the next opcode fetch
    # always lands on row ncyc; final_offset only shifts the register row.
    if ncyc < W:
        bus, _ = groups[ncyc]
        if bus[4] != 'R' or int(bus[0:4], 16) != f['pc']:
            fails.append('complete: row %d not a fetch at final pc %04X '
                         '(got %04X/%s)' % (ncyc, f['pc'],
                                            int(bus[0:4], 16), bus[4]))

    # final RAM at listed addresses
    for addr, val in test['final']['ram']:
        if ram.get(addr) != val:
            fails.append(f'final ram[{addr:04X}] = {ram.get(addr)} != {val}')
    return fails

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--suite', default='wdc65c02')
    ap.add_argument('--ops', default='a9', help='comma list or "all"')
    ap.add_argument('--sample', type=int, default=100)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--bin', required=True)
    ap.add_argument('--root', default=REPO_DEFAULT)
    ap.add_argument('--workdir',
                    default=r'E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer')
    ap.add_argument('--max-fail-detail', type=int, default=3)
    ap.add_argument('--final-offset', type=int, default=0,
                    help='rows after ncyc to read the final register state')
    args = ap.parse_args()

    build = os.path.join(args.workdir, 'module_tests', 'cpu_65c02', 'build')
    batch = os.path.join(build, 'sst_batch.txt')
    results = os.path.join(build, 'sst_results.txt')

    ops = ['%02x' % i for i in range(256)] if args.ops == 'all' else \
          [o.strip().lower() for o in args.ops.split(',')]

    selected = []   # (op, test)
    for op in ops:
        try:
            tests = load_tests(args.root, args.suite, op)
        except FileNotFoundError:
            print(f'!! {args.suite}/v1/{op}.json missing'); continue
        rng = random.Random(args.seed * 1000 + int(op, 16))
        sel = rng.sample(tests, min(args.sample, len(tests)))
        selected.extend((op, t) for t in sel)

    make_batch([t for _, t in selected], batch)
    print(f'batch: {len(selected)} tests -> {batch}')

    env = dict(os.environ)
    env['PATH'] = r'C:\msys64\ucrt64\bin' + os.pathsep + env.get('PATH', '')
    r = subprocess.run([args.bin, f'+TESTS={batch}', f'+OUT={results}'],
                       capture_output=True, text=True, env=env, cwd=args.workdir)
    if r.returncode != 0:
        print('SIMULATION FAILED'); print(r.stdout[-2000:]); print(r.stderr[-2000:]); sys.exit(1)

    res = parse_results(results)
    print(f'results parsed: {len(res)}')

    total = passed = 0
    per_op = {}
    for idx, (op, t) in enumerate(selected):
        total += 1
        groups = res.get(idx)
        if groups is None or len(groups) < W:
            per_op.setdefault(op, [0, 0, []])[2].append((idx, ['no result line']))
            continue
        fails = compare(t, groups, args.final_offset)
        entry = per_op.setdefault(op, [0, 0, []])
        if fails:
            entry[1] += 1
            if len(entry[2]) < args.max_fail_detail:
                entry[2].append((idx, fails[:8]))
        else:
            entry[0] += 1
            passed += 1

    print(f'\n=== {args.suite}: {passed}/{total} pass ===')
    for op in ops:
        if op not in per_op: continue
        p, fl, details = per_op[op]
        n = p + fl
        tag = 'PASS' if fl == 0 else f'FAIL {fl}/{n}'
        print(f'  {op}: {tag}')
        for idx, fails in details:
            t = selected[idx][1]
            print(f'    #{idx} [{t["name"]}]')
            for msg in fails:
                print(f'      {msg}')

if __name__ == '__main__':
    main()
