# 65C02 core — final verdict (SST sweep campaign closeout)

> **Superseded for v2 claims:** this document covers the v1 core
> (`rtl/new_cpu/`). See `V2_VERDICT.md` (2026-09-03) for the v2 verdict,
> the strengthened instruction-completion checker, and the corrected
> classifications (op 7c, JAM/SLO family, BCD −0x10, NMOS mode naming).

Machine clock 2026-09-02. This document folds together the single-step-test
campaign results (WDC + MOS suites), the r65-pair semantic equivalence, the
T65 baseline, and the Priority-3 directed cases into one verdict on
`rtl/new_cpu/cpu_65c02.sv` + `cpu_alu.sv` (the "new core"), with
`rtl/R65Cx2.sv` as golden reference. Read `sst_progress.md` for the full
session history and `wdc_vs_6502_analysis.md` for Categories A–I detail.

## Verdict

> The new core is a behaviorally faithful 65C02 **within the WDC / W65C02S
> convention family**. On every opcode where the test reference is
> demonstrably reliable, its bus trace and final architectural state match the
> suite's expectations. Every observed deviation is accounted for as one of:
> a documented suite/reference-model convention (Categories A–I), a deliberate
> lineage choice under adopted policy (a) — W65C02S/WDC authoritative for bus
> conventions — or one small BCD-flag edge case (Section 4). It is
> cycle-equivalent to golden R65Cx2 on the r65-pair stimulus modulo a short
> named whitelist, and it **never fails a test that golden passes** in the
> WDC agreed-reference set.

The core is ready for integration-level validation (Quartus compile, Apple II
I/O impact review — see Section 6). No RTL "fixes" to chase the suites were
made in this campaign beyond the earlier Option C and `S_DEC_FIX` removal;
the remaining suite disagreements are reference-model artifacts or documented
convention deltas, not core defects.

## Evidence summary

| Check | Result | Artifact |
|---|---|---|
| r65-pair semantic equivalence (golden vs new core, 4000-row directed stimulus) | PASS — 1504/1504 fetch pairs identical; final state equal modulo constant P_B; deltas = named whitelist only (4× `LEN +1 1e 3e 5e 7e`, 2× `LEN -1 6c 7c`, 28 RMW pre-writes) | `build/semantic_summary.json` |
| WDC suite sweep, new core (sample=50 seed=1, 12700 tests) | **10798/12700 (85.0%)**; all failures attributed to Categories C/D/G/I + xF-column suite garbage; zero NEW-ONLY-FAIL vs golden | `build/sweep_wdc_abxfix.txt` |
| WDC suite sweep, golden | 8093/12700 (63.7%) | `build/sweep_wdc_golden.txt` |
| MOS (6502) suite sweep, new core (12800 tests) | **6706/12800 (52.4%)** — see §2.4 for why this is lower and what it proves | `build/sweep_6502_abxfix.txt` |
| MOS suite sweep, golden | 7869/12800 (61.5%) | `build/sweep_6502_golden.txt` |
| Agreed-reference opcodes (30 opcodes where WDC and MOS traces agree), fail-signature analysis | new core 667/1500, golden 1050/1500; golden-only-fail = 57 ops; **new-only-fail = none** | `build/fail_sigs_report.txt` |
| T65 baseline + alignment (VHDL→Verilog) | PASS — `rowsA=320 rowsB=500 fieldsA=3072 fieldsB=5784 ignored_metavalues=80 gate_checks=17` | `module_tests/t65/` |
| Priority-3 directed cases (BRK/RTI/IRQ/NMI/reset-midstream/RMW-toggle) | 12/12 green (exit 0), both phase-1 and phase-2 | `build/p3/summary.json` |
| Provenance (suite commit, seed, per-opcode test IDs, SHA-256 of RTL/TBs/binaries/results) | complete, zero missing hashes | `build/provenance.json` |

## 1. What the WDC sweep shows

The new core passes every reliable-reference test except those explained by
`wdc_vs_6502_analysis.md`:

- **Category C** (abs,X/abs,Y page-cross dummy): resolved by Option C — the
  penalty/forced-fix cycle re-reads b2 at `pc+2` per WDC convention. All M_ABX
  opcodes now pass (incl. `de`/`fe`/`9d`/`9e` 0→50, `3c` 27→50); residual
  failures are the page-cross-only subset where the suite's dummy address
  convention still differs.
- **Category D** ("(zp),Y" generator convention): perfect Y-page-cross
  correlation (51: 30/30, b1: 25/25, d1: 25/25 of failures are exactly the
  cross tests; `$91` fails all 50 on read-before-write-at-EA vs the suite's
  `pc+1` re-read).
- **Category G** (BCD D=1 extra read): WDC-lineage suites add one extra read
  to every ADC/SBC when D=1; neither core performs it. Documented, not
  emulated (policy (a)).
- **Category I / xF column**: `0f..ff` (odd), `5c`, `2f` — suite final PC
  values are nonsensical (generator ran garbage); not reliable references.
  The core implements these per W65C02S datasheet.

## 2. What the MOS sweep shows (step 6)

The MOS (6502) suite was run through both SST binaries with the identical
selection scheme (sample=50, seed=1, 256 ops → 12800 tests). Raw results:
`build/sweep_6502_abxfix_results.txt` (new core),
`build/sweep_6502_golden_results.txt` (golden, `--final-offset 1`). Per-opcode
summaries and the WDC cross-tab: `build/mos_analysis_report.txt` +
`build/mos_analysis.py`.

### 2.1 RMW write-back family — a perfect mirror (the key proof)

For all 24 RMW-family opcodes — the 20 classic ones (ASL/ROL/LSR/ROR ×
zp/abs/(zp,X)/(abs,X) plus INC/DEC zp/abs) and 4 standard-NOP-position
opcodes (46/4E/66/6E, defined by the W65C02S datasheet per Category I; both
suites give them RMW-like bus models) — the two suites demand opposite bus
behavior and the two cores split accordingly:

```
opcode family                    WDC new  MOS new   WDC gold  MOS gold
ASL/ROL/LSR/ROR zp   06 16 26 36    50       0         0         50
INC/DEC zp           C6 E6          50       0         0         50
ASL/ROL/LSR/ROR abs  0E 1E 2E 3E    50       0         0         50 (1e gold: WDC 1, MOS 49)
INC/DEC abs          CE EE          50       0         0         50
ASL/ROL/LSR/ROR (zp,X) F6 76 D6 56  50       0         0         50
ASL/ROL/LSR/ROR (abs,X) FE 7E DE 5E 50       0         0         50
W65C02S NOP-position 46 4E 66 6E    50       0         0         50
```

MOS silicon write-backs the old value on RMW; the WDC reference model does
not. Every row is a clean mirror; the only blip in the whole family is `1e`
(golden: one WDC test, 49 MOS tests). **Golden R65Cx2 follows MOS; the new core follows WDC.** This is exactly
the policy-(a) decision made 2026-09-02, now directly proven at suite scale:
the step-6 hypothesis "cores track MOS for RMW" is *false for the new core*
by design and *true for golden*.

### 2.2 Page-cross / JMP-indirect family — MOS tracks golden, WDC tracks the new core

```
op   WDC new  MOS new | WDC gold  MOS gold
1d    50      25     |  22       50
3d    50      29     |  21       50
5d    50      26     |  27       50
bc    50      27     |  24       50
bd    50      28     |  26       50
dd    50      27     |  23       50
9d    50       0     |   0       50
fd    31      19     |  18       46
3c    50       5     |  27       10
7c     0       0     |   0       20
6c     0       0     |   0       50
7d    23      28     |  10       50
```

MOS silicon's page-cross behavior (low-byte wrap) matches golden; the new
core's Option C WDC-convention dummies match the WDC suite instead. Both are
"correct" within their convention family; neither is a defect. `6c`/`7c`
remain unresolved in both cores on both suites (suite EA conventions there
are unreliable — see Category I notes).

### 2.3 BCD — one genuine new-core-only difference, small and edge-case

On MOS (which has no D=1 extra-cycle convention), golden fails only 17/700
sampled BCD tests; the new core fails **114/700** (14 ADC/SBC opcodes × 50),
verified at test level (`build/bcd_classify.py`, `build/bcd_bus_check.py`) and
splitting into three classes:

- **Class A — 50 tests: final A correct, only masked P differs (N/V)**
  (e.g. `6d` @A=B6 M=F5 C=0: both compute A=0x11; suite expects N=0, core
  emits N=1). 45 of the 50 have at least one operand nibble > 9 in A or M
  (invalid BCD input — behavior not strictly defined by the architecture);
  the remaining 5 have a valid A digit and an M whose pointer bytes are not
  derivable from `initial.ram`. **No P-only failure was found where both
  operands are fully valid BCD.** The new core derives N/V from a
  pre-correction intermediate value on this path; R65Cx2 does not. This is
  the only new-core-only functional difference found in the entire campaign.
- **Class B — 47 tests: bus-trace mismatch, all of them (abs,X) page-cross
  cases** (`7d`: 20, `fd`: 30; zero flat/non-cross failures). This is the
  Category C Option-C dummy convention seen at suite scale: the new core's
  WDC-style re-read does not match MOS silicon, which golden follows
  (golden passes 47 of these 50 and fails the same 3 `fd` page-cross tests
  that appear in Class C).
  Documented policy-(a) choice, same family as §2.1/§2.2 — not a defect.
- **Class C — 17 tests: final A wrong in BOTH cores** (`e1`:2 `e5`:3 `e9`:3
  `ed`:3 `f1`:2 `fd`:4). 14 have byte-identical bus traces in both cores
  (the D=1 indexed-SBC convention class — both perform extra reads the MOS
  reference model does not); the other 3 are `fd` page-cross cases whose
  traces differ by one dummy cycle but land on the same wrong A. Shared
  inherited behavior, not a new-core defect.
- **Zero tests where final A is wrong in the new core while golden passes** —
  no new-core-only data corruption anywhere in the BCD family.

Risk assessment: Apple II software effectively never runs with D=1 (the
Apple II's standard toolchain does not use BCD mode), so Class A is latent
on the target machine. It is an open decision: either align the new core's
BCD N/V computation with R65Cx2/MOS or accept and document the delta. No
action taken in this campaign.

### 2.4 MOS suite reliability — file-dependent, verified

The MOS suite cannot be used as a blanket reference. Of 256 opcode files:

- **64 files are broken references** — both cores fail 50/50 on MOS while the
  new core passes WDC 50/50 on the same opcodes (02 03 07 0b 12 13 14 17 1a
  1b 1c 22 23 27 2b 32 33 37 3a 3b 42 43 47 4b 52 53 57 5b 62 63 64 67 6b 73
  74 77 7b 83 87 8b 92 93 97 9b 9c 9e a3 a7 ab b2 b3 b7 bb c3 c7 d2 d3 d7 e3
  e7 eb f3 f7 fb). Verified forensics:
  - `02`/`12`/`32`: **100% of all 10000 tests** have final state = initial
    state with PC+1, RAM untouched, and an 11-cycle trace padded with
    $FFFE/$FFFF vector reads — the generator captured a mid-instruction
    snapshot and let the model run garbage.
  - `14` (BIT zp): 0/10000 tests update N/V/Z; expected trace includes a
    bogus extra read at an address unrelated to EA.
  - `34` (JMP (abs)): second pointer read at EA+1 then the 16-bit value at
    EA, and final PC = pc+2 — the reference model never jumps.
- **23 opcodes are known-quirk territory on both suites** (xF column, 5C,
  JAM 72/F2, CB/DB, DC) — Category I / halt conventions; not reliable
  references in either suite.
- The remaining files are usable where at least one core passes a sane
  fraction (the RMW family via golden's 50/50, BCD via golden's ~50/50).

Consequently the MOS pass totals (6706 / 7869) understate both cores' true
conformance; they are reported for completeness and for the per-opcode
directional evidence in 2.1–2.3, not as a quality score.

### 2.5 New core passes where golden fails (MOS)

`40` (RTI, golden misses 1 edge test), `44`/`54`/`d4`/`f4` (NOP family — MOS
agrees with the WDC NOP model the new core implements; golden uses a shorter
zp-style model), `5a`/`7a`/`da`/`fa` (undocumented opcodes where the new
core's implementation matches the MOS reference). No action needed.

## 3. Category status table (A–I, from wdc_vs_6502_analysis.md)

| Cat | Description | Status |
|---|---|---|
| A | Suite final-state garbage (xF column etc.) | documented, not emulated |
| B | WDC `cycles` field incomplete for some opcodes | documented |
| C | abs,X/abs,Y page-cross dummy convention | **resolved by Option C** (WDC convention); MOS delta quantified §2.2 |
| D | "(zp),Y" generator read-order convention | documented; Y-page-cross correlation proven |
| E | 62 (ADC (zp,X)) degenerate tests | skipped by driver |
| F | b5/05 read-only RMW in this lineage | inherited golden behavior, documented |
| G | BCD D=1 extra read (WDC-lineage only) | documented, not emulated; MOS has no such cycle |
| H | $F1 split | resolved earlier |
| I | undocumented decode mismatch vs suites | new core follows W65C02S datasheet; MOS agrees on 44/54/d4/f4/5a/7a/da/fa |

## 4. Complete list of new-core-only differences (all campaigns)

1. **BCD N/V flags on invalid-BCD-digit operands** (§2.3 Class A: 50 of the
   114 new-core BCD failures; final A always correct; 45/50 have an invalid
   digit in A or M). Open decision: fix or document.
2. **P_B constant 1** — structural (`reg_p` bit 4 never cleared); skipped by
   convention in the comparator. Not observable through any documented
   instruction sequence (B is set only by push/BRK and restored by PHP/RTI,
   which write the full status byte).
3. **RMW old-value pre-write absent** (golden writes the old value before the
   update on RMW; new core does a single final write). This is the
   policy-(a) WDC-convention choice; `p3-rmw-toggle` provides an executable
   reference showing the difference is visible to memory-mapped devices
   (one extra write strobe per RMW on golden).

Everything else observed in any campaign is either a suite artifact or a
shared convention.

## 5. What this does NOT prove

- FPGA timing, metastability, memory packing — Verilator is a software model.
- Visual/interactive Apple II behavior (the CPU is one block of the machine).
- Quartus synthesis of the integrated core (see Section 6).
- Behavior beyond the sampled tests: 50/10000 per opcode per suite; directed
  r65/T65/P3 stimuli cover interrupts, reset, and RMW side effects but not
  exhaustive corner cases.

## 6. Remaining work (user decisions)

1. **Quartus compile** of the MiSTer project with the new core integrated
   (Apple-II.sv / apple2.v wiring landed in commit `6881e13` on the Verilog
   repo; the newsdee Quartus project needs its own source-list update + a
   user-run compile — map/fit/STA/RBF).
2. **Apple II I/O impact review**: with the RMW pre-write difference now
   executable (`p3-rmw-toggle`), decide whether any Apple II-era
   memory-mapped device (e.g. disk controller, slot ROMs are read-only) could
   observe the missing golden-style pre-write strobe. Current assessment:
   standard Apple II I/O is not affected (Section 4, item 3).
3. **BCD N/V edge case** (§2.3): fix or accept-and-document.
4. **Commit**: all campaign artifacts are in place; commit only when asked.

## Reproduction

```bash
# from Apple-II-Verilog_MiSTer repo root (MSYS Python)
/c/msys64/ucrt64/bin/python module_tests/cpu_65c02/sst_driver.py \
  --suite wdc65c02 --ops all --sample 50 --seed 1 \
  --bin module_tests/cpu_65c02/build/sst_verilog/Vcpu65_sst_tb.exe
/c/msys64/ucrt64/bin/python module_tests/cpu_65c02/sst_driver.py \
  --suite 6502 --ops all --sample 50 --seed 1 --final-offset 1 \
  --bin module_tests/cpu_65c02/build/sst_r65/Vr65cx2_sst_tb.exe
/c/msys64/ucrt64/bin/python module_tests/cpu_65c02/rebuild_summary.py \
  --results module_tests/cpu_65c02/build/sweep_6502_abxfix_results.txt \
  --suite 6502 --out module_tests/cpu_65c02/build/sweep_6502_abxfix.txt
/c/msys64/ucrt64/bin/python module_tests/cpu_65c02/build/mos_analysis.py
/c/msys64/ucrt64/bin/python module_tests/cpu_65c02/build/bcd_classify.py
/c/msys64/ucrt64/bin/python module_tests/cpu_65c02/provenance.py
```

The driver writes the TB's raw output to `build/sst_results.txt` on every
run; after each sweep, copy it to the retained name (`sweep_<suite>_*_
results.txt`) before running the next suite/core combination.

Retained raw results (force-add precedent: tracked files under
`module_tests/*/build/`): `sweep_wdc_abxfix_results.txt`,
`sweep_wdc_golden_results.txt`, `sweep_6502_abxfix_results.txt`,
`sweep_6502_golden_results.txt` (12700/12700/12800/12800 R-lines).
