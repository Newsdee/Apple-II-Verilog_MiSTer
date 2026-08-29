# Module Port Validation Methodology

## Abstract

This directory contains differential tests used while replacing VHDL modules
with Verilog implementations. The original VHDL is executed as the reference
model and the candidate Verilog is given the same inputs. Their externally
visible results are recorded and compared at defined clock boundaries.

A passing test is the first acceptance gate for a port. It establishes
behavioral equivalence for the documented stimulus, observation windows,
known-valued outputs, and coverage requirements. It does not by itself prove
that every possible input was tested, that the interfaces bind correctly in
Quartus, that the synthesized circuits are formally equivalent, or that the
design meets FPGA timing.

## Plain-language explanation

The method is similar to testing a replacement part beside the original part:

1. Give both parts the same sequence of commands.
2. Observe their answers after the same clock events.
3. Stop at the first answer that differs.
4. Also verify that the commands exercised the important features. Matching
   answers are not useful if the test never turned a feature on.

The VHDL implementation is the executable reference, not an abstract
specification. GHDL runs that reference. Verilator runs the Verilog candidate.
Each simulator writes a trace containing cycle numbers and signal values. The
PowerShell runner compares the traces and applies module-specific coverage
checks.

This answers a limited but useful question:

> Under the tested conditions and at every observed point, did the candidate
> produce the same externally visible behavior as the reference?

It does not answer whether untested conditions match. Passing this gate permits
the port to move to interface, synthesis, timing, and formal review; it does
not replace those later gates.

## Acceptance model

Port validation is divided into four gates. A failure at an earlier gate blocks
promotion to the next one.

| Gate | Question | Evidence |
|---|---|---|
| 1. Differential behavior | Does the candidate match the reference for the defined experiment? | Matching traces, coverage gates, ROM parity, and controlled metavalue handling |
| 2. Interface compliance | Are names, directions, widths, signedness, parameters, clocks, and resets compatible? | Strict lint, interface manifest review, and no relevant connection or width warnings |
| 3. Synthesis integration | Does the replacement bind and synthesize in the real project? | Quartus Analysis & Synthesis, source registration, ROM discovery, and warning review |
| 4. Complete or formal equivalence | Does equivalence hold beyond the directed experiment? | Formal proof where practical, or expanded boundary, phase, reset, and reproducible randomized tests |

The tests in this directory implement Gate 1. They may contribute evidence to
the other gates, but they do not complete them.

## Research question and claim

For each module, the experiment compares one VHDL reference implementation and
one Verilog candidate implementation as black boxes. Internal representation
may differ. The comparison is made only through the declared module boundary,
except where a module README explicitly documents additional instrumentation.

The permitted conclusion is:

> The candidate is behaviorally equivalent to the executable reference for
> the defined stimulus, sampled cycles, known-valued outputs, and coverage
> requirements.

Do not describe a pass as exhaustive, complete port compliance, or formal
equivalence.

## Experimental method

### 1. Establish the module contract

Before writing stimulus, record:

- every port name, direction, width, and signedness;
- all parameters or VHDL generics;
- each clock and its relationship to other clocks;
- reset polarity, synchronous or asynchronous behavior, and reset values;
- combinational versus registered outputs;
- memory and ROM dependencies;
- legal input combinations and externally visible side effects.

The testbench must connect every port explicitly by name. An output that is not
observed and an input that never changes must be justified in the module README.

### 2. Select and preserve the reference

Use the original VHDL module from `../Apple-II_MiSTer_newsdee/rtl/` as the
reference. Do not edit reference or candidate RTL to make a test pass. If GHDL
requires a generated compatibility copy, create it under `build/` or use an
audited shared shim.

Classify every compatibility change as one of:

- syntax-only normalization;
- initialization modeling;
- simulation primitive replacement;
- semantic or structural transformation.

The first three require an exact, mechanically bounded transformation and an
explanation. A semantic or structural transformation limits the validity of
the golden model and must state the excluded cases. Preserve occurrence-count,
length, line-by-line, ROM-byte, or equivalent checks that prove no unintended
text was changed.

### 3. Generate identical stimulus

Both implementations must receive the same deterministic input sequence. For
new tests, prefer one generated stimulus table consumed by both testbenches.
If stimulus is implemented separately in VHDL and SystemVerilog, trace the
inputs as well as the outputs so the runner proves that both schedules agree.

Stimulus must cover, where applicable:

- reset assertion, release, and a reset after normal operation;
- idle and active operation;
- every command, mode, select, and enable;
- minimum, maximum, wraparound, and invalid or ignored values;
- one-cycle pulses and held inputs;
- simultaneous or competing operations;
- memory read, write, collision, and read-during-write behavior;
- delayed events long enough to expose terminal count and off-by-one errors;
- each supported parameter, video standard, or other configuration.

Do not use wall-clock state or unrecorded randomness. Randomized tests must use
an explicit seed and retain the failing seed.

### 4. Reproduce clock and reset semantics

Drive stimulus on the same clock phase in both testbenches and sample after the
same state-update boundary. Account for VHDL delta cycles and SystemVerilog
scheduling explicitly. For multiple clocks, reproduce the intended frequency
and phase relationship. Sweep relevant phase offsets and coincident-edge cases
when the interface is asynchronous or edge ordering can affect behavior.

Reset handling must match the source exactly. Do not add a reset to make an
uninitialized reference easier to simulate without documenting that the model
no longer represents native power-up behavior.

### 5. Record the observable behavior

The standard CSV schema is:

```text
CYCLE,<input columns>,<output columns>
```

Use hexadecimal values and one row per observed clock event. Both traces must
have the same header, column order, cycle values, and sampling schedule. Dense
tracing is preferred. Sparse tracing is allowed for long idle intervals only
when the omitted interval, surrounding windows, and reason are documented.

All externally visible outputs must be compared. Internal signals may support
diagnosis or coverage, but a test must not depend on candidate internals to
define correctness.

### 6. Compare traces

The runner must:

1. Fail if either simulation or build command returns a nonzero status.
2. Fail if either trace is absent or incomplete.
3. Validate the exact CSV schema before comparing values.
4. Require equal row counts and matching cycle identifiers.
5. Compare each required field and stop at the first divergence.
6. Report cycle, signal, reference value, and candidate value.
7. Reject duplicate, missing, or non-monotonic cycle identifiers.
8. Count the number of fields actually compared.

`-CompareOnly` may compare existing traces, but those traces are authoritative
only if their source, stimulus, schema, and tool provenance still match the
current test.

### 7. Handle VHDL metavalues explicitly

Verilator is primarily a two-state simulator, while VHDL can expose `U`, `X`,
`W`, `Z`, and don't-care values. A VHDL metavalue must never be counted as a
successful equality comparison. Current runners skip and count fields that
contain metavalues.

Each module must document where metavalues are expected. New tests should
compare known bits through an explicit known-bit mask rather than discarding an
entire partially known field. Set per-column and post-reset limits so an
increase in unknown state causes a failure. A minimum compared-field threshold
prevents a trace dominated by skipped values from passing.

### 8. Enforce behavioral coverage

Trace equality alone is insufficient because two idle implementations can
match perfectly. Each runner must apply coverage gates derived from the module
contract. Gates should prove exact milestones or sequences rather than merely
showing that a signal was high once.

Examples include:

- every register or soft switch read and write;
- exact pulse width and cycle;
- address progression and wraparound;
- both selected devices and all operating modes;
- write protection and busy/ready handling;
- reset state and state retained across reset;
- complete delayed transitions such as motor spin-down;
- NTSC, PAL, and other supported configurations.

List every gate in the module README. The final result must report the number
of rows, compared fields, ignored metavalues, and module-specific gate checks.

### 9. Verify memories and ROMs

Reference and candidate ROM contents must be compared independently before
behavioral comparison. A shared filename is not proof of shared content. Check
byte count, ordering, and every byte. Run each simulator from the directory
required by its relative ROM paths.

Memory tests must state initialization, output-register, byte-enable, collision,
and read-during-write semantics. Simulator primitive substitutions are part of
the test model and require their own sanity check.

### 10. Interpret the result

A runner ends with either a terminating error naming the first divergence or:

```text
<NAME> EQUIVALENCE PASS rows=<n> fields=<n> ignored_metavalues=<n> <gate summaries>
```

A pass is valid only for the sources, tools, stimulus, and assumptions used by
that run. Record expected exclusions in the module README. Unexpected
divergence is a finding: stop and report it before changing either RTL model.

## Expert and agent review checklist

Before accepting a Gate 1 result, independently review the following:

- The reference file is the intended source of truth and has not drifted.
- Generated golden copies differ only by documented transformations.
- The candidate source loaded by the runner is the source intended for Quartus.
- Every interface port is connected; all outputs are observed or justified.
- Width, pin, range, undriven, multidriver, latch, and truncation warnings are
  absent or individually explained. `-Wno-fatal` is not evidence that a warning
  is harmless.
- Clock edge, phase, enable, and reset behavior match the source.
- Persistent sequential state uses equivalent assignment timing.
- Arithmetic widths and signedness are equivalent.
- Inferred RAM and ROM behavior is equivalent, including collisions.
- Stimulus reaches every claimed behavior and boundary.
- Sparse trace gaps cannot hide an externally visible transition under test.
- Metavalue skips occur only in approved fields and windows.
- Coverage gates test expected values and timing, not only activity.
- The failure message identifies the first useful divergence.
- The module README states what remains untested.

After Gate 1, run strict interface lint and Quartus Analysis & Synthesis. Review
new warnings separately from existing warnings. Verilator cannot prove
mixed-language binding, FPGA memory packing, clock-domain safety, timing, or
hardware signal quality.

## Repository implementation

Use `disk_ii/` as the basic directory pattern, while applying the stronger
requirements in this document to new tests.

```text
module_tests/<name>/
  README.md                 scope, assumptions, coverage, exclusions, results
  <name>_vhdl_tb.vhd        GHDL testbench -> build/vhdl_trace.csv
  <name>_verilog_tb.sv      Verilator testbench -> build/verilog_trace.csv
  run_equivalence.ps1       build, run, compare, and enforce coverage
  gen_stim.ps1              optional canonical stimulus generator
  build/                    generated artifacts; never edit or commit
```

### Tools

- GHDL: `C:\msys64\ucrt64\bin\ghdl.exe` (`-a/-e/-r --std=08`)
- Verilator: `C:\msys64\ucrt64\bin\verilator_bin.exe`
- Make: `C:\msys64\ucrt64\bin\mingw32-make.exe`
- Shell: `C:\msys64\usr\bin\sh.exe`
- Verilator root: `C:/msys64/ucrt64/share/verilator`

Use `<build>/vhdl` as the GHDL work directory. Run simulations from the
repository root when ROM paths are relative to that root.

Typical execution:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
Set-Location E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer
.\module_tests\<name>\run_equivalence.ps1
```

Compare existing traces without rebuilding:

```powershell
.\module_tests\<name>\run_equivalence.ps1 -CompareOnly
```

### Agent-independent suite runner

The test suite is ordinary source-controlled tooling and does not require an
agent or language model. `test_manifest.json` is the machine-readable list of
runnable tests and their capabilities. `run_tests.ps1` selects tests, invokes
each existing module runner in a separate PowerShell process, prints a summary,
and returns a nonzero exit code if any selected test fails. `run_tests.bat` is
the Command Prompt and Explorer-friendly entry point.

List registered tests without compiling or simulating:

```bat
module_tests\run_tests.bat -List
```

Run every registered test from any working directory:

```bat
E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer\module_tests\run_tests.bat
```

Run selected tests:

```bat
module_tests\run_tests.bat -Tests disk_ii,hdd,keyboard
```

Recheck existing traces without rebuilding where supported:

```bat
module_tests\run_tests.bat -Tests disk_ii,hdd -CompareOnly
```

Use `-ContinueOnFailure` to run the remaining selected tests after a failure.
Without it, the suite stops at the first failure. A test whose runner does not
support `-CompareOnly` is reported as `SKIP` in that mode. Add a new runnable
test by creating its module runner and registering it in `test_manifest.json`.

The suite runner deliberately does not reinterpret a module result. Each
module's checked-in runner remains authoritative for stimulus, trace comparison,
metavalue policy, and coverage gates. This keeps verification deterministic and
re-runnable while those checks are gradually moved into shared tooling.

### GHDL 6.0.0 ROM workaround

GHDL 6.0.0 does not honor the `ram_init_file` attribute in `rtl/spram.vhd` in
this environment. It also has a verified code-generation defect in which
signal assignments can be dropped when a case-based function call occurs in
the same loop. See `shared/spram_sim.vhd` and the reproductions under
`shared/build/`.

Golden harnesses that require `work.spram` (`video_generator`, `keyboard`, and
`apple2`) must analyze `shared/spram_const.vhd`. This constant-array shim has
the same generics and ports, remains writable, and selects the required ROM by
the `init_file` generic. Regenerate it with `shared/gen_spram_const.ps1` after
ROM changes. Its independent sanity result is `SPRAM CONST SHIM PASS`. Do not
use `shared/spram_sim.vhd` while the documented GHDL defect remains.

## Current module roster

| Module | Reference | Candidate | Status |
|---|---|---|---|
| disk_ii | disk_ii.vhd + drive_ii.vhd + disk_ii_rom.vhd | disk_ii.v + drive_ii.v + rom.v | PASS baseline |
| dpram | dpram.vhd | dpram.v | PASS 2026-08-28; rows=32864, fields=197172 |
| virtual_keyboard_overlay | Verilog-internal prior version | virtual_keyboard_overlay.sv | PASS 2026-08-28; frames=10, checks=1076946 |
| video_generator | video_generator.vhd + spram_const shim | video_generator.v + video2.hex | PASS 2026-08-29; ports-only trace, ROM parity checked |
| hdd | hdd.vhd + hdd ROM | hdd.v + rom.v + hdd.hex | PASS 2026-08-29; rows=6416, fields=102387, gate_checks=63 |
| timing_generator | timing_generator.vhd | timing_generator.v | PASS 2026-08-29; NTSC and PAL, 26937 rows each |
| keyboard | keyboard.vhd + spram_const shim | keyboard.v + keyboard.hex | PASS 2026-08-28; re-verified 2026-08-29 (rows=316, fields=2528) |
| via6522 | mockingboard/via6522.vhd | mockingboard/via6522.v | PASS 2026-08-29; rows=794, fields=14292, gate_checks=7; candidate aligned to golden per user decision (pre-alignment FAIL profile and fix list in module_tests/via6522/README.md) |
| mockingboard | mockingboard + via6522 + stub PSG | mockingboard + via6522 + stub PSG | PASS 2026-08-30; rows=488, fields=5856, gate_checks=10; candidate aligned per user decision (6-line glue fix: .ce(VIA_CE_F), side-select .strobe ≡ golden wen|ren, .portb_in 8'hFF; pre-alignment FAIL profile and harness bring-up fixes in module_tests/mockingboard/README.md). Real YM2149.sv differs only in volTable init syntax (64/64 values verified identical 2026-08-29); test glue uses a bit-identical stub PSG on both sides |
| t65 | t65/T65*.vhd | t65*.v | In progress; isolates CPU behavior for apple2 |
| apple2 | apple2.vhd and VHDL dependencies | apple2.v and Verilog dependencies | In progress; integration-level harness |
| apple2_font_rom | apple2_font_rom.vhd + spram_const shim | apple2_font_rom.v + video2.hex | PASS 2026-08-29; rows=4228, fields=38052, writes=37 (36 divergent probes aligned write-first, 1 equal), 64/64 readbacks; candidate aligned per user decision (one-line glyph_data fix; pre-alignment FAIL profile in module_tests/apple2_font_rom/README.md) |
| vga_controller | vga_controller.vhd | vga_controller.v | DIVERGENCE (expected palette-download signature) 2026-08-29; rows=163248, fields=3226938, ignored_metavalues=38022, mismatched_fields=57261 all in VGA_R/G/B on lines 114-130+171-179 only; all timing/control paths (HS/VS/HBL/VBL/IOCTL_WAIT) cycle-equivalent; two real RTL differences (beat-4 new-vs-old latch, 3-beat vs 4-beat color_addr wrap -> candidate LUT scrambled + colors 0-4 second-pass overwrite); power-up artifacts classified (line-0 VGA_HBL U-vs-0 hcount init, cycle-17 U island); full profile in module_tests/vga_controller/README.md; candidate fix pending user decision |

Verilog-to-Verilog synchronized files such as `ramcard.v`, `clock_card.v`, and
`floppy_track.sv` may be certified by a byte comparison when the requirement is
exact source parity. Record the compared paths and hashes; use behavioral tests
when the implementations are allowed to differ.

## Threats to validity

- Directed stimulus cannot establish behavior for untested inputs or states.
- Sparse observation can miss transient differences in omitted intervals.
- VHDL metavalue skipping weakens comparison against a two-state candidate.
- Hand-maintained duplicate stimulus can drift between testbenches.
- A compatibility shim can differ from native VHDL simulation or FPGA power-up.
- A simulator pass does not establish synthesis equivalence or timing closure.
- Coverage gates can prove that an event occurred without proving every legal
  event sequence unless their expected values and timing are explicit.
- A live reference file can drift; a historical pass is not evidence for new
  source unless provenance is recorded.

These limitations do not invalidate Gate 1. They define the boundary of its
claim and determine what the later gates must address.

## Further work

Prioritize improvements in this order:

1. Add a strict interface stage that compares port manifests and rejects
   Verilator width, missing-pin, range, undriven, and multidriver warnings.
2. Create a shared trace-comparison library for schema validation, monotonic
   cycles, duplicate detection, known-bit masks, coverage summaries, and
   consistent failure messages.
3. Write a provenance manifest beside each trace containing source hashes,
   stimulus hash, schema version, tool versions, command line, and timestamp.
   Require matching provenance for `-CompareOnly` unless explicitly overridden.
4. Move manually duplicated schedules to canonical generated stimulus tables.
5. Add per-column and post-reset metavalue budgets; compare known bits in
   partially unknown fields.
6. Add reusable reset, boundary, parameter, and multi-clock phase matrices.
7. Add reproducible constrained-random tests after directed coverage is stable.
8. Add negative self-tests that deliberately introduce a trace mismatch,
   malformed CSV, missing cycle, width mismatch, and unexpected metavalue to
   prove that the harness fails for the intended reasons.
9. Add a project-level Gate 3 procedure covering `files.qip`, `Apple-II.qsf`,
   Quartus Analysis & Synthesis, warnings, ROM initialization, and component
   binding.
10. Evaluate formal equivalence per module. Start with small synchronous blocks
    and explicit assumptions; retain differential tests as readable regression
    tests even when a formal proof is available.
