# SST (single-step test) progress handoff — 2026-09-03

Resume point for the WDC 65x02 single-step harness work. Read this top to bottom, then continue at "Next steps".

**Current state (machine clock 2026-09-02; supersedes the
"Remaining: Priority 4 onward" line in the block below): PRIORITY 4
COMPLETE — all five sub-items shipped and verified.**

1. **T65 baseline + alignment: PASS.** The boot preamble fix (A9 21 A2 32
   A0 43 at $6B4C–$6B51) was already in both `t65_vhdl_tb.vhd` and
   `t65_verilog_tb.sv`; re-verified with `run_equivalence.ps1 -CompareOnly`:
   `T65 EQUIVALENCE PASS rowsA=320 rowsB=500 fieldsA=3072 fieldsB=5784
   ignored_metavalues=80 gate_checks=17`. (Full-repo `run_tests.ps1` and the
   apple2 harness cycle-358 re-run remain as optional follow-ups.)
2. **SST re-described as a 50-sample sweep + $DE decision closed.** New
   maintained tool `rebuild_summary.py` reconstructs the deterministic
   selection (`random.Random(1*1000+op).sample(tests, 50)` per op, cb/db
   empty → 12700) and re-derives summaries from the raw traces:
   `build/sweep_wdc_abxfix.txt` = **10798/12700** — exactly the recorded
   Option-C state (diff vs the pre-rebuild summary shows only the M_ABX
   family changed, as expected). $DE/$FE now PASS 50/50 on the new core;
   decision: keep the Option C WDC-convention model (single write +
   no-carry-EA dummy). Golden R65Cx2 still fails them per Category C.
3. **`build/fail_sigs.py` shipped** → `build/fail_sigs_report.txt`: the 30
   agreed-reference opcodes (WDC==MOS pattern) with true fail counts and
   normalized signatures for both cores; golden-only / new-only (NONE) /
   golden-only-fail (57 opcodes) / new-only (none) / both-fail (52
   opcodes) sections. Agreed-reference totals: new core
   667/1500, golden 1050/1500.
4. **Categories kept separate** (WDC convention / MOS convention /
   suite-generator quirk / core defect) — root-caused this session with
   trace-level evidence (see `wdc_vs_6502_analysis.md` Category F, updated):
   - Category D (bbb=4 "(zp),Y" generator convention): *perfect* Y-carry
     correlation re-verified — 51: 30/30, b1: 25/25, d1: 25/25 of failures
     are exactly the Y-page-cross tests; $91 fails all 50 on the core's
     read-before-write at EA vs the suite's `pc+1` re-read.
   - Category C (abs,X/abs,Y page-cross dummy): 19: 20/20 and 39: 21/21
     failures are cross-only; f9 = 21 cross + 14 BCD D=1; golden-only
     {3c 5d bd} loads + {9d 9e} stores (double-write RMW pre-write).
   - Category G (BCD D=1 extra read): failures confined to the D=1 subset
     of 65/69/e5/e9/ed/fd.
   - Category I (undocumented decode): golden-only {44 54 d4 f4} — new core
     implements the WDC suite's NOP model (`cpu_65c02.sv` decodes 54/d4/f4
     as `C_NOP, M_ZPX`, cycle-for-cycle match with the suite) while R65Cx2
     uses a shorter zp-style model; bf/dc/fc = undocumented/xF-column
     conventions (suite final PCs there are nonsensical, e.g. $BF @A142 →
     final A0FB — unreliable reference).
   - NEW-ONLY-FAIL: none — the new core never fails where golden passes.
5. **Provenance metadata shipped.** New maintained tool `provenance.py`
   → `build/provenance.json`: suite commit 2f6980a (clean tree), seed=1,
   per-opcode sampled test IDs (all 12700, verified to reproduce the
   driver's selection exactly), SHA-256 of RTL (new core + ALU + R65Cx2),
   TBs, checker tools, SST binaries, and every retained result file; zero
   missing hashes. Re-run after any rebuild to refresh.

**Remaining: optional MOS-suite sweep (Next step 6) and the final verdict
doc (Next step 7).**

**Current state (2026-09-02 machine clock, crash recovery; supersedes the
"Remaining for Priority 3" line in the block below): Priority 3 COMPLETE —
PHASE 2 shipped, all 12 directed cases green (exit 0).**
`p3_cases.py` full run from repo root: p3-brk PASS, p3-rti PASS,
p3-irq-masked PASS, p3-irq-unmask EXPECTED, p3-nmi-priority EXPECTED,
p3-nmi-during-irq EXPECTED, p3-adj-shift EXPECTED, p3-jmpax PASS,
p3-reset-park PASS, p3-reset-midinsn PASS, p3-reset-midpush PASS,
p3-rmw-toggle PASS (rollup `build/p3/summary.json` with both exe SHA-256s).

Phase 2 deliverables:
- **TB plusargs in BOTH r65-pair TBs** (`cpu65_r65_tb.sv`,
  `r65c02_verilog_tb.sv`; contracts documented in the golden TB header):
  `+RESETAT=<cyc>` re-asserts reset for 4 cycles [cyc, cyc+4) mid-stream
  (write commits suppressed inside the window so a stale strobe from an
  interrupted instruction cannot corrupt the image) and `+WRTOGGLE=1` makes
  every write commit a stateful toggle of the CURRENT byte
  (`mem[addr] <= mem[addr]^8'h01`, dout discarded) so write-STROBE-COUNT
  differences (the golden RMW old-value pre-write) become visible in final
  memory. Both default-off and behavior-preserving: all phase-1 verdicts
  unchanged.
- **p3-reset-park** (reset in the self-JMP park operand phase),
  **p3-reset-midinsn** (reset mid-JSR operand phase, before the push lands;
  post-reset re-execution compared positionally via semantic_compare.py
  `--reset-at` + `--compare-from`), **p3-reset-midpush** (reset inside a
  PHA/PHP sequence with WRTOGGLE=1: any ungated stale commit during the
  window flips write parity and fails final-memory equality).
- **p3-rmw-toggle**: six absolute RMW instructions (ASL/EOR/INC/TSB/ROL/DEC
  abs) over scratch $0200–$0205 with WRTOGGLE=1. Result: golden = exactly 2
  strokes per address (pre-write + final → initial byte restored), new core
  = exactly 1 stroke (→ initial^1); no other write addresses; parity equal
  everywhere else. This empirically demonstrates the whitelisted
  RMW_PREWRITE_GOLDEN class on side-effecting memory — a memory-mapped
  device WOULD see the extra pre-update write strobe (the decision-policy
  "Apple II I/O impact review" item now has an executable reference).
- **Negative mutation validation of check_rmw_toggle**: dropping golden's
  pre-write row at $0200 → DETECTED (final value + stroke count); appended
  stray write to an unrelated address in golden only → DETECTED (parity).
  DO corruption is the semantic checker's final write-map equality job
  (negative-validated in the earlier session).

Crash-recovery bug fixes in p3-rmw-toggle (the case was FAILing at crash
time; NEITHER finding was an RTL bug):
1. **Test program used zero-page opcodes, not absolute:** `06`/`E6`/`C6`
   are ASL/INC/DEC **zp** (2-byte); absolute is `0E`/`EE`/`CE`. Both cores
   decoded them correctly — the observed "broken walk" (RMWs at $0000/
   $0002/$0005, park JMP eaten by the misaligned stream) was correct CPU
   behavior on a wrong program. The misaligned walk then ran into base-
   pattern code where WRTOGGLE parity differences (e.g. $0000 = 3c golden
   vs 3d new) changed computed addresses ($3C4A vs $3D4A) and diverged the
   streams at fetch #112 (golden=168 vs new=141). Fixed opcodes; the walk
   now reaches the park cleanly and both streams are identical.
2. **rmw_expect new-core values were `f(initial)^1` — wrong under pure
   toggle semantics** (dout is discarded; each stroke flips bit 0 of the
   CURRENT byte, so one stroke → `initial^1`). Fixed to initial^1 per
   address. The computed f(initial) still lands on DO and is covered by the
   semantic checker's final write-map equality (last-write-wins: golden's
   last pre/post write and the new core's single write both carry
   f(initial)).

**Remaining: Priority 4 onward** (T65 VHDL→Verilog baseline + alignment,
SST re-description as a 50-sample sweep, provenance metadata; optional MOS-
suite sweep; final verdict) — see "Next steps" items 5–7.

**Current state (2026-09-04): Priority 3 PHASE 1 DONE — all 8 directed cases green on the canonical base image.**
`p3_cases.py` full run (MSYS Python from repo root): p3-brk PASS, p3-rti PASS,
p3-irq-masked PASS, p3-irq-unmask EXPECTED, p3-nmi-priority EXPECTED,
p3-nmi-during-irq EXPECTED, p3-adj-shift EXPECTED, p3-jmpax PASS (exit 0;
artifacts per case under `build/p3/<case>/`, rollup `build/p3/summary.json`).
Findings baked into the harness/checker this session:
- **Stale-base-image artifact resolved.** The earlier 6-case FAIL batch ran
  against a hex left by a crashed session (0600=`4C 08 09`, 0908=`08`); the
  canonical `r65_mem_init.hex` (0600=`A1 D0 B1…`, 0908/090B self-JMP parks,
  0A00-0B00 sequential filler) is restored and verified; every trace was
  regenerated against it.
- **Stack model verified on both cores:** push (PHA/PHP/BRK/interrupt entry)
  = store at [S] then S←S-1; RTI = P←[S+1], PC_lo←[S+2], PC_hi←[S+3], S←S+3.
- **RTI D-force expectation retracted.** R65Cx2's `T <= di|0x30` (calcT,
  PLP/RTI) shows only transiently in T/dout; the D flag register is NOT
  forced on either core — both restore N,V,D,I,Z,C identically from the stack
  byte, and PHP pushes the B|D-forced status (30) on BOTH cores. p3-rti now
  expects a clean pass (target = base's own `JMP $0908` at 0905; no park
  clobber). The old `expect='rti-d-flag'` path was removed from evaluate().
- **Entry-latency model confirmed** on all four pulse cases: golden has
  exactly one extra dummy entry fetch per entry (its address equals that
  entry's pushed return PC); the new core pushes one instruction earlier.
  `check_entry_latency` resync: identical (addr,op) prefix, ≤1 extra golden
  row per entry, push-triple pairing with return-PC delta ∈ {0,1,2} (status
  must match at a shared boundary), park-loop tails (length delta ≤ 2 — the
  new core parks earlier in the fixed 400-cycle window and gets more park
  fetches; its remainder is tail, not a stream mismatch), final state equal
  except PC within the park window.
- **p3-jmpax redesigned** (old layout clobbered both base parks): stage 2
  lives in the 0A0B filler region; ptr1 @0A07 → 0A0B; ptr2 @**0B00** —
  `JMP ($0A01,X)` with X=FF computes EA = 0A01+FF = **0B00** (low-byte wrap
  WITH page carry; the old comment "EA=0AFF" was an arithmetic error); target
  = base park at 0908, untouched.
- **semantic_compare.py additions** (behavior-preserving for previously
  passing cases; all report-and-accept, never silent):
  1. state_at_boundaries: after PLP/RTI, flag columns also accept the
     UNSHIFTED match (writeback lands mid-instruction at different phases;
     both cores agree at their own fetch row) — reported as
     `rti_flag_unshifted`.
  2. final_state: PC park-loop phase tolerance — if both last fetches are at
     the same address and the PC-column delta ≤ 3, it is self-JMP loop phase
     (golden PC column lags one row), reported, not failed. p3-brk's earlier
     pass was a phase coincidence; this makes it robust.
  3. fetch_pair: count mismatch accepted when every extra row of the longer
     trace repeats the last paired (addr,op) — park-loop phase from
     whitelisted LEN deltas (e.g. `LEN -1 7c`: JMP (abs,X) is 5c golden /
     6c new; two instances shift the park entry by 2 cycles and one trace
     fits one more park fetch in the window). Reported as `count_note`.
- **Remaining for Priority 3:** phase 2 (TB plusargs `+RESETAT`, write-toggle
  memory for mid-stream reset + side-effecting RMW), then closeout per the
  recommendations doc. Then Priority 4 and the final verdict (next steps 5–7).

**Current state (2026-09-03, cont. 3): Priority 3 STARTED — directed coverage gaps.**
Both r65-pair TBs inspected for the case harness design:
- `module_tests/cpu_65c02/cpu65_r65_tb.sv` (new core) and
  `module_tests/r65c02/r65c02_verilog_tb.sv` (golden) both take plusargs
  `+IRQPULSE=<cyc>` / `+NMIPULSE=<cyc>` (8-cycle pulse from <cyc>, 0 =
  disabled) and `+TOTAL=<cyc>` (default 4000). Reset window is hardcoded to
  cycles 0..3 in both (active-high sync in the new-core TB, active-low in
  the golden TB).
- **Both TBs hardcode the memory image path**
  (`$readmemh("module_tests/r65c02/build/r65_mem_init.hex", mem)`)
  **and the output trace path** (golden → `module_tests/r65c02/build/
  verilog_trace.csv`, new core → `module_tests/cpu_65c02/build/
  r65_trace.csv`), CWD = repo root. No rebuild needed for directed cases:
  swap the hex file per case (back up + restore in a finally block), run
  both exes with the same plusargs, copy both CSVs to
  `module_tests/cpu_65c02/build/p3/<case>/` before the next run.
- Golden TB header documents: "The DUT samples the interrupt lines only on
  non-fetch/non-branch-taken cycles, so a 1-cycle pulse can be missed
  depending on instruction phase" — relevant to IRQ/NMI timing cases; our
  pulses are 8 cycles so they cannot be missed, but entry latency is
  phase-dependent (that is what the cases measure).
- New-core TB: `SYNC_IRQ = sync && int_seq` (int_active stays high through
  the whole interrupt sequence); write commit at posedge where registered
  `we` is high. Golden: write commit where registered `nwe` is low.
- Mid-stream reset and side-effecting-I/O RMW cases REQUIRE TB changes
  (proposed optional plusargs, behavior-preserving defaults): `+RESETAT=<cyc>`
  (re-assert reset for 4 cycles at <cyc>, 0 = disabled) and a write-toggle
  memory mode (e.g. `+WRTOGGLE=1`: write commit does `mem[addr] <= dout^1`,
  so any extra write strobe changes the final byte — makes the golden RMW
  pre-write visible to final write-map equality). Phase these after the
  no-TB-change cases.
Phase-1 case list (no TB change, hex-swap only): BRK push+vector entry;
RTI restoration (read R65Cx2.sv RTI/BRK semantics first — R65Cx2 has
documented non-standard RTI behavior); IRQ while masked + unmask timing;
NMI/IRQ priority + NMI during IRQ handling; interrupt request adjacent to
a length-differing instruction (.ax shift); JMP (abs,X) with X≠0, page
carry near $FF, boundary addresses. Each case gets a coverage gate via
`semantic_compare.py --gate NAME=ADDR` proving the intended path executed,
plus case-specific expected-difference handling where a documented delta is
the point of the case (e.g. RMW pre-write under WRTOGGLE).
Harness file planned: `module_tests/cpu_65c02/p3_cases.py` (case table +
hex patching from the original r65 image + run + compare + summary).

**Current state (2026-09-03, cont. 2): Priority 2 DONE — `cpu_cycle_analysis.md` corrected** per the recommendations doc: narrowed headline (architectural vs bus-protocol equality separated), precise check names (final write-map equality ≠ transaction equality; ordered write events = 98 vs 70 rows, exactly 28 whitelisted RMW pre-writes), BRK marked source-level-only, RTI/interrupt-return marked not covered, IRQ vector fixed to `$FFFE/$FFFF`, 1504-fetch composition explained (766 distinct + 738 park-loop repetitions), §4.1 delta table now carries whitelist IDs shared with `semantic_whitelist.txt`. Next: Priority 3 directed coverage.

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
| **Semantic checker (Priority 1, 2026-09-03)** | `module_tests/cpu_65c02/semantic_compare.py` + `semantic_whitelist.txt`; JSON summary `build/semantic_summary.json`. Usage: `python semantic_compare.py <golden.csv> <new.csv> [--whitelist ...] [--report-reads] [--gate NAME=ADDR ...] [--reset-at CYC --compare-from ADDR (phase-2) --json-out FILE]`; exit 0 pass / 2 divergence / 1 usage |
| **Priority 3 directed-case harness** | `module_tests/cpu_65c02/p3_cases.py` — 12 cases (8 phase-1 + 4 phase-2), hex-swap per case with backup/restore of the shared image AND both canonical traces, probe run for anchor location, per-case artifacts under `build/p3/<case>/`, rollup `build/p3/summary.json`. Run: `/c/msys64/ucrt64/bin/python module_tests/cpu_65c02/p3_cases.py [--only NAME]` from repo root. Phase-2 TB plusargs `+RESETAT`/`+WRTOGGLE` documented in the golden TB header |
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
3. ~~**Priority 2 — correct `cpu_cycle_analysis.md`**: narrow headline to the
   exact r65 stimulus; precise transaction wording; architectural vs
   bus-protocol separation; BRK = source-level reasoning; RTI/interrupt-return
   not covered; fix IRQ vector `$FFFC/$FFFD` → `$FFFE/$FFFF` (§4.4); explain
   1504 fetches = repeated park loop; accepted-differences table shares IDs
   with the whitelist.~~ **DONE 2026-09-03**: all eight items applied and
   trace-verified (IRQ vector read at G cycles 736/737 = `$FFFE/$FFFF`;
   park loop = 738 repeated fetches of the single `4C` @ $0908; 766
   non-park fetches each at a distinct address: 760 program + 6 handler;
   28 RMW pre-write instances enumerated per opcode in §4.1). Step 2 now
   documents why fetch selection is `SYNC=1` alone (G marks the whole 7-row
   entry sequence with SYNC_IRQ, N only the entry fetch + reset first
   fetch); Step 4 carries the verified one-fetch skew rule; Step 5 renamed
   to final write-map equality with the first-write-wins measurement
   caution; §6 lists `semantic_compare.py` as the primary maintained gate.
4. ~~**Priority 3 — directed coverage gaps: PHASE 1 DONE (2026-09-04, see
   state block at top); phase 2 remains.** Phase 1 shipped all eight no-TB-
   change cases green (BRK, RTI, IRQ masked/unmask timing, NMI priority +
   NMI-during-IRQ, adjacent length-delta IRQ, JMP (abs,X) wrap+carry). Phase
   2 = optional-plusarg TB edits (`RESETAT`, write-toggle memory) for
   mid-stream reset at each phase and RMW into side-effecting I/O.~~ **DONE
   (crash-recovery session): all 12 cases green, exit 0 — see top state
   block. Every item on the recommendations-doc Priority-3 coverage list is
   now covered with a gate.**
5. ~~**Priority 4 — finish independent comparisons**: T65 VHDL→Verilog baseline
   first, then phase-A/B alignment; SST re-description as a 50-sample sweep;
   `build/fail_sigs.py` for the 30 both-suites-agree opcodes; provenance
   metadata (suite revision, seed=1, test IDs, RTL SHA-256s, checker version)
   with every retained result.~~ **DONE (machine clock 2026-09-02)** — see the
   top state block: T65 PASS; `rebuild_summary.py` (10798/12700, $DE/$FE
   closed); `fail_sigs_report.txt` (30 agreed opcodes + all-fail sections);
   category root-cause re-verified at trace level; `provenance.py` →
   `build/provenance.json`.
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
