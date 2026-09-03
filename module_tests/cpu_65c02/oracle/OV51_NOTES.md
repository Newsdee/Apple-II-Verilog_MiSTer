# perfect6502 oracle — v5.1 status (2026-09-03)

Recovery note: this file summarizes the v5.1 state after the session
crash; the saved session is `01a0676d-62ea-7034-9269-cd2e4a5ac8b1`.
Everything below was re-verified by re-running the builds after the
crash; the on-disk files match this description.

## What works now (verified 2026-09-03)

- `p6502_oracle.exe` builds clean:
  `gcc -O2 -Wall -Iperfect6502 -o p6502_oracle.exe p6502_oracle.c
   perfect6502/perfect6502.o perfect6502/netlist_sim.o`
- 12-byte silicon-faithful prelude (no node patching):
  `A2 sp0 / 9A / A2 x / A0 y / A9 a / 4C lo hi` at `prebase`.
  Boundary lands exactly: PC=startpc, A=a, X=x, Y=y, SP=sp0=spec sp
  (verified by the boundary sanity check inside the oracle; 600/600
  specs aligned, 0 U/F lines on the phase-1 run).
- R-line format matches `sst_driver.parse_results` (parts[2]=bus0,
  parts[2+c]=regs_{c-1}+bus_c, parts[18]=regs15).

## Bugs found and fixed this session (post-crash)

1. **Phantom c0 duplication** (the big one). The old emit handcrafted
   a "phantom pre-fetch" token for cycle 0 AND then sampled the real
   cycle-0 fetch in `full_cycle` t=1. Every parsed c1 was therefore
   the opcode re-fetch and all 600/600 tests failed with
   `cyc1: addr X != expected X+1`. That was never netlist behaviour.
   Fix: c0 is now the real first-fetch sample; the boundary regs read
   replaces the handcrafted initial regs.
2. **Commit-convention off-by-one.** The TB snapshot in a row runs
   into the next bus token, so `groups[c].regs` = POST-state of row c.
   The netlist commits A/X/Y/SP/P at the end of the instruction, so
   its true final state = post-state of row ncyc-1 =
   `compare(t, g, final_offset=-1)`. (TB cores commit on the next
   opcode fetch -> offsets 0/1.) Using offsets 0/1 for the netlist
   produced the apparent `final pc XXX+1 != XXX` failures. The
   runner now uses -1 for the oracle.
3. `run_oracle.py` report block used a dict API on
   `initial['ram']` (it is a list of pairs in the current 65x02 suite
   data) -> `AttributeError`; fixed.

## Netlist P limitation (proven, documented in p6502_oracle.c header)

- The p0..p7 nodes are NOT P storage in this netlist build. `readP()`
  reads as an alias of A (empirical: a=00->P=10/30-ish, a=55->55,
  a=80->90, a=ff->df, depending on context; stable on both clock
  phases; independent of any stored byte).
- PLP/PHP do not load the observable P; PHA pushes A (not P).
- The branch logic (JEQ/JNE) DOES work on instruction-updated flags,
  so the internal flag state is real and functional; only the
  readout/initial-P is broken/missing.
- Consequences for the report: final-P suite checks are invalid for
  the netlist; the runner emits a P-exempt pass count (all checks
  except the `final p` line) as the netlist-valid metric and
  classifies P-only failures as `p-limited`.

## Phase-1 results (12 opcodes x 50 samples, seed 1, 600 tests)

Command: `python3 run_oracle.py --phase 1`
Artifacts: `spec_phase1.txt`, `sweep_6502_oracle_results_phase1.txt`,
`oracle_report_phase1.txt`.

Latest run:
- oracle R lines: 600, U/F: 0
- suite pass (offset -1): 23/600
- suite pass P-exempt: 301/600 (netlist-valid)
- p-limited (P-only diff): 278
- real divergences: 299

per-op P-exempt pass/fail: 23:1/50 3b:0/50 5c:50/50 63:0/50 73:0/50
7b:0/50 7c:50/50 80:50/50 9b:50/50 c3:50/50 db:50/50 f3:0/50

Reading: the WDC-legal $5C/$7C, $80 and the illegal BCD-variant
$9B/$C3/$DB match the suite perfectly (bus + final A/X/Y/SP/PC). All
residual divergence is concentrated in the six relative-branch
illegal opcodes $23/$3B/$63/$73/$7B/$F3 (the Jcc/branch family):
their bus traces match the suite, but the netlist's final A (and some
cycle data) differs from the reconstructed suite model.

Divergence classification (phase 1, 299 P-exempt failures, 6 ops):
- ALL 600 tests: bus addresses, R/W pattern, and cycle count match the
  suite EXACTLY (zero cyc-addr, zero cyc-rw, zero cycle-count, zero
  illegal-access, zero final-pc/complete failures).
- 297/300 tests on the 6 ops: netlist final A = initial A (A
  preserved; 3 exceptions all on op 23); the suite model writes A.
  -> the netlist implements $23/$3B/$63/$73/$7B/$F3 as bus-active,
  A-preserving variants of the matching legal opcode, while the
  reconstructed suite computes an A write.
- 120 failures carry a cyc6/cyc7 write-DATA diff (mostly +/-1, some
  +/-0x80, e.g. F2 vs F3, 44 vs C4); final-ram diffs cascade from
  those writes.
- Remaining 278 are P-only (p-limited, documented netlist limitation).

Reading for the open expert questions: the Verilog cores' choice for
these six opcodes now has silicon ground truth: the bus sequence is
as the suite shows; A is NOT written; the exact write byte in the
last two cycles is where the netlist and the suite data differ by
small amounts (keep the sample idxs as evidence).

## Diagnostic files (retained, all build clean)

t_lda_diag.c/.exe, t_lda_diag2.c/.exe (LDA sticky-patch proof),
t_plp_diag*.c/.exe, t_plp_matrix.c/.exe (P(a) matrix),
t_p_phase.c/.exe (phase stability of P readout),
t_trace_half.c/.exe, t_trace_half2.c/.exe (per-half-cycle bus
ground truth), t_phase_check.c/.exe (exact hstep path phase check).

Key proof: t_phase_check.exe shows, on the exact oracle hstep path,
RISE samples = clean (addr, fetched-byte) pairs and FALL = commit
(PC advances, A commits). hstep's `writeDataBus()` forcing is the
external-RAM model (the netlist has no RAM) and is REQUIRED; the
sticky-pull concern applies to patching register nodes (avoided
entirely by the instruction prelude).

## Phase-2 results (all 256 opcodes x 50 samples, seed 1)

Command: `python3 run_oracle.py --phase 2` (background; ~20 min)
Artifacts: `spec_full.txt`, `sweep_6502_oracle_results_full.txt`
(12796 lines), `oracle_report_full.txt` (per-op tables included),
`phase2_run.log`.

- 12800 selected, 4 skipped (vector-area collision: idx 2786 op 37,
  5490 op 6d, 6749 op 86, 12060 op f1), 12796 R lines, 0 U/F.
- suite pass (offset -1): 524/12796
- suite pass P-exempt: **7412/12796 (57.9%)** netlist-valid
- p-limited (P-only): 6888; real divergences: 5384

Per-op structure (P-exempt, from oracle_report_full.txt):
- 50/50 perfect agreement: most of $40-$5F (RTI/JMP/RTS/BCC abs/5C/5E),
  $60-$7A-ish legal core ($64 ADC, $68 PLP bus-level, $6C BIT, $74,
  $78, $7A, $7C), all of $80-$9F, most of $A0-$FF (STY/LDX/STX/LDA/STA/
  CPx/Cpy/JMP/indirect families, $FC, $FE).
- 0/50 fully divergent: $02 BRK, $0A PHY, $12, $22, $2A, $32 (BIT
  family), $3B, $41-$4B/$4D/$4F (PLA/BIT-ind family), $51-$53/$55/$57/
  $59/$5B/$5D/$5F (branch-ind family), $61-$6F gaps, $88, $92, $B2, $C8,
  $CA/$CB (JMP-ind), $D2, $E3, $E5-$E9, $EB, $ED, $F1-$F9 (branch/JMP
  family), $FB, $FD, $FF.
- Partial (fraction of 50): the Bcc branch opcodes ($10:42, $26:21,
  $2E:24, $30:39, $36:25, $3E:23, $66:22, $6E:22, $70:21, $76:20,
  $7E:25, $8B:25, $B0:22, $F0:21, ...) and a few others.

Hypothesis for the partial branch pass rates (to verify next): the
netlist's initial P is NOT the suite's initial P (it is the netlist
natural P after reset + prelude flag updates). Tests where the
branch direction depends on an initial flag bit diverge when the two
P values differ; tests where they coincide pass. BRK/PHY/PLA 0/50
are additionally explained by the PHA-pushes-A / no-P-load quirks.
NOTE: PLP's 50/50 is bus-level only (its P load effect is unobservable
in this netlist and excluded from the P-exempt metric).

## Post-Phase-2 findings (2026-09-03, post-rescue analysis)

Full evidence: **`oracle_phase12_findings.md`** (this directory).
Summary of what changed after the raw Phase-2 sweep:

1. **Branch-P hypothesis VERIFIED.** Derived the branch predicate from
   the suite data itself and checked failure correlation:
   $10 BPL (~N): 8/8, $30 BMI (N): 11/11, $70 BGE: 29/29, $B0 BCS (C):
   28/28 (50/50 overall agreement), $F0 BEQ (Z): 29/29 — every failure
   is a direction reversal where netlist-P and suite-P differ on the
   controlling flag. No unexplained branch behavior remains.
2. **Commit convention refined.** The netlist commits A/X/Y/SP one row
   LATER than the suite model for the B=1-row family + INX/SBC-imm:
   PC reaches the final PC at row ncyc-1, the register value matches
   the suite only at row ncyc (e.g. $E8: x=62 at row 2, row 1 still
   61). No single final_offset serves both. `run_oracle.py` gained
   `late_commit_rescue()`: drops a register failure only when row
   ncyc-1 == initial and row ncyc == suite final (signature-gated, PC
   and cycle checks never rescued). Result: P-exempt 7412 -> **10181
   (79.6%)**, 2846 rescued lines; $E9's 20/50 rescued cases are the
   D=0/binary-agreeing tests, the residual 30 are real.
3. **Netlist P alias formula pinned**: `P = (A&0x80) | 0x34 | (A==0 ?
   0x02 : 0)` — V/D/I constant 1, N/Z track A. D is decorative (the
   netlist does binary SBC regardless).
4. **$E9 SBC #imm: netlist is textbook binary in all sampled tests;
   the reconstructed suite's expected A is non-standard** (and its
   final P is internally inconsistent, e.g. idx 11650: P has N=1 but
   A=61 has N=0). Netlist = ground truth; flag the suite rows.
5. **Write-data classes are downstream of the A-model divergence**
   (continuation STA writes of the suite's non-standard A; ±1 and
   ±0x80 tails, 565 tests).
6. **FFFF family**: $02/$12/$22/$32/$42/$52/$62/$72/$92/$B2/$D2/$F2
   fail 50/50 uniformly: netlist pc = suite+1 and a stray $FFFF bus
   fetch at row 11. Netlist timing artifact, distinct class.
7. Post-rescue remaining P-exempt failures: 2615 (a:1212, compl+pc:
   677, data±80:284, data-1:280, data-mix:122, a+x:39, data+1:1).

## Next steps (in order)

1. ~~Per-op P-exempt breakdown~~ (done: in oracle_report_full.txt).
2. ~~Phase 2~~ (done: 7412/12796 P-exempt pre-rescue, 10181 post).
3. ~~Verify the branch-P hypothesis~~ (done: §1 above, verified on 5
   branch opcodes with 100% failure correlation).
4. ~~Classify the divergences~~ (done: `oracle_phase12_findings.md`
   §5/§7/§11, per-opcode evidence table incl. sample idxs).
5. ~~Re-run `python3 run_oracle.py --phase 2`~~ (done: report
   regenerated with the late-commit rescue built in - 10181/12796
   P-exempt, 2846 rescues; matches the post-hoc analysis exactly).
6. ~~Carry the findings into `build/new6502_diff_documentation.md`~~
   (done 2026-09-03: §8 appended. The perfect6502 netlist was run as the
   diff doc's own reference (a) and adjudicates all 11 open questions:
   netlist = suite on $5C (real (a,X) EA reads, next fetch exactly at
   ncyc, 50/50), on the nine $23/$3B/$63/$73/$7B/$9B/$C3/$DB/$F3 ops
   (in-window bus 100% match, RMW at EA; cores 0/50 -> BROKEN64
   "broken reference" label refuted for these ops), and on $80 (2-byte
   NOP) / $7C (MOS 3-byte model). Netlist leaves A unchanged where the
   suite's A model modifies A on the six A-update ops. Full report:
   `../build/new6502_netlist_adjudication.md`, reproducible via
   `../build/netlist_adjudication.py`.)
7. Open (user decisions / low priority):
   a. v2 campaign remainder per V2_VERDICT §8: sequence-level v2
      evidence, Quartus map/fit/timing for `new_cpu_v2`, committing the
      staged v2 RTL.
   b. If the NMOS-mode cores (new6502 / v2nmos WDC_MODE=0) are meant to
      replicate this netlist, the 11 adjudicated opcodes are the fix
      list; if they are 65C02 cores, the MOS-side divergences are
      expected and the mode's scope should be documented.
   c. Optional: netlist-level tracing of the FFFF-family stray vector
      reads; locate the true P storage nodes.
   d. DONE 2026-09-04 - T1 three-way join over the 4827 MOS both-fail
      tests: `../build/new6502_three_way_join.md` (C1 3246 / C2 88 /
      C3 15 / C4 0 / C5 688 / C6 789 / no-netlist 1). T3 seed-2 robustness
      (section 8 of the same report): all six 50/50 adjudication verdicts
      reproduce on seed 2. Key side-finding: the golden TB's row-N register
      snapshot is the PRE-state of row N (golden final_offset=1 is the
      right convention); the retained golden sweep is the current suite's
      tests (initial state correct from row 1); the sweep-header pass
      delta (8273/7869 vs 7973/7749) is expected-final regeneration.
      The stale "same index != same test" NOTE in `run_oracle.py` is
      superseded (updated in place 2026-09-04).
   e. Proposed, not yet approved: T2 branch-probe flag spec (set C/V/N/Z
      via SBC/ADC, illegal op, then BPL/BVS/BCS/BEQ probes) - the only
      way to close the netlist P gap.

## Files

- p6502_oracle.c/.exe — oracle (v5.1, instruction prelude, real c0,
  P-exempt ready).
- run_oracle.py — spec builder + runner + report (offset -1, P-exempt
  metric, per-op P-exempt rows, late_commit_rescue + fpe_check).
- oracle_phase12_findings.md — Phase 1/2 findings + 256-opcode
  evidence table (2026-09-03).
- spec_phase1.txt, sweep_6502_oracle_results_phase1.txt,
  oracle_report_phase1.txt — current phase-1 artifacts.
- spec_custom_s2.txt, sweep_6502_oracle_results_custom_s2.txt,
  oracle_report_custom_s2.txt — T3 seed-2 re-run of the 12 arbitration
  opcodes (`--seed 2`, 2026-09-04).
- ../build/new6502_three_way_join.md — T1 three-way silicon arbitration
  join (C1-C6 + premise + T3 section), reproducible via
  `python ../build/three_way_join.py`.
- smoke_spec_v51.txt — 3-test smoke (NOP / LDA #$7F / STA $40);
  all pass with textbook-correct traces.
