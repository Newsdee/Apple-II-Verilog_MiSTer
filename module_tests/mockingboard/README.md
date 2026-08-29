# mockingboard equivalence harness

Board-level VHDL/Verilog differential test for the Mockingboard clone:
golden `Apple-II_MiSTer_newsdee/rtl/mockingboard/mockingboard.vhd` (+
`via6522.vhd`) vs candidate `Apple-II-Verilog_MiSTer/rtl/mockingboard/
mockingboard.v` (+ `via6522.v`). The board is tested as a whole — address
decoding, L/R VIA selection, IRQ/NMI routing, OE, PSG bus wiring, and audio
summing — not just the VIA sub-component (that is the `via6522` harness).

## Run

```powershell
Set-Location E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer
.\module_tests\mockingboard\run_equivalence.ps1
```

Recheck existing traces without rebuilding:

```powershell
.\module_tests\mockingboard\run_equivalence.ps1 -CompareOnly
```

## Files

- `gen_stim.ps1` — emits the identical 24-bit per-cycle stimulus table for both sides.
- `mockingboard_vhdl_tb.vhd` / `mockingboard_verilog_tb.sv` — the two testbenches.
- `ym2149_stub.vhd` / `ym2149_stub.v` — bit-identical deterministic PSG stubs (see below).
- `via6522_shim.vhd` — GHDL-only helper for normalizing the golden VIA (copy of the via6522 harness shim).
- `run_equivalence.ps1` — transforms, builds, runs, compares, gates.
- `build/` — generated: golden copies, stimulus tables, traces, simulators.

## PSG stubs

GHDL cannot compile the shared `YM2149.sv`, so both sides use a stub with the
exact port list of the real chip's component declaration. The stub is NOT an
AY-3-8910 model — it exists for determinism and parity:

- 32x8 register file, value 0 after reset/power-up.
- On posedge CLK: `RESET=1` clears everything; `CE & BC & BDIR` writes
  `mem[DI(5:0)] <= DI`; `CE & BC & ~BDIR` does a registered read
  `do_reg <= mem[DI(5:0)]`.
- `DO` is the registered readout (one-cycle latency).
- `CHANNEL_A/B/C` are pure combinational functions of `mem(0)/mem(1)/mem(2)`;
  no free-running state, so `O_AUDIO` changes only on writes.
- Board wiring: `CE = PHASE_ZERO_F & I_ENA_H`, `RESET = ~PB2`, `BDIR = PB1`,
  `BC = PB0`, `DI = port A out`, `DO -> port A in`.

Consequence for stimulus: a "write" of register value V stores V at index
`V(5:0)`, so only values with low 6 bits <= 31 are legal (all stimulus values
obey this). Channel values used: left A/B/C = 0x80/0xC1/0x82 (sum 451 = 0x1C3),
right A/B/C = 0x40/0x81/0x02 (sum 195 = 0x0C3).

## Phase schedule (dense alternating)

Even cycles: `PHASE_ZERO_R=1` (golden VIA falling slot — all bus accesses land
here); odd cycles: `PHASE_ZERO_F=1` (golden VIA rising slot, PSG CE with ENA).
This extends the `via6522` module harness contract to board level: even cycle
= golden `falling` = candidate `ce` **if the board glue is correct**.

Note on real-hardware scheduling: on the core, PHASE_ZERO_R/F are single-cycle
pulses once per PHI0 period (see `timing_generator.vhd`:
`PHI0_EN_R <= not PHI0 and PHI0_PRE`). The candidate VIA derives its rising
phase as `~ce`, which is only equivalent under dense alternation; under the
real sparse schedule `~ce` would be high ~13 of 14 cycles and the golden's
rising-gated toggle/shift logic (timer A toggle, serial shift clock) could
multi-fire. On this board the timer A output (PB7) is unconnected, so only the
serial engine would be observably affected. The dense contract is the v1
equivalence claim; sparse-schedule certification would require giving
`via6522.v` an explicit rising input (port change — user decision).

## Stimulus word layout (24 bits)

```
bit 23     rst      (1 = reset asserted; TB drives I_RESET_L = ~rst)
bit 22     iosel    (I_IOSEL_L level; 0 = board selected)
bit 21     ena      (I_ENA_H level)
bit 20     rw       (I_RW_L level; 1 = read, 0 = write)
bits 19..12 addr    (I_ADDR)
bits 11..4 din      (I_DATA)
bits 3..0  spare    (always 0)
```

Phase is derived from cycle parity in each TB, not stored. Every step emits an
even + odd cycle. PSG transactions hold ENA high on the odd cycle (stub CE)
with a no-op DDRB read (no VIA read action exists for addr 2).

Phases: P0 reset; P1 post-reset read sweeps both Vias (exposes port_b_i width
via ORB read with DDRB=0); P2 program + read back all 16 registers on both
Vias; P3/P4 PSG channel setup and readbacks (L/R); P5 left IRQ via Timer A
one-shot; P6 right NMI likewise; P7 ENA gating window (IRQ pending while
I_ENA_H=0); P8 IOSEL gating (deselected write must not land); P9 serial engine
(ACR=0x12, TB-tick clocked output shift); P10 final read sweeps.

## Trace schema (13 columns)

`CYCLE,RESET,IOSL,ENA,RW,ADDR,DIN,ODATA,OE,IRQ,NMI,AUDL,AUDR` — hex values;
RESET/IOSL/ENA/RW/OE/IRQ/NMI are single-bit port levels (IRQ/NMI active low);
AUDL/AUDR are the 10-bit O_AUDIO_L/R sums. One row per traced clock edge.

## Golden-side normalization (no logic changed)

- `mockingboard_golden.vhd`: the `component YM2149 ... end component;` block is
  stripped so `psg_left`/`psg_right` bind to entity `work.YM2149` (the stub).
- `via6522_golden.vhd`: identical transform to the via6522 harness (case/with
  choices on std_logic_vector normalized via `to_int_vec`, one use clause
  added).

## Coverage gates

- G1: both Vias accessed, >=4 write and >=4 read rows each (selected + enabled).
- G2/G3: all 16 low addresses read AND written on each side.
- G4: OE observed in both states (>=8 rows each).
- G5: O_IRQ_L asserted (>=3 low rows) then deasserted (>=3 high rows after).
- G6: O_NMI_L asserted then deasserted (same shape).
- G7: ENA gating window — IRQ low, then >=8 consecutive ENA=0 rows with both
  IRQ and NMI forced high, then IRQ low again.
- G8: max AUDL = 0x1C3 and max AUDR = 0x0C3 (stub channels + summing verified
  against expected values), >=2 distinct values each.
- G9: ignored_metavalues < 600 (pre-reset noise only).
- G10: >=100 selected+enabled access rows total.

## Current result

**PASS (2026-08-30):**
`MOCKINGBOARD EQUIVALENCE PASS rows=488 fields=5856 ignored_metavalues=0 gate_checks=10`

All 12 trace columns agree on every cycle; all 10 coverage gates pass.
The only pipeline warning is the pre-existing `cb2_c` shadow in the golden
VIA (same as the via6522 harness). `-CompareOnly` re-checks existing traces.

## Alignment (per user decision)

Pre-alignment first run (2026-08-30): **FAIL — expected.**
`rows=482 fields=5784 divergences=892 first=cycle 1/ODATA`; per column:
ODATA=380, AUDL=269, AUDR=233, IRQ=7, NMI=3. Three board-glue divergences in
the candidate `mockingboard.v`, all confirmed in the trace:

1. `.ce(VIA_CE_R)` = PHASE_ZERO_F: the candidate VIA's falling slot was the
   golden's RISING slot (golden wires `falling => VIA_CE_F` = PHASE_ZERO_R).
2. `.strobe` unconnected: `wr_strobe = strobe && we` always 0, so all VIA
   writes and read actions were dead (Verilator also linted
   `%Warning-PINMISSING ... 'strobe'`); AUDL/AUDR stuck at 0x000 because the
   PSG reset was never released.
3. `.portb_in(1'b1)` / `(10'b1)`: candidate saw 8'h01 where the golden ties
   `port_b_i` to 8'hFF — first divergence of the trace (cycle 1, ODATA FF vs
   01 on an idle ORB read).

Candidate-side fix applied to `rtl/mockingboard/mockingboard.v` (6 lines,
CRLF preserved):

- `.ce(VIA_CE_F)` on both VIAs (correct falling slot = PHASE_ZERO_R).
- `.strobe((~I_IOSEL_L) & I_ENA_H & ~I_ADDR[7])` (left) / `& I_ADDR[7]`
  (right): this reproduces the golden's `wen|ren` exactly, because the
  candidate derives `wr_strobe = strobe && we` ≡ golden `wen` and
  `rd_strobe = strobe && !we` ≡ golden `ren`. A plain `.strobe(1'b1)` would
  NOT be equivalent — `rd_strobe` would fire on every deselected cycle.
- `.portb_in(8'hFF)` on both VIAs.

Also updated the now-stale clocking-contract comment in
`rtl/mockingboard/via6522.v` (comment only; no logic change).

Harness fixes made during bring-up (before alignment):

- Golden board build copy: Quartus-legal shorthand instantiations normalized
  to VHDL-2008 direct-entity form (`entity work.via6522`,
  `entity work.YM2149`) — GHDL treats bare/qualified names in instantiation
  statements as component references.
- Stimulus: PSG write/read helpers were hardcoded to the left VIA; the right
  PSG phase now uses side-specific addresses, and each PSG phase ends with an
  ORB release (BC=0) because PSG_EN is board-wide.
- G7 relaxed from exactly-8 to >=8 forced-high rows between two IRQ-low
  selected rows (step parity always inserts a trailing ENA=0 odd cycle), and
  the P7 pre-window IFR reads were extended so the TA flag (visible from
  load+8) is guaranteed pending before the ENA=0 window.

Known coverage limitation: the stub's registered readout (DO) is exercised
but not directly observed in any trace column (ORA readback returns the index
that was written; DO reaches only port_a_i, whose bit-1 never transitions in
this stimulus so no CA2/IFR flag results). The write path and audio summing
are fully observed via AUDL/AUDR.
