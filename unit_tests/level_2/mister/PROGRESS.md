# Level 2 — MiSTer FPGA integration test — PROGRESS

Companion to `PLAN.md`. Log of what was built and verified.

## 2026-09-06 — level-2 mister core created

Built `unit_tests/level_2/mister/` by mirroring the level-1 mister setup
(`unit_tests/level_1/mister/`) and adding the Disk II + floppy + SD image
channel, per `PLAN.md`.

### Files created
- `Apple-II.sv` — the `module emu` core. Level-1 core (PLL, hps_io, 1-ce
  latch RAM, reset chain + flash divider + cold-reset `$3F4` force,
  keyboard, monochrome video with the **fixed narrow-sync derivation**,
  tie-offs) plus:
  - `disk_ii` (slot 6): `IO_SELECT[6]`/`DEVICE_SELECT[6]`, `A=ADDR`,
    `D_IN=D` (CPU data out), `D_OUT -> core.PD`, `CLK_2M`/`PHASE_ZERO` from
    the core's timing-HAL outputs, `D1_WP=status[6]`/`D2_WP=status[7]`
    (OSD Write Protect), `RESET=reset_sync`.
  - 2× `floppy_track` (`ft1`/`ft2`), each with its internal `dpram` track
    RAM. Track bus `disk_ii.TRACKx <-> ft.ram_*`; `ft.active =
    disk_ii.Dx_ACTIVE`; `ft.ready -> disk_ii.DISK_READY[x]`.
  - SD image channel: hps_io channel 0 -> `ft1`, channel 1 -> `ft2`.
    `img_mounted[x]` arms `disk_mount[x]=(img_size!=0)` + toggles
    `disk_change[x]` (mirrors `verilator/sim.v:605-620`).
  - 60 Hz IRQ (one 16-cycle pulse per VBL rise) -> `core.IRQ_n` (mirrors
    `tb_l2.sv`; the ROM's 60 Hz handler keeps the OS 1-second counter the
    boot path waits on).
  - `hps_io` `VDNUM(2)`; `CONF_STR` adds `O6,WP Drive 1` / `O7,WP Drive 2`.
- `level2.qpf` (`PROJECT_REVISION = "level2"`), `level2.qsf` (byte-identical
  to level1's — the revision name lives in the qpf; device 5CSEBA6U23I7,
  top `sys_top`, `JOY_TO_KEY=1`, board pins + HPS from the root project).
- `files.qip` — level-1 sources + `disk_ii.v`, `drive_ii.v`,
  `floppy_track.sv` (SystemVerilog), `dpram.v` (Verilog); DUT referenced
  live at `../../../rtl/...`.
- `build_id.v`, `build.bat`, `build.sh` (paths adapted level_1->level_2,
  level1->level2; refresh the in-project `sys/`, `jtag.cdf`, PLL QIP, and
  `rtl/roms/*.hex` copies newer-files-only, then
  `quartus_sh --flow compile unit_tests/level_2/mister/level2`).
- `PLAN.md` (this scope) + this `PROGRESS.md`.

### Verification (done here, no Quartus)
- **Verilator elaboration of `module emu`** (all DUT sources + `sys/
  hps_io.sv` + a `pll` port stub, `-DJOY_TO_KEY=1`): **clean, exit 0, no
  errors in `Apple-II.sv`**. Confirms every `apple2`/`disk_ii`/
  `floppy_track`/`keyboard` port connection, signal declaration, and width
  is valid. (Two `// verilator ...` comment lines that Verilator parsed as
  unknown pragmas were reworded; `joy_key_code`/`joy_key_press` are
  `ifdef JOY_TO_KEY` ports, present in the Quartus build via the qsf macro.)
  The only residual warnings are in the shared `sys/hps_io.sv`
  (`PROCASSWIRE` strictness, `UNOPTFLAT` on the `HPS_BUS` inout) —
  pre-existing infrastructure, not this core, and not Quartus concerns.
- EOL preserved: `Apple-II.sv`, `files.qip`, `build.bat`, `build.sh`,
  `level2.qpf`, `PLAN.md`, `PROGRESS.md` are pure LF (matching level-1);
  `level2.qsf` is CRLF (copied from level1's, 279 CR, unchanged).

### Pending (user)
- **Re-run `build.bat` after the 2026-09-06 (evening) video fix**
  (swap to the `video_mixer` presentation — see last entry below) →
  `output_files/level2.rbf` → hardware re-test of the video. The
  dpram-swap rebuild (first item in the 17:00 build) already passed:
  Fitter **successful** 17:00:17, Assembler **successful** 17:00:39.
- Hardware acceptance per `PLAN.md` (cold boot to monitor; mount
  `DOS_3_3.nib` on drive 1 + cold reset -> DOS 3.3 boots; keyboard; CPU
  switch; OSD Pause).

## 2026-09-06 — first full compile: fitter failed on `dpram.v` inference; swapped to `dpram.vhd`

User ran the first `level2` compile (A&S 15:05 **green**, 143,273 registers;
Fitter 15:46 **failed**).

### Symptom (exactly the risk PLAN.md "Known risks" flagged)
- `Error (170011): Design contains 267,479 blocks of type combinational
  node. However, the device contains only 83,820 blocks` → `Error (11802):
  Can't fit design in device` (326% ALM).
- Fit summary: **Total RAM Blocks: 0 / 553** — no block RAM placed.
- Map report's inferred-altsyncram list shows every other memory packed
  correctly (`disk_ii` diskrom, BIOS `roms`, `ram0`/`ram1`, video_rom,
  keyboard_rom, all sys/HDMI RAM) — but **no `dpram` instance** (the ft1/ft2
  track RAMs). The two Verilog behavioral `dpram.v` instances were
  synthesized as LUT-based distributed RAM. This is the same Quartus 17.0.2
  non-inference the newsdee project hit (dpram revert, AGENTS.md
  2026-08-31 entry: 285,718 nodes there vs 83,820).
- The many map warnings in the message window (10034/10036/12030/14284/
  14320/276027: PLL unused outputs, HDMI PLL synthesized-away nodes,
  ascal/shadowmask dual-clock RAM inference) are standard MiSTer `sys`
  template noise — identical to the newsdee project's compile; none
  reference the Apple II RTL, and none affect this outcome.

### Fix applied (the PLAN's pre-agreed response)
- Copied `Apple-II_MiSTer_newsdee/rtl/dpram.vhd` (explicit altsyncram,
  75 lines, CRLF as in the source project — kept byte-identical to the
  proven file; Quartus compiles it CRLF in newsdee) into this project as
  `mister/rtl/dpram.vhd`.
- `files.qip`: `VERILOG_FILE ../../../rtl/dpram.v` →
  `VHDL_FILE rtl/dpram.vhd` (with a comment explaining the trap).
  `level2.qsf` carries no source list (byte-identical to level1's) — no
  other reference to `dpram.v` exists in the project; `build.sh`/`build.bat`
  only refresh `sys/`, `jtag.cdf`, the PLL QIP, and `rtl/roms/*.hex`.
- Binding is proven, not assumed: the `dpram #(13,8)` instantiation in
  `rtl/floppy_track.sv` is **byte-identical** in this repo and newsdee's,
  and newsdee compiles + fits that exact Verilog-instantiates-VHDL-entity
  pair (named ports; positional generics 13,8 → `addr_width_g`/
  `data_width_g`; explicit `.enable_a/.enable_b(1'b1)` matches the VHDL
  port defaults). Quartus A&S on the re-run is the binding proof per the
  AGENTS.md mixed-language rule.
- **Unchanged:** the repo's `rtl/dpram.v` (simulation/differential
  candidate; all Verilator level-1/level-2 and module-test paths keep
  using it) and `rtl/floppy_track.sv` (no RTL edits, no TB edits).

### Verification status
- Done: root-cause evidence from `level2.map.rpt`/`level2.fit.rpt` (above);
  byte-identical copy check; binding diff vs newsdee; EOL check (files.qip
  still pure LF).
- Pending (user): re-run `build.bat`/`build.sh` → A&S should show the two
  `dpram` instances in the inferred-altsyncram list and the fitter should
  pass with the track RAMs in M10Ks. Remaining warnings expected to be the
  same benign `sys` template set.

### 2026-09-06 (later) — Quartus GUI rewrote `level2.qsf`; dpram source line fixed there too

The user's Quartus GUI session (project loaded before the files.qip fix,
rewrites at 16:12 and 16:19) overwrote `level2.qsf` and — in doing so —
appended the **explicit source list** (all 15 sources, mirrored from the
pre-fix `files.qip`) after the existing `source files.qip` line, plus the
`PRE_FLOW_SCRIPT_FILE "quartus_sh:sys/build_id.tcl"` line. The stale mirror
still contained `VERILOG_FILE ../../../rtl/dpram.v`, which would have
re-registered the Verilog `dpram` alongside the VHDL entity → name clash.
Everything else in the rewritten qsf was intact (device 5CSEBA6U23I7, top
`sys_top`, `JOY_TO_KEY=1`, 145 pin/HPS assignments, `source sys/sys.tcl`).

- Fix: `level2.qsf` line 294 is now `set_global_assignment -name VHDL_FILE
  rtl/dpram.vhd`, matching `files.qip` line 39 (both files verified to
  carry zero references to `dpram.v`). Verified content-identical to the
  original 16:19 qsf apart from that one line; CRLF preserved (295/295),
  final line without trailing newline as in the original.
- **Caveat:** if the Quartus GUI still holds the project with the stale
  in-memory state, closing/saving it could write the old dpram line back.
  Close the project without saving (or just re-open it so it reloads the
  corrected files), or run `build.bat`/`build.sh` from the shell instead.
- No new compile has run since the 15:46 failure **at the time of this
  entry**; the user's 17:00 rebuild (with the corrected qsf/qip source set)
  completed successfully — Fitter 17:00:17, Assembler 17:00:39, `level2.rbf`
  written — which also confirms the dpram swap worked (track RAMs inferred,
  no Error 170011).

### 2026-09-06 (evening) — first hardware run: bad video; swapped to the `video_mixer` presentation

User's first hardware test of the 17:00 `level2.rbf`: the machine loaded
and ran, but the **video is garbled — the same lock/corruption symptom as
the level-1 first hardware run** (the 2026-09-05 inverted-sync bug).

### Diagnosis
- The emu-level sync geometry was **not** the problem: the level-2 sync
  derivation is a byte-faithful port of the level-1 *verified* fix (same
  counters — count within blanking, reset while active; same windows —
  HSYNC 68 cycles @ [130,198) of HBL, VSYNC 3 lines @ [33,36) of VBL — on
  the same `hbl`/`vbl`/`video` from the same `apple2` core at the same
  14.318 MHz clock).
- The structural difference between the two cores is the **presentation to
  the sys frontend**:
  - level 1 (proven on hardware): `CLK_VIDEO` = 57.27 MHz (PLL
    `outclk_0`) + 4:1 `ce_pix` divider (14.318 MHz pixel enable) →
    `video_mixer` (`.LINE_LENGTH(580)`, `.GAMMA(1)`) regenerates the emu
    pixel/sync/CE presentation.
  - level 2 (bad on hardware): `CLK_VIDEO` = 14.318 MHz (same net as the
    machine clock) with raw `CE_PIXEL = ~hbl` / `VGA_DE = ~hbl & ~vbl` /
    direct pixel assigns, no `video_mixer`.
- User confirmed (2026-09-06): the proper MiSTer pattern is the
  `CLK_VIDEO` + `CE_PIXEL` + `video_mixer` one.

### Fix applied (wrapper-only; no RTL, no testbench changes)
- `Apple-II.sv` CLOCKS block: PLL `outclk_0` now drives `CLK_VIDEO`
  (57.27 MHz) — previously left unconnected with `assign CLK_VIDEO =
  clk_sys;` — plus the level-1 `video_div`/`ce_pix` 4:1 divider
  (14.318 MHz one-sample-per-machine-cycle cadence).
- `Apple-II.sv` VIDEO OUT block: direct `CE_PIXEL`/`VGA_R/G/B`/`VGA_HS`/
  `VGA_VS`/`VGA_DE` assigns replaced by the level-1 block — `native_hsync`/
  `native_vsync`/`native_rgb` wires + the `video_mixer` instance driving the
  emu ports. **Verified byte-identical to the level-1 block** (awk-extracted
  both VIDEO OUT sections → empty diff); the sync-derivation counters were
  already identical and are unchanged. `gamma_bus` (already wired to
  `hps_io`) now feeds the mixer as in level 1.
- EOL preserved: `Apple-II.sv` still pure LF (0 CR).

### Result
- Video confirmed working on hardware (user report 2026-09-06) after the
  rebuilt `level2.rbf`. A follow-up comment-only edit fixed the stale
  file-header video note in `Apple-II.sv` (no functional change; the
  flashed rbf was unaffected).

## 2026-09-06 (drive status overlay)

Goal: see what the Disk II controller is doing on hardware (motor /
activity per drive) — especially while sorting out the missing OSD
image-mount entries.

### Changes (wrapper + one in-project module copy; no DUT RTL, no testbench)
- `rtl/drive_status_overlay.sv` — **byte-identical** copy of the newsdee
  core's module (`cmp`-verified; CRLF 113/113 preserved, same pattern as
  the `dpram.vhd` in-project copy). Draws 2×2 LEDs at x=538/542, y=182 in
  the native active area; dim while the drive motor is on, bright for
  ~50 ms after an I/O transfer.
- `Apple-II.sv` — overlay instance inserted between the native core RGB
  (`native_rgb`) and the `video_mixer` (repo overlay rule); mixer R/G/B
  now come from `drive_overlay_rgb`. Wiring: `clk=clk_sys`,
  `reset=reset_cold`, `enable=~status[8]`, `hblank/vblank=hbl/vbl`,
  drive1/2 motor=`d1_active`/`d2_active` (selected-drive motor state
  incl. spin-down), activity=`d1_io_active`/`d2_io_active`; HDD LED tied
  off (no HDD in this core).
- OSD: new item `O8,Disk LED overlay,Yes,No` → `status[8]` (default Yes;
  status[8] was free — WP Drive 2 is status[7]).
- Sources registered in **both** `files.qip` (LF) and the explicit
  `level2.qsf` source list (`VERILOG_FILE rtl/drive_status_overlay.sv`)
  per the mixed-language registration rule.

### Verification
- All referenced identifiers exist in `Apple-II.sv` (grep-verified:
  `clk_sys`, `reset_cold`, `status`, `hbl`/`vbl`, `native_rgb`,
  `dX_active`/`dX_io_active`). Parse/binding precedent: the module is the
  newsdee core's, which Quartus already compiled in the newsdee RBF.
- EOL: `Apple-II.sv` 0 CR; `files.qip` 0 CR (40 lines); `level2.qsf`
  CRLF 296/296 with the trailing blank line + `PARTITION_HIERARCHY` line
  (no trailing NL) preserved; `rtl/drive_status_overlay.sv` CRLF
  113/113 (byte-identical).
- Note: a standalone Verilator lint of the module was not run — the
  MSYS2 `verilator_bin.exe` standalone invocation fails with a Windows
  include-path quoting bug (`verilated_std.sv`), an environment issue
  unrelated to the module.

### Pending (user)
- Re-run `build.bat` → new `level2.rbf` → flash. On hardware the OSD
  should now list `Disk LED overlay` (default Yes); the two LEDs appear
  at the bottom-right of the active area. While the ROM polls an empty
  drive the LEDs stay off; with a disk mounted the drive-1 LED should
  light (dim) when the motor spins up and flash bright during DOS boot
  reads.

## 2026-09-06 (missing OSD mount entries — fixed)

Symptom: after the video fix, the OSD listed the core's options but no
image-mount entries at all, so no `.nib` could be mounted on hardware.

### Diagnosis (HPS-side trace)
- The MiSTer HPS builds the OSD file-mount menu **from the core's
  `CONF_STR`**, not from `VDNUM`. In the HPS OSD-string parser (`menu.cpp`
  — local reference trees `E:\MiSTer\Main_MiSTer` (2021) and
  `Main_MiSTer_ND` (2020); identical semantics in both), an item whose
  first character is `S` (SD image) or `F` (file load) becomes a menu
  entry: the digit after the letter is the **hps_io image channel index**,
  the first comma field is the **extension list** (3-char groups, e.g.
  `NIB` → `*,NIB` display + file-browser filter), and an optional second
  field is a custom label.  `VDNUM` only sizes the hps_io channel arrays.
- Proof: the newsdee core's `CONF_STR` declares exactly such items
  (`"S0,NIBDSKDO PO ;"`, `"S1,HDV;"`, `"S2,NIBDSKDO PO ;"`) and its mount
  entries work on this board.  Level-2's `CONF_STR` had none.
- The core side was already complete: `hps_io #(.VDNUM(2))` with the full
  `sd_*` bus wired, and `floppy_track` ft1/ft2 consuming the stream
  (same port contract the Verilator harness drives); `img_mounted`/
  `img_size` arm `disk_mount`/`disk_change`.  Only the OSD declaration was
  missing.

### Fix (CONF_STR only)
- `Apple-II.sv` `CONF_STR`: added
  `"S0,NIB,Drive 1;"` and `"S1,NIB,Drive 2;"` after the first separator
  → OSD items **`Drive 1 *.,NIB`** / **`Drive 2 *.,NIB`** (label = 3rd
  field; `.nib`-only filter — the floppy_track engine reads the raw
  35×13×512 track layout, not `.po`/`.dsk` sector dumps).
- `PLAN.md`: corrected the false "auto-generated from `VDNUM(2)`" claim
  (OSD section + Media/boot wording).
- EOL: `Apple-II.sv` still 0 CR; `PLAN.md` 0 CR.

### Pending (user)
- Re-run `build.bat` → flash → OSD should show the two `*.,NIB` mount
  items. Select a `.nib` (e.g. `DOS_3_3.nib`, 232,960 bytes) from the
  MiSTer SD card, then **Cold Reset** → DOS 3.3 boots. Note:
  `img_readonly` is wired from hps_io but not consumed by the core (WP
  protection is the OSD `WP Drive n` items; the HPS itself discards
  writes to a read-only mounted file) — revisit only if interactive
  DOS WRITE testing surfaces a problem.

## 2026-09-06 (black screen after the 18:09 build — root-caused + fixed)

Symptom: after the 18:09 build (overlay + `S0`/`S1` OSD items), the OSD
worked and listed the `*.,NIB` mount items, but the screen was black
(except the OSD) with no overlay pixels.

### Diagnosis
- My own changes were exonerated: the VIDEO OUT block is byte-identical to
  the proven level-1 one (only the overlay sits in the R/G/B path, and
  `drive_status_overlay` is a provable pass-through — `rgb_out = rgb_in`
  default with a 2x2 pixel override), `sys/` and the PLL QIP are
  byte-identical across all builds, and the 18:03 map/STA show the complete
  design with all slack positive (57.27 MHz domain has 7.3 ns margin).
- The real cause: the **parallel save-state work** rewrote `rtl/apple2.v`
  and `rtl/timing_generator.v` at **18:03** (commit `f5b3c64` "wire save
  state to more components") — seconds before the 18:03:05 A&S, which
  references the DUT **live from the repo** (the point of this project).
  That work added new inputs `machine_ce`/`ss_addr`/`ss_wdata`/`ss_wren`
  (plus outputs `ss_rdata`/`cpu_frozen`).  The level-2 wrapper did not
  connect them, and Quartus ties unconnected inputs to GND:
  **`machine_ce = 0` gates ALL machine state** (CPU register updates in
  `apple2.v`; the `HBLANK`/`VBLANK` output registers and H/V counters in
  `timing_generator.v`) → the core produces no sync → `video_mixer` never
  locks → black screen.  The OSD is unaffected because the sys/OSD/ascal
  chain runs on its own clocks.  Map proof: `level2.map.rpt` —
  "machine_ce … not connected by instance … will be connected to GND".
- The 17:44 "it works" build predated the port addition.

### Fix (wrapper + harness only; DUT untouched)
- `mister/Apple-II.sv` `apple2 d1`: added
  `.machine_ce(1'b1), .ss_wren(1'b0), .ss_addr(10'd0), .ss_wdata(64'd0)`
  (OSD pause stays on the existing `STALL` path; level-2 has no
  save-state feature).
- `unit_tests/level_2/tb_l2.sv` `apple2 d1`: same four connections — an
  unconnected input is 0 in two-state Verilator, so the harness had the
  same dead-machine trap.

### Verification (current 18:03 core)
- `run_l2.sh both --empty` → **PASS x2** (frames=19, ink=2 — video live).
- `run_l2.sh both --disk` → **PRELOADED PASS x2** (DOS 3.3 boot:
  sectors=13, bytes=6656, mot1=1, ready=1, ink=580).
- EOL: both edited files still 0 CR.

### Latent instances of the same trap (not fixed here)
- `unit_tests/level_1/mister/Apple-II.sv` also references `rtl/apple2.v`
  live and does not wire `machine_ce` — the next level-1 rebuild hits the
  same blackout.
- `rtl/apple2_top.v` (repo) likewise does not wire the new ports — the
  parallel session's responsibility.

### Pending (user)
- Re-run `build.bat` → flash → video should be back (Apple logo at cold
  reset), with the `Disk LED overlay` and `Drive 1/2 *.NIB` OSD items
  present; then the disk-mount test: select `Drive 1 *.NIB`, pick
  `DOS_3_3.nib`, Cold Reset → DOS 3.3 boots, drive-1 LED lights/flows.
