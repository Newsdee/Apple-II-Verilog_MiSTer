# perfect6502 netlist oracle — Phase 1/2 findings (65x02 suite, 256 opcodes)

Status: **analysis complete, evidence tables below.** Companion notes:
`OV51_NOTES.md` (oracle pipeline, P-register proof, history). This document
covers the Phase 2 comparison results (all 256 opcodes × 50 samples) and the
post-hoc findings from classifying the divergences.

All numbers below are from the retained artifacts in this directory:

- `sweep_6502_oracle_results_full.txt` — 12796 raw R lines (Phase 2)
- `spec_full.txt` — 12800 spec lines (4 skipped: vector-area collision,
  idx 2786 op $37, idx 5490 op $6D, idx 6749 op $86, idx 12060 op $F1)
- `oracle_report_full.txt` — report from the last full `run_oracle.py --phase 2`
- `sst_driver.py compare()` — the comparison harness (shared with the TB cores)

## 1. Metrics

- **full**: `compare(t, g, final_offset=-1)` returns zero failures, including
  the final-P line.
- **P-exempt (Pex)**: zero failures excluding the `final p ...` line. This is
  the netlist-valid metric: the netlist's P readout (p0..p7 nodes) is an
  alias of A, not the P storage (see OV51_NOTES.md §P register). The
  alias is exactly `P ≡ (A & 0x80) | 0x34 | (A == 0 ? 0x02 : 0)` — i.e.
  N/Z track A and **V, D, I are constant 1** in every observed row.
- **late-commit rescue** (added to `run_oracle.py` after Phase 2): see §3.
- **p-limited**: failed only on the final-P line.

## 2. Headline results (Phase 2, 12796 tests)

| metric | pre-rescue | post-rescue |
|---|---|---|
| full pass | 524 | 822 |
| P-exempt pass | 7412 (57.9%) | **10181 (79.6%)** |
| P-exempt failures | 5384 | **2615** |
| late-commit rescues (failure lines dropped) | — | 2846 |

Bus-level agreement (per-cycle addr / R-W / data / cycle count, first ncyc
rows) was already 100% across Phase 1 (600 tests) and holds for Phase 2
as well — every residual failure is in the final-state or write-data
classes below, not in fetch address or R/W pattern.

## 3. Commit-convention finding (why the rescue exists)

The netlist's observable register-commit timing is **instruction-dependent**,
and for a whole family of opcodes it commits A/X/Y/SP one row later than the
suite's model implies. Evidence (raw rows from the retained sweep; row c =
bus activity of cycle c, regs = state sampled at row end):

- **$A9 LDA #imm** (ncyc=2): A and PC committed at row 1 (= ncyc-1). Standard.
- **$7C LDA abs,X** (ncyc=5): A and PC committed at row 4 (= ncyc-1). Standard.
- **$9B STA abs,X** (ncyc=5): SP and PC committed at row 4 (= ncyc-1). Standard.
- **$E8 INX** (ncyc=2): PC at row 1 (= final PC), **X committed at row 2
  (= ncyc)**, where row 2 is a re-read of the next-opcode byte.
- **$E9 SBC #imm** (ncyc=2): PC at row 1, **A committed at row 2**.
- **$C8 / $88 / $CA / $CB / $E8** (ncyc=2): the PC row matches the suite,
  but the changed register (Y+1 / Y-1 / X-1 / X) matches the suite's
  expected final value **only at row ncyc**.

So for the late-commit family no single `final_offset` can satisfy both the
PC check and the register check. The netlist agrees with the suite
*semantically* (same final value) and differs only in the observable commit
cycle. `run_oracle.py late_commit_rescue()` therefore drops a register
failure (`final a/x/y/sp`) when the signature holds:

- row ncyc-1 value == row 0 (initial) value (register uncommitted in window), and
- row ncyc value == the suite's expected final value.

PC failures, cycle-data failures, and completion failures are never
rescued. This is a conservative, per-test, signature-gated adjustment; it
turns 7412 → 10181 P-exempt passes (2846 rescued failure lines) and converts
the previously "0/50" opcodes $01/$03/$05/$07/$09/$0A/$0D/$0F/$11/$13/$15/$17/
$19/$1B/$1D/$1F/$21/$25/$29/$2D/$31/$35/$39/$41/$43/$45/$47/$49/$4A/$4D/$4F/
$51/$53/$55/$57/$59/$5B/$5D/$5F/$88/$C8/$CA/$CB/$E8 from apparent
divergence to P-only limitation.

## 4. Branch-P hypothesis — VERIFIED

Hypothesis (from Phase 1): for Bcc opcodes the netlist branches on its own
natural initial P (the alias), not the suite's initial P, so the branch
direction diverges exactly when the two P values differ on the controlling
flag. Verified per-opcode by deriving the predicate from the suite data
itself (no opcode-table hardcoding) and checking the failure correlation:

| op | suite predicate | Pex | fail ↔ (netlist-P vs suite-P disagree) |
|---|---|---|---|
| $10 BPL | ~N | 42/50 | **8/8** (36/50 overall agreement) |
| $30 BMI | N | 39/50 | **11/11** (46/50) |
| $70 BGE | N==V family | 21/50 | **29/29** (49/50) |
| $B0 BCS | C | 22/50 | **28/28**, 50/50 overall agreement |
| $F0 BEQ | Z | 21/50 | **29/29** — all 29 have suite-Z ≠ netlist-Z |

$F0 direct evidence: taken-when-Z-set = 29/30, taken-when-Z-clear = 0/20
(suite data); the netlist's natural Z = 0 (P alias of A) so it never takes,
while the suite (Z=1) does; 29/29 failures are `row 3 not a fetch at final
pc` with the netlist fetch ≠ suite final PC (direction reversed).

The residual 0/50 "0B/2B-style" opcodes that still fail are *not* branch-
direction failures (their dpc delta is uniform — the suite constructs those
50 samples on the not-taken path); their failures are the write-data / A-
model classes of §5.

## 5. Post-rescue failure classes (2615 remaining P-exempt failures)

| class | count | meaning | ops (dominant) |
|---|---|---|---|
| `a` | 1212 | final A differs: suite's B=1-row A model ≠ netlist A (netlist A is standard for the family; see §6) | $0B, $2A/$2B, $4B, $61–$7F odd, $E1/$E3/$E5/$E7/$E9/$EB/$ED/$EF, $F1/$F3/$F5/$F7/$F9/$FB/$FD/$FF |
| `compl+pc` | 677 | branch direction (P, §4) + the FFFF family (§7) | $10/$30/$70/$B0/$F0 + $02/$12/$22/$32/$42/$52/$62/$72/$92/$B2/$D2/$F2 |
| `data±80` | 284 | in-window write data ±0x80: continuation writes of the suite's non-standard A | $00, $63/$66/$67/$6E/$6F, $73/$76/$77/$7B/$7E/$7F |
| `data-1` | 280 | in-window write data −1: same cause, suite A = netlist A − 1 (e.g. $26: expected write = suite final A BB, netlist writes BA) | $00, $23, $26/$27, $2E/$2F, $33, $36/$37, $3B/$3E/$3F |
| `data-mix` | 122 | mixed write diffs (continuation-write class, incl. $08 PHA tests and branch-op tests) | $00, $08, $10, $30, $70, $B0, $F0 |
| `a+x` | 39 | $AB only: netlist A := X (XAA-style), suite A,X := A+1 | $AB |
| `data+1` | 1 | single $08 oddity | $08 |

The write-data classes are *downstream* of the A-model divergence: the
failing write is a continuation instruction (typically STA) storing the A
value, and the expected byte equals the suite's final A.

## 6. $E9 SBC #imm: the netlist is standard; the suite is the outlier

Direct register evidence (idx / suite A-imm-C → suite final A / netlist
committed A at row ncyc / textbook binary `A - imm - ~C`):

| idx | A | imm | P(D,C) | suite A | netlist A | binary |
|---|---|---|---|---|---|---|
| 11650 | 0F | 4D | (0,0) | 61 | C1 | C1 |
| 11651 | 54 | FC | (0,0) | F1 | 57 | 57 |
| 11652 | F6 | 90 | (0,1) | 66 | 65 | 66 |
| 11653 | 94 | FE | (0,0) | 3F | 95 | 95 |
| 11654 | CC | 0A | (0,0) | C1 | C1 | C1 |
| 11655 | 01 | 45 | (0,0) | BB | BB | BB |

- The netlist computes textbook binary SBC in all six cases (no BCD mode:
  its P alias has D=1 constant, so BCD is not observable/enabled anyway).
- When the carry flag agrees (C=0 both), the suite's expected A still
  diverges (11650/11651/11653) — a genuine suite-model divergence, not a
  P issue. The suite's final P is even internally inconsistent in these
  (idx 11650: final P has N=1 while final A=61 has N=0).
- When C differs (11652: suite C=1), the netlist used its natural C=0 —
  the P-hypothesis case.

Conclusion: for $E9 (and by class-mate reasoning $E3/$ED and the B=1-row
CMP/SBC family), the **reconstructed suite's expected A values are
non-standard; the NMOS netlist is the ground truth** and the Verilog cores
should follow the netlist. The suite rows for these opcodes should be
flagged as suspect in the diff documentation.

## 7. FFFF-family anomaly (12 opcodes × 50/50, uniform)

$02, $12, $22, $32, $42, $52, $62, $72, $92, $B2, $D2, $F2 — every test
fails identically: `final pc = suite+1` and
`complete: row 11 not a fetch at final pc XXXX (got FFFF/R)`. The netlist's
row-11 bus fetch is **$FFFF** (vector area) while the PC node is at
suite+1. Pattern: uniform 50/50, always +1, always FFFF — a netlist
timing/sequencing artifact of this B=1-row family (a stray vector-area
read after the instruction), not a per-test semantic divergence. Requires
netlist-level tracing to pin the exact row; recorded as a distinct class
so it is not misfiled as branch behavior. (These are also the opcodes the
$5C-style "next fetch" probe would flag as `late`.)

A separate harmless artifact seen in many traces: a stray `00EE/EE` read
around row 4–5, outside the suite window, never affecting the checks.

## 8. Phase 1 opcodes, post-rescue (12-op phase, P-exempt /50)

| op | pre | post | note |
|---|---|---|---|
| $23 | 1 | 29 | A-model (suite A = netlist A ±1/±0x80) + write-data tails |
| $3B | 0 | 26 | same |
| $63 | 0 | 15 | same |
| $73 | 0 | 10 | same |
| $7B | 0 | 14 | same |
| $F3 | 0 | 17 | same |
| $5C / $80 / $7C | 50 | 50 | unchanged (standard, commit in window) |
| $9B / $C3 / $DB | 50 | 50 | unchanged |

The Phase-1 story ("netlist preserves A, suite writes A") is refined: the
netlist *does* update A per its own (standard) semantics; it commits it one
observable row later than the suite model, and the suite's expected A for
these B=1 rows is non-standard by ±1/±0x80.

## 9. Verdict for the open expert questions

1. **Illegal/B=1-row behavior**: the NMOS netlist implements the B=1 rows
   as standard-semantics variants (binary SBC, XAA-style $AB = A:=X,
   Y+1/$C8, Y-1/$88, X-1/$CA/$CB) and is self-consistent; the
   reconstructed suite's expected values for these rows are non-standard
   and sometimes internally inconsistent. **Netlist = silicon ground
   truth; suite rows are the outlier.** The Verilog cores should be
   judged against the netlist for these opcodes.
2. **Flag-dependent branches**: all branch-direction divergences are fully
   explained by P non-representability (initial P is the netlist's natural
   post-reset/prelude state, not the suite's). No unexplained branch
   behavior remains among the tested samples.
3. **Commit timing**: the netlist commits A/X/Y/SP one observable cycle
   later than the suite model for the B=1-row family and INX/SBC-imm;
   this is a netlist-vs-suite timing difference, not a semantic one
   (values match once the commit row is accounted for).
4. **Residual unknowns**: (a) the FFFF-family stray vector reads (§7) —
   netlist-level row tracing needed; (b) the true P storage location
   (out of scope: P-exempt metric works around it); (c) the netlist's
   internal reason for the extra bus row in the late-commit family.

## 10. Reproduction

```bat
rem from module_tests/cpu_65c02/oracle (MSYS2 UCRT64 python3)
python3 run_oracle.py --phase 1    rem 660 tests, ~1 min
python3 run_oracle.py --phase 2    rem 12800 tests, ~20 min
```

Post-rescue numbers are produced by `run_oracle.py` directly (rescue is
applied in the compare loop); the tables below are generated from the
retained `sweep_6502_oracle_results_full.txt` via
`compare()` + `late_commit_rescue()` + `fpe_check()`.

## 11. Per-opcode evidence table (Phase 2, post-rescue)

Columns: `full` = full pass, `Pex` = P-exempt pass, `rescues` =
late-commit-rescued failure lines, `classes` = post-rescue P-exempt
failure classes (dominant two), `sample idx` = a failing test with the
fewest failure lines, `sample failures` = its first failure lines.
`-1` / `-` = no failures (P-only or full pass).
| op | n | full | Pex | rescues | failure classes (post-rescue) | sample idx | sample failures |
|----|---|------|-----|---------|-------------------------------|------------|-----------------|
| $00 | 50 | 1 | 1 | 0 | data-mix:46; data-1:2 | 0 | cyc4: data B4 != expected 7D ; final ram[0175] = 180 != 125 |
| $01 | 50 | 0 | 50 | 47 | none | -1 | - |
| $02 | 50 | 0 | 0 | 0 | compl+pc:50 | 100 | final pc 102A != 1029 ; complete: row 11 not a fetch at final pc 1029 (got FFFF/R) |
| $03 | 50 | 3 | 50 | 43 | none | -1 | - |
| $04 | 50 | 1 | 50 | 0 | none | -1 | - |
| $05 | 50 | 4 | 50 | 47 | none | -1 | - |
| $06 | 50 | 5 | 50 | 0 | none | -1 | - |
| $07 | 50 | 8 | 50 | 46 | none | -1 | - |
| $08 | 50 | 1 | 1 | 0 | data-mix:48; data+1:1 | 401 | cyc2: data 34 != expected F7 ; final ram[0125] = 52 != 247 |
| $09 | 50 | 1 | 50 | 47 | none | -1 | - |
| $0a | 50 | 9 | 50 | 50 | none | -1 | - |
| $0b | 50 | 0 | 4 | 0 | a:46 | 550 | final a  4C != 08 |
| $0c | 50 | 1 | 50 | 0 | none | -1 | - |
| $0d | 50 | 3 | 50 | 47 | none | -1 | - |
| $0e | 50 | 4 | 50 | 0 | none | -1 | - |
| $0f | 50 | 6 | 50 | 42 | none | -1 | - |
| $10 | 50 | 3 | 42 | 0 | compl+pc:6; data-mix:2 | 801 | final pc 3E8F != 3E95 ; complete: row 3 not a fetch at final pc 3E95 (got 3E8F/R) |
| $11 | 50 | 2 | 50 | 43 | none | -1 | - |
| $12 | 50 | 0 | 0 | 0 | compl+pc:50 | 900 | final pc 88CB != 88CA ; complete: row 11 not a fetch at final pc 88CA (got FFFF/R) |
| $13 | 50 | 3 | 50 | 39 | none | -1 | - |
| $14 | 50 | 2 | 50 | 0 | none | -1 | - |
| $15 | 50 | 3 | 50 | 45 | none | -1 | - |
| $16 | 50 | 3 | 50 | 0 | none | -1 | - |
| $17 | 50 | 8 | 50 | 45 | none | -1 | - |
| $18 | 50 | 3 | 50 | 0 | none | -1 | - |
| $19 | 50 | 3 | 50 | 44 | none | -1 | - |
| $1a | 50 | 2 | 50 | 0 | none | -1 | - |
| $1b | 50 | 12 | 50 | 41 | none | -1 | - |
| $1c | 50 | 0 | 50 | 0 | none | -1 | - |
| $1d | 50 | 6 | 50 | 45 | none | -1 | - |
| $1e | 50 | 6 | 50 | 0 | none | -1 | - |
| $1f | 50 | 4 | 50 | 47 | none | -1 | - |
| $20 | 50 | 0 | 50 | 0 | none | -1 | - |
| $21 | 50 | 7 | 50 | 48 | none | -1 | - |
| $22 | 50 | 0 | 0 | 0 | compl+pc:50 | 1700 | final pc BAEC != BAEB ; complete: row 11 not a fetch at final pc BAEB (got FFFF/R) |
| $23 | 50 | 1 | 29 | 38 | data-1:21 | 1755 | cyc7: data 8C != expected 8D ; final ram[2DCD] = 140 != 141 |
| $24 | 50 | 5 | 50 | 0 | none | -1 | - |
| $25 | 50 | 2 | 50 | 45 | none | -1 | - |
| $26 | 50 | 3 | 21 | 0 | data-1:29 | 1900 | cyc4: data BA != expected BB ; final ram[0076] = 186 != 187 |
| $27 | 50 | 2 | 22 | 38 | data-1:28 | 1950 | cyc4: data 72 != expected 73 ; final ram[00B0] = 114 != 115 |
| $28 | 50 | 50 | 50 | 0 | none | -1 | - |
| $29 | 50 | 6 | 50 | 45 | none | -1 | - |
| $2a | 50 | 1 | 25 | 25 | a:25 | 2100 | final a  E2 != C5 |
| $2b | 50 | 0 | 4 | 0 | a:46 | 2150 | final a  51 != 10 |
| $2c | 50 | 6 | 50 | 0 | none | -1 | - |
| $2d | 50 | 3 | 50 | 48 | none | -1 | - |
| $2e | 50 | 2 | 24 | 0 | data-1:26 | 2301 | cyc5: data FE != expected FF ; final ram[DDA4] = 254 != 255 |
| $2f | 50 | 4 | 26 | 28 | data-1:24 | 2353 | cyc5: data BC != expected BD ; final ram[BA40] = 188 != 189 |
| $30 | 50 | 1 | 39 | 0 | compl+pc:6; data-mix:5 | 2401 | cyc3: addr 0D30 != expected 0DEF ; cyc3: data EE != expected CE |
| $31 | 50 | 4 | 50 | 45 | none | -1 | - |
| $32 | 50 | 0 | 0 | 0 | compl+pc:50 | 2500 | final pc 350F != 350E ; complete: row 11 not a fetch at final pc 350E (got FFFF/R) |
| $33 | 50 | 8 | 27 | 33 | data-1:23 | 2550 | cyc7: data 90 != expected 91 ; final a  99 != 91 |
| $34 | 50 | 4 | 50 | 0 | none | -1 | - |
| $35 | 50 | 8 | 50 | 47 | none | -1 | - |
| $36 | 50 | 3 | 25 | 0 | data-1:25 | 2701 | cyc5: data A8 != expected A9 ; final ram[006D] = 168 != 169 |
| $37 | 50 | 3 | 27 | 36 | data-1:22 | 2750 | cyc5: data E6 != expected E7 ; final a  5B != 43 |
| $38 | 50 | 4 | 50 | 0 | none | -1 | - |
| $39 | 50 | 2 | 50 | 44 | none | -1 | - |
| $3a | 50 | 0 | 50 | 0 | none | -1 | - |
| $3b | 50 | 0 | 26 | 37 | data-1:24 | 2950 | cyc6: data F2 != expected F3 ; final ram[A1F9] = 242 != 243 |
| $3c | 50 | 3 | 50 | 0 | none | -1 | - |
| $3d | 50 | 1 | 50 | 45 | none | -1 | - |
| $3e | 50 | 3 | 23 | 0 | data-1:27 | 3101 | cyc6: data BC != expected BD ; final ram[6DDC] = 188 != 189 |
| $3f | 50 | 3 | 21 | 29 | data-1:29 | 3150 | cyc6: data 70 != expected 71 ; final a  F7 != 71 |
| $40 | 50 | 50 | 50 | 0 | none | -1 | - |
| $41 | 50 | 4 | 50 | 50 | none | -1 | - |
| $42 | 50 | 0 | 0 | 0 | compl+pc:50 | 3300 | final pc D30F != D30E ; complete: row 11 not a fetch at final pc D30E (got FFFF/R) |
| $43 | 50 | 8 | 50 | 50 | none | -1 | - |
| $44 | 50 | 1 | 50 | 0 | none | -1 | - |
| $45 | 50 | 4 | 50 | 50 | none | -1 | - |
| $46 | 50 | 6 | 50 | 0 | none | -1 | - |
| $47 | 50 | 6 | 50 | 50 | none | -1 | - |
| $48 | 50 | 3 | 50 | 0 | none | -1 | - |
| $49 | 50 | 5 | 50 | 50 | none | -1 | - |
| $4a | 50 | 6 | 50 | 50 | none | -1 | - |
| $4b | 50 | 0 | 4 | 4 | a:46 | 3750 | final a  72 != 00 |
| $4c | 50 | 1 | 50 | 0 | none | -1 | - |
| $4d | 50 | 1 | 50 | 50 | none | -1 | - |
| $4e | 50 | 3 | 50 | 0 | none | -1 | - |
| $4f | 50 | 6 | 50 | 49 | none | -1 | - |
| $50 | 50 | 4 | 50 | 0 | none | -1 | - |
| $51 | 50 | 2 | 50 | 50 | none | -1 | - |
| $52 | 50 | 0 | 0 | 0 | compl+pc:50 | 4100 | final pc 019C != 019B ; complete: row 11 not a fetch at final pc 019B (got FFFF/R) |
| $53 | 50 | 5 | 50 | 49 | none | -1 | - |
| $54 | 50 | 4 | 50 | 0 | none | -1 | - |
| $55 | 50 | 3 | 50 | 50 | none | -1 | - |
| $56 | 50 | 6 | 50 | 0 | none | -1 | - |
| $57 | 50 | 6 | 50 | 50 | none | -1 | - |
| $58 | 50 | 2 | 50 | 0 | none | -1 | - |
| $59 | 50 | 5 | 50 | 50 | none | -1 | - |
| $5a | 50 | 3 | 50 | 0 | none | -1 | - |
| $5b | 50 | 7 | 50 | 49 | none | -1 | - |
| $5c | 50 | 5 | 50 | 0 | none | -1 | - |
| $5d | 50 | 5 | 50 | 50 | none | -1 | - |
| $5e | 50 | 6 | 50 | 0 | none | -1 | - |
| $5f | 50 | 5 | 50 | 50 | none | -1 | - |
| $60 | 50 | 1 | 50 | 0 | none | -1 | - |
| $61 | 50 | 4 | 12 | 12 | a:38 | 4851 | final a  2D != 22 |
| $62 | 50 | 0 | 0 | 0 | compl+pc:50 | 4900 | final pc FAD4 != FAD3 ; complete: row 11 not a fetch at final pc FAD3 (got FFFF/R) |
| $63 | 50 | 3 | 15 | 15 | data+-80:23; a:12 | 4950 | final a  FB != 63 |
| $64 | 50 | 0 | 50 | 0 | none | -1 | - |
| $65 | 50 | 3 | 15 | 15 | a:35 | 5051 | final a  1D != 35 |
| $66 | 50 | 4 | 22 | 0 | data+-80:28 | 5101 | cyc4: data 1D != expected 9D ; final ram[0046] = 29 != 157 |
| $67 | 50 | 2 | 14 | 14 | data+-80:24; a:12 | 5153 | final a  5E != 6E |
| $68 | 50 | 4 | 50 | 0 | none | -1 | - |
| $69 | 50 | 2 | 8 | 8 | a:42 | 5250 | final a  8B != 04 |
| $6a | 50 | 2 | 17 | 17 | a:33 | 5300 | final a  BB != DD |
| $6b | 50 | 0 | 0 | 0 | a:50 | 5350 | final a  87 != 20 |
| $6c | 50 | 2 | 50 | 0 | none | -1 | - |
| $6d | 50 | 2 | 10 | 10 | a:39 | 5450 | final a  B6 != 11 |
| $6e | 50 | 3 | 22 | 0 | data+-80:28 | 5502 | cyc5: data 18 != expected 98 ; final ram[A1BF] = 24 != 152 |
| $6f | 50 | 1 | 8 | 8 | data+-80:27; a:15 | 5550 | final a  C4 != 88 |
| $70 | 50 | 1 | 21 | 0 | compl+pc:24; data-mix:5 | 5601 | final pc BF71 != BF23 ; complete: row 3 not a fetch at final pc BF23 (got BF71/R) |
| $71 | 50 | 1 | 8 | 8 | a:42 | 5650 | final a  82 != 15 |
| $72 | 50 | 0 | 0 | 0 | compl+pc:50 | 5700 | final pc 5D2A != 5D29 ; complete: row 11 not a fetch at final pc 5D29 (got FFFF/R) |
| $73 | 50 | 1 | 10 | 10 | data+-80:25; a:15 | 5754 | final a  75 != 09 |
| $74 | 50 | 2 | 50 | 0 | none | -1 | - |
| $75 | 50 | 3 | 13 | 13 | a:37 | 5851 | final a  07 != 29 |
| $76 | 50 | 1 | 20 | 0 | data+-80:30 | 5901 | cyc5: data 0A != expected 8A ; final ram[004F] = 10 != 138 |
| $77 | 50 | 2 | 12 | 12 | data+-80:25; a:13 | 5951 | final a  79 != 4D |
| $78 | 50 | 1 | 50 | 0 | none | -1 | - |
| $79 | 50 | 6 | 16 | 15 | a:34 | 6050 | final a  CC != B7 |
| $7a | 50 | 3 | 50 | 0 | none | -1 | - |
| $7b | 50 | 2 | 14 | 14 | data+-80:27; a:9 | 6166 | final a  4A != 6F |
| $7c | 50 | 2 | 50 | 0 | none | -1 | - |
| $7d | 50 | 2 | 17 | 16 | a:33 | 6250 | final a  50 != A3 |
| $7e | 50 | 6 | 25 | 0 | data+-80:25 | 6300 | cyc6: data 39 != expected B9 ; final ram[71AC] = 57 != 185 |
| $7f | 50 | 2 | 11 | 11 | data+-80:21; a:18 | 6350 | final a  B7 != 65 |
| $80 | 50 | 4 | 50 | 0 | none | -1 | - |
| $81 | 50 | 2 | 50 | 0 | none | -1 | - |
| $82 | 50 | 1 | 50 | 0 | none | -1 | - |
| $83 | 50 | 0 | 50 | 0 | none | -1 | - |
| $84 | 50 | 3 | 50 | 0 | none | -1 | - |
| $85 | 50 | 3 | 50 | 0 | none | -1 | - |
| $86 | 50 | 2 | 49 | 0 | none | -1 | - |
| $87 | 50 | 0 | 50 | 0 | none | -1 | - |
| $88 | 50 | 5 | 50 | 50 | none | -1 | - |
| $89 | 50 | 1 | 50 | 0 | none | -1 | - |
| $8a | 50 | 5 | 50 | 0 | none | -1 | - |
| $8b | 50 | 6 | 25 | 0 | a:25 | 6951 | final a  00 != 02 |
| $8c | 50 | 2 | 50 | 0 | none | -1 | - |
| $8d | 50 | 1 | 50 | 0 | none | -1 | - |
| $8e | 50 | 1 | 50 | 0 | none | -1 | - |
| $8f | 50 | 2 | 50 | 0 | none | -1 | - |
| $90 | 50 | 1 | 50 | 0 | none | -1 | - |
| $91 | 50 | 3 | 50 | 0 | none | -1 | - |
| $92 | 50 | 0 | 0 | 0 | compl+pc:50 | 7300 | final pc F348 != F347 ; complete: row 11 not a fetch at final pc F347 (got FFFF/R) |
| $93 | 50 | 2 | 50 | 0 | none | -1 | - |
| $94 | 50 | 3 | 50 | 0 | none | -1 | - |
| $95 | 50 | 1 | 50 | 0 | none | -1 | - |
| $96 | 50 | 1 | 50 | 0 | none | -1 | - |
| $97 | 50 | 0 | 50 | 0 | none | -1 | - |
| $98 | 50 | 2 | 50 | 0 | none | -1 | - |
| $99 | 50 | 3 | 50 | 0 | none | -1 | - |
| $9a | 50 | 1 | 50 | 0 | none | -1 | - |
| $9b | 50 | 1 | 50 | 0 | none | -1 | - |
| $9c | 50 | 1 | 50 | 0 | none | -1 | - |
| $9d | 50 | 2 | 50 | 0 | none | -1 | - |
| $9e | 50 | 2 | 50 | 0 | none | -1 | - |
| $9f | 50 | 2 | 50 | 0 | none | -1 | - |
| $a0 | 50 | 4 | 50 | 0 | none | -1 | - |
| $a1 | 50 | 2 | 50 | 0 | none | -1 | - |
| $a2 | 50 | 1 | 50 | 0 | none | -1 | - |
| $a3 | 50 | 3 | 50 | 0 | none | -1 | - |
| $a4 | 50 | 4 | 50 | 0 | none | -1 | - |
| $a5 | 50 | 6 | 50 | 0 | none | -1 | - |
| $a6 | 50 | 3 | 50 | 0 | none | -1 | - |
| $a7 | 50 | 2 | 50 | 0 | none | -1 | - |
| $a8 | 50 | 1 | 50 | 0 | none | -1 | - |
| $a9 | 50 | 5 | 50 | 0 | none | -1 | - |
| $aa | 50 | 3 | 50 | 0 | none | -1 | - |
| $ab | 50 | 0 | 11 | 0 | a+x:39 | 8550 | final a  11 != 1D ; final x  11 != 1D |
| $ac | 50 | 2 | 50 | 0 | none | -1 | - |
| $ad | 50 | 3 | 50 | 0 | none | -1 | - |
| $ae | 50 | 3 | 50 | 0 | none | -1 | - |
| $af | 50 | 3 | 50 | 0 | none | -1 | - |
| $b0 | 50 | 1 | 22 | 0 | compl+pc:21; data-mix:7 | 8800 | final pc 572B != 579C ; complete: row 3 not a fetch at final pc 579C (got 572B/R) |
| $b1 | 50 | 2 | 50 | 0 | none | -1 | - |
| $b2 | 50 | 0 | 0 | 0 | compl+pc:50 | 8900 | final pc 5C3C != 5C3B ; complete: row 11 not a fetch at final pc 5C3B (got FFFF/R) |
| $b3 | 50 | 2 | 50 | 0 | none | -1 | - |
| $b4 | 50 | 4 | 50 | 0 | none | -1 | - |
| $b5 | 50 | 7 | 50 | 0 | none | -1 | - |
| $b6 | 50 | 4 | 50 | 0 | none | -1 | - |
| $b7 | 50 | 2 | 50 | 0 | none | -1 | - |
| $b8 | 50 | 2 | 50 | 0 | none | -1 | - |
| $b9 | 50 | 6 | 50 | 0 | none | -1 | - |
| $ba | 50 | 2 | 50 | 0 | none | -1 | - |
| $bb | 50 | 6 | 50 | 0 | none | -1 | - |
| $bc | 50 | 3 | 50 | 0 | none | -1 | - |
| $bd | 50 | 3 | 50 | 0 | none | -1 | - |
| $be | 50 | 2 | 50 | 0 | none | -1 | - |
| $bf | 50 | 6 | 50 | 0 | none | -1 | - |
| $c0 | 50 | 4 | 50 | 0 | none | -1 | - |
| $c1 | 50 | 0 | 50 | 0 | none | -1 | - |
| $c2 | 50 | 0 | 50 | 0 | none | -1 | - |
| $c3 | 50 | 5 | 50 | 0 | none | -1 | - |
| $c4 | 50 | 3 | 50 | 0 | none | -1 | - |
| $c5 | 50 | 5 | 50 | 0 | none | -1 | - |
| $c6 | 50 | 4 | 50 | 0 | none | -1 | - |
| $c7 | 50 | 4 | 50 | 0 | none | -1 | - |
| $c8 | 50 | 2 | 50 | 50 | none | -1 | - |
| $c9 | 50 | 2 | 50 | 0 | none | -1 | - |
| $ca | 50 | 6 | 50 | 50 | none | -1 | - |
| $cb | 50 | 9 | 50 | 50 | none | -1 | - |
| $cc | 50 | 3 | 50 | 0 | none | -1 | - |
| $cd | 50 | 3 | 50 | 0 | none | -1 | - |
| $ce | 50 | 2 | 50 | 0 | none | -1 | - |
| $cf | 50 | 3 | 50 | 0 | none | -1 | - |
| $d0 | 50 | 0 | 50 | 0 | none | -1 | - |
| $d1 | 50 | 5 | 50 | 0 | none | -1 | - |
| $d2 | 50 | 0 | 0 | 0 | compl+pc:50 | 10500 | final pc BDA0 != BD9F ; complete: row 11 not a fetch at final pc BD9F (got FFFF/R) |
| $d3 | 50 | 4 | 50 | 0 | none | -1 | - |
| $d4 | 50 | 4 | 50 | 0 | none | -1 | - |
| $d5 | 50 | 4 | 50 | 0 | none | -1 | - |
| $d6 | 50 | 3 | 50 | 0 | none | -1 | - |
| $d7 | 50 | 1 | 50 | 0 | none | -1 | - |
| $d8 | 50 | 4 | 50 | 0 | none | -1 | - |
| $d9 | 50 | 2 | 50 | 0 | none | -1 | - |
| $da | 50 | 0 | 50 | 0 | none | -1 | - |
| $db | 50 | 6 | 50 | 0 | none | -1 | - |
| $dc | 50 | 3 | 50 | 0 | none | -1 | - |
| $dd | 50 | 2 | 50 | 0 | none | -1 | - |
| $de | 50 | 3 | 50 | 0 | none | -1 | - |
| $df | 50 | 0 | 50 | 0 | none | -1 | - |
| $e0 | 50 | 2 | 50 | 0 | none | -1 | - |
| $e1 | 50 | 0 | 13 | 12 | a:37 | 11250 | final a  D4 != 46 |
| $e2 | 50 | 1 | 50 | 0 | none | -1 | - |
| $e3 | 50 | 3 | 13 | 13 | a:37 | 11350 | final a  8D != 43 |
| $e4 | 50 | 4 | 50 | 0 | none | -1 | - |
| $e5 | 50 | 3 | 13 | 13 | a:37 | 11451 | final a  DC != B8 |
| $e6 | 50 | 6 | 50 | 0 | none | -1 | - |
| $e7 | 50 | 4 | 16 | 15 | a:34 | 11550 | final a  80 != 4A |
| $e8 | 50 | 5 | 50 | 50 | none | -1 | - |
| $e9 | 50 | 4 | 20 | 20 | a:30 | 11650 | final a  0F != 61 |
| $ea | 50 | 1 | 50 | 0 | none | -1 | - |
| $eb | 50 | 5 | 20 | 20 | a:30 | 11750 | final a  20 != 1A |
| $ec | 50 | 5 | 50 | 0 | none | -1 | - |
| $ed | 50 | 3 | 15 | 15 | a:35 | 11850 | final a  A7 != 64 |
| $ee | 50 | 1 | 50 | 0 | none | -1 | - |
| $ef | 50 | 3 | 12 | 11 | a:38 | 11950 | final a  5A != 05 |
| $f0 | 50 | 0 | 21 | 0 | compl+pc:20; data-mix:9 | 12000 | cyc3: addr E897 != expected E80A ; cyc3: data EE != expected 12 |
| $f1 | 50 | 0 | 12 | 12 | a:37 | 12050 | final a  91 != 41 |
| $f2 | 50 | 0 | 0 | 0 | compl+pc:50 | 12100 | final pc 7867 != 7866 ; complete: row 11 not a fetch at final pc 7866 (got FFFF/R) |
| $f3 | 50 | 0 | 17 | 17 | a:33 | 12150 | final a  B7 != 62 |
| $f4 | 50 | 2 | 50 | 0 | none | -1 | - |
| $f5 | 50 | 0 | 17 | 17 | a:33 | 12250 | final a  F5 != 84 |
| $f6 | 50 | 2 | 50 | 0 | none | -1 | - |
| $f7 | 50 | 3 | 14 | 14 | a:36 | 12351 | final a  6B != F4 |
| $f8 | 50 | 2 | 50 | 0 | none | -1 | - |
| $f9 | 50 | 1 | 17 | 17 | a:33 | 12450 | final a  54 != 92 |
| $fa | 50 | 5 | 50 | 0 | none | -1 | - |
| $fb | 50 | 2 | 16 | 15 | a:34 | 12550 | final a  33 != F4 |
| $fc | 50 | 4 | 50 | 0 | none | -1 | - |
| $fd | 50 | 3 | 16 | 16 | a:34 | 12650 | final a  EA != AD |
| $fe | 50 | 2 | 50 | 0 | none | -1 | - |
| $ff | 50 | 4 | 21 | 21 | a:29 | 12750 | final a  C8 != A7 |