# 65C02 comparison recommendations

Purpose: instructions for the next agent continuing the comparison between
`rtl/new_cpu/cpu_65c02.sv`, `rtl/R65Cx2.sv`, T65, and the available
SingleStepTests references.

Read these first:

- `cpu_cycle_analysis.md`
- `sst_progress.md`
- `wdc_vs_6502_analysis.md`
- `../r65c02/README.md`

Do not describe the CPU cores as generally functionally equivalent based on
the existing r65 trace. The supported conclusion is narrower:

> On the covered directed r65 stimulus, the new core and R65Cx2 execute the
> same instruction-fetch sequence and reach the same architectural and final
> RAM state, with documented bus-visible cycle differences.

Extra reads and writes are observable by memory-mapped devices even when final
RAM is identical. Treat them as behavioral differences, not sampling noise.

## Priority 1: make the semantic comparison reproducible

Replace the collection of build-directory analysis helpers with one maintained
checker under `module_tests/cpu_65c02/`. It must:

1. Select real opcode fetches with `SYNC=1 && SYNC_IRQ=0`.
2. Assert equal fetch counts and equal `(ADDR, DI)` for every paired fetch.
3. Compare instruction lengths between consecutive paired fetches.
4. Compare A, X, Y, SP, PC, and N/V/D/I/Z/C at stable instruction boundaries,
   with the known one-row observation skew handled explicitly.
5. Compare ordered write events `(address, data)`, including multiplicity.
6. Optionally compare ordered read events where reads may trigger I/O effects.
7. Allow only named, reviewed bus differences through an explicit whitelist.
8. Fail on a new opcode, state, write, or non-whitelisted bus divergence.
9. Emit a machine-readable summary containing input paths, row counts, hashes,
   fetch counts, compared instruction counts, and allowed differences used.

Final-memory reconstruction remains useful as an additional check, but must be
called `final write-map equality`; it is not transaction equality.

## Priority 2: correct the current report

Update `cpu_cycle_analysis.md` when the semantic checker is in place:

- Narrow the headline verdict to the exact r65 stimulus.
- Replace "all memory writes" or "memory transactions" with the precise check
  actually performed.
- Separate architectural equality from bus-protocol equality.
- Mark BRK behavior as source-level reasoning until BRK is tested.
- State that RTI and interrupt return are not covered.
- Correct the IRQ vector from `$FFFC/$FFFD` to `$FFFE/$FFFF`.
- Explain that 1504 fetches include repeated execution of the final park loop;
  they do not represent 1504 distinct instruction cases.
- Keep the accepted W65C02S-versus-R65Cx2 differences in a named table that can
  be shared with the checker whitelist.

## Priority 3: close directed coverage gaps

Add focused cases for:

- BRK status/return-address pushes and vector entry.
- RTI restoration using the intended core contract, including the documented
  non-standard R65Cx2 semantics where comparison to that golden is required.
- IRQ while masked, IRQ unmask timing, NMI edge behavior, and IRQ/NMI priority.
- Interrupt return, nested requests, and requests adjacent to instructions
  whose cycle counts differ.
- Mid-stream reset and reset asserted at different instruction phases.
- `JMP (abs,X)` with nonzero X, page carry, and boundary addresses.
- Read-modify-write targets modeled as side-effecting I/O, so an extra write
  cannot be hidden by final-memory equality.

Each case needs a coverage gate proving that the intended path executed.

## Priority 4: finish the independent comparisons

The T65 phase-A and phase-B traces currently have substantial unaligned
differences. Complete instruction/event alignment before using T65 as evidence
for either core. First prove or retain the T65 VHDL-to-Verilog baseline so a
language-port defect is not attributed to CPU semantics.

For SingleStepTests:

- Describe the current 12,700-test run as an all-opcode, 50-samples-per-opcode
  sweep, not exhaustive suite coverage.
- Finish the `$DE` dummy-read decision and the outstanding agreed-reference
  failure signatures described in `sst_progress.md`.
- Keep WDC-specific, MOS-specific, suite-generator, and core defects as separate
  categories. Do not change RTL merely to match a known suite convention.
- Record suite revision, sample seed, sampled test identifiers, RTL hashes, and
  checker version with each retained result.

## Decision policy

Preserve the new core's documented W65C02S behavior unless the project decides
that exact R65Cx2 bus compatibility is required. Make that policy explicit
before changing cycle timing.

The comparison is ready to support a CPU replacement decision only when:

- the reproducible semantic checker passes with no unexplained differences;
- every accepted bus difference is documented and reviewed for Apple II
  memory-mapped-I/O impact;
- BRK, RTI, reset, and interrupt-return coverage is present;
- T65 differences and outstanding SST categories are classified; and
- full-machine Verilator and FPGA integration validation are tracked separately
  from module-level CPU equivalence.

Do not claim FPGA timing or hardware equivalence from these simulation tests.