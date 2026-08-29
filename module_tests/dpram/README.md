# dpram VHDL/Verilog equivalence test

This directory contains a black-box differential test for the dual-port RAM
wrapper `dpram`. The Quartus-project VHDL implementation
(`../../Apple-II_MiSTer_newsdee/rtl/dpram.vhd`) is the reference model; it
instantiates `altsyncram` from the official Quartus 17.0 VHDL simulation
library, so the golden behavior is the vendor megafunction model itself. The
active Verilog implementation (`../../Apple-II-Verilog_MiSTer/rtl/dpram.v`)
is the candidate.

Run from PowerShell (from `Apple-II-Verilog_MiSTer`):

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\module_tests\dpram\run_equivalence.ps1
```

To rerun only the comparison and coverage checks against existing traces:

```powershell
.\module_tests\dpram\run_equivalence.ps1 -CompareOnly
```

The runner builds each language separately, executes identical deterministic
stimuli (32864 cycles, single clock driving both `clock_a` and `clock_b`,
enables held high exactly as in `floppy_track.sv`), and compares the cycle
traces field by field. The first mismatch stops the run and names the cycle,
signal, and both values.

## Files

- `dpram_vhdl_tb.vhd` - golden testbench; writes `build/vhdl_trace.csv`.
- `dpram_verilog_tb.sv` - candidate testbench; writes `build/verilog_trace.csv`.
- `run_equivalence.ps1` - builds, runs, compares, enforces coverage gates.
- `build/` - generated only: VHDL library files, the bound golden copy,
  the generated TB wrapper, Verilator objects, and both CSV traces.

## Golden build notes (GHDL + vendor model)

- The Quartus simulation library (`altera_mf_components.vhd`,
  `altera_mf.vhd`) is analyzed with `--std=08 -fsynopsys` into library
  `altera_mf` (package only) and into `work` (full model, so the unqualified
  `altsyncram` component in `dpram.vhd` binds to `work.altsyncram`).
- GHDL does not auto-bind components across libraries the way Quartus does,
  so the runner generates `build/vhdl/dpram_bound.vhd`: a byte-verified copy
  of the golden file with a marker-tagged strict-IEEE `component altsyncram`
  declaration inserted after the architecture header. The runner re-derives
  the original from the bound file and fails if any golden line changed.
  No RTL in either repository is modified.
- GHDL resolves library files from the current working directory (not from
  `--workdir`), so all GHDL commands run with CWD = `build/vhdl`.
- GHDL 6.0 has no `--generic-map` option, and the TB opens its trace file
  during elaboration, so the runner generates a small wrapper entity
  (`dpram_vhdl_tb_top`) that passes an absolute trace path as a generic.

## Stimulus schedule

| Cycles      | Phase | Behavior |
|-------------|-------|----------|
| 0..7        | INIT  | no writes, both ports read address 0 (initial contents) |
| 8..23       | AW    | port A writes addr i <- 0xA0+i; B reads addr 1000 |
| 24..39      | ARB   | port B reads back addr i (expect 0xA0+i); A reads 1000 |
| 40..55      | BW    | port B writes addr 16+i <- 0xB0+i; A reads addr 1000 |
| 56..71      | BRB   | port A reads back 16+i (expect 0xB0+i); B reads 1000 |
| 72..95      | SIM   | even i: both ports write simultaneously (distinct addresses); odd i: A writes 300+i while B reads 300+i (same-address cross-port conflict) |
| 96..8287    | SW    | port A sweep write addr i <- P(i); B reads (i-1) mod N |
| 8288..16479 | SRB   | port B reads back addr i; A reads (i-1) mod N |
| 16480..24671| BSW   | port B sweep write addr i <- P(i); A reads (i-1) mod N |
| 24672..32863| ARBB  | port A reads back addr i; B reads (i-1) mod N |

with `P(i) = (7*i + 3) mod 256` and `N = 8192`.

CSV columns: `CYCLE,Q_A,Q_B,WREN_A,WREN_B,ADDR_A,ADDR_B`. Hex case is
normalized before comparison (GHDL emits uppercase, Verilator lowercase).

## Metavalues

The golden model produces `X` for a same-address cross-port read/write
conflict (mixed-port behavior is `DONT_CARE` in the altsyncram model and is
undefined on real hardware). Those cells are skipped and counted as
`ignored_metavalues`; the coverage gate below still requires that the
conflict condition actually occurred 12 times.

## Coverage gates

- 8/8 INIT cycles read back `00` on both ports (initial RAM contents).
- 16/16 port A writes read back correctly through port B.
- 16/16 port B writes read back correctly through port A.
- 12/12 simultaneous dual-port write cycles (both wrens high, distinct addresses).
- 12/12 same-address cross-port conflict cycles produced observable X in the golden trace.
- Full 8192-word sweep on both ports: every address written and read back
  through the other port with the expected `P(i)` pattern (both Q_A and Q_B).
- At least 100000 fields actually compared (guards against metavalues hiding
  an empty comparison).

A passing run prints:

```text
DPRAM EQUIVALENCE PASS rows=32864 fields=<n> ignored_metavalues=<n> init_zero=8 a_readback=16 b_readback=16 dual_write_cycles=12 conflict_x_samples=12 sweep_words=8192
```

## Current status

The harness is complete and functional, but the candidate currently FAILS:
the first divergence is at cycle 71, signal `Q_A` (golden `BF`, candidate
`00`). Root cause analysis: the candidate's port B write block
(`mem[address_b_r] <= data_b_r`) uses the pre-edge values of the registered
address/data while `wren_b` is sampled on the current edge, so every port B
write lands one cycle late - at the previous cycle's address with the
previous cycle's data. A single-cycle port B write pulse (the actual
`floppy_track.sv` usage pattern) is written to the wrong address entirely.
The golden vendor model commits the write on the same edge using the newly
latched values. See the task report for details; no RTL was modified.
