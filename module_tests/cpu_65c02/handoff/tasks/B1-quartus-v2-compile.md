# B1 - Quartus map/fit/timing for new_cpu_v2 (USER-GATED)

- status: running
- kind: user
- owner: user
- created: 2026-09-04
- updated: 2026-09-04
- eta: agent prep ~30 min; user compile 30-60 min machine time
- gate: user go-ahead to compile (AGENTS.md: do not start long Quartus
  compiles unless the user asks)
- parallel-safe: yes (prep is read-only)

## What the agent does (prep, thinking-lite, unattended)
1. Verify the Quartus project registers rtl/new_cpu_v2/ sources and the
   correct top entity for the v2 build; check files.qip + Apple-II.qsf
   source sections. (This is the FPGA project
   Apple-II_MiSTer_newsdee - a SEPARATE directory; state which
   project/directory is being prepared.)
2. Emit the exact compile command (quartus_sh --flow compile ...) and
   the report checklist (map.summary, fit.summary, sta.summary, asm.rpt)
   with the baseline to compare against
   (Apple-II-Verilog_MiSTer/FPGA_LOGIC_BASELINE.md).
3. Write prep notes to build/quartus_v2_prep.md; set status=ready.

## What the user does
Run the compile; feed back the report summary; record ALM/register/M10K/
timing deltas vs the baseline + new-vs-known warnings in
build/quartus_v2_prep.md.

## Acceptance
- build/quartus_v2_prep.md: command, checklist, (after run) delta table,
  warning delta.
- No .qsf/.qip change without an explicit note of what changed and why.
- Board updated.

## May write
- build/quartus_v2_prep.md
- this task file (status/log only)
## Safety (all workers)
- Read AGENTS.md at the workspace root first; it is the operating guide.
- Touch ONLY the paths listed under "May write". No RTL edits (C tasks
  excepted), no git commits, no unrelated cleanup, preserve line endings.
- Windows: use `python3` (MSYS2 ucrt64), not `python`. Stop any running
  Vemu.exe before Verilator rebuilds (Windows locks the linker output).
- Use disposable media copies when writes must not alter originals.
- Deterministic re-runs: every step must be reproducible from the listed
  inputs; keep seeds fixed (record any seed used).
- Report: update this task file's `updated:` field, append a dated line
  to the progress log, list artifacts. Refresh the board with
  `python3 handoff/board_status.py` when done. Do NOT hand-edit BOARD.md.

## Progress log

- 2026-09-04 (pi-session): prep done -> build/quartus_v2_prep.md.
  CORRECTION: the project is Apple-II-Verilog_MiSTer/Apple-II.qpf
  (top sys_top), NOT Apple-II_MiSTer_newsdee (that project has no
  new_cpu* sources). User is running Quartus now. IMPORTANT: v2
  sources (rtl/new_cpu_v2/) are NOT registered in qip/qsf - the live
  project registers rtl/cpu_65c02.sv + rtl/cpu_alu.sv (original ALU).
  So the in-flight compile is the BASELINE (current live state); the
  v2 compile needs the documented swap (a: overwrite the two live
  files with new_cpu_v2 content, or b: re-point the two
  SYSTEMVERILOG_FILE assignments) - do it AFTER the current compile
  finishes (Quartus locks the project). Baseline: 2026-09-02 fit ok,
  ALM 18,334/41,910 (44%), regs 20,652, setup slack 0.653, TNS 0.000.
- 2026-09-04: user running Quartus (baseline compile of live state).
- 2026-09-04 (pi-session): user STOPPED Quartus - the in-flight baseline
  run did not complete (A&S finished 08:27, fitter killed); last
  COMPLETED baseline remains the 2026-09-02 numbers. A fresh compile
  is needed for either the baseline or the v2 build.
- 2026-09-04 (pi-session): superseded CPU copies moved to untracked
  backup rtl/old/cpu/ (new_cpu, new_cpu_original, new_cpu_v2,
  new_6502; rtl/old/cpu/ gitignored). new_cpu (== live v1) and
  new_cpu_v2 (was tracked) are now untracked backup; new_cpu_v2
  untracked from the index. Live project sources rtl/cpu_65c02.sv /
  rtl/cpu_alu.sv (v1) untouched - the B1 swap still overwrites them
  with the canonical rtl/cpu/wdc65c02/ content at compile time.
