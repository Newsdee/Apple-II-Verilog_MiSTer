# R65C02 Equivalence Harness — Execution Plan

Status: **COMPLETE (v1) 2026-08-30** — `R65C02 EQUIVALENCE PASS`
(83,906 fields compared, 0 mismatches, coverage 61/61). Contract doc:
`README.md`; session log + DUT facts: `PROGRESS.md`. Roster entry updated.

## As-built deviations from this plan (all deliberate)

1. **Trace schema is 22 columns, not 15**: P is emitted per-bit
   (`P_N..P_C`) instead of one `P` byte, so the permanently-undefined B flag
   can be skipped field-by-field without discarding defined rows. The plan's
   "metavalue budget" for R/B is subsumed by field-level meta-skip.
2. **Memory model**: single generated 64K image (pattern + program +
   vectors) instead of `apple2e.hex` ROM + RAM overrides — the CPU is tested
   in isolation; the apple2 harness covers the ROM path.
3. **v1 = Phase A only** (single phase, no `+PHASE`). Phase B (mid-stream
   reset) is deferred — see README "v1 exclusions".
4. **Coverage is 61/63 mnemonics**: BRK and RTI are excluded from v1 (RTI's
   non-standard semantics need a dedicated test design; v2).
5. **Executed-opcode detection** uses `SYNC=1 AND SYNC_IRQ=0` rows (DI =
   opcode) rather than reconstructing fetches from ADDR==PC — and it must
   exclude `SYNC_IRQ=1` rows because interrupt-injected fetches carry bogus DI.
6. **GHDL requires `--std=93 -C`** for the golden (VHDL-2008 mode fails on
   the opcode-table aggregate). No wrapper file was needed, as predicted.
7. **Generator is Perl** (`build/gen_mem_array.pl`), not PowerShell; sources
   live in `build/` and are tracked via force-add (the directory is
   gitignored for generated artifacts).
8. Interrupts use **8-cycle pulse windows** at fixed cycles 730/768 (the DUT
   samples nmi_n/irq_n only outside branch-taken/opcode-fetch subcycles).

The remainder of this file is the original plan, kept as history.

## Purpose and claim boundary

Differential Gate-1 test proving the Verilog port `rtl/R65Cx2.sv`
(module `R65C02`) is cycle-equivalent to the VHDL original
`../Apple-II_MiSTer_newsdee/rtl/R65Cx2.vhd` (entity `R65C02`) under
identical stimulus. Same standard as t65 and disk_ii: **port equivalence,
not 65C02 datasheet conformance** — both DUTs are the same design family, so
any divergence is a porting defect regardless of whether the instruction is
"legal".

The 65C02 path has never been exercised by any harness: the apple2
full-core harness drives `.cpu(1'b0)` (T65) in both testbenches, and there is
no c02 roster entry with a runner.

## Verified DUT facts (checked 2026-08-30)

- **Ports match 1:1** (12 ports). Only name difference: Verilog data-out is
  `dout`, VHDL is `do`.
- **Reset is ACTIVE-LOW**, asynchronous in the Verilog port
  (`always_ff @(posedge clk, negedge reset)` with `if (~reset)`,
  `R65Cx2.sv:1079`). The full core drives it inverted:
  `.reset((~reset))` / `reset => not reset`. TB must drive the port
  directly: hold `reset=1` (deasserted), pulse `reset=0` to assert.
- **`Regs[63:0]` layout is identical on both sides** — Verilog
  `R65Cx2.sv:1320`: `{PC, 8'b00000001, S, N,V,R,B,D,I,Z,C, Y, X, A}`;
  VHDL `R65Cx2.vhd:1522`: same with `"00000001"`. Note the hard-coded
  `0x01` byte at `[47:40]` in BOTH ports (not a register), and S is an
  **8-bit** register here (unlike T65's 16-bit S with FF high byte).
- **`enable`** gates every state update (`if (enable)` throughout). The full
  core drives `CPU_EN & ~CPU_WAIT`; this harness ties `enable=1'b1`
  (free-running) — the apple2 harness with `cpu=1` covers gated-enable later.
- **`sync`** = pulse on each opcode fetch (`theCpuCycle == opcodeFetch`,
  `R65Cx2.sv:1316`); **`sync_irq`** = `irqActive`. Both are cheap trace
  columns worth including.

## Opcode census (from `opcodeInfoTable[256]`, `R65Cx2.sv:283`)

The table carries a mnemonic comment per entry, so coverage design is a
grep, not a decode. Result: **64 unique mnemonics, 79 NOP slots, 63
non-NOP instructions**:

- Full 6502 base set (all addressing modes; LDA/ORA/EOR/CMP/AND/ADC/SBC
  ×9 modes each).
- **C02 stack set fully present:** `PHA PHP PHX PHY PLA PLP PLX PLY`.
- C02 extensions present: `BRA`, `TSB`, `TRB`, `STZ`, C02 NOPs.
- **Absent (full WDC set):** `STP/JAM` (no CPU halt — no halt handling
  needed in the harness), `JMR`, `RMB/SMB`, `BBR/BBI`.

Execution step 1 re-extracts this census from the source into a machine-
readable list (`build/opcode_census.txt`) so the coverage gate is generated,
not hand-typed. If the candidate table ever changes, the gate follows.

## Harness design

### Files (mirror `module_tests/t65/` layout)

```
module_tests/r65c02/
  PLAN.md               (this file)
  README.md             (written at execution end: pass/fail profile, gates)
  run_equivalence.ps1   (mirror of t65 runner: build both, run phases,
                         compare CSVs field-by-field with metavalue skip,
                         coverage gates, PASS line)
  r65c02_verilog_tb.sv  (candidate: rtl/R65Cx2.sv)
  r65c02_vhdl_tb.vhd    (golden: ../Apple-II_MiSTer_newsdee/rtl/R65Cx2.vhd)
  build/                (ignored; Verilator Mdir + GHDL work + CSVs)
```

No GHDL wrapper file is expected (entity has no generics — unlike T65).
Add one only if GHDL 6.0.0 objects, following `t65_vhdl_wrappers.vhd`.

### Trace schema (reuse t65's 13 columns; +2 for this DUT)

```
CYCLE,PC,SP,P,Y,X,A,ADDR,DI,DO,RW,NMI_N,IRQ_N,SYNC,SYNC_IRQ
```

- PC = `Regs[63:48]`, SP = low byte of `Regs[39:32]` (S), P/Y/X/A per the
  verified layout. RW from `nwe`.
- Both TBs emit identical rows for identical stimulus; comparison is the
  existing field-by-field engine with the standard metavalue skip + budget.

### Memory model and stimulus (reuse t65 machinery)

- ROM `$F000-$FFFF` from shared `rtl/roms/apple2e.hex` (CWD = repo root for
  Verilator; GHDL side per t65 runner conventions). Vectors: NMI
  $FFFA/$FFFB, IRQ/BRK $FFFE/$FFFF — same file the t65 harness uses, so
  vector targets are already known.
- RAM `$0000-$EFFF` model with the same override pattern as the t65 TB
  (test program + park locations).
- **Stimulus must be byte-identical in both TBs** — single source of truth:
  generate the program once (PowerShell generator, or a hand-maintained
  array duplicated verbatim with a checksum comment, per the t65 pattern)
  and include a build-time length/byte check.

### Phases (`+PHASE=0|1`, same convention as t65)

**Phase A — reset, full program, park.**
1. Assert reset ≥ 4 cycles, release at a fixed cycle.
2. Program starts at a fixed PC (post-reset vector or known start).
3. Directed test program exercising **every non-NOP mnemonic in the census**,
   each with at least one representative addressing mode; C02 stack ops get
   explicit value/flag round-trips (PHA/PLA, PHP/PLP incl. V/B bits,
   PHX/PLX, PHY/PLY) with known pre/post values.
4. Page-wrapping indirect JMP ($7C form) and plain indirect JMP.
5. NMI pulse and IRQ pulse at fixed cycles (vectors from ROM); handler
   trampoline parks back into the program — same technique as the apple2
   harness NMI trampoline.
6. Normal park `JMP self` at a fixed address; run to TOTAL cycles.

**Phase B — mid-stream reset (the scrutiny phase).**
Given the T65 `Dec_S/RstCycle` finding (post-reset S was 00 instead of FD),
Phase B re-asserts reset after ~100 executed instructions, releases it, and
runs to park. Gates check the post-reset PC/SP sequence field-by-field —
this is where an async-reset edge difference between the Verilog
`negedge reset` sensitivity list and the VHDL process style would surface.

(Phase C for `STP`-class halt behavior is **not needed** — STP/JAM are not
in this core's opcode table.)

### Coverage gates (enforced by the runner, like t65's gate_checks)

1. **Per-mnemonic fetch coverage**: reconstruct executed opcodes from the
   trace (fetch row = `ADDR == PC` at instruction start; first fetched byte
   is the opcode). Every census mnemonic must appear ≥ 1× per phase where
   applicable. Generated from `build/opcode_census.txt`.
2. **Park reached** at the expected address in both phases.
3. **NMI and IRQ entries observed** (PC hit the vector trampoline).
4. **Post-reset PC/SP sequence** matches the golden's exact values
   (Phase B) — expected constants recorded in the runner, not inferred.
5. **Metavalue budget**: VHDL 'U' fields at power-on (e.g., flag bits never
   written before first store, R bit `P[5]` if it stays 'U') are skipped
   with an explicit budget line in the PASS report — same discipline as
   disk_ii's `ignored_metavalues`.
6. **No error park**: a dedicated error-park address (JMP target on any
   unexpected branch) must never be hit.

## Build and run (mirror t65 runner)

- Verilator: `verilator_bin --binary --timing -Wno-fatal
  --top-module r65c02_verilog_tb module_tests/r65c02/r65c02_verilog_tb.sv
  rtl/R65Cx2.sv` → Mdir under `module_tests/r65c02/build/verilog`.
- GHDL: analyze `../Apple-II_MiSTer_newsdee/rtl/R65Cx2.vhd` +
  `r65c02_vhdl_tb.vhd`, run per t65 runner conventions (CWD = repo root).
- Runner output target (same shape as t65):
  `R65C02 EQUIVALENCE PASS rowsA=... rowsB=... fieldsA=... fieldsB=...
  ignored_metavalues=... gate_checks=...`

## Execution steps (in order)

1. Extract opcode census → `build/opcode_census.txt`; confirm 63 non-NOP
   mnemonics; record exact per-mnemonic opcode list.
2. Write the test program generator (or fixed array) + park/trampoline
   layout; compute expected park values and post-reset PC/SP constants.
3. Write `r65c02_verilog_tb.sv` (port map, memory model, stimulus, trace).
4. Write `r65c02_vhdl_tb.vhd` as an exact mirror (same stimulus bytes, same
   timeline, same CSV columns; VHDL entity ports are semicolon-separated —
   preserve file EOL style when creating).
5. Write `run_equivalence.ps1` from the t65 runner (build/run/compare/gates).
6. Run Phase A only first (fast Verilog-only iteration allowed as in apple2
   work), fix TB issues, then full two-DUT run.
7. Add Phase B; verify reset-release edge parity explicitly.
8. Full suite: `module_tests/run_tests.ps1` must stay green (13 existing +
   r65c02 = 14).

## Definition of done

- PASS line as above with all gates, both phases, metavalue budget reported.
- `module_tests/r65c02/README.md` written (contract, stimulus description,
  gate list, pass profile; FAIL profiles retained if any pre-pass divergence
  appears — per house style).
- Roster line updated: `Planned` → `PASS <date>; rows=... fields=...
  gate_checks=...`.
- `test_manifest.json` gains the r65c02 entry (only after the runner exists,
  so `run_tests.ps1` never points at a missing script).
- No edits to golden or candidate RTL to make the test pass. If a real
  divergence appears, stop and report it — do not "fix" either side without
  a user decision (same rule as t65/vga_controller).

## Risks and open questions

- **Reset-release edge**: Verilog models reset asynchronously
  (`negedge reset`); the VHDL process style may release one cycle
  differently. Phase B exists specifically to catch this; if it diverges,
  classify (port defect vs. acceptable sim-only artifact) before touching
  RTL — the T65 precedent shows the golden can have its own quirks.
- **R flag bit `P[5]`**: C02 "reserved" bit; may stay 'U' in VHDL and 0 in
  Verilator at power-on → budget it, don't chase it.
- **Floating-bus reads**: like the apple2 harness, reads from unmapped RAM
  regions must use the same stateless pattern model on both sides; never
  rely on simulator X/0 luck.
- **Program size vs. run time**: ~63 mnemonics × modes ≈ a few hundred
  instructions; at 14 MHz-cycle granularity this is small (t65 ran 320/500
  rows for far less). No runtime risk expected.
