# B1 prep - Quartus map/fit/timing for new_cpu_v2

Status: user is compiling 2026-09-04. This document is the B1 prep
record (project identity, exact state, commands, checklist, baseline,
delta table). Written read-only - no project files were touched.

## Project identity (CORRECTION to the task file's guess)

- Project: `E:/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/Apple-II.qpf`
  (NOT `Apple-II_MiSTer_newsdee` - that project's source lists contain no
  `new_cpu*` references at all).
- Revision `Apple-II`, top entity `sys_top`, device Cyclone V
  `5CSEBA6U23I7`, Quartus Prime 17.0.2 Build 602 Lite.
- Reports land in this repo's `output_files/`.

## Registration state at writing time (2026-09-04)

- Working-tree `Apple-II.qsf` is the expanded Quartus-rewritten form
  (committed qsf was the minimal 10-line form; the rewrite is normal
  Quartus behavior and does not change source registration).
- CPU sources registered in BOTH `files.qip` (lines 7-8) and
  `Apple-II.qsf` (lines 283-284):
  - `rtl/cpu_65c02.sv` (md5 a61f98cb...)
  - `rtl/cpu_alu.sv` (md5 dfc623d3... == `rtl/new_cpu_original/cpu_alu.sv`)
- `rtl/apple2.v` instantiates `cpu_65c02 cpu65c02(...)` (line 613;
  comment at line 158: "replaced R65Cx2/RC65x02 on 2026-09-02") - the
  top binds by MODULE NAME, so a file-content swap needs no binding
  change.
- `rtl/new_cpu_v2/` (cpu_65c02.sv md5 822591a2..., cpu_alu.sv
  md5 1d76d132...) is **NOT registered anywhere** in qip/qsf.
- Consequence: a compile started right now measures the CURRENT live
  project state (original ALU), i.e. the BASELINE - not new_cpu_v2.

## What the v2 compile requires (one of)

CANONICAL SOURCE (2026-09-04): the intended versions now live under
`rtl/cpu/` - WDC core: `rtl/cpu/wdc65c02/` (byte-identical copy of
`rtl/new_cpu_v2/`), NMOS core: `rtl/cpu/nmos6502/` (copy of
`rtl/new_6502/`). Use the canonical files below; the `rtl/new_cpu_v2/`
paths remain the copy source of record (md5s verified equal).

a) Content swap (matches the 2026-09-02 convention in apple2.v):
   overwrite `rtl/cpu_65c02.sv` and `rtl/cpu_alu.sv` with
   `rtl/cpu/wdc65c02/cpu_65c02.sv` / `rtl/cpu/wdc65c02/cpu_alu.sv`
   (keep the originals - `rtl/new_cpu_original/` - for diffing).
b) Re-point the two assignments:
   `set_global_assignment -name SYSTEMVERILOG_FILE rtl/cpu/wdc65c02/cpu_65c02.sv`
   `set_global_assignment -name SYSTEMVERILOG_FILE rtl/cpu/wdc65c02/cpu_alu.sv`
   (in both files.qip and Apple-II.qsf).
Either way: do NOT start this while the current compile is running
(Quartus locks the project), and record which variant was used.

## Commands (cwd = repo root)

```bat
rem full compile
quartus_sh --flow compile Apple-II
rem cheaper interface/synthesis check
quartus_map Apple-II --read_settings_files=on --write_settings_files=off
```

## Report checklist after each run

| report | what to read |
|--------|--------------|
| output_files/Apple-II.map.summary | A&S status |
| output_files/Apple-II.map.rpt | source registration, elaboration, NEW warnings |
| output_files/Apple-II.fit.summary | fitter status, top-level ALM % |
| output_files/Apple-II.fit.rpt | resource hierarchy: sys_top, emu, apple2_top, cpu instance ALMs/regs/M10K |
| output_files/Apple-II.sta.summary | setup/hold slack, TNS |
| output_files/Apple-II.asm.rpt | RBF generation |

Verify report timestamps before trusting any of them.

## Baselines

- Last completed compile of this project: 2026-09-02 - fit Successful,
  ALM 18,334 / 41,910 (44%), total registers 20,652, pins 145, setup
  slack 0.653 (pll_hdmi divclk path), TNS 0.000.
  Caveat: the project source set has expanded since (working-tree qsf
  now includes t65, mouse, mockingboard, NSC, ...), so treat these as
  the nearest reference, not an identical configuration.
- Documented pre-port baseline: `FPGA_LOGIC_BASELINE.md` (repo root).

## Delta table (fill after the runs; one row per compile)

| date | build | fit | ALM (delta) | regs (delta) | M10K (delta) | worst setup slack (delta) | TNS | new warnings | notes |
|------|-------|-----|-------------|--------------|--------------|---------------------------|-----|--------------|-------|
| 2026-09-02 | live state (committed qsf era) | ok | 18,334 | 20,652 | - | 0.653 | 0.000 | - | baseline |
| 2026-09-04 | (user running: live state) | ? | | | | | | | |
| - | new_cpu_v2 (after swap a/b) | ? | | | | | | | |

## Warning protocol

Separate pre-existing warnings from NEW ones (map.rpt). Never hide a
warning that affects correctness (multiple drivers, truncated regs,
incomplete cases, inferred latches) - report each with a note on why
it is or is not a problem.
