# LADDER — `unit_tests` verification ladder (reference)

Created 2026-09-10. This file is the *reference*: what each level is, how to
run it, and how the levels relate. Companion documents:

- **`PLAN.md`** — design intent of the ladder (why the levels exist, grounding facts)
- **`PROGRESS.md`** — session-by-session history (root-cause findings, bugs fixed)
- **Workspace `AGENTS.md`** — "Unit-test ladder build setup" (the three load-bearing
  MSYS2 build facts: native `mingw32-make`, exported `TMP`, `--binary` for pure TBs)

## What the ladder is

Per-level Verilator harnesses for bug bisection: isolated CPU → machine, one
peripheral slice added per level. Rules (PLAN.md §3.3):

- **Independent builds** — each level has its own top module + Makefile; levels
  pull in *unmodified* `rtl/` modules and never `#undef` pieces of the machine build.
- **Built from MSYS2 ucrt64** with native `mingw32-make` (MSYS `make` strips
  `TMP` from recipe children); export `TMP/TEMP/TMPDIR` *inside* the shell.
- **Pure self-driving SystemVerilog TBs build with `verilator --binary`**
  (not `--exe` — the `sc_time_stamp()` link failure).
- **Exes run with CWD at the `Apple-II-Verilog_MiSTer` repo root** — the DUT's
  `$readmemh` ROM paths are CWD-relative.
- **Top-level runner:** `run_unit_tests.ps1` — iterates `level_*` dirs, runs
  `mingw32-make CPU=<cpu>` + the exe per (level, CPU) pair; exit codes:
  0 pass, 201 make failed, 202 no exe, n = the exe's own exit code.
  `level_1` is special-cased (one build covers both CPUs; delegates to
  `level_1\run_l1.sh`).

## The levels

| Level | Dir | Scope (adds over the previous) | DUT | Key TBs / entry | Quartus test project | Status (2026-09-10) |
|---|---|---|---|---|---|---|
| **−1** | `level_neg1` | Isolated CPU core, selectable: `make CPU=nmos` → `nmos6502`, `CPU=wdc` → `wdc65c02`. Behavioral 64K RAM (1-`ce` read delay), 2-phase `ce` driver, savestate bus. No `apple2.v`. | one CPU core | `tb_cpu.sv`: (1) self-check program, (2) execution-equivalence "killer" (save/perturb/restore + full-RAM compare), (3) RAM stomp. GUI = isolated-CPU savestate debugger (deliberately vsync + small batches). | — (sim only) | **GREEN both CPUs** (2026-09-05) |
| **0** | `level_0` | + machine ROM (BIOS) + memory map. No drives, no slots, no video. CPU executes *real BIOS code*. Program injected directly (Option B, PLAN.md §3.2). | CPU + ROM + RAM | `tb_l0.sv`, `run_l0.sh/.bat` | — | **GREEN** (2026-09-05, with neg1 — PROGRESS §1g) |
| **1** | `level_1` | Full `rtl/apple2.v` core (both CPUs, BIOS, timing HAL, native video) + `rtl/keyboard.v`; native **monochrome** video + PS/2 keyboard. TB samples `VIDEO`/`HBL`/`VBL` directly (no `vga_controller`). **One build covers both CPUs** (`+cpu=0/1` runtime select). | full core + keyboard | `tb_l1.sv` (headless), `tb_l1_gui.sv` (SDL, no-vsync standard), `run_l1.sh/.bat`, `run_l1_gui.bat` | `mister/level1.qpf` | build green; last recorded run partial (PROGRESS §1h) |
| **1b** | `level_1b` | **Savestate layer**: the `savestate_*_l1b.sv` module family + its TBs. `savestate_{ram,regs,slot_arbiter}` = original generation (replaced); `savestate_{ddr,manager}` = current (512 KiB slot base, `error_code`); `savestate_ui` = the OSD "Save States" page. | savestate modules | `tb_l1b_ss.sv`, `tb_savestate_{ui,hotkeys}.sv`, `tb_ss_{ram,regs,arbiter,manager,ddr}.sv`, `main_cpu_ss.cpp`; Makefile target **`ui`** (self-contained: `tb_savestate_ui.sv` + `savestate_ui.sv` only) | `mister/level1b.qpf` | ddr/manager fixes committed 2026-09-10 (`a388f75`); **`tb_savestate_ui` never built/run yet**; older-generation files (ram/regs/arbiter, `tb_l1b_*`, `tb_ss_*`, `gui/`) still untracked — commit-or-drop decision open |
| **2** | `level_2` | **Color/composite video pipeline**: `apple_composite.sv` (SPC=4 composite decoder), `composite_decoder.sv`, `video_mixer_plus.sv` (blend-capable mixer), `ntsc_vertical_blend.sv` (2-line vertical comb, 560-entry line RAM, OSD-togglable via `status[11]`). Test media in-folder: `Akalabeth.nib`, `DOS_3_3.nib`(+scratch), `.dsk`, `.woz`. | core + composite/blend video | `tb_l2.sv`, `tb_composite.sv`(+`_dbg`), `tb_burst_probe.sv`, `tb_ss_ddr.sv`, `tb_vblend.sv`/`tb_mixplus.sv` (in `mister/`); `run_l2.sh/.bat` | `mister/level2.qpf` (→ `level2.rbf`) | TBs PASS (vblend, mixplus, composite regression); Quartus compiled 2026-09-10 07:35 (fit/ASM OK; **STA flag**: emu core PLL −1.743 ns/TNS −108.5 — blend almost certainly not the cause, A/B tie-off build in flight 09-10); blend hardware A/B pending |
| **2b** | `level_2b` | Level-2 variant with **disk host** (`l2b_disk_host.h`); GUI-centric (`main_l2b.cpp`, `gui/`). Own wrapper (`Apple-II.sv`), own PLAN/PROGRESS. | core + composite + disk host | `tb_l2b.sv`, `run_l2b_gui.bat` | `mister/level2b.qpf` | see `level_2b/PLAN.md` + `level_2b/PROGRESS.md` |

`common/` — shared TB helpers: `tb_ce_gen.sv` (2-phase `ce` driver),
`tb_ram_mem.sv` (behavioral 64K memory), `tb_ss_pkg.sv` (savestate package).
Extracted at the level_0 step (PLAN.md §3.2).

## Cross-level relationships (the non-obvious parts)

1. **`level_1b` → `level_2` (live file references):** `level_2/mister/files.qip`
   and `level2.qsf` register `../../level_1b/savestate_{manager,ddr}_l1b.sv`
   directly — the level2 Quartus build consumes the level_1b sources in place.
   Do not rename/move `level_1b/` files without updating those references.
2. **`level_1b` → main repo (`Apple-II_MiSTer`, byte-identical mirrors):**
   `savestate_{ddr,manager,ui}_l1b.sv` are mirrored into the main repo's
   `rtl/` and into its `files.qip`/`Apple-II.qsf`. Apply behavioral edits to
   both copies in the same change (same rule as the mirrored keyboard files).
   The `ram/regs/arbiter` generation is **not** mirrored (superseded).
3. **Each level owns a Quartus test project** (`level1.qpf`, `level1b.qpf`,
   `level2.qpf`, `level2b.qpf` in their `mister/` dirs) — separate from the
   production builds (`Apple-II.qpf` in each repo, `level2` aside). Their
   `build.bat`/`build.sh` refresh infrastructure copies (sys/, jtag.cdf,
   pll qip, ROMs) then run `quartus_sh --flow compile`.
4. **`level_1b` vs `level_1` — do NOT merge:** `level_1` = base machine
   harness; `level_1b` = the savestate layer on top (own DUTs, TBs, Makefile
   targets, Quartus project). The "b-suffix = variant of the same level" is
   the repo convention; `level_2`/`level_2b` follow it too.
5. **GUI speed standard** (PLAN.md §3.3): display-harness GUIs must run
   un-vsynced with whole-machine batch size (650,000 slots; slider to
   1,750,000 in `sim_main.cpp`). Headless harnesses run at model throughput.
   Exception: `level_neg1`'s GUI (short interactive CPU debugging) keeps
   vsync + small batches deliberately.

## Build gotchas (pointer, not copy)

The three load-bearing facts (native make, exported TMP *inside* the MSYS
shell, `--binary` for pure TBs) and their failure modes are documented in
workspace `AGENTS.md` §"Unit-test ladder build setup" and in `PROGRESS.md`
§1b. Environment hazard: the host AV/endpoint layer can kill freshly linked
C++ PEs mid-session (exit 127 / 0xC0000061) — fall back to
`verilator --lint-only -sv` for integration checks and re-run the functional
harness later.

## Status snapshot (2026-09-10)

- **GREEN:** level_neg1 (both CPUs), level_0, level_2 Verilator TBs (vblend /
  mixplus / composite), level_1 builds.
- **In flight:** `tb_savestate_ui` (level_1b, run after the Quartus compiles);
  level2 Quartus A/B (blend tied off at `mister/Apple-II.sv` line 280 for the
  STA emu-domain comparison; restore with `git checkout -- unit_tests/level_2/mister/Apple-II.sv`).
- **Planning only:** NTSC color killer (`level_2/NTSC_COLOR_KILLER_PLAN.md`,
  7 open questions in §6).
- **Open decisions:** level_1b older-generation files (commit or drop).
