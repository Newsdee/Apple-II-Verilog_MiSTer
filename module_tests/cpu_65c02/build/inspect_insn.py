import csv, sys

def load(p):
    with open(p) as f:
        rows = list(csv.reader(f))
    return rows[0], rows[1:]

gh, gr = load('module_tests/r65c02/build/verilog_trace.csv')
nh, nr = load('module_tests/cpu_65c02/build/r65_trace.csv')
gi = {n: i for i, n in enumerate(gh)}
ni = {n: i for i, n in enumerate(nh)}

def fetches(rows, idx):
    return [(int(r[idx['CYCLE']]), r[idx['ADDR']], r[idx['DI']]) for r in rows if r[idx['SYNC']] == '1']

gf = fetches(gr, gi)
nf = fetches(nr, ni)

def show(row, idx):
    return (f"  {row[idx['CYCLE']]}: PC={row[idx['PC']]} SP={row[idx['SP']]} "
            f"N={row[idx['P_N']]} Z={row[idx['P_Z']]} C={row[idx['P_C']]} V={row[idx['P_V']]} "
            f"B={row[idx['P_B']]} I={row[idx['P_I']]} A={row[idx['A']]} X={row[idx['X']]} Y={row[idx['Y']]} "
            f"ADDR={row[idx['ADDR']]} DI={row[idx['DI']]} DO={row[idx['DO']]} RW={row[idx['RW']]} SYNC={row[idx['SYNC']]}")

targets = [int(t) for t in sys.argv[1:]] or [94, 172, 188, 189, 246]
for i in targets:
    print(f'=== insn #{i}: G fetch cyc {gf[i][0]} @ {gf[i][1]} op {gf[i][2]} | N fetch cyc {nf[i][0]} @ {nf[i][1]} op {nf[i][2]}')
    g0, g1 = gf[i][0], gf[i + 1][0]
    n0, n1 = nf[i][0], nf[i + 1][0]
    print('  G rows:')
    for r in range(g0, min(g1 + 2, len(gr))):
        print(show(gr[r], gi))
    print('  N rows:')
    for r in range(n0, min(n1 + 2, len(nr))):
        print(show(nr[r], ni))
    print()
