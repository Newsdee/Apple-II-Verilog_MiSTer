# MB_UPGRADE_PLAN — Mockingboard VIA upgrade: onboarding the fixed 6522

Status: **PLANNED** (2026-08-30). Phase 0 is license-independent and can start
anytime. Phases 1–4 are blocked on getting permission from the Appletini One
author (hasseily) — his repo is unlicensed outside separately-licensed files.

Source: item 2 of `alanswx/Apple-II_MiSTer` TODO.md (work plan benchmarked
against Appletini One). Related: item 3 (mixer overflow — must land before any
extra PSGs), item 8 (Phasor/Echo+ modes — explicitly "do after item 2").

## Where we are today

- FPGA project (`Apple-II_MiSTer_newsdee`) already runs the Verilog board:
  `rtl/mockingboard/{mockingboard.v, via6522.v, YM2149.sv}`; the old VHDL files
  are retired from the project (commit `08a2c2d`).
- Our `via6522.v` is **Skibo's original BSD-3 VIA**, rewritten as a faithful
  port of the old VHDL behavior (harness-aligned). It has none of Appletini's
  four fixes.
- Harnesses green:
  - via6522: `PASS rows=794 fields=14292 ignored_metavalues=0 gate_checks=7`
  - mockingboard: `PASS rows=488 fields=5856 gate_checks=10`

## What the upgrade is

Swap in Appletini's improved `via6522.v` (still Skibo-derived, BSD-3) carrying
four fixes, each tagged with the mb-audit test it satisfies:

| # | Fix | Audit test |
|---|-----|-----------|
| F1 | Timer snapshot at the slow clock so a late read returns the pre-decrement value | T6522_3/4 |
| F2 | IFR read does not expose timer underflow early | T6522_F/10/11 |
| F3 | T1 flag-clear semantics | T6522_15 |
| F4 | `power_reset` vs `reset` split so T1/T2 latches survive an Apple RESET | — |

Wiring spec (from the TODO, to be verified against the file):
`slow_clock` = 1 MHz tick, `strobe` = PHASE_ZERO edge, `ifr_*_ext` tied off,
`timer_read_extra_clock` = 0.

**Open decision (independent of the swap):** IRQ vs NMI routing. Our
`mockingboard.v:83-84` routes left MB→IRQ, right MB→NMI; Appletini routes
VIA1→IRQ. Decide which matches the boards we claim to emulate — this can be
settled in Phase 0 and applied as a separate one-line-class change.

## Method: harness as bounded-diff review, swap last

A plain swap is rejected as the validation strategy: the fixes are subtle
timing semantics with non-obvious wiring, and a wrong wire or dropped fix can
pass casual hardware testing and only break timer-counting software later.

The `via6522` harness has already served this exact role twice in this repo
(t65 alignment, via6522 pre-alignment FAIL profile). For this change its role
flips: **a PASS against the old golden is impossible by design** — the fixes
are intentional divergences. The pass criterion becomes: *every divergence maps
to F1–F4 and nothing else moves.*

## Phases

### Phase 0 — harness prep (now, no license needed)

Extend the via6522 stimulus so all four fixes are testable:

1. **P10 mid-run reset** (currently untestable): P0 holds reset for 8 cycles
   at power-on only. Add a phase that runs the timers, pulses `reset` (not
   power), and reads back. Old golden clears latches; fixed VIA keeps them —
   a known-explainable divergence that proves F4 works.
2. **Directed window for F1**: TA/TB counter read straddling the slow-clock
   decrement boundary (late read must return pre-decrement).
3. **Directed window for F2**: IFR read in the first cycle after overflow.
4. Update coverage gates; re-run against the *current* aligned pair — must
   still PASS unchanged (validates the stimulus extension itself).

Also: candidate-side TB port shim for the widened port list
(`power_reset`, `slow_clock`, `timer_read_extra_clock`, ...) driven per the
wiring spec, and settle the IRQ/NMI routing question.

### Phase 1 — obtain + functional gate (needs permission)

Take `via6522.v` **and** its testbench `tb_via6522_timing.sv`. Run his TB
under Verilator: this certifies F1–F4 functionally, independent of our golden.

### Phase 2 — bounded-diff review

Run the fixed VIA as candidate against the old VHDL golden. Expect a bounded
FAIL profile; document it per-column exactly like the existing pre-alignment
table in `module_tests/via6522/README.md`. Any divergence outside F1–F4
territory (CA2O reset state, serial port, handshakes) = porting/wiring bug,
stop and fix.

### Phase 3 — re-baseline the harnesses

Once every divergence is explained:

- Freeze Appletini's fixed `via6522.v` as the **new reference**; flip the
  via6522 harness to Verilog-vs-Verilog (both sides in Verilator, GHDL retired
  from this pair). Old VHDL stays as historical reference only.
- Update the mockingboard harness golden/candidate accordingly; both harnesses
  must PASS on the new baseline before touching the FPGA project.

### Phase 4 — swap + validate

- Replace `Apple-II_MiSTer_newsdee/rtl/mockingboard/via6522.v`; wire per spec
  in `mockingboard.v` (slow_clock, strobe edge, tie-offs).
- Quartus compile (user-run) + hardware: timer-based Mockingboard software,
  IRQ/NMI behavior on both slots.

## Fallback if permission is denied

Clean-room the four fixes into our existing Skibo-BSD `via6522.v` (the audit
test descriptions in the TODO are sufficient specification for F1–F3; F4 is a
port split). Then: write our own directed tests for F1–F4 (Phase 0 windows
already exist), run the same bounded-diff review against the old golden, and
skip Phase 1. The harness workflow is unchanged.

## Constraints / notes

- Do not touch `Apple-II_MiSTer_newsdee` while its Quartus compile is running
  (RTL edits OK; never `Apple-II.qsf`/`output_files/` mid-compile).
- Harness rule stands: report divergences, never edit RTL from a harness.
- Item 8 (Phasor/Echo+) depends on this plan AND on item 3's mixer fix — two
  more PSGs make the 10-bit overflow worse.
