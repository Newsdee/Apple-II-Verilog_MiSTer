# via6522 equivalence harness

Standalone VHDL-vs-Verilog equivalence test for the VIA 6522 used by the
Mockingboard. Built before the `mockingboard` harness so that any VIA-level
divergence is isolated from board glue and PSG interaction.

- Golden:   `Apple-II_MiSTer_newsdee/rtl/old/via6522.vhd`
- Candidate: `Apple-II-Verilog_MiSTer/rtl/mockingboard/via6522.v`
- Rule: this harness reports divergences; it never edits RTL.

## Run

From the project root or anywhere:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer\module_tests\via6522\run_equivalence.ps1
# recheck existing traces without rebuilding:
...\run_equivalence.ps1 -CompareOnly
```

Fixed tool paths (see `module_tests/README.md`): GHDL, Verilator, make, sh
from `C:\msys64\ucrt64`. Both simulations run with CWD = project root because
the TBs open their trace CSV at a project-root-relative path.

## Files

| File | Purpose |
|---|---|
| `gen_stim.ps1` | Deterministic stimulus, 794 cycles, emits one 36-bit-per-cycle table to both languages (`build/stim_table.vhd`, `build/stim_table.sv`) |
| `via6522_vhdl_tb.vhd` | Golden-side TB: `entity work.via6522`, event-driven driver, textio CSV |
| `via6522_verilog_tb.sv` | Candidate-side TB: module `via6522`, same CSV via `$fdisplay` |
| `via6522_shim.vhd` | GHDL-only helper package (`to_int_vec`) for the golden transform |
| `run_equivalence.ps1` | Transform, build, run both sims, compare, coverage gates |
| `build/` | Generated: golden copy, stim tables, traces, sim objects (ignored) |

## Cycle model

Each stimulus step emits two cycles: an F slot (even index) and an R slot (odd).
All bus accesses happen in F slots.

- Golden TB drives `falling=1` in F slots, `rising=1` in R slots.
- Candidate TB drives `ce=1` in F slots (its timer clock) and strobe/we in F slots.

Timer decrements therefore align edge-for-edge with the golden's falling-phase
decrements. Effective timing is identical on both sides: posedge every 70 ns,
inputs driven at the negedge, outputs sampled at posedge + 1 ns.

## Stimulus word layout (36 bits, top bit always 0)

```
bit 34     reset    bit 33 strobe   bit 32 we
bits 31..28 addr    bits 27..20 din
bit 19 ca1i  bit 18 ca2i  bit 17 cb1i  bit 16 cb2i
bits 15..8 pai       bits 7..0 pbi
```

Phases:

- P0 reset held 8 cycles, released
- P1 post-reset read sweep, all 16 addresses
- P2 program ORA/ORB/DDR/ACR/PCR/IER/TA latch/SR, read back all 16
  (IER write is 0x7F = clear-all mask bits, bit7=0)
- P3 CA1/CA2 handshakes: rising/falling edge select, port A latch, IFR reads
- P4 CB1/CB2 handshakes: falling detect, port B latch, IFR reads
- P5 Timer A: free-run load, one-shot loads, PB7 output toggle mode
- P6 Timer B: one-shot load + readback, count mode on PB6 edges
- P7 serial port, all 8 ACR[4:2] shift modes (CB1-clocked modes get CB1 pulses)
- P8 IFR clear matrix (all bits, single bit)
- P9 IRQ via Timer A one-shot: write TA LO latch=01 (addr 4), IER=0xFF
  (enable all), TA HI counter write loads count=1 -> overflow sets flag bit6;
  also writes addr F (ORA no-handshake). Gives >=5 rows with IRQ=1.

## Trace schema (19 columns, hex values)

```
CYCLE,RESET,STROBE,WE,ADDR,DIN,CA1I,CA2I,CB1I,CB2I,PAI,PBI,DOUT,PAO,PBO,CA2O,CB2O,CB1O,IRQ
```

One row per traced clock edge (794 rows). Metavalues (`U`/`X`) on either side
are skipped and counted as `ignored_metavalues`, never treated as matches.

## Golden-side normalization (no logic changed)

`via6522.vhd` uses Quartus-legal but strict-VHDL-illegal case/with-select
choices on `std_logic_vector`. The runner copies the golden to
`build/vhdl/via6522_golden.vhd` and applies exactly 27 counted replacements:

- 3x `case addr is` -> `case to_int_vec(addr) is` + 37x `when X"n" =>` -> integer
- 1x `case shift_clk_sel is` + its 2 choices
- 1x `case shift_mode_control is` + its 1 multi-choice
- 2x `with ca2/cb2_out_mode select` + 6 choice replacements

Each replacement asserts an exact expected count before applying, and one use
clause (`use work.via6522_shim.all;`) is inserted after the existing
`std_logic_unsigned` use clause. The shim's `to_int_vec` uses
`std_logic_arith.to_integer`-free manual conversion so it cannot introduce
`numeric_std` operator-overload ambiguity with the file's existing arithmetic.

## GHDL 6.0 pitfalls (this harness depends on all three)

1. **mcode re-execution bug**: an unsensitized process whose body *completes*
   after a `wait for` re-executes from the top of its body forever (variable
   state preserved). The driver therefore uses only event waits
   (`wait until falling_edge/rising_edge`) plus one `wait for 1 ns` inside the
   loop, and ends in a bare `wait;`. Do not "simplify" this to a single-process
   clock+`wait for` driver.
2. **No `std_env` with `-fsynopsys`**: this GHDL build's synopsys ieee library
   lacks `std.env`, so the sim cannot call `finish`. The concurrent free-running
   clock (`clk <= not clk after 35 ns`) keeps events pending forever.
3. **Mandatory `--stop-time=56000ns`** on `ghdl -r`: last sample lands at
   `106 + 70*793 = 55616 ns`. Without the stop time the simulation hangs after
   the driver suspends (and a killed run leaves a ghdl process that keeps
   writing the trace file — kill survivors and delete the CSV before reruns).

## Coverage gates

A PASS additionally requires:

- G1 all 16 addresses read (strobe & !we) at least once
- G2 all 16 addresses written (strobe & we) at least once
- G3 CA1I transitions >= 4 and CB1I transitions >= 4
- G4 rows with IRQ=1 >= 5
- G5 distinct DOUT values >= 20
- G6 ignored_metavalues <= 600
- G7 total strobe rows >= 80

## Current result

```
VIA6522 EQUIVALENCE PASS rows=794 fields=14292 ignored_metavalues=0 gate_checks=7
```

All 7 coverage gates pass. The candidate `rtl/mockingboard/via6522.v` was
aligned to the golden by explicit user instruction (see below). Reproducible
with `-CompareOnly` from the existing traces.

## Alignment of the candidate (this change)

The pre-alignment run reported 1634 divergences: CA2O 177, CB2O 479,
DOUT 415, PBO 414, CB1O 148, IRQ 1. Root cause: the candidate implemented a
different state machine than the golden (different reset/init values, mode
encodings, output registration, and serial/IRQ structure). The candidate was
rewritten as a faithful Verilog port of the golden's processes under the
harness clocking contract (`ce` = falling slot, `~ce` = rising slot; on the
Mockingboard `ce = PHASE_ZERO_F`, the same falling-phase pulse the golden
uses for `falling`). The golden VHDL was not touched; the module port list
is unchanged (six outputs changed from `reg` to combinational).

Main fixes, mapped to the diverging columns:

- **CA2O / CB2O**: golden handshake/pulse register pairs (reset to 1),
  output mode muxes on `pcr(2:1)` and `pcr(6:5)`, and CB2 serial override
  via full `serport_en = acr[4] | acr[3] | acr[2]`.
- **DOUT**: read mux registered and updated on every clock edge (candidate
  was combinational, one edge ahead); timer counts/latches reset to the
  golden `latch_reset_pattern` X"5550"; IER read returns bit7=0; ORA/ORB
  reads return the `ira` / `(prb&ddrb)|(irb&~ddrb)` latches, which track
  inputs one edge delayed (`port_a_c`/`port_b_c`) and re-latch on CA1/CB1
  events.
- **PBO**: PB7 = golden `timer_a_out` (toggle register, reset 1, flips on
  the rising edge when `reload & (freerun|oneshot)`, cleared by TA-HI
  writes); TA reload/oneshot structure ported verbatim.
- **CB1O**: golden `ser` block replaces the old divider-based shifter:
  `shift_clock`/`shift_clock_d`, tick detectors, active state machine,
  CB1 = `shift_clock_d`, serial-mode TB LO-reload ticks.
- **IRQ**: combinational `|(irq_flags & irq_mask)` as in the golden
  (candidate had a one-cycle registered delay).
- Edge detection uses the golden two-stage FFs (`caX_c`/`caX_d`);
  two-stage detectors were missing from the candidate.

## Pre-alignment result (reference)

```
VIA6522 EQUIVALENCE FAIL rows=794 fields=14292 ignored_metavalues=0 divergences=1634 first=cycle 0/CA2O
```

All 7 coverage gates passed on the stimulus. Divergence profile by column:

| Column | Count | Characterization |
|---|---|---|
| CA2O | 177 | golden=1 / candidate=0 from cycle 0: different reset state of the CA2 output (golden `ca2_pulse_o`/handshake init) |
| CB2O | 479 | same class: CB2 output reset/init mismatch from cycle 0 |
| DOUT | 415 | register readback differs: golden TA count reads 0x554A (decrementing from `latch_reset_pattern` X"5550"), candidate reads F8/FF/F4 (raw latch pattern); IFR/DOUT during write strobes also differ |
| PBO | 414 | PB7 (timer A output) inverted vs golden from ~cycle 363: golden `timer_a_toggle` resets to '1' and toggles on events; candidate's PB7 complement |
| CB1O | 148 | golden=1 / candidate=0 from cycle 521: CB1 pulse output timing differs after the P5/P6 timer phases |
| IRQ | 1 | one-cycle latency: at cycle 758 (IER write enabling a pre-set CB1 flag) golden asserts combinationally in the same slot, candidate one cycle later; both agree from 759 on |

Stimulus, input pins, and all non-divergent outputs (IRQ except above, PAO,
address/data handshake columns) matched.
