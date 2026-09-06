# Level 2 — MiSTer FPGA integration test

Optional on-FPGA integration test for the **level 2 machine**: the level-1
machine core (`rtl/apple2.v`, both CPU cores muxed on `cpu`) plus the real
PS/2 keyboard (`rtl/keyboard.v`) plus the real Disk II slot controller
(`rtl/disk_ii.v`: two `drive_ii` MFM decoders + controller ROM) plus one
`floppy_track` per drive (`rtl/floppy_track.sv`, each with its own `dpram`
track RAM), compiled as a standalone MiSTer core into a clean `.rbf` with a
barebones OSD.

Goal: verify on real hardware the same DUT that `tb_l2.sv` verifies in
Verilator — cold boot, monitor, keyboard, **and a genuine DOS 3.3 boot from
a mounted `.nib` image** — with no test-harness logic in the FPGA image.

## Scope

**In (identical DUT to `unit_tests/level_2/tb_l2.sv`):**
- `rtl/apple2.v` — machine core: nmos6502 + wdc65c02 (muxed on `cpu`), RAM
  decode, BIOS ROM (`rom.v` + `apple2e.hex`), timing HAL
  (`timing_generator.v`), native video pipeline (`video_generator.v` +
  `video2.hex`), ramcard decode (`ramcard.v`).
  **Save-state WIP ports** (added to `rtl/apple2.v` by the parallel
  save-state work, commit `f5b3c64`, 2026-09-06): the wrapper drives
  `.machine_ce(1'b1)` (the core gates ALL machine state on it — unconnected
  it ties to GND and the machine is dead: no sync, no video, no boot),
  `.ss_wren(1'b0)`, `.ss_addr(10'd0)`, `.ss_wdata(64'd0)` (level-2 has no
  save-state feature).  `tb_l2.sv` wires the same constants.
- `rtl/keyboard.v` — real PS/2 interface (`keyboard.hex`), keys forwarded by
  the HPS over the io protocol (`hps_io.ps2_key`)
- `rtl/disk_ii.v` + `rtl/drive_ii.v` — Disk II slot controller (slot 6),
  controller ROM `diskii.hex`
- `rtl/floppy_track.sv` + `rtl/dpram.v` — one per drive; the physical track
  buffer + the SD/blkdev image interface
- 128 K RAM (64 K main + 64 K aux), 1-ce latch (TB / newsdee pattern)
- Reset chain + flash divider + cold-reset RAM force + 60 Hz IRQ, mirroring
  `tb_l2.sv` (which mirrors `rtl/apple2_top.v` + `verilator/sim.v`)

**Out (deliberately):**
- Color pipeline (`vga_controller.v` — lives in `apple2_top`, level 2+ of
  the color work)
- HDD, mockingboard, mouse, serial, clock, slots 4/5 — none
- Audio (tied off; `apple2.speaker` left unconnected)

## Disk / SD image channel

The two `hps_io` SD image channels drive the two floppy tracks:

| hps_io channel | floppy_track | Disk II drive |
|----------------|--------------|---------------|
| 0 | `ft1` | drive 1 |
| 1 | `ft2` | drive 2 |

- `hps_io` drives `sd_ack / sd_buff_addr / sd_buff_dout / sd_buff_wr`.
- Each `floppy_track` drives its channel's `sd_lba / sd_rd / sd_wr /
  sd_buff_din`.
- `img_mounted[x]` (a 1-cycle pulse from the HPS when an image is mounted on
  channel x) arms `disk_mount[x] = (img_size != 0)` and toggles
  `disk_change[x]` (mirrors `verilator/sim.v:605-620`).

Mount a `.nib` image on channel 0 (drive 1) via the OSD **Drive 1 *.,NIB**
menu item (`S0`), then Cold Reset: the ROM's disk-boot routine runs and
DOS 3.3 boots.
This is the same "preloaded drive 1" scenario `tb_l2.sv` / `main_l2.cpp`
verify in Verilator.

## Video presentation

Native monochrome through MiSTer's standard `video_mixer` — byte-identical
to the level-1 core's proven block (swapped in 2026-09-06 after the first
hardware run showed the direct-14.318-MHz presentation would not lock; see
PROGRESS.md):
- `CLK_VIDEO` = 57.27 MHz (PLL `outclk_0`); `ce_pix` = 4:1 divider →
  14.318 MHz one-sample-per-machine-cycle presentation cadence
- `CE_PIXEL` = `video_mixer`'s regenerated pixel-enable
- `VGA_R/G/B`, `VGA_HS/VSYNC`, `VGA_DE` from the `video_mixer` outputs
- Narrow sync pulses derived from the blanking edges (the machine exposes
  HBL/VBL blanking, not syncs): a 68-cycle HSYNC 130 cycles into HBL and a
  3-line VSYNC 33 lines into VBL, matching the newsdee `vga_controller.v`
  structure (`VGA_FRONT_PORCH=130`, `VGA_HSYNC=68`, `VBL_TO_VSYNC=33`,
  `VGA_VSYNC_LINES=3`), fed to the mixer alongside the raw HBL/VBL.

Correct for TEXT mode (boot logo, monitor, BASIC, DOS). Hires content
(7.159 MHz pixel rate) is half-sampled and appears 2× stretched
horizontally — the same documented caveat as the level-1 core.

## Drive status overlay

`rtl/drive_status_overlay.sv` (byte-identical copy of the newsdee core's
module, ported 2026-09-06): draws two 2×2 LED pixels near the bottom-right
of the active area (drive 1 at x=538, drive 2 at x=542, y=182 in native
coordinates). A drive's LED lights dim while that drive's motor is on
(`dX_active`, which includes delayed spin-down) and goes bright for ~50 ms
after each I/O transfer (`dX_io_active` activity hold). Runs on `clk_sys`,
sits between the native core RGB and the `video_mixer` (per the repo
overlay rule), and is gated by the OSD `Disk LED overlay` item (status[8],
default Yes). No HDD in this core — the third (HDD) LED is tied off.

## OSD (barebones)

| Item | Bit | Effect |
|------|-----|--------|
| `O5,CPU,65C02,6502` | status[5] | `cpu = ~status[5]` (newsdee convention: 0=65C02, 1=6502) |
| `O1,OSD Pause,Off,On` | status[1] | CPU held **while the OSD is open** (`status[1] && OSD_STATUS`) → `apple2.STALL` |
| `O6,WP Drive 1,Off,On` | status[6] | `disk_ii.D1_WP` |
| `O7,WP Drive 2,Off,On` | status[7] | `disk_ii.D2_WP` |
| `R0,Cold Reset` | status[0] | `reset_cold = RESET \| status[0]` |
| `O8,Disk LED overlay,Yes,No` | status[8] | enables the drive status overlay, default Yes (see **Drive status overlay**) |

The two image-mount entries are **declared in `CONF_STR` as `S` items**
(`S0,NIB,Drive 1;` / `S1,NIB,Drive 2;`): the MiSTer HPS generates one
"Mount" menu entry per `S` item — the digit after `S` selects the hps_io
image channel (0=drive 1, 1=drive 2) and the extension field (3-char
groups) filters the file browser.  They display as `Drive 1 *.,NIB` /
`Drive 2 *.,NIB`.  `VDNUM(2)` only sizes the hps_io channel arrays; it does
NOT make the HPS create menu entries (fixed 2026-09-06 — see PROGRESS.md).

## Files (this folder)

| File | Purpose |
|------|---------|
| `Apple-II.sv` | the `module emu` core (port list = root project's core, binds to `sys/sys_top.v`) |
| `level2.qpf` / `level2.qsf` | Quartus project: device 5CSEBA6U23I7, top `sys_top`, board pins + HPS from the root project's `Apple-II.qsf` (qsf is byte-identical to level1's; the revision name lives in the qpf) |
| `files.qip` | level 2 source list (DUT paths `../../../rtl/...` — live repo files; adds `disk_ii.v`, `drive_ii.v`, `floppy_track.sv`, `dpram.v` over level 1) |
| `sys/`, `jtag.cdf` | **copies** of the repo's MiSTer infrastructure (copied, not referenced, because `sys/sys.tcl` sets project-relative refs that must resolve inside the project dir) |
| `rtl/pll.qip`, `rtl/pll.v`, `rtl/pll/` | **copy** of the PLL QIP package (`sys.tcl` expects `QIP_FILE rtl/pll.qip` in-project; the package provides the MegaWizard `pll.v` + altpll core `pll/pll_0002.*`) |
| `rtl/roms/*.hex` | **copy** of the ROM data for the DUT's CWD-relative `$readmemh` paths (`apple2e.hex`, `keyboard.hex`, `video2.hex`, `diskii.hex`) |
| `build.bat` / `build.sh` | one-command compile: cds to the repo root (so the DUT's CWD-relative `$readmemh` paths resolve), refreshes the copies (newer files only), then `quartus_sh --flow compile unit_tests/level_2/mister/level2` |
| `PLAN.md` / `PROGRESS.md` | this plan + progress log |

The build scripts refresh all copies (newer files only) on every build. The
DUT RTL is deliberately NOT copied — the test compiles the repo's live
`rtl/`.

Output: `mister/output_files/level2.rbf` — copy to the MiSTer SD card root
to load.

## Parity with the level-1 mister core

Everything the level-1 core does (PLL, hps_io, RAM, reset chain, keyboard,
monochrome video + the fixed narrow-sync derivation, tie-offs) is carried
over unchanged. Level 2 adds: the Disk II controller, two floppy tracks,
the SD image channel (2 hps_io channels), the 60 Hz IRQ, and the
`PD`/slot-select/`CLK_2M`/`PHASE_ZERO` connections the disk needs.

## Dependencies

- `rtl/apple2.v` **`STALL` port** (the OSD-pause port; also present in
  newsdee as `cpu_pause`).
- ROMs at `rtl/roms/{apple2e,keyboard,video2,diskii}.hex`.
- In-project `sys/` copy (refreshed by the build scripts).
- Quartus Prime 17.0.2 Lite on PATH (build script calls `quartus_sh`).
- A `.nib` disk image on the MiSTer SD card (e.g. `DOS_3_3.nib`) to mount
  for the DOS boot test.

## Acceptance (on hardware)

1. `level2.rbf` loads; OSD shows "Apple-II_L2" with CPU / OSD Pause /
   WP Drive 1 / WP Drive 2 / Cold Reset items and two image-mount entries.
2. Cold reset with **no** disk mounted → Apple logo + monitor prompt
   (the level-1 behavior).
3. Mount `DOS_3_3.nib` on drive 1, Cold Reset → DOS 3.3 boots (the
   `tb_l2.sv` scenario).
4. Typing on the physical PS/2 keyboard reaches the monitor.
5. CPU option switches 65C02/6502 across a cold reset; both boot.
6. OSD Pause: machine freezes while the OSD is open, resumes on close.
7. WP Drive 1/2: with WP on, a write to that drive is refused (optional).

## Known risks

- **`dpram.v` block-RAM inference.** `dpram.v` is the Verilog *behavioral*
  dual-port model (the newsdee project uses the explicit-altsyncram
  `dpram.vhd` because a different instantiation did not infer into block
  RAM — see AGENTS.md 2026-08-31 note). Here it is a clean 13×8 dual-port
  RAM instantiated twice (inside the two `floppy_track`s). Quartus should
  infer it into M10Ks, but if the fitter reports a combinational-node
  explosion (Error 170011) or the RAM is not inferred, that is a real
  DUT FPGA-synthesizability finding to address (e.g. swap in the
  explicit-altsyncram model for the FPGA build).
  **MATERIALIZED 2026-09-06 (first compile):** the fitter failed with
  Error 170011 (267,479 combinational nodes vs 83,820; 0 RAM blocks;
  326% ALM) — the two Verilog `dpram` instances were the only memories
  missing from the map report's inferred-altsyncram list. Swapped the FPGA
  build to the in-project explicit-altsyncram `rtl/dpram.vhd` (see
  PROGRESS.md, 2026-09-06 entry). The repo `rtl/dpram.v` remains the
  simulation/differential candidate, unchanged.
