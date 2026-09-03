# Three-way silicon arbitration join (T1) - MOS 6502 both-fail population

Joins the suite expectation (current 65x02 data) with the three retained
behavioral references - v2nmos (offset 0), golden R65Cx2 (offset 1),
perfect6502 netlist (offset -1, late-commit rescue, P-exempt) - on the
common 12800 tests (the 4 oracle-missing specs: idx 2786 op $37, 5490 op $6D,
6749 op $86, 12060 op $F1 - are reported as no-netlist). Pure analysis
over retained files; no simulation.

## 1. Premise check - are the retained sweeps the same tests?

For every common idx, the opcode fetch (row 0) and the low-byte operand
fetch (row 1, when the suite row 1 is a read) must agree in addr+data
across suite, netlist, v2nmos and golden. Result: **12799 of 12800 agree**
(plus 4 idx with no netlist row - the 4 oracle-missing specs, checked
against suite/cores only). Mismatches: idx 1507.

The retained core sweeps and the oracle sweep describe the same test
programs on the sampled rows, so the per-index join below is valid. This
supersedes the stale NOTE at the end of `oracle/run_oracle.py` (written
from git-history inspection of the 65x02 clone) which claimed "same index
!= same test"; the NOTE's residual risk - that the *expected final*
values were regenerated even though the stimuli are identical - is real
and is exactly what this join measures (sweep-header pass totals differ
from the current-suite compare() totals: v2nmos 8273 vs 7973, golden 7869
vs 7749 - see section 7).

Exception: idx 1507 (op $1E) - the golden row-0 data byte reads 0x1F
where the suite and the v2nmos trace have 0x1E. This is the golden
TB's row-0 prelude artifact (documented below): its row-0 fetch can
overlap the test-program memory write and sample the previous byte.
Rows 1-15 of that trace are genuine instruction cycles; the exception
is cosmetic and does not affect the join.

Register initial-state validation (same indices, register fields): the
v2nmos row-0 post-state equals the suite initial state (sp,a,x,y) on
12800/12800 indices. For the golden sweep the row-0 post-state is the
PREVIOUS test's residual state: the golden TB's row-N register snapshot
is the PRE-state of row N (one row behind the bus tokens), and the spec
initial-state load lands during row 0. From row 1 onward the golden
trace carries the correct suite initial state (verified on sample: idx 1
-> sp=99 a=b7 x=6c y=33; idx 4 -> sp=a5 a=0a x=38 y=cf). Consequences:
  * the campaign's golden final_offset=1 is the right convention - the
    committed final state is at group[ncyc+1], exactly what compare()
    reads;
  * the golden column's final-A siding in C2/C3 is valid (correct
    initial state, correct program);
  * the golden row-0 register field must not be used as the test's
    initial state (it is the TB pre-state).

## 2. Census (current suite, compare() with campaign offsets)

| category | count |
|----------|-------|
| both-pass (v2nmos and golden) | 7749 |
| v2nmos-only pass | 224 |
| golden-only pass | 0 |
| both-fail | 4827 |
| v2nmos pass total | 7973 (V2_VERDICT: 7973 over 12800) |
| golden pass total | 7749 (V2_VERDICT: 7749 over 12800) |

Both-fail population: 4827 tests across 105 opcodes.

## 3. Arbitration classes (both-fail tests)

| class | meaning | count |
|-------|---------|-------|
| C1 | netlist passes the suite (P-exempt) - suite row silicon-faithful, core-vs-silicon divergence confirmed | 3246 |
| C2 | final A: netlist == v2nmos == golden, all != suite - silicon and cores agree on register state; the suite A model is the outlier | 88 |
| C3 | netlist trace ~= v2nmos (>=14/16 rows) and A agrees, != suite - strongest suite-row-suspect signal | 15 |
| C5 | final A matches the suite; bus/PC/cycle model differs | 688 |
| C6 | three-way divergence (no two references share the final A) | 789 |
| no-netlist | oracle spec skipped (vector-area collision) | 1 |

Cross-check against the adjudicated 11 ops (section 4 of
`new6502_netlist_adjudication.md`): C1 for 5c/80/7c/9b/c3/db should be
50 each and 23/3b/63/73/7b/f3 29/26/15/10/14/17.

## 4. Per-suite-class breakdown of the both-fail population

| suite class | C1 | C2 | C3 | C4 | C5 | C6 | no-net | total |
|-------------|----|----|----|----|----|----|--------|-------|
| broken-ref | 1940 | 88 | 15 | 0 | 564 | 592 | 1 | 3200 |
| xF | 100 | 0 | 0 | 0 | 0 | 0 | 0 | 100 |
| JAM | 0 | 0 | 0 | 0 | 100 | 0 | 0 | 100 |
| OTHER | 1206 | 0 | 0 | 0 | 24 | 197 | 0 | 1427 |

C1 in broken-ref = the netlist passes the suite where both cores fail:
the "broken reference" label is refuted for those (core-vs-silicon
divergence). C2/C3/C4 in broken-ref = the suite row is the outlier there.

## 5. Per-opcode table (ops with both-fail tests)

| op | class | both-fail | C1 | C2 | C3 | C4 | C5 | C6 | no-net | samples (C2/C3/C4) |
|----|-------|-----------|----|----|----|----|----|----|--------|---------------------|
| 02 | broken-ref | 50 | 0 | 0 | 0 | 0 | 50 | 0 | 0 | - |
| 03 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 04 | OTHER | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 07 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 0b | broken-ref | 50 | 4 | 41 | 5 | 0 | 0 | 0 | 0 | C2: 0227 0228 0229; C3: 0226 022E 0230 |
| 0c | OTHER | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 0f | OTHER | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 12 | broken-ref | 50 | 0 | 0 | 0 | 0 | 50 | 0 | 0 | - |
| 13 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 14 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 17 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 1a | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 1b | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 1c | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 1f | OTHER | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 22 | broken-ref | 50 | 0 | 0 | 0 | 0 | 50 | 0 | 0 | - |
| 23 | broken-ref | 50 | 29 | 0 | 0 | 0 | 10 | 11 | 0 | - |
| 27 | broken-ref | 50 | 22 | 0 | 0 | 0 | 19 | 9 | 0 | - |
| 2b | broken-ref | 50 | 4 | 37 | 9 | 0 | 0 | 0 | 0 | C2: 0866 0867 0868; C3: 0872 0876 087E |
| 2f | OTHER | 50 | 26 | 0 | 0 | 0 | 10 | 14 | 0 | - |
| 32 | broken-ref | 50 | 0 | 0 | 0 | 0 | 50 | 0 | 0 | - |
| 33 | broken-ref | 50 | 27 | 0 | 0 | 0 | 12 | 11 | 0 | - |
| 37 | broken-ref | 50 | 27 | 0 | 0 | 0 | 10 | 12 | 1 | - |
| 3a | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 3b | broken-ref | 50 | 26 | 0 | 0 | 0 | 13 | 11 | 0 | - |
| 3f | OTHER | 50 | 21 | 0 | 0 | 0 | 14 | 15 | 0 | - |
| 42 | broken-ref | 50 | 0 | 0 | 0 | 0 | 50 | 0 | 0 | - |
| 43 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 47 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 4b | broken-ref | 50 | 4 | 0 | 0 | 0 | 0 | 46 | 0 | - |
| 4f | OTHER | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 52 | broken-ref | 50 | 0 | 0 | 0 | 0 | 50 | 0 | 0 | - |
| 53 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 57 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 5a | OTHER | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 5b | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 5c | OTHER | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 5f | OTHER | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 62 | broken-ref | 50 | 0 | 0 | 0 | 0 | 50 | 0 | 0 | - |
| 63 | broken-ref | 50 | 15 | 1 | 0 | 0 | 0 | 34 | 0 | C2: 1357 |
| 64 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 67 | broken-ref | 50 | 14 | 0 | 0 | 0 | 0 | 36 | 0 | - |
| 6b | broken-ref | 50 | 0 | 0 | 0 | 0 | 0 | 50 | 0 | - |
| 6f | OTHER | 50 | 8 | 0 | 0 | 0 | 0 | 42 | 0 | - |
| 72 | JAM | 50 | 0 | 0 | 0 | 0 | 50 | 0 | 0 | - |
| 73 | broken-ref | 50 | 10 | 0 | 0 | 0 | 0 | 40 | 0 | - |
| 74 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 77 | broken-ref | 50 | 12 | 0 | 0 | 0 | 0 | 38 | 0 | - |
| 7a | OTHER | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 7b | broken-ref | 50 | 14 | 0 | 0 | 0 | 0 | 36 | 0 | - |
| 7c | OTHER | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 7f | OTHER | 50 | 11 | 0 | 0 | 0 | 0 | 39 | 0 | - |
| 83 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 87 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 8b | broken-ref | 50 | 25 | 1 | 0 | 0 | 0 | 24 | 0 | C2: 1B33 |
| 8f | OTHER | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 92 | broken-ref | 50 | 0 | 0 | 0 | 0 | 50 | 0 | 0 | - |
| 93 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 97 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 9b | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 9c | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 9e | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 9f | OTHER | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| a3 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| a7 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| ab | broken-ref | 50 | 11 | 6 | 1 | 0 | 0 | 32 | 0 | C2: 2166 216A 216E; C3: 2169 |
| af | xF | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| b2 | broken-ref | 50 | 0 | 0 | 0 | 0 | 50 | 0 | 0 | - |
| b3 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| b7 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| bb | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| bf | xF | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| c3 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| c7 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| cb | OTHER | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| cf | OTHER | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| d2 | broken-ref | 50 | 0 | 0 | 0 | 0 | 50 | 0 | 0 | - |
| d3 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| d7 | broken-ref | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| da | OTHER | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| db | OTHER | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| dc | OTHER | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| df | OTHER | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| e3 | broken-ref | 50 | 13 | 2 | 0 | 0 | 0 | 35 | 0 | C2: 2C6D 2C77 |
| e7 | broken-ref | 50 | 16 | 0 | 0 | 0 | 0 | 34 | 0 | - |
| eb | broken-ref | 50 | 20 | 0 | 0 | 0 | 0 | 30 | 0 | - |
| ef | OTHER | 50 | 12 | 0 | 0 | 0 | 0 | 38 | 0 | - |
| f2 | JAM | 50 | 0 | 0 | 0 | 0 | 50 | 0 | 0 | - |
| f3 | broken-ref | 50 | 17 | 0 | 0 | 0 | 0 | 33 | 0 | - |
| f7 | broken-ref | 50 | 14 | 0 | 0 | 0 | 0 | 36 | 0 | - |
| fa | OTHER | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| fb | broken-ref | 50 | 16 | 0 | 0 | 0 | 0 | 34 | 0 | - |
| fc | OTHER | 50 | 50 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| ff | OTHER | 50 | 21 | 0 | 0 | 0 | 0 | 29 | 0 | - |
| 3c | OTHER | 40 | 40 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 34 | OTHER | 39 | 39 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| 89 | OTHER | 28 | 28 | 0 | 0 | 0 | 0 | 0 | 0 | - |
| fd | OTHER | 4 | 0 | 0 | 0 | 0 | 0 | 4 | 0 | - |
| e5 | OTHER | 3 | 0 | 0 | 0 | 0 | 0 | 3 | 0 | - |
| e9 | OTHER | 3 | 0 | 0 | 0 | 0 | 0 | 3 | 0 | - |
| ed | OTHER | 3 | 0 | 0 | 0 | 0 | 0 | 3 | 0 | - |
| 79 | OTHER | 2 | 0 | 0 | 0 | 0 | 0 | 2 | 0 | - |
| e1 | OTHER | 2 | 0 | 0 | 0 | 0 | 0 | 2 | 0 | - |
| f1 | OTHER | 2 | 0 | 0 | 0 | 0 | 0 | 2 | 0 | - |
| f9 | OTHER | 1 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | - |

Dominant netlist failure signature per class (first failing line,
prefix before "!="):

- C2: final a  91 x2, final a  5A x2, final a  E4 x2, final a  9C x2, final a  C8 x2, final a  66 x2
- C3: final a  4C x1, final a  75 x1, final a  E0 x1, final a  CA x1, final a  76 x1, final a  D7 x1
- C5: cyc7: data A8 x2, cyc7: data 3C x2, cyc4: data A2 x2, cyc4: data EA x2, cyc5: data C0 x2, cyc5: data 3A x2
- C6: final a  00 x11, final a  39 x7, final a  80 x7, final a  50 x7, final a  DA x6, final a  6F x6

## 6. $5C: functional or bus-only?

The netlist executes a real SBC (a,X) (adjudication section 2). Does the
core do it too?

| check | count (of 50 tests) |
|-------|--------------------|
| netlist final A == suite | 50 |
| v2nmos final A == suite | 50 |
| v2nmos final A == netlist | 50 |

v2nmos final A matches the suite/netlist state: the $5C difference is
bus-model only (timing/phantom), the SBC A update is performed.

## 7. Caveats

- Netlist verdicts are P-exempt (final P unobservable: A alias); flag
  updates are not part of this join (see the adjudication report).
- C2/C3/C4 "suite-row-suspect" verdicts are per-test; the same op may
  contain a mix (e.g. A-model residual on some samples only).
- The sweep-header pass totals (v2nmos 8273, golden 7869) were computed
  by the TB's own checker against the suite generation the sweeps were
  generated from; compare() against the current 65x02 data gives 7973 / 7749.
  The delta (v2nmos -300, golden -120) is consistent with regenerated
  expected-final values on a subset of tests - precisely the population
  this join arbitrates. (The old suite data itself is not retained; the
  65x02 clone's history is a single "Import current test set" commit.)
- Premise check covers the fetch rows (rows 0-1); settle-row stimulus
  differences, if any, would show up as netlist-vs-core row mismatches
- C6 "three-way divergence" rows are genuine: e.g. idx 3750 (op $4B,
  2-cycle suite model) - the suite expects final A=00 (cleared), the
  netlist ends A=39 after a 3-cycle execution (final PC one further),
  and both cores preserve the initial A=72. All three disagree: the NMOS
  illegal-op behavior on the B=1-row family is unreferenced by the suite
  model and differs from both cores.

## 8. T3 seed-2 robustness (12 arbitration opcodes)

The 12 opcodes of the netlist adjudication were re-run through the oracle
harness with `--seed 2` (retained: `oracle/sweep_6502_oracle_results_
custom_s2.txt`, report `oracle/oracle_report_custom_s2.txt`).

| op | seed-1 P-exempt | seed-2 P-exempt | verdict |
|----|-----------------|-----------------|---------|
| 5c | 50/50 | 50/50 | netlist=suite: real SBC (a,X); next-fetch rows {5:27,6:23} s1 / {5:25,6:25} s2 (same 5/6-cycle page-cross split) |
| 7c | 50/50 | 50/50 | netlist=suite: MOS 3-byte JMP (abs,X) |
| 80 | 50/50 | 50/50 | netlist=2-byte NOP=suite; next fetch at 1-based row 3 x50 on both seeds |
| 9b | 50/50 | 50/50 | netlist=suite |
| c3 | 50/50 | 50/50 | netlist=suite |
| db | 50/50 | 50/50 | netlist=suite |
| 23 | 29/50 | 26/50 | structure netlist=suite (A-model residue) |
| 3b | 26/50 | 24/50 | structure netlist=suite (A-model residue) |
| 63 | 15/50 | 9/50 | structure netlist=suite (A-model residue) |
| 73 | 10/50 | 18/50 | structure netlist=suite (A-model residue) |
| 7b | 14/50 | 21/50 | structure netlist=suite (A-model residue) |
| f3 | 17/50 | 18/50 | structure netlist=suite (A-model residue) |

All six 50/50 verdict opcodes reproduce 50/50 on the second seed; the six
A-model opcodes keep their structural verdict (netlist cycle count, final
PC, and RMW rows equal to the suite on both seeds) while the P-exempt
counts move with the per-sample A-model residue. The adjudication
verdicts are robust to the sample draw.

## 9. Reproduction

```
cd E:/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/module_tests/cpu_65c02
python build/three_way_join.py   # T1 join (this document)
python build/netlist_adjudication.py   # 11-op adjudication (seed 1)
cd ../oracle && python run_oracle.py --ops 5c,80,7c,23,3b,63,73,7b,9b,c3,db,f3 --seed 2  # T3
```

Inputs (retained, untouched): `evidence/sweep_6502_v2nmos_results.txt`,
`evidence/sweep_6502_golden_results.txt`, `evidence/sweep_6502_new6502_results.txt`,
`oracle/sweep_6502_oracle_results_full.txt`, current 65x02 suite data.

---
_Generated by build/three_way_join.py from retained evidence only._
_All tables mechanically computed 2026-09-03._
