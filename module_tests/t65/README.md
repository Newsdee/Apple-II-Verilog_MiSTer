# T65 equivalence harness

Golden: `Apple-II_MiSTer_newsdee/rtl/t65/{T65.vhd, T65_Pack.vhd, T65_MCode.vhd, T65_ALU.vhd}`
Candidate: `rtl/t65/{t65.v, t65_pack.v, t65_mcode.v, t65_alu.v}`

Purpose: isolate the 6502 CPU core so the apple2 full-core divergence (cycle 358,
stack-region address off by one) can be diagnosed at module level. Mode is fixed to
`"00"` (6502) on both sides, matching how `apple2.vhd`/`apple2.v` instantiate it.

## Status: PASS (both phases, post-alignment + boot preamble)

```
T65 EQUIVALENCE PASS rowsA=320 rowsB=500 fieldsA=3072 fieldsB=5784 ignored_metavalues=80 gate_checks=17
```

- The S/Dec_S divergence (below) was confirmed real and the user ordered alignment on
  2026-08-30. Candidate `t65.v` line ~550 now reads
  `if (Dec_S == 1'b1 & (RstCycle == 1'b0 | Mode == 2'b00))` (CRLF preserved, 1 line).
- **Phase A (directed program): full match** -- rows=320, fields=3072 compared, 64
  metavalue rows skipped, 17/17 gates pass.
- **Phase B (boot walk): full match** -- rows=500, fields=5784 compared, 16 metavalue
  rows skipped. The earlier cycle-84 divergence (PC 6BC8 vs 6BCA) was a simulation-only
  power-on artifact: golden T65 resets only P; ABC/X/Y start 'UUUU' in VHDL sim vs 0 in
  Verilator, and the pattern walk executed indexed/RMW/ALU opcodes while they were still
  undefined (GHDL maps metavalue->1 in unsigned arithmetic, so the golden computed
  defined-but-garbage values). On FPGA both sides power up 0. Fixed TB-side with a boot
  preamble at the reset vector $6B4C (A9 21 / A2 32 / A0 43 = LDA/LDX/LDY immediate) in
  BOTH testbenches' `main_byte()`, so A/X/Y are defined before the pattern walk starts
  at $6B52. No RTL change.

## Run

```powershell
Set-Location E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer
.\module_tests\t65\run_equivalence.ps1
# recheck existing traces without rebuilding:
.\module_tests\t65\run_equivalence.ps1 -CompareOnly
```

The runner regenerates the ROM/RAM init files (gen_rom_array.ps1 is the single source
of truth), analyzes the golden with GHDL (`-fsynopsys`, std=08), builds the candidate
with Verilator, runs both phases on both sides, compares field-by-field, then applies
coverage gates.

## Phases

Two runs per side (4 CSVs total), selected by VHDL generic `PHASE` (via wrapper
entities `t65_vhdl_tb_prog`/`t65_vhdl_tb_boot`, because GHDL 6.0.0 has no generic-map
option) and Verilog `+PHASE=` plusarg:

- **Phase A "prog" (320 cycles)** -- directed program at $0500 in real writable RAM
  (full $0000-$EFFF, 61440 bytes). The ROM reset vector is overridden to $0500 via the
  `rom_byte()` read function (TB-side only; no RTL change). The program covers:
  immediate ALU ops with carry/borrow/overflow flag checks (SBC #$07 -> A=$FD N set;
  ADC #$03 -> Z+C; SEC; ADC #$FF), zero-page and absolute STA/LDA readbacks,
  STX/LDX, LDY/TYA, JSR/RTS (stack push/pop of return address), PHA/PLA, CLI,
  BEQ/BNE taken and not-taken branches, a park loop at $0546, an IRQ pulse
  (cycles 120-124) and an NMI pulse (cycles 200-204).
- **Phase B "boot" (500 cycles)** -- standalone reproduction of the full-core finding
  environment: pure apple2e ROM, stateless `main_byte()` pattern RAM copied verbatim
  from the apple2 harness. The reset vector $6B4C points into main RAM; the bytes at
  $6B4C-$6B51 are a boot preamble (LDA #$21 / LDX #$32 / LDY #$43) that deterministically
  defines A/X/Y before the deterministic pattern walk starts at $6B52. The preamble is
  TB-side only (identical in both testbenches) and exists because the golden T65 leaves
  A/X/Y undefined at reset in VHDL simulation (see Status). Both CPUs then execute the
  pattern bytes as code; this walk is NOT identical to the full-core walk (the real core
  has soft-switch/IO behavior), but it drives the same S/stack machinery hard -- which is
  where the full-core divergence lives.

Memory model (both TBs): combinational read mux -- addresses >= $F000 come from
apple2e.hex, < $F000 from real RAM (phase A) or `main_byte` (phase B). Writes commit
in phase A only. Enable=1 continuously; the full core's 1-cycle ROM latency is not
needed because its CPU steps only every 14th cycle and q settles within the step.

## Trace schema (13 columns, hex values)

`CYCLE,PC,SP,P,Y,X,A,ADDR,DI,DO,RW,NMI_N,IRQ_N` -- sampled at posedge+1ns, one row
per traced clock edge. PC is full 16-bit. P bits follow T65_Pack: C=0,Z=1,I=2,D=3,B=4,V=6,N=7.

Regs port layout (both DUTs, verified): `{PC[15:0], S[15:0], P, Y[7:0], X[7:0], A}` =
exactly 64 bits. **S is a 16-bit register whose high byte stays FF**, so the trace
slices are PC=regs[63:48], SP=regs[39:32] (S low byte), P=regs[31:24], Y=regs[23:16],
X=regs[15:8], A=regs[7:0]. (An earlier draft of the TB assumed S was 8 bits and put
A at regs[15:8]; that silently traced X into the A column.)

## Reset and vectors (established facts)

- Res_n=0 cycles 0-3, released cycle 4 (keyboard harness convention). The DUT
  double-synchronizes it internally (`Res_n_i`), so the internal reset releases ~2
  cycles later; both sides identical.
- Post-reset S in 6502 mode is **$FD** in the golden: the RstCycle window executes
  three Dec_S micro-ops (S: 00 -> FF -> FE -> FD) while reading $0100/$01FF/$01FE.
- T65 Mode="00" interrupt vectors, observed in the golden trace: **IRQ at
  $FFFE/$FFFF** (handler $DFCF), **NMI at $FFFA/$FFFB** (handler $B4D0), reset at
  $FFFC/$FFFD. Not the standard 6502 $FFF6/$FFF7 IRQ location.

## Known divergence (the finding)

First difference, both phases, cycle 7, SP column: VHDL=FF, Verilog=00.

- Golden `T65.vhd` line 418:
  `if Dec_S = '1' and (RstCycle = '0' or Mode = "00") then -- Decrement during reset - 6502 only?`
- Candidate `t65.v` line 550:
  `if (Dec_S == 1'b1 & RstCycle == 1'b0)`

The candidate dropped the `or Mode == "00"` clause. In 6502 mode the golden therefore
honors Dec_S during the reset window (S ends at $FD); the candidate suppresses it
(S stays $00). Everything downstream of S then differs: JSR pushes go to $01FD/$01FC
(golden) vs $0100/$01FF (candidate), PLA reads different stack bytes, flags diverge,
and the instruction walk forks.

This is the most likely root cause of the apple2 full-core cycle-358 divergence
(ADDR 01FB vs 01FE): a different S after reset changes what PLA puts into P, which
changes branch outcomes in the pattern-code walk, so by the time the full core reaches
the $FE8x ROM code the two stack pointers are one apart.

**Alignment APPLIED 2026-08-30 (user-ordered):** candidate `t65.v` line ~550 changed to
`if (Dec_S == 1'b1 & (RstCycle == 1'b0 | Mode == 2'b00))` with a comment referencing the
golden. One-line, behavior-preserving port of the golden's documented condition.
Pre-alignment signature: both phases diverged at cycle 7, SP: VHDL=FF Verilog=00.

## Testbench bug fixed during bring-up (not a DUT difference)

The Verilog TB's write-back `always @(posedge clk)` fired on the first posedge, before
stimulus started: the DUT's R_W_n output register is 0 at init, so the TB wrote
DO(=0) into ram[0]. The VHDL side never sees this because rw_n is 'U' there and
`rw_n = '0'` evaluates false. Fix: a `sim_go` flag set at the first stimulus
application guards the write-back. After the fix, cycles 0-6 match bit-for-bit.

## GHDL 6.0 pitfalls (this harness depends on them)

- `-fsynopsys` is required (T65_MCode.vhd uses `ieee.std_logic_unsigned`) and it
  removes `std.env`, so termination is by mandatory `--stop-time`.
- No generic-map option: phase selection goes through wrapper entities.
- Multi-driver array corruption: RAM is a static initial aggregate (from the
  generated `t65_rom_array.vhd` package) driven by a single clocked process; no seed
  process.

## Coverage gates

Phase A: park loop reached (PC=$0546); SBC result A=$FD with N set; ADC result A=$00
with Z+C set; SP back to $FD after the JSR/RTS window; IRQ vector fetch at
$FFFE/$FFFF after cycle 120; NMI vector fetch at $FFFA/$FFFB; >=4 distinct P values.
Phase B: boot walk started at $6B4C; >=100 distinct addresses; >=5 stack-page ($01xx)
accesses; >=20 write cycles; >=3 distinct SP values. Cross-phase: total ignored
metavalue rows < 400; phase A compared fields >= 3000; phase B compared fields >= 4800.

Gates run only when both phases compare clean (a divergence throws first).

## Current result (2026-08-30, post-alignment + boot preamble)

```text
T65 EQUIVALENCE PASS rowsA=320 rowsB=500 fieldsA=3072 fieldsB=5784 ignored_metavalues=80 gate_checks=17
```

Exit code 0; registered in test_manifest.json as PASS. History: pre-alignment both
phases diverged at cycle 7, SP: VHDL=FF Verilog=00 (the S/Dec_S difference); after
alignment Phase A matched but Phase B diverged at cycle 84 on the power-on artifact,
resolved by the boot preamble.

## Files

- `t65_vhdl_tb.vhd` -- golden testbench (entity `t65_vhdl_tb`, generic PHASE)
- `t65_vhdl_wrappers.vhd` -- `t65_vhdl_tb_prog` (PHASE=0), `t65_vhdl_tb_boot` (PHASE=1)
- `t65_verilog_tb.sv` -- candidate testbench (`+PHASE=` plusarg)
- `gen_rom_array.ps1` -- single source of truth for ROM/RAM init; emits
  `build/t65_rom_array.vhd` (VHDL constants) and `build/t65_ram_init.hex` ($readmemh)
- `run_equivalence.ps1` -- build, simulate x4, compare, gates
- `PROGRESS.md` -- working log with environment notes
- `build/` -- generated artifacts (gitignored)
