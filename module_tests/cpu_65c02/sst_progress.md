# SST (single-step test) progress handoff — 2026-09-03

Resume point for the WDC 65x02 single-step harness work. Read this top to bottom, then continue at "Next steps".

**Current state (2026-09-03, continued): Priority 1 DONE — semantic checker built and validated.**
New `module_tests/cpu_65c02/semantic_compare.py` + `semantic_whitelist.txt`
(named entries). On the regenerated r65 pair it reports **PASS (exit 0)**:
1504/1504 fetch pairs identical; 1503 instruction lengths checked (whitelist
used: 4× `LEN +1 1e 3e 5e 7e`, 2× `LEN -1 6c 7c`); 1503 boundary states
clean under the one-fetch skew rule; write events 98 golden vs 70 new with
exactly 28 whitelisted RMW old-value pre-writes (shifts/INC/DEC/EOR/
TSB/AND-bit families — the first run exposed 4 TSB instructions missing from
the initial whitelist); final state equal modulo constant P_B; **final
write-map equality TRUE** (33 distinct addresses, last-write-wins);
gates irq_handler=1020 / nmi_handler=1030 / errpark=0908 hit in both.
Verified with 5 mutated-trace negative tests (write-data corruption,
fetch-opcode change, state-bit flip, RMW-entry-free whitelist → all FAIL
with precise localization; unmutated control → PASS). `--report-reads`
(report-only) shows 31/1504 instructions with read-list differences: 24 RMW
EA re-reads (new core), 7 convention reads (STZ dummy-EA-vs-b2-re-read,
JMP-indirect extra reads matching the +1c length delta, pre-interrupt NOP
dummies, park-loop tail truncation), and the 4 .ax shifts have NO read diff
(golden's b2 forced-fix re-read coincides with the new core's EA re-read
shape) — write-only delta. Key measured conventions now baked into the
checker: golden state columns lag one fetch (gf[i] vs nf[i-1]); SP accepts
unshifted at 14 stack-op/interrupt-entry boundaries; PC column dPC∈{0,1}
plus reported in-transition exceptions after RTS@0912 and BRA@08fd.
JSON summary: `build/semantic_summary.json`.

**Current state (2026-09-03):** Session resumed after a crash; three outcomes:

1. **SST debug anomaly RESOLVED — no RTL bug.** The "BIT abs,X reads wrong
   data at EA" case was a corrupted hand-written `build/dbg_batch.txt` (the EA
   address 5B57 sat in the patch list, displacing the last instruction byte;
   value F5 landed at 5B57 instead of 5622). With the corrected batch, a clean
   rebuild (`build/sst_rebuild/Vcpu65_sst_tb.exe`, SHA-256 `4039594a…a596`)
   reads the EE sentinel at EA and produces the exact expected result (P=F9 —
   the injected P=AB already has D=1; A unchanged). Old and new SST binaries
   give byte-identical output on this test, so the stale-binary concern was
   moot. The full observed trace (BIT abs,X → EOR zp → INC abs) was re-derived
   by hand and is 100% correct for the (corrupted) memory.
2. **Step 1 complete — r65 pair regenerated** (`run_divergence.ps1` full run;
   log `build/divergence_rerun.log`). Equivalence story re-verified after
   Option C: **1504/1504 fetches, 0 opcode mismatches, 0 fetch-address
   mismatches**; final state identical (PC=090A SP=F7 A=33 X=00 Y=55,
   N/V/D/I/Z/C all equal) except P_B, a structural constant 1 in the new core
   (`reg_p = {fl_n, fl_v, 1'b1, 1'b1, fl_d, fl_i, fl_z, fl_c}` — B never
   cleared; skipped by convention in the comparator). Delta table unchanged:
   4× abs,X shift/rotate golden +1c (ASL/ROL/LSR/ROR .ax), 2× JMP indirect
   new-core +1c (6c/7c); net final +2. IRQ@730 and NMI@768 gates hit in both
   cores; both park at 0908. T65 phases unchanged (1932/4160, 4378/6500 —
   pre-existing, not Option-C-related).
3. **Category G corrected: D flag, not I flag** (bit-index error in the
   2026-09-02 re-attribution; "P[3]" in LSB numbering is bit 3 = D). Decisive
   evidence: for `69`/`e9` the WDC suite pins I=0 on all 10000 tests, yet the
   D=1 half still takes the extra cycle; rockwell/synetek show the same
   D-dependence, MOS suites depend on neither. See the correction block in
   `wdc_vs_6502_analysis.md`. Policy (a) and all pass counts unaffected; the
   failing half of each ADC/SBC opcode is the D=1 half. Side observation:
   post-test garbage-phase INC abs shows the new core doing read,
   second-read, write while golden shows W(old),W(new) consecutive rows
   (write-strobe duration convention) — pre-existing delta class, candidate
   for Priority-3 RMW/I-O coverage.

**Current state (2026-09-02):** Policy **(a) adopted** (W65C02S/WDC reference
authoritative for bus conventions — see `CPU_COMPARISON_RECOMMENDATIONS.md`).
Option C applied and verified: the new core's M_ABX penalty/forced-fix cycle now
re-reads b2 at `pc+2` (WDC convention) instead of dummies at the no-carry EA.
Full WDC re-sweep: **10798/12700 pass, zero per-test regressions** vs the
10302 baseline (`build/regress_check.py`, gate rc=0); +496 passes, all in the
M_ABX family incl. `de`/`fe`/`9d`/`9e` 0→50 and `3c` 27→50. Category G
re-attributed: the WDC ADC/SBC extra cycle is **I-flag-driven, not D=1**
(the generator pins D per opcode family); documented, not emulated. Files
staged in git (NOT committed) — see "Git state". Next: follow the plan in
`CPU_COMPARISON_RECOMMENDATIONS.md` (semantic checker → report corrections →
directed coverage → T65/SST closeout), starting with regenerating the r65 pair
traces (new-core trace is stale after Option C).

## Goal recap

Build a per-instruction functional/cycle checker that replays the WDC SingleStepTests/65x02 suite
(`E:/MiSTer/Apple-II_FPGAdev/65x02/<suite>/v1/<op>.json`, suites: wdc65c02, rockwell65c02,
synertek65c02, nes6502, 6502) against:

1. **New core** `rtl/new_cpu/cpu_65c02.sv` (+ `cpu_alu.sv`) — DONE, full sweep done.
2. **Golden R65Cx2** `rtl/R65Cx2.sv` — harness just finished building/calibrating; this is where we are.
3. (Later) T65 if useful.

Then produce the 3-way comparison table (suite vs golden vs new core) and final verdict.

## Key files

| What | Path |
|---|---|
| New-core SST TB | `Apple-II-Verilog_MiSTer/module_tests/cpu_65c02/cpu65_sst_tb.sv` (has +DBG=<idx> internal dump to stdout for idx-matching test) |
| Golden R65Cx2 SST TB | `Apple-II-Verilog_MiSTer/module_tests/cpu_65c02/r65cx2_sst_tb.sv` (has same +DBG=0 debug $display, gated on idx==0) |
| Probe TB (throwaway) | `module_tests/cpu_65c02/r65cx2_probe_tb.sv` |
| Driver | `module_tests/cpu_65c02/sst_driver.py` — now has `--final-offset N` flag (default 0; use **1** for golden R65Cx2) |
| New-core build dir / binary | `module_tests/cpu_65c02/build/sst_verilog/Vcpu65_sst_tb.exe` |
| New-core SST TB clean rebuild (2026-09-03) | `build/sst_rebuild/Vcpu65_sst_tb.exe` (SHA-256 `4039594a…a596`; byte-identical output to the sst_verilog build on the dbg test) |
| r65-pair rerun log (2026-09-03) | `build/divergence_rerun.log` (full run_divergence.ps1: all 6 stages + divergence report) |
| Golden build dir / binary | `module_tests/cpu_65c02/build/sst_r65/Vr65cx2_sst_tb.exe` |
| Old standalone golden TB | `module_tests/cpu_65c02/r65cx2_ora_tb.sv` (proved ORA zp = 3 cyc read-only) |
| Sweep artifacts (persistent) | `build/sweep_wdc.txt`, `build/sweep_wdc_results.txt` (pre-fix new core), `build/sweep_wdc_nobcdfix_results.txt` (post-DEC_FIX-removal baseline), **`build/sweep_wdc_abxfix_results.txt` (current new-core state, post Option C)**, `build/sweep_wdc_golden_results.txt`, `build/sweep_wdc_batch.txt`, `build/fail_examples.json` |
| Pre-Option-C RTL snapshot | `build/cpu_65c02_preabxfix.sv` (= `/tmp/cpu_65c02.sv.pre-abxfix`; 17-line diff vs current, see Category C resolution) |
| Regression gate | `build/regress_check.py` — per-test pass/fail diff of the two sweep files above; exit 1 on any pass→fail flip |
| Comparison plan | `module_tests/cpu_65c02/CPU_COMPARISON_RECOMMENDATIONS.md` (priorities 1–4 + decision policy; policy (a) adopted 2026-09-02) |
| **Semantic checker (Priority 1, 2026-09-03)** | `module_tests/cpu_65c02/semantic_compare.py` + `semantic_whitelist.txt`; JSON summary `build/semantic_summary.json`. Usage: `python semantic_compare.py <golden.csv> <new.csv> [--whitelist ...] [--report-reads] [--gate NAME=ADDR ...] [--json-out FILE]`; exit 0 pass / 2 divergence / 1 usage |
| CPU analysis doc | `module_tests/cpu_65c02/cpu_cycle_analysis.md` (needs Priority-2 corrections; accepted-differences table must share IDs with the whitelist) |
| WDC-vs-MOS attribution doc | `module_tests/cpu_65c02/wdc_vs_6502_analysis.md` (Categories A–I; G = ADC/SBC **D-flag** extra cycle — corrected 2026-09-03, the 09-02 "I-flag" attribution was a bit-index error; C resolved by Option C; I = illegal-opcode decode mismatch) |
| BCD root-cause artifacts | `build/bcd_batch.py`, `build/bcd_batch.txt`, `build/bcd_dbg*.txt`, `build/bcd_results*.txt`, `build/bcd_matrix.py` |

Driver usage:

```bash
# new core
/c/msys64/ucrt64/bin/python3 module_tests/cpu_65c02/sst_driver.py \
  --suite wdc65c02 --ops all --sample 50 --seed 1 \
  --bin module_tests/cpu_65c02/build/sst_verilog/Vcpu65_sst_tb.exe

# golden (NOTE --final-offset 1)
/c/msys64/ucrt64/bin/python3 module_tests/cpu_65c02/sst_driver.py \
  --suite wdc65c02 --ops a9,69,e9,05,85,a5,65,6d --sample 20 --seed 1 --final-offset 1 \
  --bin module_tests/cpu_65c02/build/sst_r65/Vr65cx2_sst_tb.exe
```

Build (verilator's internal make fails; run make manually):

```bash
export VERILATOR_ROOT='C:/msys64/ucrt64/share/verilator' PATH="/c/msys64/ucrt64/bin:$PATH"
C:/msys64/ucrt64/bin/verilator_bin.exe --binary --timing -Wno-fatal --top-module r65cx2_sst_tb \
  --Mdir module_tests/cpu_65c02/build/sst_r65 \
  rtl/R65Cx2.sv module_tests/cpu_65c02/r65cx2_sst_tb.sv   # (ignore the internal-make %Error)
/c/msys64/ucrt64/bin/mingw32-make -C module_tests/cpu_65c02/build/sst_r65 -f Vr65cx2_sst_tb.mk -j4
```

Running the golden binary directly from Git Bash fails (rc=127) — it needs
`PATH=C:\msys64\ucrt64\bin;...`; use the driver or a Python subprocess with that env.

## New-core sweep results (persistent in build/sweep_wdc*)

- **CURRENT (post Option C): 10798/12700 pass (85.0%)** —
  `build/sweep_wdc_abxfix_results.txt`. Per-test gate vs baseline: zero
  regressions, +496 passes, all in M_ABX opcodes (`1d 3d 5d bc bd dd 1e 3e
  5e 7e 9d 9e de fe 3c` → 50/50; `7d` 10→23, `fd` 18→31 — remainder is the
  Category G I-flag convention). No other opcode changed.
- 10302/12700 pass (81.1%), wdc65c02, sample=50, seed=1 (pre-Option-C baseline,
  `build/sweep_wdc_nobcdfix_results.txt`).
- 62 functional failures — ALL ADC/SBC variants (61,65,7d,69,71,72,79,75,6d): final A/P/RAM mismatch.
- 2336 timing-only failures (final state correct).
- ~~Known new-core BCD bugs~~ **RESOLVED 2026-09-02** — the `S_DEC_FIX` dummy cycle (M_IMM read
  pc+2, default-mode read reg_pc=pc+3) was removed from `cpu_65c02.sv`; it matched neither the
  suite's addresses nor golden. Re-sweep in `build/sweep_wdc_nobcdfix_results.txt`: zero pass/fail
  change outside BCD, new core ≡ golden per-test on all 18 BCD opcodes. The WDC D=1 extra-cycle
  expectation remains as a suite convention (Category G) — both cores fail those tests identically.
- xF-column opcodes (0f..ff), 5c, 6c, 91, 99/9f, dc, ff fail 50/50; `de`/`fe`
  now pass 50/50 post Option C — see suite-quirk findings below.

## Golden R65Cx2 SST harness — how it works (hard-won details)

R65Cx2 = module `R65C02` in `rtl/R65Cx2.sv`. Ports: reset (**active-low**, held 1 forever),
clk, **enable** (the stall: theCpuCycle frozen while 0; PC/myAddr/S/regs all enable-gated too),
nmi_n, irq_n, di; outputs dout, addr, nwe, sync, sync_irq, Regs[63:0]
(Regs = {PC, 8'h01, S, N,V,R,B,D,I,Z,C, Y, X, A}).

TB injection scheme (all in `r65cx2_sst_tb.sv`):
1. Apply RAM patch (sentinel 0xEE fill).
2. **Drain**: en_sig=1, run on sentinel RAM until `int'(dut.theCpuCycle) == 5'd0`
   (opcodeFetch). Up to 64 negedges; $fatal if not reached. (theCpuCycle is an enum — NOT
   writable hierarchically; Verilator errors on implicit conversion, but the `int'(...)` READ cast works.)
3. **Stall + safe writes** (at a negedge, en_sig=0): PC=t_pc, myAddr=t_pc, T=0, irqActive=0,
   processIrq=0, nmiReg=0, irqReg=0, soReg=0, dout=0, **nwe=1** (drain may leave a stale write strobe).
4. Capture loop: row 0 sampled while stalled (clean fetch @t_pc); after row 0 set en_sig=1
   (release posedge = real fetch: latches theOpcode/opcInfo, PC<=myAddr, **and clobbers
   A/X/Y/S/flags with stale drain ALU result** because R65Cx2 commits architectural updates on
   the NEXT opcodeFetch via `updateRegisters`).
5. **At row 1**: inject A,X,Y,S,N,V,D,I,Z,C (R=1,B=0), T=0. The instruction's own register
   updates land on its final opcodeFetch, after this point.
6. **Final state is at row[ncyc+1], not row[ncyc]** → driver `--final-offset 1`.
   (Safe for non-updating opcodes too: nothing changes between the rows.)
7. RAM write commit in TB: `if (running && en_sig && ~nwe)` — **en_sig gating is mandatory**
   (without it, a stale nwe=0 during the stall posedge wrote dout=00 over the test opcode at row 0).

Batch/result line formats are identical to the new-core TB, so sst_driver.py is shared.
P-byte emitted as {N,V,2'b11,D,I,Z,C}; driver masks with 0x6F (clears R,B) — same convention.

### Golden calibration status (last run, sample=20 seed=1, --final-offset 1)

```
a9: PASS      05: PASS      85: PASS      a5: PASS
69: FAIL 11/20   e9: FAIL 9/20    65: FAIL 8/20    6d: FAIL 11/20
```

**MAJOR FINDING: the golden R65Cx2 ALSO fails the WDC BCD tests.** Pattern for D=1 ADC/SBC:
- extra-cycle address is NOT the suite's ($007F/$0000/re-read ea) — it's a garbage/pc-relative addr,
- **SP decrements by 1** on the BCD extra cycle (e.g. "final sp 9D != 9E") → the golden's BCD
  correction cycle looks like a stack operation!

So the new core's BCD "bugs" may actually be cases where BOTH cores diverge from the WDC suite
model, and the golden has its own BCD quirk. The 3-way comparison is essential before fixing anything.

**RESOLVED 2026-09-02 (see `wdc_vs_6502_analysis.md` Category G):** the SP decrement + `$FFFA`
vector fetch in the raw trace below were an artifact of the TB revision that produced it — a
synthetic BRK injected by `calcInterrupt` before the harness gained the `nmiReg`/`irqReg`/
`processIrq` state injection. A fresh `+DBG=0` run on the current TB (`build/bcd_dbg.txt`) shows
golden executing `69` D=1 as plain fetch → operand → final fetch: **no extra BCD cycle, no stack
traffic, `procIrq=0`**. The WDC suite's extra read ($007F/$0000/EA re-reads) is a reference-model
convention absent from the MOS 6502 suite and from real silicon. The new core's `S_DEC_FIX` state
(wrong-address dummy cycle) was removed; after the fix the new core matches golden per-test on all
18 BCD opcodes (`build/sweep_wdc_nobcdfix_results.txt`).

### Raw golden trace for 69 test (pc=6204, `69 90`, D=1, s=9E a=6B x=87 y=41 p=68) — DECODED (TB artifact, see above)

Suite expects: [6204 R 69][6205 R 90][007F R 0E], final pc=6206 s=9E a=61 p=29.
RAM: 6204=69, 6205=90, 6206=2E, 007F=0E.

Raw result line (tokens as emitted; row c = bus token then regs token):

```
R 00000000
6204R69 | 62040000000030   <- row 0 (note: sp shows 00, p=30 — pre-injection snapshot)
6205R90 | 62049e6b874178
6207Ree | 62069e6b874178
019eW62 | 62069e61874139
019dW06 | 62069d61874139
019cW29 | 62069c61874139
fffaRee | 62069b61874139
fffbRee | 62069b61874139
eeeeRee | 62069b61874139
eeefRee | 62069b61874139
eef0Ree | eeee9b61874135
eeeeRee | eef09b61874135
eeeeWee | eef19b61874135
eeeeWef | eef19b61874135
eef1Ree | eef19b61874135
```

(regs token = pc(4) sp(2) a(2) x(2) y(2) p(2). Decode on resume: note three consecutive stack-page
writes $019E/$019D/$019C with data 62/06/29, then vector fetches $FFFA/$FFFB — this sequence after
the BCD extra cycle needs identification; compare against R65Cx2.sv FSM (cycleStack*, cycleBranch*,
opcInfo table) to find what the BCD path triggers.)

Debug helper: run golden binary with `+DBG=0` → per-cycle stdout dump of
theCpuCycle/en/PC/myAddr/A/S/nwe/di/opcInfo[31:0] for test idx 0.
New-core TB: `+DBG=<idx>` dumps state/ir/dl/ea/idx_carry/nop8_cnt/sync/pc.

## Suite-quirk findings (WDC data itself)

- **ADC/SBC D-flag (BCD) extra read cycle (Category G, corrected 2026-09-03):**
  ~~I-flag re-attribution of 2026-09-02 was a bit-index error~~ — "P[3]" in LSB
  numbering is bit 3 = **D** (C=0 Z=1 I=2 D=3 B=4). The WDC-lineage suites add
  one extra read to every ADC/SBC when **D=1** (imm: fixed $007F/$0000;
  zp/abs/indexed: EA re-read); the original per-bit statistic (1017/1017 vs
  0/976) measured D all along. Decisive: for `69`/`e9` the suite pins I=0 on
  all 10000 tests per file, yet exactly the D=1 half takes the extra cycle
  (5000/5000); rockwell/synertek show the same D-dependence, MOS suites
  neither. Policy (a): documented, not emulated — the **D=1** half of every
  ADC/SBC opcode still fails on the new core (and golden).
- **Illegal-opcode decode mismatch (Category I):** `bf`/`df` 0/50 both cores —
  WDC models them as 2-byte zero-page ops; the core decodes LDA abs,X / DEC
  abs,X. Pre-existing, unchanged by Option C.
- **xF column (SPL/PHP/JAM/PLP/PHB/...), 2F, 5C: suite final PC values are nonsensical**
  (e.g. SPL #35 @FEB7 → final pc FF0E = pc+87; PHP → +75). Looks like the reference generator let
  the CPU run garbage after these opcodes. These tests are NOT reliable references. The core
  implements them per W65C02S datasheet (documented NOPs/halts); disagreeing with the suite here
  is acceptable — note it in the final report, don't "fix" the core to match nonsense.
- **$5C**: suite model = 3-byte, 4-cycle [fetch, pc+1, pc+2, pc+2 re-read], final pc=pc+3.
  Core model (cpu_65c02.sv line ~294: `8'h5C: C_NOP + M_ABS`) = 8 cycles, PC+=3, reads pseudo-addr
  {byte2,byte1} (=5AC9 in the observed case) — "approx: abs read" per its comment. Real divergence
  vs suite (8 vs 4 cycles).
- WDC `cycles` field is not a complete bus trace for all opcodes; b5=4c (65C02 alt LDA zp, dummy
  read), 05 ORA zp = 3c read-only (golden-verified: class readZp in R65Cx2 table line ~299; real
  MOS silicon writes back but this lineage deliberately doesn't — inherited golden behavior, NOT a bug).
- 62 (ADC (zp,X)) all 10000 tests degenerate (fetches only) — skip.
- cb.json/db.json are intentionally empty (git empty blob); driver handles JSONDecodeError → [].

## Verified earlier (from compacted context, still valid)

- r65 pair (golden vs new core on the 4000-row trace): 1504/1504 aligned fetch pairs identical;
  only real deltas = 4 abs,X shift/rotate +1c in golden, 2 JMP-indirect -2c in new core; final +2.
- T65 pair: phase A 1932/4160 mismatches, phase B 4378/6500; final states fully different;
  LCS alignment script `build/t65_align.py` written but never run to completion.
- Verilator gotchas: substr is INCLUSIVE-END; make step must be run manually; Windows paths need
  raw strings; UCRT64 bin on PATH for running .exes.

## Next steps (in order; item 1 done 2026-09-03)

Done so far: golden BCD trace decoded (TB artifact), golden full sweep
(`build/sweep_wdc_golden_results.txt`, 8093/12700), three-way + four-way tables
(`build/three_way_report.txt`, `build/four_way_report.txt`), BCD root cause + `S_DEC_FIX`
removal, **$F1 split (Category H)**, **$DE/$FE resolved by Option C (Category C)
under policy (a) with the zero-regression gate**, Category G re-attribution
(I flag), Category I added.

The remaining work is now organized by `CPU_COMPARISON_RECOMMENDATIONS.md`
(priorities 1–4 + decision policy). Plan agreed 2026-09-02:

1. ~~**Regenerate the r65 pair traces** (`run_divergence.ps1`, full — NOT~~
   **DONE 2026-09-03** (see top): 1504/1504 aligned fetches, zero
   opcode/address mismatches, final state identical modulo constant P_B,
   delta table unchanged. Clean baseline established. Original text:
   **Regenerate the r65 pair traces** (`run_divergence.ps1`, full — NOT
   -CompareOnly: the new-core RTL changed with Option C). The existing
   `build/r65_trace.csv` (new core) is stale; the four-opcode delta table in
   `cpu_cycle_analysis.md` §4.1 may change (M_ABX cross/forced-fix instances:
   .ax shifts, INC/DEC abs,X, JMP abs,X now dummy at pc+2). Re-verify the
   equivalence story: same instruction stream, same final state.
2. ~~**Priority 1 — semantic checker**: one maintained tool~~ **DONE
   2026-09-03 (see top)**: `semantic_compare.py` + `semantic_whitelist.txt`
   in place; PASS on the regenerated pair; 5-case mutated-trace negative
   validation all correct; `--report-reads` report-only. Original text:
   **Priority 1 — semantic checker**: one maintained tool
   `module_tests/cpu_65c02/semantic_compare.py` + named whitelist file replacing
   the build-dir ad-hoc helpers (9 requirements in the recommendations doc;
   initial whitelist = the §4.1 four-opcode table with stable IDs; "final
   write-map equality" as a separately named sub-check). Validate with a
   mutated-trace negative test before trusting it.
3. **Priority 2 — correct `cpu_cycle_analysis.md`**: narrow headline to the
   exact r65 stimulus; precise transaction wording; architectural vs
   bus-protocol separation; BRK = source-level reasoning; RTI/interrupt-return
   not covered; fix IRQ vector `$FFFC/$FFFD` → `$FFFE/$FFFF` (§4.4); explain
   1504 fetches = repeated park loop; accepted-differences table shares IDs
   with the whitelist.
4. **Priority 3 — directed coverage gaps**: BRK, RTI (document R65Cx2's
   non-standard semantics first), IRQ masked/unmask timing, NMI edge +
   priority, interrupt return/nesting, mid-stream reset at each phase,
   JMP (abs,X) X≠0/cross/boundary, RMW into side-effecting I/O (write-strobe
   counter in the TB memory model). Coverage gate per case.
5. **Priority 4 — finish independent comparisons**: T65 VHDL→Verilog baseline
   first, then phase-A/B alignment; SST re-description as a 50-sample sweep;
   `build/fail_sigs.py` for the 30 both-suites-agree opcodes; provenance
   metadata (suite revision, seed=1, test IDs, RTL SHA-256s, checker version)
   with every retained result.
6. **Optional: MOS-suite sweep** — run the `6502` suite through both SST
   binaries to directly prove "cores track MOS" for RMW/page-cross categories
   (same batch shape as the WDC sweeps).
7. **Final verdict**: fold Categories A–I + three/four-way results + policy (a)
   into `cpu_cycle_analysis.md` or a new summary doc; commit only when asked.

## Git state (2026-09-02, post Option C)

~50 files STAGED, not committed: `rtl/new_cpu/` (both .sv — `cpu_65c02.sv`
re-staged with the Option C edit), all `module_tests/cpu_65c02/` sources/docs
(`wdc_vs_6502_analysis.md`, `sst_progress.md` re-staged updated), and persistent
build artifacts force-added (`module_tests/.gitignore` has `**/build/`; precedent =
tracked files under `module_tests/r65c02/build/`). New this session:
`sweep_wdc_abxfix_results.txt`, `regress_check.py`, `cpu_65c02_preabxfix.sv`
(force-added). Binaries, Verilator-generated objects, and transient WIP dumps
were left out. Other sessions' modified files (Apple-II.qsf, vga_color_test/*,
…) are untouched.

## Do NOT lose

- `build/sweep_wdc_results.txt` (12700 lines) is the only copy of the pre-fix new-core sweep
  detail; `build/sweep_wdc_nobcdfix_results.txt` is the post-DEC_FIX-removal re-sweep (the
  Option C baseline); `build/sweep_wdc_abxfix_results.txt` is the current state.
- `build/cpu_65c02_preabxfix.sv` = pre-Option-C snapshot of the new-core RTL
  (also at `/tmp/cpu_65c02.sv.pre-abxfix`, which may vanish).
- `build/bcd_batch.py` / `bcd_batch.txt` / `bcd_dbg*.txt` / `bcd_matrix.py` = BCD root-cause
  artifacts (targeted D=1 batches, per-cycle FSM dumps, per-mode matrix).
- `build/fail_examples.json` = first failure example per failing opcode (new core).
- The r65 pair traces: `module_tests/r65c02/build/verilog_trace.csv` (golden),
  `module_tests/cpu_65c02/build/r65_trace.csv` (new core).
- T65 traces: `module_tests/t65/build/{verilog,vhdl}_{prog,boot}.csv`,
  `module_tests/cpu_65c02/build/t65_{prog,boot}_trace.csv`.
