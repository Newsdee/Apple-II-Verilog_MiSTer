# PLAN — `unit_tests`: config ladder for bug bisection (isolated CPU → machine)

Scope: **this Verilog repository** (`Apple-II-Verilog_MiSTer`), new
`unit_tests/` directory only. The machine build (`verilator/`), the
differential harnesses (`module_tests/`), and the Quartus project
(`Apple-II_MiSTer_newsdee`) are out of scope unless asked.

Companion file: `PROGRESS.md` (rolling state of the ladder, updated at each
major step). The repo-root `PLAN.md`/`PROGRESS.md` cover the earlier
2026-09-02 CPU-replacement task — different work.

Status at writing (2026-09-05): level_neg1 and level_0 are **green on both
CPUs**; level_1 (video + keyboard, monochrome) is **built and running** —
the first-run anomalies are diagnosed as harness artifacts (unframe-aligned
captures, analytic V expectations, mis-armed PC traces), fix list in
`PROGRESS.md` §1h. This plan captures the agreed design so the rest can
proceed without re-deriving it.

---

## 1. Purpose

The full-machine smoke test answers "does the machine work?" at a coarse
level. When a change breaks something, it does not say **where** — CPU,
memory phasing, video, a slot card, the harness itself.

The fix is a **ladder of independently buildable/runnable configs**
("levels") of increasing complexity:

- A bug that reproduces at level N but not at level N−1 localizes to the
  slice added at level N (config bisection).
- Each level is a complete, runnable Verilator setup with its own top
  module, Makefile, and pass/fail exit code — not a fragment of the machine
  build. It is suitable for interactive debugging (gdb on the C++,
  waveforms with `--trace` if needed).
- The new CPU cores' **savestate register bus** provides the
  "inject a known-good state, run, compare" primitive — the strongest
  correctness test available, and the same primitive the machine-wide
  savestate work (repo-root `PLAN.md` §6) will build on.

The existing full-machine build (`verilator/`) remains the **top of the
ladder** (the "machine" endpoint). Nothing replaces the smoke test; the
ladder extends *below* it.

## 2. Grounding facts (verified 2026-09-04 — the plan rests on these)

1. **Core interface is minimal.** Both cores (`nmos6502`, `wdc65c02`)
   consume only `clk` + `ce` for operation — not the DRAM RAS/CAS/AX
   signals. A bare-CPU harness with a faithful 2-phase `ce` is safe.
2. **1-`ce`-cycle delayed read.** The core presents `addr` in cycle N and
   samples `din` in cycle N+1 — exactly `apple2.v`'s `CPU_DL` latch.
   Writes commit when `we` is high. Any harness memory that models same-
   cycle reads produces false negatives and must not be used.
3. **Savestate semantics** (both cores, parameter `SS_BASE`):
   - *Write (inject):* hold `stall=1`; on `ss_wren` with
     `ss_addr=SS_BASE` → {PC, A, X, Y, S, flags, IR}; `SS_BASE+1` →
     {micro-sequencer state/addr, NMI/IRQ latches}; `SS_BASE+2` →
     {SO/IRQ/φ2 latches}. Core comment: "core held in stall while these
     apply." Restore can re-enter mid-instruction.
   - *Read (verify):* `ss_rdata` is a **combinational** readout of
     PC/A/X/Y/S/flags — peekable any cycle, no timing gymnastics.
4. **Port delta:** `nmos6502` adds `so_n, be, ml_n, phi1o, phi2o, bus_oe,
   dout_oe` (all unused on Apple II — tie off); `wdc65c02` matches the old
   top-level `cpu_65c02.sv` port list byte-for-byte.
5. **Build environment** (MSYS2 ucrt64, Verilator 5.050):
   - `--cc --timing -exe` only *generates* C++ + a `.mk`; the compile/link
     is a second `make -C obj_dir -f V<top>.mk`.
   - `--timing` std-file lookup is broken by this MSYS2 build's prefix
     misdetection (`/ucrt64` vs `/c/msys64/ucrt64`); fix =
     `VERILATOR_ROOT=/c/msys64/ucrt64/share/verilator`.
   - `TMP/TEMP/TMPDIR` must be set **inside** the MSYS2 bash (parent-shell
     exports do not propagate), or g++ falls back to `C:\WINDOWS\`.
   These workarounds stay baked into each level's Makefile.

## 3. Levels

### 3.1 Level −1 (`level_neg1`) — isolated CPU *(in progress)*

**DUT:** one CPU core, selected by build variable:
`make CPU=nmos` → `nmos6502`, `make CPU=wdc` → `wdc65c02`
(`+define+CPU_WDC` switches the TB's core module name).

**Context:** nothing from `apple2.v`.
- Behavioral 64K byte memory implementing the 1-`ce`-cycle read delay and
  `we`-gated writes (§2.2).
- 2-phase `ce` clocking (CLK_14M-style clock, one `ce` per bus cycle).
- Tie-offs mirror the proven Apple II wiring from `apple2.v`: `stall=0`
  (harness drives it high only around savestate operations), `rdy=1` (no
  WAIT in this level), `stp_nop=1`, active-high synchronous `reset`, NMOS-
  only pins tied per §2.4.

**Test suite** — all three groups are **already written** in
`tb_cpu.sv` (each check increments the module-scope `errors` counter; the
positive self-check is mandatory so the harness can never pass empty):
1. **Self-check (positive):** known 13-instruction program (LDA/STA/LDX/
   LDY/STA abs,Y/TYA/NOP/JMP-loop) with hand-computed A/X/Y/S/flags and two
   RAM bytes; also proves the reset-vector fetch path.
2. **Execution-equivalence ("killer" test):** program P (DEX/ROR A/STX/
   TXA/STA loop) run for T1+T2 ce-cycles as a reference; the second run
   saves at T1 (3 ss words + full 64K RAM snapshot), perturbs T2 cycles,
   restores, continues T2, then compares all 3 CPU words *and* all 65536
   RAM bytes against the reference. A standalone CPU round-trip is
   subsumed: matching all 3 words proves capture/apply is *complete*, not
   just present.
3. **RAM restore (stomp):** save at T1, overwrite all RAM with 0xA5,
   restore, verify every byte matches the snapshot.

**Output:** `CPU_NEG1 PASS/FAIL cpu=<name>` + non-zero exit on failure.
**Status: GREEN, both CPUs (2026-09-05).** `CPU_NEG1 PASS cpu=nmos6502`
and `CPU_NEG1 PASS cpu=wdc65c02` (exit 0, `errors=0`). The build was
unblocked with plain `-public`, then four TB-side bugs were found and
fixed (2-`ce` read-latch bug, self-check opcode typos, S-after-reset
expectation, 1-`ce` stall drift in save/restore) — details in
`PROGRESS.md` §1d.

### 3.2 Level 0 (`level_0`) — CPU + memory + BIOS

Adds the machine's ROM (BIOS) and memory map. No drives, no slots, no
video. Tests the CPU executing *real BIOS code* (reset-vector handling,
NMI/IRQ vector fetch with stub handlers) instead of hand-written
micro-stimulus.

**Program injection — decision (open question, resolved here):**
- *Option A (tape-style load)* needs the cassette card: a full peripheral
  for level 0. Rejected — defeats the minimality.
- *Option B (direct injection, **recommended**):* harness writes the test
  payload straight into the behavioral RAM, and uses the savestate bus to
  set the CPU at the payload entry point (or let a reset run the BIOS and
  peek with `ss_rdata`). The savestate bus is exactly the intended
  "known-good state" primitive; the machine's cold/warm boot state is the
  canonical state to capture/restore.

**Reuse:** the level_neg1 behavioral memory and 2-phase `ce` driver are
extracted into `unit_tests/common/` at this step (avoid doing it earlier —
no premature abstraction while only one level exists).

### 3.3 Levels 1+ — one peripheral slice at a time

Each level adds **one** slice of the machine in order of
increasing complexity / likelihood of being the suspect.

**Level 1 (landed 2026-09-05, scope user-confirmed): native MONOCHROME
video + PS/2 keyboard** — not Disk II (that moves to a later level).
DUT = the full `rtl/apple2.v` machine core (both CPU cores, BIOS ROM,
timing HAL, native video pipeline — unmodified) + `rtl/keyboard.v`
(unmodified); the TB samples the native `VIDEO`/`HBL`/`VBL` ports directly
so the color pipeline (`vga_controller`, which lives in `apple2_top`) is
NOT pulled in. Two level_1-specific build facts:

- **One build covers both CPUs** — `apple2` muxes on its `cpu` input; the
  TB selects at runtime (`+cpu=0` nmos / `+cpu=1` wdc).
- The exe **must run from the repo root** — the DUT's `$readmemh` ROM
  paths are CWD-relative; outputs go to `unit_tests/level_1/out/`.

Remaining order (finalized as bugs land — the next real bug should drive
the ordering): floppy (Disk II + drives; differential-test knowledge
transfers) → slot cards (HDD, Mockingboard, …) → audio. (Memory-map
completeness is covered by level_0's BIOS and the level_1 DUT's full core
decode.)

- **Independent-build constraint:** each level has its own top module and
  Makefile. Levels pull in *unmodified* `rtl/` modules; they never
  `#undef` pieces of the machine build.
- When a level needs machine context (e.g. video needs `timing_generator`),
  reuse the proven module rather than hand-rolling the phasing (the
  Apple II derives its CPU clock from video timing; hand-rolled clocking is
  a false-negative hazard).

## 4. Shared infrastructure

- `unit_tests/common/` — shared, once-validated building blocks (extracted
  2026-09-05; consumed by level_neg1 and level_0): behavioral RAM
  (1-`ce`-cycle delay), 2-phase `ce` clock driver, savestate save/restore
  tasks, `check(...)` error-counting macros.
- `unit_tests/run_unit_tests.ps1` — the runner (written 2026-09-05):
  - sets the MSYS2 ucrt64 `PATH` and a writable `TMP` **inside** MSYS2;
  - iterates levels × `CPU=nmos|wdc`, builds + runs each;
  - prints a PASS/FAIL summary table, non-zero exit if anything failed.
  - **level_1 is special-cased** (its build contract differs: one build
    covers both CPUs, and the exe must run from the repo root): the runner
    delegates to `level_1/run_l1.sh` and derives per-CPU PASS/FAIL from the
    captured `L1 PASS/FAIL cpu=...` lines.
- **Per-level build contract:** `make [CPU=nmos|wdc]`, two-stage Verilator
  flow (§2.5), `VERILATOR_ROOT` defaulted in the Makefile, outputs under
  `build_<cpu>/`, `make clean` removes generated trees.
- **Status reporting (settled 2026-09-05):** module-scope `reg [15:0]
  errors` read by the C++ main via a public accessor — plain `-public`
  exposes module-scope regs as root-class members in this Verilator build,
  so the `tb_status.txt` fallback was never needed.

## 5. Correctness rules (anti-false-negative, from the session)

1. The 1-`ce`-cycle read delay is **not optional** — harness memory must
   mirror `apple2.v`'s `CPU_DL` timing or the harness itself is the bug
   source.
2. Never hand-roll CPU clocking; reuse `apple2.v`'s proven phase
   generation / `timing_generator` as soon as a level needs machine
   context.
3. Every level's TB must contain a **positive self-check** (a known-good
   program that must pass) so an inert harness cannot pass silently.
4. **Coverage gates** per level: assert the test actually exercised the
   DUT (PC advanced to expected values, expected memory writes observed) —
   no empty passes (the existing `module_tests/` harnesses enforce the
   same principle).
5. Levels use `rtl/` sources **unmodified**; if a level's need would force
   an `rtl/` edit, stop and re-plan.

## 6. Non-goals

- No changes to `rtl/` machine code to make levels build.
- No Quartus work at any level (Verilator only).
- No relocation of `module_tests/` (the `old_vhdl_migration/` move was
  discussed 2026-09-04 — recommended as one bookkeeping-only step *later*;
  untouched for now).
- Not replacing the full-machine smoke test; the ladder extends below it.
- B&W "minimal" video mode (bypassing the `vga_controller` color pipeline)
  is a *different axis* from the complexity ladder; not started, not
  scheduled here.

## 7. Roadmap

| # | Item | Status |
|---|---|---|
| 1 | level_neg1: TB + main.cpp + Makefile (nmos) | done (plain `-public`; `PROGRESS.md` §1d) |
| 2 | level_neg1: unblock build, first `CPU_NEG1 PASS` (nmos) | done 2026-09-05 |
| 3 | level_neg1: `CPU=wdc` variant green | done 2026-09-05 |
| 4 | `run_unit_tests.ps1` runner (levels × CPUs summary) | done 2026-09-05 (PASS/BUILD FAIL/RUN FAIL paths all exercised) |
| 5 | level_neg1: execution-equivalence killer test | done — in the TB, green both CPUs |
| 6 | Extract `unit_tests/common/` (memory, ce driver, ss tasks, checks) | done 2026-09-05 (consumed by neg1 + L0) |
| 7 | level_0: BIOS + memory map, direct injection (§3.2) | done 2026-09-05 (T1–T5 green, both CPUs) |
| 8 | level_1: video + keyboard (mono), first peripheral slice | in progress — build green; first-run fix list in PROGRESS §1h |
| 9 | `--trace`/VCD on demand for interactive debugging | done (neg1 `--trace` + GUI, level_1 `--trace`) |
| 10 | level_2: floppy (Disk II + drives) | next after level_1 is green |

## 8. Subagent (ninfer) usage notes

A local subagent is available for **delegated one-shot tasks** on this project.

- **Agent:** `custom.worker` (user agent; config at
  `C:\Users\newsdee\.pi\agent\agents\custom.worker.md`).
- **Model:** `ninfer/qwen3.8-27b` — local RTX 5090 server at
  `http://localhost:9080/v1` (OpenAI-compatible API, 128k context window).
  2026-09-04: the agent config's stale `llama-cpp/unsloth/...` model ID was
  replaced with `ninfer/qwen3.8-27b` (the ID the server actually serves);
  connectivity verified the same day (child replied `NINFER OK` to a
  no-tools prompt).
- **Usage profile:** good for bounded one-shot items with a small context
  (128k). **Run at most one at a time** — no fan-out, no parallel children.
- **Delegation policy:** the parent (strong model) owns core/base setup,
  environment work, and anything subtle (MSYS2 quirks, Verilator flags,
  HDL semantics). Once a task is confirmed clean and well-bounded, hand it
  to the ninfer worker with: an explicit objective, the exact commands to
  run, a crisp pass/fail criterion, and an authority boundary (which files
  it may touch). Give it the full environment recipe (MSYS2 ucrt64 PATH,
  TMP set *inside* bash, `VERILATOR_ROOT`) — do not expect it to discover
  the quirks in §2.5/PROGRESS §1b.
- **Verification:** treat its output as a claim, not authority — the parent
  re-checks results (test output, `git diff`) before accepting.

## 9. Open questions

- ~~Level-0 injection details~~ — resolved 2026-09-05: direct memory
  injection (harness writes the payload into RAM; the savestate bus sets
  CPU state). level_0 green on both CPUs.
- ~~Level ordering~~ — resolved 2026-09-05 (user-confirmed): level_1 =
  video + keyboard (mono); Disk II is the next level after that.
- ~~Empty-pass guard style~~ — resolved: per-level positive self-checks +
  coverage-style assertions in each TB; no shared gate macro (`common/`
  holds the clock/memory/savestate primitives only).
- **Level_1 geometry pinning (new, 2026-09-05):** T1–T5 thresholds are
  re-pinned from *measured* constants (frame-anchored captures, direct
  V-period measurement) — the HAL is a feedback state machine, so its
  cadence is not derivable analytically; see the PROGRESS §1h fix list.
