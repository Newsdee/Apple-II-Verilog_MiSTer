import csv, sys
from collections import Counter

def load(p):
    with open(p) as f:
        rows = list(csv.reader(f))
    return rows[0], rows[1:]

def analyze(gpath, npath, tag):
    gh, gr = load(gpath)
    nh, nr = load(npath)
    gi = {n: i for i, n in enumerate(gh)}
    ni = {n: i for i, n in enumerate(nh)}
    print(f'===== {tag}: G rows={len(gr)} N rows={len(nr)}')

    # fetches = rows where ADDR == PC (instruction stream)
    def fetches(rows, idx):
        out = []
        for r in rows:
            if r[idx['ADDR']] == r[idx['PC']]:
                out.append((int(r[idx['CYCLE']]), r[idx['ADDR']], r[idx['DI']]))
        return out
    gf = fetches(gr, gi)
    nf = fetches(nr, ni)
    print(f'fetch events (ADDR==PC): G={len(gf)} N={len(nf)}')
    m = min(len(gf), len(nf))
    mism = [(i, gf[i], nf[i]) for i in range(m) if gf[i][1:] != nf[i][1:]]
    print(f'aligned pairs={m} opcode/addr mismatches={len(mism)}')
    if mism[:5]:
        for i, a, b in mism[:5]:
            print(f'  first mismatch at pair {i}: G cyc{a[0]} @{a[1]} op{a[2]} | N cyc{b[0]} @{b[1]} op{b[2]}')

    # per-instruction cycle lengths, bucketed by opcode
    diff = Counter(); same = {}
    for i in range(m - 1):
        op = int(gf[i][2], 16)
        lg = gf[i + 1][0] - gf[i][0]
        ln = nf[i + 1][0] - nf[i][0]
        if lg != ln:
            diff[op] += 1
            if op not in same:
                same[op] = (gf[i][0], gf[i][1], lg, ln)
        else:
            same.setdefault(op, None)
            if op not in same or same[op] is None:
                pass
    # track a matching example length per opcode
    matchlen = {}
    for i in range(m - 1):
        op = int(gf[i][2], 16)
        lg = gf[i + 1][0] - gf[i][0]
        ln = nf[i + 1][0] - nf[i][0]
        if lg == ln and op not in matchlen:
            matchlen[op] = lg
    print('opcode classes with DIFFERING cycle counts:')
    for op, cnt in sorted(diff.items()):
        gcyc, addr, lg, ln = same[op]
        print(f'  op {op:02x}: {cnt}x  G={lg} N={ln}  first @Gcyc {gcyc} (addr {addr})')
    if not diff:
        print('  (none)')

    # final memory from writes
    def final_mem(rows, idx):
        mem = {}
        for r in rows:
            if r[idx['RW']] == '0':
                mem[int(r[idx['ADDR']], 16)] = int(r[idx['DO']], 16)
        return mem
    mg, mn = final_mem(gr, gi), final_mem(nr, ni)
    alladdrs = set(mg) | set(mn)
    dm = {a: (mg.get(a), mn.get(a)) for a in alladdrs if mg.get(a) != mn.get(a)}
    print(f'memory written: G={len(mg)} N={len(mn)}; final diffs={len(dm)}')
    for a, (g, n) in sorted(dm.items())[:10]:
        print(f'  ${a:04X}: G={g:#04x} N={n:#04x}')

    # end state
    gl, nl = gr[-1], nr[-1]
    print('end state:')
    for name in ('PC', 'SP', 'P', 'Y', 'X', 'A'):
        gv, nv = gl[gi[name]], nl[ni[name]]
        print(f'  {name}: G={gv} N={nv} {"OK" if gv == nv else "**DIFF**"}')
    print(f'  last fetch delta: G cyc{gf[m-1][0]} @{gf[m-1][1]} | N cyc{nf[m-1][0]} @{nf[m-1][1]} | {gf[m-1][0]-nf[m-1][0]:+d}')
    print()

analyze('module_tests/t65/build/verilog_prog.csv', 'module_tests/cpu_65c02/build/t65_prog_trace.csv', 't65 phase A (directed program, 320 cyc)')
analyze('module_tests/t65/build/verilog_boot.csv', 'module_tests/cpu_65c02/build/t65_boot_trace.csv', 't65 phase B (apple2e boot walk, 500 cyc)')
