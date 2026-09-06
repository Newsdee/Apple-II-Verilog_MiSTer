# Level 1 MiSTer integration test — progress

## 2026-09-05

- **Plan written** (`PLAN.md`). Scope fixed: same DUT as `tb_l1.sv`
  (unmodified `apple2.v` + both CPU cores + `keyboard.v` + 128 K RAM +
  reset chain), monochrome native video, barebones 3-item OSD, no
  slots/drives/host I/O/audio.
- **Reference audit done** (all in-repo):
  - `tb_l1.sv` — DUT wiring, reset chain, flash divider, cold-reset RAM
    force, RAM pattern, keyboard tie-offs. Copied as the machine template.
  - Root project (`Apple-II.sv` + `Apple-II.qsf` + `files.qip` + `sys/`) —
    `module emu` port list (binds to `sys/sys_top.v:1634`), `hps_io`
    instantiation pattern, PLL usage (`outclk_0` 57.27 MHz → CLK_VIDEO,
    `outclk_1` 14.318 MHz → clk_sys), board pin/HPS qsf settings, qpf
    format.
  - newsdee project — parity cross-check (PLL, RAM, cpu/reset/status
    mapping, tie-off patterns). See `PLAN.md` parity section.
  - `sys/hps_io.sv` full port list — all inputs identified for clean
    tie-offs (rumble, PS/2 physical lines, SD array inputs, ioctl).
  - Video: `video_generator.v` shift register runs off the 7.159 MHz
    decimation gated by the real LDPS/WNDW timing; `timing_generator.v`
    exposes VID7M internally (not on `apple2.v` ports) → sync pulses are
    derived from HBL/VBL blanking edges (first-64/512-cycle counters),
    presentation = 1 sample per 14.318 MHz master cycle (matches
    `tb_l1_gui.sv`; hires 2x-stretch caveat documented).
- **Project files created:** `level1.qpf`, `level1.qsf` (cloned from root
  `Apple-II.qsf`: device 5CSEBA6U23I7, top `sys_top`, pins + HPS kept;
  `sys/` refs re-based to `../../sys/`; stale explicit source section
  replaced by `source files.qip`; pre-flow build_id script dropped),
  `files.qip` (level 1 sources, paths relative to this folder),
  `build.bat`/`build.sh` (cd repo root → `quartus_sh --flow compile
  unit_tests/level_1/mister/level1`).
- **Core written:** `Apple-II.sv` (see file header).
- **Newsdee parity audit (port + value level) — PASS with one fix:**
  - `apple2` instance: perfect 1:1 with the DUT port list (48/48, diff
    empty). `keyboard` instance: 20/20 with `JOY_TO_KEY=1` (macro
    inherited from the cloned qsf, same as newsdee; joy inputs tied off).
  - hps_io: every input newsdee drives, the core drives; the 16 ports the
    core leaves unconnected are all hps_io *outputs* (HDD image, gamepad,
    mouse, SD ack) unused at this level.
  - Value-level: `cpu=~status[5]`, `reset_cold=RESET|status[0]`,
    `osd_pause=status[N]&&OSD_STATUS` (newsdee now uses the same
    `&& OSD_STATUS` pattern, bit 44; core uses bit 1), keyboard
    `.reset(reset_cold)` (newsdee `apple2_top.vhd:641` comment),
    cold-reset RAM force `we=1/addr=$3F4/data=0` (newsdee
    `apple2_top.vhd:521-523`), tie-off patterns (newsdee
    `Apple-II.sv:30-34`). All match.
  - **Bug found & fixed by the audit:** the keyboard instance (copied
    from `tb_l1.sv`) omitted `.CLK_14M` — the PS/2 decode state machine's
    clock. The TB never exercised the keyboard, so it passed; on
    hardware the physical keyboard would have been dead. Fixed:
    `.CLK_14M(clk_sys)` (newsdee `apple2_top.vhd:639`).
  - **Latent gap flagged in `tb_l1.sv` (user file, NOT edited):** same
    missing `.CLK_14M` on its keyboard instance. One-line fix if desired.
  - `RUN_FILL_OK`: newsdee-VHDL-only port (absent from the verilog DUT)
    — no action.
- **Path-depth fix (after first user map run):** `mister/` is THREE
  levels below the repo root (`unit_tests/level_1/mister/`), so the
  initial `../../sys/...` and `../../rtl/...` refs landed in
  `unit_tests/` — warnings 125092 (sys.tcl / sys.qip / sys_analog.tcl
  not found). All re-based to `../../../` in `level1.qsf` (4 lines incl.
  the `source sys/sys.tcl` I'd missed) and `files.qip` (12 lines); all
  targets verified to exist. EOL preserved (qsf 279/279 CRLF).
- **sys/ copied into the project (after second user compile attempt):**
  Error 23018 — `sys/build_id.tcl not found`. Root cause: the shared
  `sys/sys.tcl:223` sets `PRE_FLOW_SCRIPT_FILE "quartus_sh:sys/build_id.tcl"`
  (project-dir-relative) and `:226` `QIP_FILE sys/sys.qip` — refs that
  only resolve when the project dir contains `sys/`. Since `sys.tcl` is
  shared (must not be modified for one test project), `sys/` (55 files,
  740K) + `jtag.cdf` are now **copied** into `mister/`; qsf refs reverted
  to the root-project form (`sys/sys.tcl`, `sys/sys.qip`, …). The DUT
  (`rtl/`) stays referenced live via `../../../rtl/...` — copying it
  would defeat the test. `build.bat`/`build.sh` refresh the copy on
  every build (`xcopy /E /Y /D` / `cp -r -u`, newer files only).
- **Guard-line fix (after third user compile attempt):** Errors 10654 +
  10112 — `rom.v`'s `// altera message_off/on 10030` lines are rejected
  by Quartus 17 ("message-related synthesis directives are not allowed
  inside a scope") and the whole `rom` design unit was ignored. Those
  lines were **committed in this repo only** — newsdee's `rom.v` never
  had them (its A&S succeeded today at 17:36 without them). Removed the
  guard pair from `rtl/rom.v` and the same-pattern pair from
  `rtl/mouse/jt6805/6805.vh` (not in the level-1 DUT, but the same
  landmine); both files are now byte-identical to newsdee. New
  uncommitted changes in this repo: `M rtl/rom.v`,
  `M rtl/mouse/jt6805/6805.vh`. If warning 10030 itself shows up in the
  compile output, it is a warning (newsdee lives without the guard) and
  gets handled separately.
- **PLL package + ROM data copied into the project (after fourth user
  compile attempt):** two findings:
  1. `rtl/pll.v` is NOT self-contained — it's a MegaWizard wrapper
     instantiating `pll_0002` (altpll core). The root project gets the
     whole PLL from the QIP package at repo `rtl/pll.qip` via the shared
     `sys.tcl` line `QIP_FILE rtl/pll.qip -qip sys/pll_q17.qip` (that was
     the source of the `rtl/pll.qip not found` warnings).
  2. Error 10054 — `$readmemh "rtl/roms/keyboard.hex"` is CWD-relative
     and the user runs Quartus from the project dir.
  Fix: copied the PLL package (`rtl/pll.qip` + `rtl/pll.v` +
  `rtl/pll/pll_0002.{v,qip}` + `pll_0002_q13.qip`) and `rtl/roms/*.hex`
  into the project; dropped `../../../rtl/pll.v` from `files.qip` (the
  QIP package provides `pll.v` — both would be a duplicate module).
  The project is now CWD-independent: works from the project dir (user's
  workflow) or the repo root. Build scripts refresh all copies
  (newer-files-only) before compiling. Note: the QIP also references a
  `pll.cmp` MISC file that doesn't exist in the repo either — the root
  project lives with it, so it is tolerated.
- **Pending:** Quartus Analysis & Synthesis (binding check) + full compile
  → `output_files/level1.rbf`, then hardware acceptance per `PLAN.md`.
  Now runnable from the project dir directly (or `build.bat`).
- **Corrupted-video fix (2026-09-05, after first hardware run):** the core
  loaded, the OSD showed, but the video was garbled. Compared against the
  newsdee core (the model): newsdee derives its syncs in `vga_controller.v`
  (68-cycle HSYNC after a 130-cycle front porch; 3-line VSYNC starting 33
  lines into the vblank). The level-1 core derives its own narrow syncs from
  the raw machine blanking (HBL/VBL), but the counter logic was **inverted**:
  it counted cycles while the line was *active* (`!hbl`/`!vbl`) and reset
  while *blanking*. Because the active region (≈560 cycles / 192 lines) far
  exceeds the counter saturation (200 / 1024), the counter was always
  saturated at the start of blanking, so `cnt < 64` / `cnt < 512` was false
  on the first blanking cycle and true for the **rest** of the blanking.
  Net effect: `VGA_HS` was high for the *entire* HBL (≈349–351 cycles =
  24 µs, ~5× too wide) and `VGA_VS` for the *entire* VBL (≈70 lines =
  4.4 ms, ~23× too wide) — a display cannot lock to that, hence the
  corruption. Verified with a Verilator probe (`tb_sync_check.v`, real
  `timing_generator` DUT): buggy logic → HS 349–351 / VS 5469–63839 cycles;
  fixed logic → HS exactly 68 (ends 198 after the HBL rise) / VS exactly
  2736 (3 lines). **Fix:** count cycles/lines *within* the blanking interval
  (reset while active) and window the pulse to match the vga_controller
  structure: HSYNC = cycles [130,198) of HBL; VSYNC = lines [33,36) of VBL
  (VBL line count = HBL rising edges while VBL high). Changed only the
  VIDEO OUT block of `Apple-II.sv` (the FPGA-only core; not part of the
  Verilator sim path). EOL preserved (pure LF, 0 CR). **Pending:** user
  re-runs `build.bat` → new `level1.rbf` → hardware re-test.

## 2026-09-06 (machine_ce blackout trap — fixed before the next rebuild)

The parallel save-state work (commit f5b3c64, 2026-09-06 18:03) added
input ports `machine_ce`, `ss_wren`, `ss_addr`, `ss_wdata` to
`rtl/apple2.v` (+ `timing_generator.v`). The core gates ALL machine
state on `machine_ce`; this wrapper left it unconnected, so Quartus
would tie it to GND and the machine would be completely dead on the
next rebuild (no sync, no video, no boot — the exact failure that hit
the level-2 2026-09-06 18:09 build).

**Fix:** the `apple2 d1` instance in `Apple-II.sv` now drives
`.machine_ce(1'b1)` (machine always runs; OSD pause is the existing
`STALL` path, not `machine_ce`) and ties off `.ss_wren(1'b0)`,
`.ss_addr(10'd0)`, `.ss_wdata(64'd0)` — no save-state feature in
level-1. Port names verified against `rtl/apple2.v`; the identical
4-line pattern was hardware-verified in the level-2 mister build.
EOL preserved (pure LF, 0 CR).

**Verification:** the FPGA wrapper itself needs the user's
`build.bat` (A&S will prove the port binding). The Verilator side of
the same trap was verified: `tb_l1_gui.sv` had the same missing
`machine_ce` (its CLI sibling `tb_l1.sv` and the level-1b
save-state harness `tb_cpu_ss.sv` were already wired by the parallel
session) and got the same 4 connections. `run_l1.sh nmos gui
--headless 3` → **L1_GUI SMOKE PASS** for both CPUs
(`+cpu=0` and `+cpu=1` from one build): 3/3 frames, ink=67779,
video live. Note: a comment line starting with the word "Verilator"
trips Verilator 5.050 BADVLTPRAGMA (treated as a bad inline
pragma) — the fix comment was worded around that.
