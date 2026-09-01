import csv

def load(p):
    with open(p) as f:
        rows = list(csv.reader(f))
    return rows[0], rows[1:]

gh, gr = load('module_tests/r65c02/build/verilog_trace.csv')
nh, nr = load('module_tests/cpu_65c02/build/r65_trace.csv')
gi = {n: i for i, n in enumerate(gh)}
ni = {n: i for i, n in enumerate(nh)}

# --- 1. reconstruct final memory from write transactions -------------------
def final_mem(rows, idx):
    mem = {}
    for r in rows:
        if r[idx['RW']] == '0':
            a = int(r[idx['ADDR']], 16)
            mem[a] = int(r[idx['DO']], 16)
    return mem

mg = final_mem(gr, gi)
mn = final_mem(nr, ni)
alladdrs = set(mg) | set(mn)
diffs = {a: (mg.get(a), mn.get(a)) for a in alladdrs if mg.get(a) != mn.get(a)}
print(f'memory addresses written: G={len(mg)} N={len(mn)}')
if diffs:
    print('FINAL MEMORY DIFFERS at:')
    for a, (g, n) in sorted(diffs.items()):
        print(f'  ${a:04X}: G={g:#04x} N={n:#04x}')
else:
    print('FINAL MEMORY IDENTICAL (every written address, every final value)')

# --- 2. NMI region ----------------------------------------------------------
def fetches(rows, idx):
    return [(int(r[idx['CYCLE']]), r[idx['ADDR']], r[idx['DI']]) for r in rows if r[idx['SYNC']] == '1']

print()
print('--- rows around NMI (G cyc 760-800) ---')
for r in range(760, 800):
    row = gr[r]
    tag = ' SYNC' if row[gi['SYNC']] == '1' else ''
    print(f"G {row[gi['CYCLE']]}: PC={row[gi['PC']]} SP={row[gi['SP']]} I={row[gi['P_I']]} B={row[gi['P_B']]} "
          f"ADDR={row[gi['ADDR']]} DI={row[gi['DI']]} DO={row[gi['DO']]} RW={row[gi['RW']]}{tag} NMI_N={row[gi['NMI_N']]}")
print('--- rows around NMI (N cyc 758-798) ---')
for r in range(758, 798):
    row = nr[r]
    tag = ' SYNC' if row[ni['SYNC']] == '1' else ''
    print(f"N {row[ni['CYCLE']]}: PC={row[ni['PC']]} SP={row[ni['SP']]} I={row[ni['P_I']]} B={row[ni['P_B']]} "
          f"ADDR={row[ni['ADDR']]} DI={row[ni['DI']]} DO={row[ni['DO']]} RW={row[ni['RW']]}{tag} NMI_N={row[ni['NMI_N']]}")
