import csv, sys

def load(p):
    with open(p) as f:
        rows = list(csv.reader(f))
    return rows[0], rows[1:]

def sig(r, idx):
    # write cycles: data-out matters; read cycles: data-in matters
    if r[idx['RW']] == '0':
        return ('W', r[idx['ADDR']], r[idx['DO']])
    return ('R', r[idx['ADDR']], r[idx['DI']])

def lcs_align(A, B):
    n, m = len(A), len(B)
    # DP table (n+1)x(m+1) of match counts
    dp = [[0]*(m+1) for _ in range(n+1)]
    for i in range(n-1, -1, -1):
        ai = A[i]
        row = dp[i]; rowb = dp[i+1]
        for j in range(m-1, -1, -1):
            if ai == B[j]:
                row[j] = rowb[j+1] + 1
            else:
                row[j] = max(rowb[j], row[j+1])
    # backtrack to produce alignment ops: M (match), D (A only), I (B only)
    ops = []
    i = j = 0
    while i < n and j < m:
        if A[i] == B[j]:
            ops.append(('M', i, j)); i += 1; j += 1
        elif dp[i+1][j] >= dp[i][j+1]:
            ops.append(('D', i, None)); i += 1
        else:
            ops.append(('I', None, j)); j += 1
    while i < n: ops.append(('D', i, None)); i += 1
    while j < m: ops.append(('I', None, j)); j += 1
    return ops

def analyze(gpath, npath, tag, skip_g=0, skip_n=0):
    gh, gr = load(gpath)
    nh, nr = load(npath)
    gi = {n: i for i, n in enumerate(gh)}
    ni = {n: i for i, n in enumerate(nh)}
    G = [sig(r, gi) for r in gr]
    N = [sig(r, ni) for r in nr]
    ops = lcs_align(G, N)
    matches = sum(1 for o in ops if o[0] == 'M')
    dels = sum(1 for o in ops if o[0] == 'D')
    inss = sum(1 for o in ops if o[0] == 'I')
    print(f'===== {tag}')
    print(f'G rows={len(G)} N rows={len(N)} | aligned: match={matches} G-only={dels} N-only={inss}')

    # find first run of >3 consecutive non-matches (true divergence zone)
    run = 0
    first_run_start = None
    for k, o in enumerate(ops):
        if o[0] != 'M':
            run += 1
            if run == 4 and first_run_start is None:
                first_run_start = k - 3
        else:
            run = 0
    # print context around the first divergence zone
    if first_run_start is not None:
        lo, hi = max(0, first_run_start - 6), min(len(ops), first_run_start + 24)
        print(f'first non-match run starts at op-index {first_run_start}:')
        for k in range(lo, hi):
            o = ops[k]
            if o[0] == 'M':
                i, j = o[1], o[2]
                print(f'  M G{gr[i][gi["CYCLE"]]:>4} {G[i]} | N{nr[j][ni["CYCLE"]]:>4} {N[j]}')
            elif o[0] == 'D':
                i = o[1]
                print(f'  D G{gr[i][gi["CYCLE"]]:>4} {G[i]} (G-only)')
            else:
                j = o[2]
                print(f'  I N{nr[j][ni["CYCLE"]]:>4} {N[j]} (N-only)')
    else:
        print('no divergence zone found — sequences fully compatible')
    # tail stats: last 8 ops
    print('tail:', ' '.join(o[0] for o in ops[-12:]))
    print()

analyze('module_tests/t65/build/verilog_prog.csv', 'module_tests/cpu_65c02/build/t65_prog_trace.csv', 't65 phase A (directed program)')
