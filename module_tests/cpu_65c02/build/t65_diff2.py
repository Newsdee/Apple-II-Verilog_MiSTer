import csv
from collections import Counter

# --- load program bytes from the generated RAM image -----------------------
prog = {}
with open('module_tests/t65/build/t65_ram_init_lf.hex') as f:
    for i, line in enumerate(f):
        base = i * 16
        for j, b in enumerate(line.split()):
            prog[base + j] = int(b, 16)

START = 0x0500
END = 0x0580          # park loop

# classic 6502 opcode sizes (mode "00" = pure 6502)
ONE = {0x0A,0x4A,0x08,0x28,0x68,0x8A,0x2A,0x6A,0xEA,0xA8,0xAA,0x98,0xBA,
       0xCA,0xE8,0xC8,0x88,0x18,0x38,0x58,0xB8,0xD8,0xF8,0x40,0x48,0xDA,
       0xFA,0x5A,0x7A,0x9A}
THREE = {0x20, 0x4C, 0x6C, 0x7C}
SIZE = {}
for op in range(256):
    cc, bbb = op & 3, (op >> 2) & 7
    if op in ONE:
        SIZE[op] = 1
    elif op in THREE or (cc == 0 and bbb == 3) or (cc == 1 and bbb in (3, 4, 6, 7)) or (cc == 2 and bbb == 3):
        SIZE[op] = 3
    else:
        SIZE[op] = 2   # zp / imm / branch / BRK

# decode instruction list
insns = []
a = START
while a < END:
    op = prog[a]
    ln = SIZE.get(op, 2)
    insns.append((a, op, ln))
    a += ln
print(f'program: {len(insns)} instructions at ${START:04X}-${insns[-1][0]:04X}')
ops = Counter(i[1] for i in insns)
print('opcode histogram:', ' '.join(f'{op:02x}:{c}' for op, c in sorted(ops.items())))

def load(p):
    with open(p) as f:
        rows = list(csv.reader(f))
    return rows[0], rows[1:]

def analyze(gpath, npath, tag):
    gh, gr = load(gpath)
    nh, nr = load(npath)
    gi = {n: i for i, n in enumerate(gh)}
    ni = {n: i for i, n in enumerate(nh)}

    # greedy ordered match of opcode fetches
    def match(rows, idx):
        ev = []          # (cycle, insn_index)
        k = 0
        for r in rows:
            if k >= len(insns):
                break
            a, op, ln = insns[k]
            if r[idx['ADDR']] == '%04x' % a and r[idx['DI']] == '%02x' % op:
                ev.append((int(r[idx['CYCLE']]), k))
                k += 1
        return ev
    ge = match(gr, gi)
    ne = match(nr, ni)
    print(f'\n===== {tag}')
    print(f'matched instructions: G={len(ge)}/{len(insns)} N={len(ne)}/{len(insns)}')
    m = min(len(ge), len(ne))
    bad = [i for i in range(m) if ge[i][1] != ne[i][1]]
    print(f'aligned pairs={m} index mismatches={len(bad)}')

    diff = Counter(); ex = {}
    for i in range(m - 1):
        lg = ge[i + 1][0] - ge[i][0]
        ln = ne[i + 1][0] - ne[i][0]
        op = insns[ge[i][1]][1]
        if lg != ln:
            diff[op] += 1
            ex.setdefault(op, (ge[i][0], insns[ge[i][1]][0], lg, ln))
    print('opcode classes with DIFFERING cycle counts:')
    for op, c in sorted(diff.items()):
        g0, addr, lg, ln = ex[op]
        print(f'  op {op:02x}: {c}x  G={lg} N={ln}  first @Gcyc {g0} (addr {addr:04x})')
    if not diff:
        print('  (none)')

    def final_mem(rows, idx):
        mem = {}
        for r in rows:
            if r[idx['RW']] == '0':
                mem[int(r[idx['ADDR']], 16)] = int(r[idx['DO']], 16)
        return mem
    mg, mn = final_mem(gr, gi), final_mem(nr, ni)
    dm = {a: (mg.get(a), mn.get(a)) for a in set(mg) | set(mn) if mg.get(a) != mn.get(a)}
    print(f'memory written: G={len(mg)} N={len(mn)}; final diffs={len(dm)}')
    for a, (g, n) in sorted(dm.items())[:8]:
        print(f'  ${a:04X}: G={g:#04x} N={n:#04x}')

    gl, nl = gr[-1], nr[-1]
    print('end state:')
    for name in ('PC', 'SP', 'P', 'Y', 'X', 'A'):
        gv, nv = gl[gi[name]], nl[ni[name]]
        print(f'  {name}: G={gv} N={nv} {"OK" if gv == nv else "**DIFF**"}')

analyze('module_tests/t65/build/verilog_prog.csv', 'module_tests/cpu_65c02/build/t65_prog_trace.csv', 't65 phase A (directed program)')
analyze('module_tests/t65/build/verilog_boot.csv', 'module_tests/cpu_65c02/build/t65_boot_trace.csv', 't65 phase B (apple2e boot walk)')
