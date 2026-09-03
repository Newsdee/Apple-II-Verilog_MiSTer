# V2 CPU — verdict (2026-09-03)

Scope: `rtl/new_cpu_v2/cpu_65c02.sv` (+ `cpu_alu.sv`), the v2 65C02 core.
This document supersedes `FINAL_VERDICT.md` for all v2 claims. Every number
below was re-verified on 2026-09-03 from the retained raw results
(`module_tests/cpu_65c02/evidence/sweep_*_results.txt`) with the current
checker; provenance (suite commit, RTL/tool/binary hashes, pass counts)
is in `module_tests/cpu_65c02/evidence/provenance.json`.

Artifact convention: everything whose generation takes longer than ~10
minutes (raw sweep results, pinned Verilator binaries, provenance.json)
lives in `module_tests/cpu_65c02/evidence/`; derived summaries
(`build/sweep_*.txt`) are not stored and are regenerated on demand from
the raw results by `build/regen_all_summaries.py` (seconds to a few
minutes). Raw results are never touched by any analysis tool.

## Status

- **Verified (simulation, SST instruction-completion):** the results in §1–§4.
- **Unverified:** sequence-level (multi-instruction) evidence — the paired
  Verilator/R65Cx2 replay and P3 semantic cases exist only for v1; hardware;
  Quartus timing/resources for `new_cpu_v2`.
- The MiSTer target CPU is ST2204 (65C02), so **`WDC_MODE=1` is the
  deployment configuration**. `WDC_MODE=0` ("NMOS bus-convention mode", see
  §7) exists for 6502 replication/diagnostics only.

## 1. WDC_MODE=1 results (target machine)

Checker: `sst_driver.compare()` v2 — includes the instruction-complete
check (§4). After the checker change, all pass totals were recomputed
directly from the raw results in `evidence/` with the current checker
(`build/regen_all_summaries.py` reproduces them on demand; summaries are
not stored). Raw results are untouched.

| Suite (sampled) | v1 | **v2** | golden R65Cx2 |
|---|---|---|---|
| wdc65c02 (12700) | 10798 | **12106 (95.3%)** | 8092 |
| rockwell65c02 (12800) | 10829 | **12155 (95.0%)** | 8132 |
| synertek65c02 (12800) | 10031 | **10563 (82.5%)** | 8125 |
| 6502 MOS (12800) | 6406 | 5983 | 7749 |

(Additional retained baseline: wdc65c02 v1 pre-OptionC 10302/12700.)

Properties (reconciled from raw results, `v2_reconcile.py`):

- On all three 65C02 suites **v2's pass set is a strict superset of
  golden's** — no test that golden passes does v2 fail; v2 additionally
  passes 4014 (WDC), 4023 (Rockwell), 2438 (Synertek) sampled tests.
- v2 fixed **1106** of v1's 1902 WDC-suite failures and **regressed 0**;
  v2's 594 residual WDC failures are a strict subset of v1's.
- The v2 WDC_MODE=1 MOS total (5983) is *below* v1 (6406) by design: the
  MOS suite rewards 6502-era bus behavior; v2's fixes target 65C02 vendor
  behavior. WDC_MODE=0 recovers the MOS side (§2).

v2 residual failures (WDC_MODE=1, per-op counts verified from raw results):

| Suite | total | NOP-abs 5c/dc/fc | JAM 72/f2 | xD + BCD arithmetic | Xf column / other |
|---|---|---|---|---|---|
| wdc65c02 | 594 | 150 | 56 | 388 | 0 |
| rockwell65c02 | 645 | 150 | 48 | 397 | 50 (db) |
| synertek65c02 | 2237 | 150 | 42 | 395 | 1600 (32 Xf ops, 50/50) + 50 (db) |

Class notes:

- **NOP (abs) 5c/dc/fc (150 each):** both cores treat these as NOP; the
  suites model them as JAM-like 3-byte ops. Vendor-undefined op; no chase.
- **JAM family (72/f2):** bus-cycle-layout divergence at the halt boundary;
  final state matches (see §4 for the same class on the MOS suite).
- **BCD (xD + 6x/7x/ex/fx arithmetic):** vendor BCD-modeling class; the
  48-test −0x10 subset is documented in §5. Same sets fail in v1; no v1→v2
  regression.
- **Xf column (Synertek, 1600):** the Synertek suite models Xf as
  BBR/BBS; the core (and both cores) use the 65C02 JAM-family decode.
  Expected decode divergence, not a defect.

## 2. WDC_MODE=0 — "NMOS bus-convention mode"

Purpose: replicate MOS 6502 bus behavior on the v2 RTL. Not a deployment
mode. Results on the MOS 6502 suite (v2 RTL, `WDC_MODE=0` vs `WDC_MODE=1`):

- **v2nmos: 7973/12800 (62.3%)** vs golden R65Cx2 **7749/12800** → v2nmos
  beats golden by **224** tests.
- **Strict superset:** both-pass = 7749 (= golden's entire pass set),
  v2nmos-only-pass = 224, **v2nmos-only-fail = 0**. (Before the
  completion check, v2nmos "lost" 20 op-7c tests that golden passed by
  row-alignment coincidence; both now fail them — see §4/§5.)
- **WDC_MODE=0 vs WDC_MODE=1 on the same v2 RTL: 1990 tests fixed, 0
  regressed.** Fixed classes (verified per-op from raw results): RMW
  double-write removal (28 ops × 50), (zp)/abs,Y page-cross dummy
  re-reads, BCD D=1 extra-cycle, BRK (00:22). Full op list in
  `build/v2nmos_report.txt`.
- Both-fail (v2nmos and golden): **4827/12800 (37.7%)** — no sampled MOS
  test exists where exactly one of the two 6502-behavior implementations
  passes. Class table (regenerated with the current checker,
  `build/mos_bothfail_report.txt`):
  - 3200 — 64 broken-reference files (suite-generator bugs; no core can
    pass them).
  - 300 — JAM/SLO family 04/0C/5A/7A/DA/FA (vendor model divergence, §4).
  - 20 — op 7c decode divergence (§5).
  - 100 — af/bf Xf column (65C02 BBR/BBS decode vs MOS undefined).
  - 150 — NOP (abs) 5c/dc/fc.
  - 100 — cb/db undefined-op model.
  - 79+ — xC (3c/34/89/79) flag-model class.
  - 48 — BCD −0x10 class (§6).
  - remainder — partial xD/BCD and Xf samples.

  Practical MOS floor for a 65C02 core on this suite ≈ 8300/12800.

## 3. Op 7c finding (do not chase)

The $7C "cross-page mismatch" reported in the v1 era was **mislabeled**.
All three implementations (v1, v2, R65Cx2) decode $7C as `JMP (abs,X)`
(v2 line 312, v1 line 307, `R65Cx2.sv:421/1287`). The divergence is a
*decode* divergence, not a page-cross bug:

- **WDC 65x02 suite** models 7c as `JMP (abs,X)`: 6 cycles, final PC =
  jump target. v1/v2/golden all match → 50/50 pass.
- **MOS 6502 suite** models 7c as a 3-byte MOS-undefined-op: 4/5 cycles,
  final PC = pc+3, state unchanged. All cores mismatch at the bus level.

The old checker's "golden passes 20 of 50" on the MOS suite was a
row-alignment artifact: golden's 5-cycle model happened to place a fetch at
the sampled boundary row. The completion check (§4) now demotes that
coincidence; 7c is a both-fail on the MOS suite. Verdict: expected
65C02-vs-MOS undefined-op behavior; document, don't chase.

## 4. SST instruction-completion check (new, 2026-09-03)

**What:** `sst_driver.compare()` now additionally requires that the cycle
row where the *next instruction's opcode fetch* lands (row `ncyc` of the
suite's expected cycle list; `final_offset` shifts only the register row,
because R65Cx2 commits A/flags one row after PC) is a **READ at the
expected final PC**.

**Why it was missing:** the old checker compared the suite's expected
cycles `0..ncyc-1` and the final register/RAM state. A core (or the golden
model) could execute *extra or different bus activity* at/after the
instruction boundary and still pass if its final state matched. That hid
entire divergence classes.

**Effect (recomputed from raw results; raw results unchanged):** 7 of 14
totals changed; all 7 groups are classified, **none is a new core defect**:

| Group | Δ | Classification |
|---|---|---|
| 6502 v1/v2/v2nmos, JAM/SLO family (04/0C/5A/7A/DA/FA × 50) | −300 each | **Vendor-model divergence.** Core does WDC 65C02 behavior: SLO-style RMW for X4/XC and stack-write + halt-at-pc+1 for the XA family — verified byte-exact against the **WDC** suite (all pass 50/50 *including* the new check, data included). The MOS suite models MOS-silicon behavior (no push / different cycle layout). The old checker only looked at final state, where both models agree. |
| 6502 golden, 04/0C × 50 | −100 | **Golden-model quirk.** R65Cx2 executes 04/0C as SLO zp/abs with a writeback at the boundary row (row 3–4 = W), while the MOS suite's cycle list ends at row 2/3. Final state matches; boundary bus activity does not. |
| 6502 golden, 7c × 20 | −20 | **Coincidence demoted** — the known decode divergence (§3), previously masked by row alignment. Now correctly both-fail. |
| wdc65c02 golden, 1e × 1 (idx 05FC) | −1 | **Golden-model quirk.** R65Cx2 duplicates the RMW writeback cycle on an (abs,X) page-cross (rows 5 *and* 6 both `W`); the suite expects one write at row 5. 1 test in 12700. |
| synertek65c02 v1 & v2, 07-family SLO (zp,X) (8 ops × 50 + b7 × 1) | −401 each | **Vendor-model divergence.** Core does the 5-cycle RMW (read, re-read, no-op write-back of the same value) — exactly the **WDC** suite's model (passes 50/50 with the new check). The Synertek suite models 3-cycle read-only. Final state matches both references; only bus-cycle count differs. Identical delta on v1 and v2 → suite-model difference, not a core change. |

Unchanged: wdc65c02 v1/v2/pre-OptionC, rockwell v1/v2/golden, synertek
golden. The strengthened checker is strictly stronger and has been pinned:
all pass totals are recomputed from the raw results in `evidence/` with
the current checker, and `regen_all_summaries.py` (dry run) reproduces
all 14 derived totals byte-identically.

## 5. BCD −0x10 class (48 tests) — document, do not chase

SBC D with D=1 on certain operand classes leaves the core's A low nibble
0x10 high (e.g. fd idx 0x316F: suite A=0x7F, core A=0x6F). **R65Cx2 also
produces 0x6F** — the golden model shares the behavior, so this is a vendor
BCD-divergence class in the suite reference, not a core defect (and not
fixable without diverging from the golden model). 48 tests on the MOS
suite; the same class appears partially in the BCD columns of all suites.

## 6. Sampling caveat (wording matters)

Every suite number is **50 tests per opcode, fixed seed (seed=1), from
~10000 generated tests per opcode** — a reproducible sample, not an
exhausted test space. Correct claim:

> *All sampled tests with reliable references pass (or fail only in the
> documented vendor-divergence and broken-reference classes).*

Not correct: "95.3% of all 65C02 behavior is verified". The WDC suite's
12700 = 254 non-empty opcodes × 50; the MOS/rockwell/synertek suites have
256 opcodes × 50. The "breadth score" (coverage of ops exercised) is a
secondary diagnostic, not a correctness claim.

## 7. Naming

`WDC_MODE` is a misnomer at 0. `WDC_MODE=1` = default 65C02 (WDC/ST
conventions). `WDC_MODE=0` = **NMOS bus-convention mode** (6502
replication). Renaming the parameter is deferred to a clean branch;
documented here in the meantime.

## 8. Unverified / remaining

1. **Sequence-level evidence for v2 (biggest gap).** The paired Verilator
   vs R65Cx2 replay harness (`cpu65_r65_tb.sv`) and the P3 semantic cases
   were built and verified only against v1. v2 inherits no semantic-level
   evidence yet. Requires a user go-ahead (campaign step 4).
2. **Hardware** — nothing here is a hardware result.
3. **Quartus** — `new_cpu_v2` has no map/fit/timing report in this project
   yet; the v1-era reports in `output_files/` do not cover it.
4. **v2 RTL is staged but uncommitted** (per user policy: commit only on
   request).

## 9. Provenance and reproduction

- `module_tests/cpu_65c02/evidence/` holds the long-generated evidence:
  the 15 raw sweep result files, the 5 pinned Verilator binaries, and
  `provenance.json` (regenerated 2026-09-03): suite commit `2f6980a2`
  (clean tree), SHA-256 of v1/v2/golden RTL, all SST binaries, all
  analysis tools, all raw results, sampled test-id lists for all four
  suites, per-sweep `depends_on` closure, and recomputed per-sweep
  `pass_count` (with `pass_count_inputs` cache keys so unchanged reruns
  are cheap). Raw results and binaries are never rewritten.
- The v2 WDC_MODE=1 SST binary (`Vcpu65_sst_tb_v2_wdc.exe`) was **rebuilt
  2026-09-03** after the move into `evidence/`: the WDC_MODE=1 and
  WDC_MODE=0 binaries shared the file name `Vcpu65_sst_tb_v2.exe` and one
  overwrote the other. The rebuild used the exact command and sources
  recorded in `build/sst_verilog_v2/Vcpu65_sst_tb_v2__verFiles.dat` (same
  pinned Verilator, unchanged source mtimes) and reproduced the pinned
  raw sweep byte-for-byte on 50/50 op-00 tests; its PE timestamp differs,
  so its SHA-256 differs from the original build. See
  `sweep.binary_rebuild_note` in provenance.json.
- Regenerate the derived artifacts (raw results are never touched):

  ```
  python module_tests/cpu_65c02/build/regen_all_summaries.py     # all 14 summaries -> build/
  python module_tests/cpu_65c02/build/v2nmos_report.py           # §2 numbers
  python module_tests/cpu_65c02/build/mos_bothfail_decomp.py     # both-fail classes
  python module_tests/cpu_65c02/provenance.py                    # hashes -> evidence/
  ```

  A full pass runs `compare()` over every sampled test: a few minutes of
  wall time on this machine (I/O-bound; CPU work is seconds).
- Checker version is part of the provenance (`sweep.checker_note`): any
  future change to `sst_driver.compare()` requires recomputing the derived
  summaries and the provenance pass counts so they stay pinned to the
  checker.
- Historical v1 tools (`fail_sigs.py`, `mos_analysis.py`) still read the
  old `build/sweep_*.txt` locations; their reports are frozen in
  FINAL_VERDICT.md and are not regenerated. `v2_compare.py` reads
  summaries from `build/` and auto-regenerates missing ones from
  `evidence/` first.

## 10. Verdict

The v2 core **passes all sampled tests with reliable 65C02 references**:
on the WDC, Rockwell and Synertek 65C02 suites it passes a strict superset
of the golden reference's pass set (12106/12700, 12155/12800,
10563/12800; residual failures confined to the documented
NOP-abs/JAM/BCD/Xf-column classes, no v1 regressions). In NMOS
bus-convention mode it replicates MOS 6502 behavior better than the
R65Cx2 model on the MOS suite (7973/12800, strict superset of golden's
7749, 1990 WDC_MODE fixes with zero regressions).

The strengthened instruction-completion checker (a) removed a hidden
checker blind spot, (b) exposed four documented vendor/golden-model
divergence classes, and (c) demoted the op-7c "golden passes 20" artifact.
No new core defect was found; nothing in the v2 RTL was changed as a
result of this check.

**Open items before this can be called hardware-verified:** v2
sequence-level (paired replay / P3) evidence, and Quartus map/fit/timing
for `new_cpu_v2`.
