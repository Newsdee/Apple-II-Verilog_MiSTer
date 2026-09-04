# v2 CPU campaign — handover doc (written after crash of session 01a0601c)

**State: analysis COMPLETE and reconciled; verdict ready to write up; nothing
left except optional polish (per-failure-kind breakdown of the 3 65C02
golden-only-fail sets, updating FINAL_VERDICT.md / sst_progress.md with v2
results, and committing on user request).**

Machine clock at writing: 2026-09-03 ~00:35 CST.
Crashed session: `01a0601c-aa93-78d0-b6d0-742b9742d5a3` (last user request was
exactly "save progress to .md file so we can handover" — this file is that).

> **NOTE 2026-09-04 (path canonicalization):** the intended CPU core
> versions now live at `rtl/cpu/nmos6502/` (copy of `rtl/new_6502/`, incl.
> its README) and `rtl/cpu/wdc65c02/` (copy of `rtl/new_cpu_v2/`, the v2
> core) — one version per core, canonical. The superseded dirs
> (`rtl/new_cpu/`, `rtl/new_cpu_original/`, `rtl/new_cpu_v2/`,
> `rtl/new_6502/`) were MOVED to untracked backup `rtl/old/cpu/`
> (gitignored). All `rtl/new_cpu_v2/`-style paths in this document are
> HISTORICAL/PINNED (they identify the exact sources the evidence was
> built from — verFiles.dat manifests and provenance.json keep them on
> purpose); the byte-identical copies now at `rtl/cpu/` are the working
> sources (md5s recorded in the backup-move log). Live project sources
> `rtl/cpu_65c02.sv`/`rtl/cpu_alu.sv` (v1) still await the B1 swap with
> the canonical v2 content. Quartus compile for v2: see
> `build/quartus_v2_prep.md` and handoff task B1.

---

## 1. What the user asked

> "a new version of the CPU core is available, I put it under /rtl/new_cpu_v2/.
> Run the suite for this and document any changes, I want to know if it's a
> closer match to the 65c02 or not"

Answer (all numbers below verified on disk): **Yes — v2 is dramatically closer
to the 65C02.** It beats both v1 (`rtl/new_cpu`) and the T65 golden on all
three 65C02 vendor suites, passes *every* test the golden passes there
(new-only-fail = 0), and its only cost is on the MOS `6502` suite, where it
trades 423 tests against v1 by adopting 65C02 conventions that MOS silicon
doesn't have (BCD extra cycle, page-cross dummies).

**UPDATE (same day): the user asked whether v2's `WDC_MODE` parameter should
be used to replicate the MOS 6502 — it should, and it works.** Built with
`WDC_MODE=0` (NMOS-flavored bus behavior), v2 scores **8273/12800 on the 6502 suite: +1990
fixed vs WDC_MODE=1, ZERO regressions, and it beats the T65 golden (7869)
by +404.** (Historical figures — they predate the instruction-complete
check now in `sst_driver.compare()`; like-for-like current totals are in
the new6502 UPDATE below.) Its only remaining new-only-fails are 20 tests
of op 7c — the suite's 6502-subset model for that opcode (JMP (abs,X) on
W65C02; NMOS-silicon behavior of $7C is a known open question, see §3b
caveat) — a lineage trait v1 shares. See §3b and §8.

**Caveat on the “v2nmos = NMOS 6502” label (2026-09-03, from independent
review):** `WDC_MODE=0` does NOT make v2 an NMOS 6502 model. It switches
only a limited set of bus/flag behaviors (RMW write-back order, indexed
page-cross dummy addresses, BCD D=1 extra cycle, BRK, D-clear on IRQ, ~10
gated sites in `cpu_65c02.sv`); the opcode decode remains the 65C02-style
decode (65C02-only instructions still execute). The 6502-suite score
therefore demonstrates compatibility with the documented MOS subset, not
MOS correctness. Treat the “v2nmos” column as “v2 with WDC bus behavior
off” — a useful NMOS-leaning reference, not an oracle.

**UPDATE (2026-09-03, ~09:30 CST): a third, netlist-derived NMOS-specialized
core arrived as `rtl/new_6502/`.** Compared on the MOS 6502 suite against the
NMOS results only (per user): **tied with v2nmos (7973/12800, fixed=0 /
regressed=0), strictly dominates v2 WDC=1 (+1990) and v1 (+1567), zero
new-only-fails vs golden; its 91 raw-trace diffs vs v2nmos are all
netlist-specific behavior the suite cannot see ($5C LLX decode, released-bus
settle addresses).** See §3c.

## 2. The cores

| name | path | notes |
|---|---|---|
| v1 (new core) | `rtl/new_cpu/` | the core from the prior campaign; SST binary pinned at `build/sst_verilog/Vcpu65_sst_tb.exe` |
| **v2** | `rtl/new_cpu_v2/` | `cpu_65c02.sv` (1431 ln, +~350 diff lines) + `cpu_alu.sv` (141 ln). Untracked in git. |
| golden | T65-based SST build | binary under `build/` (see sst_progress.md); **compare with `final_offset=1`** — see §6 |

### v2 changes vs v1 (from the diff, verified)

`cpu_alu.sv`:
- **BCD N/V fix** (the open decision item from FINAL_VERDICT): ADC decimal
  `overflow` now taken from the *intermediate* sum before the high-nibble +6
  (`d_hi[3]`), and `carry_out = d_hi_c` only. Comment in code: verified against
  WDC/Rockwell/Synertek ADC sets, 0 mismatches (old formula missed ~26%).
- Nibble adders narrowed to 4 bits (only low nibble of +6 kept).

`cpu_65c02.sv`:
- **`WDC_MODE` parameter** (1 = W65C02S bus/flag behavior, 0 = NMOS 6502).
  ST2204 instantiation uses `WDC_MODE=1`.
- **`S_DEC_FIX` state**: BCD extra cycle when `WDC_MODE && fl_d`, applied to
  ADC/SBC in all addressing modes.
- **BBR/BBS** ($A0–$A7/$B0–$B7 = the xF column, bit4=0): dedicated
  `S_ZPR_M` (second zp read) + `S_ZPR_FIX` (branch page fix) states; matches
  the WDC/Rockwell model exactly (bit mapping verified against all 10,000
  WDC xF tests — see §5.1). v1 also decoded xF as BBR/BBS but with a generic
  one-read zp path that failed the vendor traces.
- **$x2 column**: decoded as the 65C02 (zp) versions of the cc=01 ops.
- **1-cycle NOP set** per WDC datasheet Table 7-1 (e.g. $9B; `nop1_hold`
  merges it into the following instruction and gates `take_int`).
- **$x3/$xB columns**: now 2-byte 2-cycle via `S_NOP8` (v1 had them as
  1-byte 1-cycle).
- **NMI**: edge-detected (`nmi_sync`/`nmi_last`), two-ce latency to
  `nmi_pending`. TB must init `nmi_sync=1` (see §4).
- **IRQ**: double-sampled (`irq_l1`/`irq_l2`, decision on `irq_l2`) — poll
  twice per fetch.
- **JMP (abs,X) / (zp),Y / abs,Y page-cross** conventions moved to the WDC
  family (pc_dec fix); this is what fixed JMP(abs)/(abs,X) on WDC/Rockwell
  and the 19 D=0 (zp),Y ADC dummies on WDC.

## 3. Authoritative results (recomputed 2026-09-03, all files on disk)

Sweep method: identical to the v1 campaign — `select_tests(sample=50, seed=1)`
over all 256 ops; WDC selection yields 12700 (cb/db ship empty), others 12800.
Pass totals are from the retained per-opcode summary headers:

| suite | v1 | **v2** | golden (T65) | v2−v1 | v2−gold |
|---|---|---|---|---|---|
| wdc65c02 (12700) | 10798 (85.0%) | **12106 (95.3%)** | 8093 (63.7%) | **+1308** | **+4013** |
| rockwell65c02 | 10829 (84.6%) | **12155 (95.0%)** | 8132 (63.5%) | **+1326** | **+4023** |
| synertek65c02 | 10432 (81.5%) | **10964 (85.7%)** | 8125 (63.5%) | **+532** | **+2839** |
| 6502 MOS | 6706 (52.4%) | 6283 (49.1%) | 7869 (61.5%) | −423 | −1586 |

### Four-way split vs golden (`build/v2_reconcile.py`, report
`build/v2_reconcile_report.txt`; golden `final_offset=1` verified per suite by
exact reproduction of every summary header):

| suite | core | both-pass | both-fail | golden-only-fail (core wins) | **new-only-fail** |
|---|---|---|---|---|---|
| wdc65c02 | v1 | 8093 | 1902 | 2705 | **0** |
| wdc65c02 | v2 | 8093 | 594 | 4013 | **0** |
| rockwell65c02 | v1 | 8132 | 1971 | 2697 | **0** |
| rockwell65c02 | v2 | 8132 | 645 | 4023 | **0** |
| synertek65c02 | v1 | 8125 | 2368 | 2307 | **0** |
| synertek65c02 | v2 | 8125 | 1836 | 2839 | **0** |
| 6502 MOS | v1 | 6305 | 4530 | 401 | **1564 (43 ops)** |
| 6502 MOS | v2 | 5882 | 4530 | 401 | **1987 (53 ops)** |

Key properties:
- On all three 65C02 suites, both-pass == golden's total pass count, i.e.
  **v2 passes a strict superset of the golden's passing tests** — v2 never
  fails a test that T65 passes. v1 already had this property; v2 extends it
  by ~4000 tests.
- MOS both-fail is *identical* for v1 and v2 (exactly 4530) — the broken-MOS-
  reference opcodes identified in FINAL_VERDICT §2 fail in all cores equally.
- MOS golden-only-fail = 401 for both v1 and v2 (core wins over T65/MOS on
  the same tests).

### 3b. WDC_MODE=0 (NMOS) run on the 6502 suite — DONE, result: best 6502

`cpu65_sst_tb_v2.sv` gained a pass-through `parameter WDC_MODE = 1'b1`
(default keeps existing binaries' behavior); built in a separate Mdir:
`build/sst_verilog_v2nmos/` via `verilator ... -GWDC_MODE=0`. Raw results
`build/sweep_6502_v2nmos_results.txt`, summary `sweep_6502_v2nmos.txt`,
analysis `build/v2nmos_report.txt`.

| 6502 suite | v1 | v2 WDC=1 | **v2 WDC=0** | golden |
|---|---|---|---|---|
| pass / 12800 | 6706 (52.4%) | 6283 (49.1%) | **8273 (64.6%)** | 7869 (61.5%) |

- vs golden (offset 1): both-pass 7849, both-fail 4507, v2nmos-wins 424,
  **new-only-fail = 20 — all op 7c (the suite models this opcode for the
  6502 subset; v2/v1 disagree on its cyc3 address/data)**
  (e.g. `7c [7c 3068]: cyc3: addr 8212 != expected 685E`). v1 had the same
  7c:20 — lineage trait, not a v2 regression.
  **$7C note (independent review):** $7C is JMP (abs,X) on the W65C02;
  it is not “SBC abs,X” as an ISA fact. What the suite expects here is the
  6502-subset model of the suite; verified from the retained results, ALL
  FIVE cores (new6502, v2nmos, v2 WDC1, v1, R65Cx2) fail 50/50 of the $7C
  tests against it — the suite’s $7C model matches no core. The real
  NMOS-silicon behavior of $7C (indexed-NOP vs SBC-abs,X modeling) is an
  open question for the perfect6502 NMOS-oracle run (2026-09-03, expert
  question 11 of `build/new6502_diff_documentation.md`).
- WDC=0 vs WDC=1 on the same RTL: **fixed 1990, regressed 0**. Fixed classes:
  RMW double-write family (26 ops × 50 — the `!WDC_MODE` write-back of the
  unmodified value before the modified one, lines ~1009/1043 of
  `cpu_65c02.sv`), (zp),Y/abs,Y page-cross dummy addresses (wrapped EA instead
  of PC/pc_dec), BCD D=1 extra cycle (S_DEC_FIX not taken), plus BRK (00:22).
- **FPGA framing: the Apple II CPU is an ST2204 (65C02) — the MiSTer core
  keeps `WDC_MODE=1`.** WDC_MODE=0 is for NMOS-6502 replication/diagnostics,
  not for this project's target machine.

### MOS new-only-fail detail (`build/v2_mos_newonly.txt`)

v2's 1987 = v1's 1564 re-cut:
- **gone-in-v2** (v1 fails, v2 passes): BCD ops 61(7), 65(8), 69(4), 6d(11),
  75(9) — the P-only N/V-on-invalid-digit failures, fixed by the ALU change —
  plus 7d(22→20). Arithmetic: +464 new − 39 − 2 = +423 = the pass-total delta.
- **NEW-in-v2** (the −423 cost, all 65C02-convention-on-MOS-data):
  - (zp),Y page-cross family: 11(28) 19(24) 31(20) 39(24) 51(30) 59(25) b1(30)
    d1(28) d9(25) f1(20)
  - abs,Y page-cross: 79(5→22) 91(50) 99(50) b9(27) be(24) f9(26)
  - BCD D=1 extra cycle (MOS has no such cycle): 71(9→25) and the indexed BCD
    ops' cyc4 failures
- **unchanged** (both v1 and v2 fail, MOS RMW write-back convention — the core
  lineage never does RMW write-backs; documented in FINAL_VERDICT): 06 0e 16 1e
  26 2e 36 3e 46 4e 56 5e 66 6c 6e 76 7e 9d c6 ce d6 de e6 ee fe (all 50/50 or
  near) plus the (zp),Y/abs,Y non-cross and 1d/3d/5d/3c/7c/bc/bd/dd/fd remnants.
- Failure kinds in v2: `cyc4`-only 831 (BCD extra cycle + page-cross dummies),
  `cyc3`-only 807 (RMW write-back), `cyc3+cyc5` 194 (indexed RMW + cross), and
  ~120 final-state-only off-by-one PC cases where the *bus trace fully matches*
  golden but the suite's expected final PC differs by ±1 (suite final-state
  field inconsistent with its own trace — same broken-reference class as
  FINAL_VERDICT §2; v1 showed the same set plus cyc4/cyc5/cyc6 on top).

### 3c. `rtl/new_6502` (netlist-derived NMOS-specialized core) — DONE 2026-09-03

User-provided core (first copy was a byte-identical duplicate of v2 —
re-supplied). `cpu_65c02.sv` 58,215 B, `cpu_alu.sv` 4,779 B (md5
`ce55e5ec…` / `96caadf9…` — pinned in `evidence/provenance.json`). README:
"netlist derived, fixed some pin definitions, IRQ timing speculative based
on 6502". Same module name and `WDC_MODE` param as v2 plus new pins
(`so_n`, `be`, `ml_n`, `phi1o/phi2o`, split `din`/`dout` + output enables).
`cpu65_sst_tb_v2.sv` compiles unchanged: the two new inputs stay unconnected
(= 0 — no SOB edge, BE only gates unused output-enables) and the new outputs
are unused, so the only on-bus difference vs v2nmos is core behavior.

Built with the pinned command (v2nmos Mdir recipe with the sources swapped,
Verilator 5.050, `-GWDC_MODE=0`): `build/sst_verilog_6502/`. Integrity check:
op 00 raw traces are **byte-identical** to v2nmos, so every diff below is
core-level, not harness plumbing.

| 6502 suite, current checker (12800) | v1 | v2 WDC=1 | v2 WDC=0 | **new6502** | golden |
|---|---|---|---|---|---|
| pass | 6406 | 5983 | 7973 | **7973** | 7749 |

(all five columns computed with the current `sst_driver.compare()` incl.
instruction-complete check — the 8273/7869 figures in §1/§3b predate that
check; within one column set the comparison is like-for-like.)

- vs v2nmos (the other NMOS result): **fixed=0, regressed=0** — identical
  verdict on all 12800 tests. vs v2 WDC=1: +1990/0; vs v1: +1567/0. vs
  golden: only-pass 224, **only-fail = 0** (never loses to the reference).
- **91/12800 raw bus traces differ vs v2nmos — one systematic class**
  (`build/new6502_report.txt`, regenerated from raw results):
  - **50× $5C, in-window**: new core does the documented NMOS LLX decode
    (FFbb + FFFF reads); v2nmos does WDC-style extra cycles at PC. Both fail
    the MOS suite's own $5C model (pinned both-fail class) — the suite agrees
    with neither.
  - **9× illegal ops, in-window (23 3b 63 73 7b 9b c3 db f3)**: the
    netlist's settle/extra-cycle address model differs from v2's
    hand-modelled one. All 59 in-window diff lines sit in the both-fail
    class — both cores disagree with the suite's model on those cycles.
  - **32× trailing-only (legal ops)**: differences only at cyc ≥ ncyc — the
    suite models no post-instruction cycles, so all three cores PASS these
    tests. Both cores take the **same cycle count** and re-sync right after
    the settle window; during it the new core drives FFxx/FFFF (netlist
    released-bus model) where v2nmos drives PC/EE values. (Interpretation,
    not a suite-verifiable claim — the released NMOS bus floats; FFFF is the
    pull-up-high resolution.)
- **Completion timing (added 2026-09-03, reviewer-driven)**: `sst_driver.py`
  gained `completion_classify()` (first (READ finalPC, READ finalPC+1) row
  pair = next-opcode fetch start; exact / early-N / late-N / no-fetch vs the
  suite row) and `build/new6502_report.py` reports it. For $5C: R65Cx2 starts
  the next fetch at row 4 on 50/50 (exact on the 27 4-cycle tests, 1 row
  early on the 23 5-cycle tests); v2nmos and new6502 both start it at row 8
  on 50/50 — their rows 4-7 are PC-hold / phantom reads, not a fetch. For the
  nine illegal ops the two NMOS cores have identical timing classes (mostly
  early or no-fetch — their final PC = PC+4 differs from the suite’s, so the
  expected pair never forms); golden diverges. Per-cycle register snapshots
  of new6502 and v2nmos are byte-identical on all 12800 tests — the 91-line
  difference is purely bus activity. No change to `compare()` pass/fail
  semantics; the classifier is reporting/analysis only.
- **$80 silent branch (2026-09-03 — the concrete “finish early/late and
  occasionally appear correct” case)**: all 50 op-$80 tests PASS for all five
  cores, yet every core decodes $80 as a 2-byte relative branch (WDC BRA,
  target = PC+2+signed(offset)) and continues execution at the branch
  target. The suite models $80 as a 2-byte NOP and never sees the branch:
  row ncyc is a coincidental READ of PC+2 (the expected next-fetch address)
  and the register snapshot at row ncyc is still pre-branch. If NMOS silicon
  treats $80 as a NOP, new6502 — despite being NMOS-specialized — still
  carries the 65C02 decode for this opcode. Expert question 11 in the doc
  below (same class of question for $7C, where all five cores fail 50/50
  against the suite’s 6502-subset model).
- **Expert-review document**: `build/new6502_diff_documentation.md` (generated
  by `build/new6502_diff_doc.py` from the retained raw traces only) —
  self-contained: per-cycle four-opinion bus traces with exact starting state
  for every one of the 91 diff lines, mechanical verification output, 11
  expert questions, and a reference ladder with perfect6502 (the
  transistor-level NMOS netlist simulation) as the best non-hardware oracle.
- **Verdict: tied on the suite (whose $5C / illegal-op / settle models
  cannot discriminate the two NMOS behaviours), and strictly closer to the
  netlist exactly where the suite is blind. Zero regressions against any
  reference. As an NMOS 6502 model, new6502 ≥ v2nmos on every axis
  measured.** Rockwell/Synertek (65C02 vendor) suites were NOT run —
  WDC-mode territory, out of scope per the user's "NMOS results only".
- FPGA framing unchanged: the Apple II CPU is an ST2204 (65C02) — the MiSTer
  core keeps `WDC_MODE=1`. new6502 targets NMOS-6502 contexts (e.g. Atari
  7800), per its README.

## 4. Harness state (how the v2 binary was built)

- TB copy: `module_tests/cpu_65c02/cpu65_sst_tb_v2.sv` (untracked) — identical
  to `cpu65_sst_tb.sv` except it drives/initializes **`nmi_sync = 1'b1`** at
  time 0 (v2 edge-detects NMI; an uninitialized nmi_sync caused spurious NMI).
- Build dir: `build/sst_verilog_v2/` (separate Mdir so the pinned v1 binary
  stays untouched). Same recipe as v1 (see sst_progress.md build notes).
- Pitfalls hit this session (already resolved, do not re-litigate):
  1. zero-byte `Vcpu65_sst_tb_v2__ALL.cpp` left by an interrupted Verilator
     generation blocks the build — delete it and re-run make.
  2. the "GUI subsystem / WinMain" link failure was a *symptom* of (1): with no
     generated main, mingw links crt-exe **win**. `crtexewin.o` in the link
     line = red herring; do not chase `-mconsole`.
  3. run make with the MSYS2 UCRT64 PATH set (a fresh Windows shell resolves
     `python3` to the broken WindowsApps stub).
- Sweep runtime: ~39 s per (core × suite) on this machine.

## 5. Findings worth keeping (all trace/suite-verified in the crashed session)

1. **xF column = BBR/BBS, vendor split.** WDC and Rockwell model $A0–$B7 as
   BBR/BBS with the same bit encoding as v2 (verified against all 10,000 WDC
   tests incl. a direct single-test run through the v2 binary); Synertek models
   the column as 3-byte NOPs. v2 follows WDC/Rockwell → passes their suites,
   fails Synertek's xF (and that is part of why v2's Synertek gain is smaller).
   $A8–$AF/$B8–$BF are 1-cycle NOPs in all three vendor suites.
2. **BCD extra cycle is a 65C02 family trait, not WDC-specific.** All three
   vendors add an extra cycle for D=1 ADC/SBC; MOS does not. v2's S_DEC_FIX is
   therefore correct for 65C02 and costs on MOS (§3).
3. **The immediate-mode extra-cycle address is a reference-model artifact.**
   The D=1 immediate BCD tests record a *constant* dummy address per vendor:
   WDC $007F, Rockwell $0059, Synertek $0056 (three different constants). v2
   re-reads PC (PC+2) on that cycle — it cannot match any of the constants, so
   **all 337 of v2's WDC BCD failures are exactly this one convention mismatch
   on D=1 tests** (D=0 all pass). In zp mode WDC re-reads EA, which v2 also
   does not replicate. This is a testable open question: should v2 emit a
   vendor-matching dummy read on the BCD extra cycle? (It would be chasing a
   reference-model artifact; recommendation so far: document, don't chase.)
4. **v2's +19 over v1 on WDC D=0 BCD** = 19 (zp),Y ADC page-cross dummy tests
   v1 failed; fixed by the pc_dec change.
5. **JMP (abs,X) / indirect family**: v2 matches WDC/Rockwell (both-fail set
   shrank 1902→594 on WDC); Synertek differs again on some of these.
6. `v2_compare.py` (build/) is the per-opcode delta tool across all 8
   summaries; its GROUPS table is a handy index.

## 6. THE crash-point bug — RESOLVED (read this first if resuming)

Three throwaway scripts in the crashed session reported three different MOS
"new-only-fail" totals for v2: **782, 4530, 1987**. All three were wrong or
mislabeled. Root cause: `sst_driver.compare(test, groups, final_offset)`'s
third argument is the *register-snapshot offset* (golden commits A/X/Y/S/P one
cycle later than the new-core lineage), **not** a bus-cycle alignment shift —
and the scripts used it inconsistently (0 vs 1).

**Verified rule: golden results are compared with `final_offset=1` for ALL
four suites; v1/v2 use `final_offset=0`.** Proof: offset 1 reproduces every
retained summary header exactly (8093/7869/8132/8125); offset 0 does not.
(The line-410 script's per-suite goff choices {0,0,0,1} were guesswork — its
WDC/Rockwell/MOS four-way numbers are invalid; only its Synertek row was
right.) The "4530" came from a script whose `if not fg: continue` guard was
inverted in effect — it counted BOTH-FAIL (which is genuinely 4530 for both
v1 and v2 on MOS). The true numbers are in §3's table.

`build/v2_reconcile.py` is the persistent, self-verifying replacement for all
throwaway comparisons — use it going forward (it re-verifies the offset
against headers before reporting anything).

## 7. Artifacts (all under `module_tests/cpu_65c02/`)

- `V2_HANDOVER.md` — this file
- `build/sst_verilog_v2/` — v2 SST binary (`Vcpu65_sst_tb_v2.exe`)
- `cpu65_sst_tb_v2.sv` — v2 TB (nmi_sync init)
- `build/sweep_{wdc,rockwell,synertek}_{v1,v2,golden}_results.txt` + `.txt`
  summaries; `build/sweep_6502_v2_results.txt` + `sweep_6502_v2.txt` (MOS v2)
- `build/v2_compare.py` — per-opcode/group delta table
- `build/v2_reconcile.py` + `v2_reconcile_report.txt` — four-way split,
  offset self-verification
- `build/v2_mos_newonly.txt` — MOS new-only-fail per-op table + kinds
- `build/sst_verilog_v2nmos/` — WDC_MODE=0 binary (`Vcpu65_sst_tb_v2.exe`)
- `build/sweep_6502_v2nmos_results.txt` / `sweep_6502_v2nmos.txt` / `v2nmos_report.txt`
  — the NMOS-mode sweep (8273/12800) + analysis
- NOTE: `cpu65_sst_tb_v2.sv` was edited to add the WDC_MODE pass-through
  parameter (default 1 = behavior-preserving); the `sst_verilog_v2` Mdir
  binary predates the edit but remains valid.
- `build/bcd_classify_wdc.py` — last tool written before the crash (WDC BCD
  D-flag failure classifier; output: all 337 = extra-cycle address mismatch)
- `build/sst_verilog_6502/` — new_6502 SST binary (WDC_MODE=0); pinned copy
  `evidence/Vcpu65_sst_tb_6502.exe`
- `evidence/sweep_6502_new6502_results.txt` (12800 R-lines) +
  `build/new6502_report.py` → `build/new6502_report.txt` — the §3c sweep and
  its trace-diff analysis
- `evidence/provenance.json` now carries the new_6502 entries
  (`files.rtl.new_6502_core`, `files.binaries.new_6502_sst`,
  `retained_results.new6502_mos_sweep` = 7973/12800)
- prior campaign: `FINAL_VERDICT.md`, `sst_progress.md`, `provenance.json`
  (committed as `74546ce`)

## 8. Open items / suggested next steps

1. **Write the v2 verdict** — either extend `FINAL_VERDICT.md` with a "v2"
   section or a sibling `V2_VERDICT.md`: headline is §1's answer + §3 tables +
   §5 findings + the WDC_MODE=0 question below. (This was the natural next
   step; the user only asked to "document any changes".)
2. ~~WDC_MODE=0 untested~~ **DONE (2026-09-03)**: 8273/12800, +1990 fixed /
   0 regressed vs WDC=1, beats golden by 404; only residual = 20× op 7c
   (lineage trait). See §3b. Remaining question if it matters: why does 7c
   (suite model for the 6502 subset) cyc3 disagree with the MOS suite (and
   note 6c/7c are flagged as
   unreliable refs in FINAL_VERDICT — check whether those 20 are the same
   broken-reference class before treating them as a real bug). $7C is
   JMP (abs,X) on W65C02; NMOS-silicon behavior pending the perfect6502
   oracle run.
3. **BCD extra-cycle dummy read** (§5.3): decide document-vs-chase. Current
   recommendation: document (three different vendor constants ⇒ artifact).
4. **Staging/commit**: v2 campaign files are all untracked in
   `Apple-II-Verilog_MiSTer` (v1 campaign was committed by the user as
   `74546ce`). Do NOT commit unless asked. Note `rtl/new_cpu_v2/` itself is
   also untracked — user-provided.
5. Not done, not requested: Quartus integration of v2, full-machine Verilator
   smoke with v2, Apple-II.sv wiring. If the user wants v2 in the FPGA core,
   that's a fresh work item (component binding in `rtl/apple2_top.vhd`,
   files.qip registration, WDC_MODE choice, Quartus map).
6. ~~new_6502 comparison~~ **DONE (2026-09-03)** — see §3c: tied with v2nmos
   on the 6502 suite, zero regressions anywhere; the 91 raw-trace diffs are
   netlist-specific (suite-blind) behaviour. Not done for new_6502: Rockwell/
   Synertek vendor suites (WDC-mode territory — out of scope per user), and
   any WDC_MODE=1 build (the core ships the param; only the NMOS mode was
   requested). **Next step (2026-09-03, after independent review):** run the
   perfect6502 NMOS-oracle on the 11 expert questions in
   `build/new6502_diff_documentation.md` (or silicon capture); also decide
   what to do about the $80 silent-branch case (expert question 11).

## 9. Reproduce

```bat
rem from E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer (MSYS2 UCRT64 on PATH)
set PYTHONIOENCODING=utf-8
C:\msys64\ucrt64\bin\python module_tests\cpu_65c02\build\v2_reconcile.py
C:\msys64\ucrt64\bin\python module_tests\cpu_65c02\build\v2_compare.py
```

Sweep driver (per core × suite, ~39 s each): see `sst_progress.md` "Step 6"
for the exact `sst_driver.py` invocations; v2 uses `--bin
module_tests/cpu_65c02/build/sst_verilog_v2/Vcpu65_sst_tb_v2.exe`.
new_6502 (§3c) uses `--bin
module_tests/cpu_65c02/build/sst_verilog_6502/Vcpu65_sst_tb_v2.exe`; its
report regenerates with no simulation:

```bat
C:\msys64\ucrt64\bin\python module_tests\cpu_65c02\build\new6502_report.py
C:\msys64\ucrt64\bin\python module_tests\cpu_65c02\provenance.py
```
