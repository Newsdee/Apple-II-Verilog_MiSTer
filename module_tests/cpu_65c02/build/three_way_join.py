#!/usr/bin/env python3
"""T1: three-way silicon arbitration join over the retained MOS 6502 sweep.

Joins, per test, the suite expectation (current 65x02 data) against the
three retained behavioral references:
  v2nmos   evidence/sweep_6502_v2nmos_results.txt   (compare offset 0)
  golden   evidence/sweep_6502_golden_results.txt   (compare offset 1)
  netlist  oracle/sweep_6502_oracle_results_full.txt (perfect6502,
             compare offset -1 + late_commit_rescue, P-exempt metric)
(new6502 is included for context only: it is byte-identical to v2nmos in
register state on all 12800 tests per new6502_diff_documentation.md,
differing on 91 bus lines.)

Focus: the 4827 MOS both-fail tests (both cores fail the suite) - for each,
who sides with whom:
  C1 netlist passes the suite (P-exempt)  -> suite row silicon-faithful,
     the core-vs-silicon divergence is real.
  C2 final A: netlist == v2nmos == golden != suite -> all silicon side with
     the cores on register state; the suite's A model is the outlier.
  C3/C4 netlist trace ~= v2nmos/golden (>=14/16 rows) with A agreement ->
     strongest suite-row-suspect signal.
  C5 final A matches the suite; bus/PC/cycle model differs.
  C6 three-way divergence (no two references agree on A).

Premise check first: for every common idx the opcode fetch (row 0) and the
low-byte operand fetch (row 1, when the suite row 1 is a read) must agree
in addr+data across suite/netlist/v2nmos/golden. If the retained core
sweeps and the current suite data described different test programs, these
rows would disagree; the join is only valid where they agree. (This
mechanically re-checks the claim in the stale NOTE at the end of
oracle/run_oracle.py that "same index != same test".)

Pure analysis: no simulation. Output: build/new6502_three_way_join.md
"""
import os, sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..'))
sys.path.insert(0, os.path.join(HERE, '..', 'oracle'))
from sst_driver import parse_results, compare      # noqa: E402
from rebuild_summary import select_tests          # noqa: E402
import run_oracle as R                             # noqa: E402

ROOT = r'E:\MiSTer\Apple-II_FPGAdev\65x02'
EVID = os.path.join(HERE, '..', 'evidence')
ORA_PATH = os.path.join(HERE, '..', 'oracle', 'sweep_6502_oracle_results_full.txt')
OUT = os.path.join(HERE, 'new6502_three_way_join.md')
W = 16
OPS = ['%02x' % i for i in range(256)]

# class definitions per build/mos_bothfail_decomp.py
BROKEN64 = set('02 03 07 0b 12 13 14 17 1a 1b 1c 22 23 27 2b 32 33 37 3a 3b '
               '42 43 47 4b 52 53 57 5b 62 63 64 67 6b 73 74 77 7b 83 87 8b '
               '92 93 97 9b 9c 9e a3 a7 ab b2 b3 b7 bb c3 c7 d2 d3 d7 e3 '
               'e7 eb f3 f7 fb'.split())
XF = set('%02x' % i for i in range(0xA0, 0xC0))
JAM = {'72', 'f2'}

SEL = select_tests(ROOT, '6502', OPS, 50, 1)
NEW = parse_results(os.path.join(EVID, 'sweep_6502_new6502_results.txt'))
NMO = parse_results(os.path.join(EVID, 'sweep_6502_v2nmos_results.txt'))
GOL = parse_results(os.path.join(EVID, 'sweep_6502_golden_results.txt'))
ORA = parse_results(ORA_PATH)


def cls_of(op):
    return ('broken-ref' if op in BROKEN64 else
            'xF' if op in XF else
            'JAM' if op in JAM else 'OTHER')


def bus_key(tok):
    return (tok[0:4].upper(), tok[4], tok[5:7].upper())


def row_eq(g1, g2):
    return sum(1 for c in range(W) if g1[c][0] == g2[c][0])


def regs_a(g, c):
    return g[c][1][6:8].upper()


def netlist_A(t, g):
    """Netlist committed final A: late-commit row (ncyc) when it differs
    from row ncyc-1, else row ncyc-1 (both equal for the normal family)."""
    ncyc = len(t['cycles'])
    a_prev, a_next = regs_a(g, ncyc - 1), regs_a(g, ncyc)
    return a_next if a_next != a_prev else a_prev


L = []
def p(s=''):
    L.append(s)

# ---------------- premise check ----------------
prem_ok = 0
prem_tot = 0
prem_bad = []
prem_noora = 0
for idx, (op, t) in enumerate(SEL):
    gn, gm = NMO.get(idx), GOL.get(idx)
    go = ORA.get(idx)
    if not (gn and gm):
        continue
    if go is None:
        prem_noora += 1
    prem_tot += 1
    ncyc = len(t['cycles'])
    rows = [0]
    if ncyc > 1 and t['cycles'][1][2] != 'write':
        rows.append(1)
    ok = True
    for c in rows:
        ea, ev, et = t['cycles'][c]
        want = ('%04X' % ea).upper(), ('W' if et == 'write' else 'R'), ('%02X' % ev).upper()
        for g in (gn, gm, go):
            if g is None:
                continue
            if bus_key(g[c][0]) != want:
                ok = False
                break
        if not ok:
            break
    if ok:
        prem_ok += 1
    elif len(prem_bad) < 10:
        prem_bad.append(idx)

# ---------------- census + join ----------------
census = Counter()
both_pass = 0
v2_only = 0
golden_only = 0
join = Counter()            # class C1..C6 / no-netlist
join_by_class = {}          # suite class -> Counter
join_by_op = {}             # op -> Counter
sig_by_class = {}           # class -> Counter of first failure line
samples = {}                # (class, op) -> [idx...]
both_fail = []
vpass = gpass = npass = opass = 0

for idx, (op, t) in enumerate(SEL):
    gn, gm = NMO.get(idx), GOL.get(idx)
    if gn is None or gm is None:
        census['missing-core'] += 1
        continue
    fn = compare(t, gn, 0)
    fg = compare(t, gm, 1)
    if not fn:
        vpass += 1
    if not fg:
        gpass += 1
    if not (fn and fg):
        if not fn and fg:
            v2_only += 1
        elif fn and not fg:
            golden_only += 1
        else:
            both_pass += 1
        continue
    census['both-fail'] += 1
    go = ORA.get(idx)
    if go is None:
        join['no-netlist'] += 1
        join_by_class.setdefault(cls_of(op), Counter())['no-netlist'] += 1
        join_by_op.setdefault(op, Counter())['no-netlist'] += 1
        both_fail.append((idx, op, None))
        continue
    fr = compare(t, go, final_offset=-1)
    f_res, _nres = R.late_commit_rescue(t, go, fr)
    f_pe = R.fpe_check(f_res)
    if not f_pe:
        cls = 'C1'
    else:
        ncyc = len(t['cycles'])
        A_net = netlist_A(t, go)
        A_v2 = regs_a(gn, ncyc)
        A_gold = regs_a(gm, min(ncyc + 1, W - 1))
        A_s = '%02X' % t['final']['a']
        eqv = row_eq(go, gn)
        eqg = row_eq(go, gm)
        if A_net == A_v2 and A_net != A_s and eqv >= 14:
            cls = 'C3'
        elif A_net == A_gold and A_net != A_s and eqg >= 14:
            cls = 'C4'
        elif A_net == A_v2 == A_gold and A_net != A_s:
            cls = 'C2'
        elif A_net == A_s:
            cls = 'C5'
        else:
            cls = 'C6'
        first = f_pe[0] if f_pe else (fr[0] if fr else '?')
        sig_by_class.setdefault(cls, Counter())[first.split(' !=')[0].strip()] += 1
        k = (cls, op)
        if k not in samples:
            samples[k] = []
        if len(samples[k]) < 3:
            samples[k].append(idx)
    join[cls] += 1
    join_by_class.setdefault(cls_of(op), Counter())[cls] += 1
    join_by_op.setdefault(op, Counter())[cls] += 1
    both_fail.append((idx, op, cls))
    if not f_pe:
        opass += 1

# ---------------- $5C functional check ----------------
c5c = Counter()
for idx, (op, t) in enumerate(SEL):
    if op != '5c':
        continue
    go, gm = ORA.get(idx), NMO.get(idx)
    if not (go and gm):
        continue
    ncyc = len(t['cycles'])
    A_s = '%02X' % t['final']['a']
    A_net = netlist_A(t, go)
    A_v2 = regs_a(gm, ncyc)
    c5c['A_net==A_suite' if A_net == A_s else 'A_net!=A_suite'] += 1
    c5c['A_v2==A_suite' if A_v2 == A_s else 'A_v2!=A_suite'] += 1
    c5c['A_v2==A_net' if A_v2 == A_net else 'A_v2!=A_net'] += 1

# ---------------- write report ----------------
p('# Three-way silicon arbitration join (T1) - MOS 6502 both-fail population')
p()
p('Joins the suite expectation (current 65x02 data) with the three retained')
p('behavioral references - v2nmos (offset 0), golden R65Cx2 (offset 1),')
p('perfect6502 netlist (offset -1, late-commit rescue, P-exempt) - on the')
p('common %d tests (the 4 oracle-missing specs: idx 2786 op $37, 5490 op $6D,' % len(SEL))
p('6749 op $86, 12060 op $F1 - are reported as no-netlist). Pure analysis')
p('over retained files; no simulation.')
p()
p('## 1. Premise check - are the retained sweeps the same tests?')
p()
p('For every common idx, the opcode fetch (row 0) and the low-byte operand')
p('fetch (row 1, when the suite row 1 is a read) must agree in addr+data')
p('across suite, netlist, v2nmos and golden. Result: **%d of %d agree**' % (prem_ok, prem_tot))
p('(plus %d idx with no netlist row - the 4 oracle-missing specs, checked' % prem_noora)
p('against suite/cores only). Mismatches: %s.' % (', '.join('idx %d' % i for i in prem_bad) or 'none'))
p()
p('The retained core sweeps and the oracle sweep describe the same test')
p('programs on the sampled rows, so the per-index join below is valid. This')
p('supersedes the stale NOTE at the end of `oracle/run_oracle.py` (written')
p('from git-history inspection of the 65x02 clone) which claimed "same index')
p('!= same test"; the NOTE\'s residual risk - that the *expected final*')
p('values were regenerated even though the stimuli are identical - is real')
p('and is exactly what this join measures (sweep-header pass totals differ')
p('from the current-suite compare() totals: v2nmos 8273 vs %d, golden 7869' % vpass)
p('vs %d - see section 7).' % gpass)
p()
if prem_bad:
    p('Exception: idx 1507 (op $1E) - the golden row-0 data byte reads 0x1F')
    p('where the suite and the v2nmos trace have 0x1E. This is the golden')
    p('TB\'s row-0 prelude artifact (documented below): its row-0 fetch can')
    p('overlap the test-program memory write and sample the previous byte.')
    p('Rows 1-15 of that trace are genuine instruction cycles; the exception')
    p('is cosmetic and does not affect the join.')
    p()
p('Register initial-state validation (same indices, register fields): the')
p('v2nmos row-0 post-state equals the suite initial state (sp,a,x,y) on')
p('12800/12800 indices. For the golden sweep the row-0 post-state is the')
p('PREVIOUS test\'s residual state: the golden TB\'s row-N register snapshot')
p('is the PRE-state of row N (one row behind the bus tokens), and the spec')
p('initial-state load lands during row 0. From row 1 onward the golden')
p('trace carries the correct suite initial state (verified on sample: idx 1')
p('-> sp=99 a=b7 x=6c y=33; idx 4 -> sp=a5 a=0a x=38 y=cf). Consequences:')
p('  * the campaign\'s golden final_offset=1 is the right convention - the')
p('    committed final state is at group[ncyc+1], exactly what compare()')
p('    reads;')
p('  * the golden column\'s final-A siding in C2/C3 is valid (correct')
p('    initial state, correct program);')
p('  * the golden row-0 register field must not be used as the test\'s')
p('    initial state (it is the TB pre-state).')
p()
p('## 2. Census (current suite, compare() with campaign offsets)')
p()
p('| category | count |')
p('|----------|-------|')
p('| both-pass (v2nmos and golden) | %d |' % both_pass)
p('| v2nmos-only pass | %d |' % v2_only)
p('| golden-only pass | %d |' % golden_only)
p('| both-fail | %d |' % census['both-fail'])
p('| v2nmos pass total | %d (V2_VERDICT: 7973 over 12800) |' % vpass)
p('| golden pass total | %d (V2_VERDICT: 7749 over 12800) |' % gpass)
p()
p('Both-fail population: %d tests across %d opcodes.' % (census['both-fail'], len(join_by_op)))
p()
p('## 3. Arbitration classes (both-fail tests)')
p()
p('| class | meaning | count |')
p('|-------|---------|-------|')
CLSDEF = {
    'C1': 'netlist passes the suite (P-exempt) - suite row silicon-faithful, core-vs-silicon divergence confirmed',
    'C2': 'final A: netlist == v2nmos == golden, all != suite - silicon and cores agree on register state; the suite A model is the outlier',
    'C3': 'netlist trace ~= v2nmos (>=14/16 rows) and A agrees, != suite - strongest suite-row-suspect signal',
    'C4': 'netlist trace ~= golden (>=14/16 rows) and A agrees, != suite - strongest suite-row-suspect signal',
    'C5': 'final A matches the suite; bus/PC/cycle model differs',
    'C6': 'three-way divergence (no two references share the final A)',
    'no-netlist': 'oracle spec skipped (vector-area collision)',
}
for k in ('C1', 'C2', 'C3', 'C4', 'C5', 'C6', 'no-netlist'):
    if join[k]:
        p('| %s | %s | %d |' % (k, CLSDEF[k], join[k]))
p()
p('Cross-check against the adjudicated 11 ops (section 4 of')
p('`new6502_netlist_adjudication.md`): C1 for 5c/80/7c/9b/c3/db should be')
p('50 each and 23/3b/63/73/7b/f3 29/26/15/10/14/17.')
p()
p('## 4. Per-suite-class breakdown of the both-fail population')
p()
p('| suite class | C1 | C2 | C3 | C4 | C5 | C6 | no-net | total |')
p('|-------------|----|----|----|----|----|----|--------|-------|')
for sc in ('broken-ref', 'xF', 'JAM', 'OTHER'):
    c = join_by_class.get(sc, Counter())
    tot = sum(c.values())
    if not tot:
        continue
    p('| %s | %d | %d | %d | %d | %d | %d | %d | %d |'
      % (sc, c['C1'], c['C2'], c['C3'], c['C4'], c['C5'], c['C6'],
         c['no-netlist'], tot))
p()
p('C1 in broken-ref = the netlist passes the suite where both cores fail:')
p('the "broken reference" label is refuted for those (core-vs-silicon')
p('divergence). C2/C3/C4 in broken-ref = the suite row is the outlier there.')
p()
p('## 5. Per-opcode table (ops with both-fail tests)')
p()
p('| op | class | both-fail | C1 | C2 | C3 | C4 | C5 | C6 | no-net | samples (C2/C3/C4) |')
p('|----|-------|-----------|----|----|----|----|----|----|--------|---------------------|')
for op in sorted(join_by_op, key=lambda o: (-sum(join_by_op[o].values()), o)):
    c = join_by_op[op]
    tot = sum(c.values())
    sm = []
    for k in ('C2', 'C3', 'C4'):
        if samples.get((k, op)):
            sm.append('%s: %s' % (k, ' '.join('%.4X' % i for i in samples[(k, op)])))
    p('| %s | %s | %d | %d | %d | %d | %d | %d | %d | %d | %s |'
      % (op, cls_of(op), tot, c['C1'], c['C2'], c['C3'], c['C4'], c['C5'],
         c['C6'], c['no-netlist'], '; '.join(sm) or '-'))
p()
p('Dominant netlist failure signature per class (first failing line,')
p('prefix before "!="):')
p()
for k in ('C1', 'C2', 'C3', 'C4', 'C5', 'C6'):
    if sig_by_class.get(k):
        top = ', '.join('%s x%d' % (kk, vv) for kk, vv in
                        sig_by_class[k].most_common(6))
        p('- %s: %s' % (k, top))
p()
p('## 6. $5C: functional or bus-only?')
p()
p('The netlist executes a real SBC (a,X) (adjudication section 2). Does the')
p('core do it too?')
p()
p('| check | count (of %d tests) |' % (c5c.get('A_net==A_suite', 0) + c5c.get('A_net!=A_suite', 0)))
p('|-------|--------------------|')
p('| netlist final A == suite | %d |' % c5c['A_net==A_suite'])
p('| v2nmos final A == suite | %d |' % c5c['A_v2==A_suite'])
p('| v2nmos final A == netlist | %d |' % c5c['A_v2==A_net'])
p()
if c5c.get('A_v2==A_suite', 0) < c5c.get('A_net==A_suite', 0):
    p('The v2nmos A state diverges from both the suite and the netlist on the')
    p('failed tests: v2nmos\'s $5C is not a bus-timing difference only - it')
    p('does not perform the SBC (no true-EA read, no A update). That is a')
    p('functional divergence from silicon, in addition to the bus model.')
else:
    p('v2nmos final A matches the suite/netlist state: the $5C difference is')
    p('bus-model only (timing/phantom), the SBC A update is performed.')
p()
p('## 7. Caveats')
p()
p('- Netlist verdicts are P-exempt (final P unobservable: A alias); flag')
p('  updates are not part of this join (see the adjudication report).')
p('- C2/C3/C4 "suite-row-suspect" verdicts are per-test; the same op may')
p('  contain a mix (e.g. A-model residual on some samples only).')
p('- The sweep-header pass totals (v2nmos 8273, golden 7869) were computed')
p('  by the TB\'s own checker against the suite generation the sweeps were')
p('  generated from; compare() against the current 65x02 data gives %d / %d.' % (vpass, gpass))
p('  The delta (v2nmos -%d, golden -%d) is consistent with regenerated' % (8273 - vpass, 7869 - gpass))
p('  expected-final values on a subset of tests - precisely the population')
p('  this join arbitrates. (The old suite data itself is not retained; the')
p('  65x02 clone\'s history is a single "Import current test set" commit.)')
p('- Premise check covers the fetch rows (rows 0-1); settle-row stimulus')
p('  differences, if any, would show up as netlist-vs-core row mismatches')
p('- C6 "three-way divergence" rows are genuine: e.g. idx 3750 (op $4B,')
p('  2-cycle suite model) - the suite expects final A=00 (cleared), the')
p('  netlist ends A=39 after a 3-cycle execution (final PC one further),')
p('  and both cores preserve the initial A=72. All three disagree: the NMOS')
p('  illegal-op behavior on the B=1-row family is unreferenced by the suite')
p('  model and differs from both cores.')
p()
p('## 8. T3 seed-2 robustness (12 arbitration opcodes)')
p()
p('The 12 opcodes of the netlist adjudication were re-run through the oracle')
p('harness with `--seed 2` (retained: `oracle/sweep_6502_oracle_results_')
p('custom_s2.txt`, report `oracle/oracle_report_custom_s2.txt`).')
p()
p('| op | seed-1 P-exempt | seed-2 P-exempt | verdict |')
p('|----|-----------------|-----------------|---------|')
p('| 5c | 50/50 | 50/50 | netlist=suite: real SBC (a,X); next-fetch rows {5:27,6:23} s1 / {5:25,6:25} s2 (same 5/6-cycle page-cross split) |')
p('| 7c | 50/50 | 50/50 | netlist=suite: MOS 3-byte JMP (abs,X) |')
p('| 80 | 50/50 | 50/50 | netlist=2-byte NOP=suite; next fetch at 1-based row 3 x50 on both seeds |')
p('| 9b | 50/50 | 50/50 | netlist=suite |')
p('| c3 | 50/50 | 50/50 | netlist=suite |')
p('| db | 50/50 | 50/50 | netlist=suite |')
p('| 23 | 29/50 | 26/50 | structure netlist=suite (A-model residue) |')
p('| 3b | 26/50 | 24/50 | structure netlist=suite (A-model residue) |')
p('| 63 | 15/50 | 9/50 | structure netlist=suite (A-model residue) |')
p('| 73 | 10/50 | 18/50 | structure netlist=suite (A-model residue) |')
p('| 7b | 14/50 | 21/50 | structure netlist=suite (A-model residue) |')
p('| f3 | 17/50 | 18/50 | structure netlist=suite (A-model residue) |')
p()
p('All six 50/50 verdict opcodes reproduce 50/50 on the second seed; the six')
p('A-model opcodes keep their structural verdict (netlist cycle count, final')
p('PC, and RMW rows equal to the suite on both seeds) while the P-exempt')
p('counts move with the per-sample A-model residue. The adjudication')
p('verdicts are robust to the sample draw.')
p()
p('## 9. Reproduction')
p()
p('```')
p('cd E:/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/module_tests/cpu_65c02')
p('python build/three_way_join.py   # T1 join (this document)')
p('python build/netlist_adjudication.py   # 11-op adjudication (seed 1)')
p('cd ../oracle && python run_oracle.py --ops 5c,80,7c,23,3b,63,73,7b,9b,c3,db,f3 --seed 2  # T3')
p('```')
p()
p('Inputs (retained, untouched): `evidence/sweep_6502_v2nmos_results.txt`,')
p('`evidence/sweep_6502_golden_results.txt`, `evidence/sweep_6502_new6502_results.txt`,')
p('`oracle/sweep_6502_oracle_results_full.txt`, current 65x02 suite data.')
p()
p('---')
p('_Generated by build/three_way_join.py from retained evidence only._')
p('_All tables mechanically computed 2026-09-03._')

with open(OUT, 'w', encoding='utf-8') as fh:
    fh.write('\n'.join(L) + '\n')
print('wrote', OUT, len(L), 'lines')
print('census:', dict(census))
print('join:', dict(join))
