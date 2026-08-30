# R65C02 VHDL/Verilog equivalence test

Black-box differential test for the 65C02 CPU core. The MiSTer VHDL
implementation (`../../Apple-II_MiSTer_newsdee/rtl/R65Cx2.vhd`, entity
`R65C02`) is the reference model; the Verilog port
(`../../rtl/R65Cx2.sv`, module `R65C02`) is the candidate.

Run from PowerShell (repo root `Apple-II-Verilog_MiSTer`):

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\module_tests\r65c02\run_equivalence.ps1
```

To rerun only the comparison and gate checks against existing traces:

```powershell
.\module_tests\r65c02\run_equivalence.ps1 -CompareOnly
```

## What it does

The runner regenerates a single 64K memory image (Perl generator:
`build/gen_mem_array.pl` + `build/program_table.pl`), builds and runs both
testbenches under identical stimulus, and compares the cycle traces
field-by-field.

- **Program**: directed 6502/65C02 test at $0500 (~324 instructions) —
  prologue that defines every register before use (LDA/LDX/LDY/TXS/CLV/CLC),
  all ALU ops across addressing modes, the full C02 stack set with
  value/flag round-trips, every branch condition both taken and not-taken
  (shared-sentinel pattern — any wrong decision walks into `ERRPARK`),
  JSR/RTS, indirect JMPs (incl. X-indexed), a page-crossing BRA, and NOP
  sleds hosting one **IRQ** and one **NMI** pulse (8-cycle windows at
  cycles 730/768; handlers at $1020/$1030 return via explicit JMP).
- **Memory**: one 64K image on both sides = deterministic pattern
  `($i + i/16 + 60) % 256` with program, vectors, and handler overrides.
  No apple2e ROM — the CPU is tested in isolation.
- **Trace**: 22 columns per cycle (4000 cycles):
  `CYCLE,PC,SP,P_N,P_V,P_R,P_B,P_D,P_I,P_Z,P_C,Y,X,A,ADDR,DI,DO,RW,NMI_N,IRQ_N,SYNC,SYNC_IRQ`.
  P is emitted per-bit so the permanently-undefined B flag can be skipped
  without discarding the rest of the row.

## Gates (enforced by the runner)

- Equal row counts and identical header; zero mismatches among compared
  fields. A field is skipped when either side holds a metavalue
  (U/X/W/Z/-/?); `P_B` is always skipped (never driven in VHDL).
- ≥75,000 fields actually compared (anti empty-pass).
- **Coverage**: all 61 v1 mnemonics (census non-NOP minus BRK/RTI) executed
  at least once on real opcode fetches (`SYNC=1` and `SYNC_IRQ=0` —
  interrupt-injected fetches are excluded), per `build/opcode_census.txt`.
- `ERRPARK` ($090B) never entered; `PARK` ($0908) reached in both traces.
- IRQ handler ($1020) and NMI handler ($1030) entered in both traces.

## Known-good result (2026-08-30)

```
R65C02 EQUIVALENCE PASS rows=4000 fields_compared=83906 skipped_meta=4094 coverage=61/61
  skip_breakdown: A=8 P_B=4000 P_C=18 P_N=8 P_V=16 P_Z=8 SP=14 X=10 Y=12
```

All skips are expected reset-window metavalue fields (registers undefined
before the prologue defines them) plus the permanent B-flag skip.

## v1 exclusions / notes

- **BRK and RTI are not exercised** (deferred to v2). RTI is non-standard in
  this core: jump to `M16[PC+1]`, status from `M[PC+2]` (with C/Z swap),
  stack untouched — a v2 test must encode those semantics, not 6502 ones.
- **No mid-stream reset phase yet** (the plan's Phase B). The async-reset
  edge parity between the Verilog `negedge reset` and the VHDL process is
  therefore only covered at power-on.
- GHDL must analyze the golden with `--std=93 -C` (VHDL-2008 mode fails on
  the opcode-table aggregate; see PROGRESS.md §9 for the full list of
  VHDL-93 workarounds used in the testbench).
- This is simulation-level port equivalence only; Quartus fit/timing and
  hardware remain separate validation.

## Layout

```
r65c02_verilog_tb.sv   candidate testbench (Verilator)
r65c02_vhdl_tb.vhd     golden testbench (GHDL)
run_equivalence.ps1    runner + comparator (gates above)
build/gen_mem_array.pl image/program generator (Perl)
build/program_table.pl directed program definition
build/analyze.pl       opcode-table decoder (produces the census)
build/opcode_census.txt  opcode→mnemonic reference used by the coverage gate
PLAN.md                original execution plan (deviations noted at top)
PROGRESS.md            session log: DUT facts, calibration, bug log
build/                 ignored; Mdir, GHDL workdir, image, traces (regenerated)
```
