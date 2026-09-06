# Level 1 — MiSTer FPGA integration test

Optional on-FPGA integration test for the **level 1 machine**: the unmodified
machine core (`rtl/apple2.v`, both CPU cores muxed on `cpu`) plus the real
PS/2 keyboard (`rtl/keyboard.v`), compiled as a standalone MiSTer core into a
clean `.rbf` with a barebones OSD.

Goal: verify on real hardware the same DUT that `tb_l1.sv` verifies in
Verilator — cold boot (Apple logo), monitor, keyboard, CPU switch — with no
test harness logic in the FPGA image.

## Scope

**In (identical DUT to `unit_tests/level_1/tb_l1.sv`):**
- `rtl/apple2.v` — machine core: nmos6502 + wdc65c02 (muxed on `cpu`), RAM
  decode, BIOS ROM (`rom.v` + `apple2e.hex`), timing HAL
  (`timing_generator.v`), native video pipeline (`video_generator.v` +
  `video2.hex`), ramcard decode (`ramcard.v`)
- `rtl/keyboard.v` — real PS/2 interface (`keyboard.hex`), keys forwarded by
  the HPS over the io protocol (`hps_io.ps2_key`)
- 128 K RAM (64 K main + 64 K aux) in the core, TB pattern (1-ce latch)
- Reset chain + flash divider + cold-reset RAM force, mirroring
  `tb_l1.sv` (which mirrors `rtl/apple2_top.v:315-330, 385-387`)

**Out (deliberately):**
- Color pipeline (`vga_controller.v` — lives in `apple2_top`, level 2+)
- Slots, drives, HDD, mockingboard, mouse, serial, clock — none
- Host I/O / SD image channel (tied off in `hps_io`)
- Audio (tied off; `apple2.speaker` left unconnected)

## Video presentation

Native monochrome, matching the `tb_l1_gui.sv` presentation:
- `CLK_VIDEO` = 14.318 MHz (PLL `outclk_1`, same net as the machine clock)
- `CE_PIXEL` must remain asserted for every master cycle, including blanking.
  `VGA_DE = ~(HBL | VBL)` identifies visible samples; it must not gate the
  pixel cadence.
- `VGA_R = VGA_G = VGA_B = {8{VIDEO}}`
- Narrow sync pulses derived from the blanking edges (the machine core
  exposes HBL/VBL blanking, not syncs): 68-cycle HSYNC after a 130-cycle
  front porch and 3-line VSYNC starting 33 lines into VBL.

Correct for TEXT mode (boot logo, monitor, BASIC — what this level shows).
Hires content (7.159 MHz pixel rate) is half-sampled and appears 2x
stretched horizontally — the same documented caveat as `tb_l1_gui.sv`
("out of scope for the boot-logo GUI").

## OSD (barebones)

| Item | Bit | Effect |
|------|-----|--------|
| `O5,CPU,65C02,6502` | status[5] | `cpu = ~status[5]` (newsdee convention: 0=65C02… see note) |
| `O1,OSD Pause,Off,On` | status[1] | CPU held **while the OSD is open** (root-core pattern `status[1] && OSD_STATUS`) → `apple2.STALL` |
| `R0,Cold Reset` | status[0] | `reset_cold = RESET \| status[0]` |

Note on CPU bit: OSD value 0 shows "65C02" → status[5]=0 → `cpu=~0=1`
→ wdc65c02. Value 1 shows "6502" → status[5]=1 → `cpu=0` → nmos6502.
Same mapping as newsdee (`.cpu_type(~status[5])`) and the root core.

## Files (this folder)

| File | Purpose |
|------|---------|
| `Apple-II.sv` | the `module emu` core (port list = root project's core, binds to `sys/sys_top.v`) |
| `level1.qpf` / `level1.qsf` | Quartus project: device 5CSEBA6U23I7, top `sys_top`, board pins + HPS from the root project's `Apple-II.qsf` |
| `files.qip` | level 1 source list (DUT paths `../../../rtl/...` — live repo files) |
| `sys/`, `jtag.cdf` | **copies** of the repo's MiSTer infrastructure. Copied (not referenced) because `sys/sys.tcl` sets project-relative refs (`sys/build_id.tcl`, `sys/sys.qip`) that must resolve inside the project dir. |
| `rtl/pll.qip`, `rtl/pll.v`, `rtl/pll/` | **copy** of the PLL QIP package. `sys.tcl` expects `QIP_FILE rtl/pll.qip` in the project dir; the package provides the MegaWizard wrapper `pll.v` + the altpll core `pll/pll_0002.*` (57.27272/14.31818 MHz from 50 MHz — the same clocks the root project uses). The repo's `rtl/pll.v` is therefore NOT in `files.qip` (would be a duplicate `pll` module). |
| `rtl/roms/*.hex` | **copy** of the ROM data for the DUT's CWD-relative `$readmemh` paths (`apple2e.hex` BIOS in `apple2.v`, `keyboard.hex` in `keyboard.v`, `video2.hex` in `video_generator.v`). |

The build scripts refresh all copies (newer files only) on every build. The DUT RTL is deliberately NOT copied — the test compiles the repo's live `rtl/`.
| `build.bat` / `build.sh` | one-command compile: cds to the repo root (so the DUT's CWD-relative `$readmemh` paths `rtl/roms/*.hex` resolve), then `quartus_sh --flow compile unit_tests/level_1/mister/level1` |
| `PLAN.md` / `PROGRESS.md` | this plan + progress log |

Output: `mister/output_files/level1.rbf` — copy to the MiSTer SD card root
to load.

## Parity with the newsdee project (checked 2026-09-05)

Mirrored from newsdee / root project:
- PLL usage: `pll(.refclk(CLK_50M), .outclk_0→CLK_VIDEO, .outclk_1→clk_sys)`
  (newsdee `Apple-II.sv:130-136`; root core `Apple-II.sv:237-242`). Level 1
  uses `outclk_1` for both machine and `CLK_VIDEO`; `outclk_0` (57.27 MHz,
  color pipeline) unused.
- `hps_io #(.CONF_STR(...), .VDNUM(3))` in the core, `HPS_BUS` passed
  through (standard MiSTer HPS pattern, both projects).
- RAM: 1-ce latch main+aux exactly as newsdee `Apple-II.sv:592-614` and
  `tb_l1.sv`.
- `cpu = ~status[5]`, `reset_cold = RESET | status[0]`, warm reset from
  `buttons[1]` (newsdee `Apple-II.sv:365-375`).
- Tie-off patterns (`SD_*='Z`, `SDRAM_*='Z`, `DDRAM_*=0`, `USER_OUT='1`)
  from newsdee `Apple-II.sv:30-34`.
- `sys/` = this repo's folder (the one the root project compiled against).

Deliberate differences:
- No `apple2_top` / `vga_controller` (level 1 scope) → monochrome video out
  as above instead of the 57.27 MHz color pipeline.
- No virtual keyboard / joy2key / A2K (newsdee features; `keyboard.v`
  virtual_* inputs tied off exactly as in `tb_l1.sv`).
- No audio, no SD image channel, no slots.
- `CONF_STR` is the 3-item barebones set (newsdee has the full menu).

## Dependencies

- `rtl/apple2.v` **`STALL` port** — the user's OSD-pause port (uncommitted
  in this repo as of 2026-09-05; also present in newsdee as `cpu_pause`).
  If it is reverted, drop `.STALL(...)` and the `O1` OSD item.
- ROMs at `rtl/roms/{apple2e,keyboard,video2}.hex` (repo root; resolved via
  the build script's CWD).
- In-project `sys/` copy (refreshed from the repo by the build scripts;
  see file layout above).
- Quartus Prime 17.0.2 Lite on PATH (build script calls `quartus_sh`).

## Corrupted-video repair plan

The Sep 6 full Quartus flow, fitter, timing analysis, and assembler all
succeeded, so this is a functional video-interface problem rather than a
failed FPGA build. The earlier blanking-counter inversion has already been
fixed: the current generated HSYNC is 68 master cycles and VSYNC is 3 lines.

The remaining primary defect is `CE_PIXEL = ~hbl`. Both HSYNC transitions
occur during HBL, when that expression holds `CE_PIXEL` low. MiSTer's
`sys_top` passes `CE_PIXEL` into the scanline/capture path as `ce_in`, so it
can miss the sync transitions and sees no pixel cadence at all during the
blanking portion of each line.

### Fix A: minimal native monochrome path (first choice)

1. Keep `CLK_VIDEO = clk_sys` at 14.318 MHz so the machine and video output
  remain in one clock domain.
2. Change only `CE_PIXEL` to constant `1'b1`. Keep `VGA_DE = ~hbl & ~vbl`.
3. Retain the corrected 68-cycle HSYNC and 3-line VSYNC logic.
4. Extend the sync probe to count total enabled samples per line and assert:
  - `CE_PIXEL` is high during active video, blanking, and both HSYNC edges;
  - active width is approximately 560 samples;
  - total line length is approximately 910 samples;
  - HSYNC is 68 samples and VSYNC is 3 lines.
5. Rebuild the RBF and test HDMI and analog VGA, with direct video both off
  and on if the display path permits it.

This is the smallest fix and matches the wrapper's claim of one output sample
per 14 MHz master cycle. It does not add color or correct the documented
hires horizontal stretching.

### Fix B: use the working core's MiSTer presentation pipeline

If Fix A does not produce stable output, copy the known-working clock and
presentation boundary rather than adding more special-case sync logic:

1. Restore PLL `outclk_0` as `CLK_VIDEO` (57.27 MHz) and keep `clk_sys` at
  14.318 MHz.
2. Generate `ce_pix` in the `CLK_VIDEO` domain at one pulse per four clocks,
  matching the newsdee core's normal double-pixel mode.
3. Feed monochrome RGB, HSync, VSync, HBlank, and VBlank through
  `video_mixer`, which produces `CE_PIXEL`, VGA RGB, sync, and DE using the
  same contract as the working core.
4. Add `sys/video_mixer.sv` dependencies through the existing `sys/sys.qip`
  path rather than duplicating modules in `files.qip`.
5. Verify clock-domain sampling carefully: the 14 MHz source signals must be
  stable when captured by the 57 MHz presentation pipeline, as they are in
  the working design.

This is higher confidence for MiSTer integration but widens the level-1 test
surface and consumes the standard video infrastructure.

### Fix C: restore the full Apple II video controller

Only if native monochrome output itself is no longer an important level-1
boundary, instantiate `vga_controller.v` (or advance the test to level 2) and
use its RGB, blanking, and sync outputs with the working `video_mixer` path.
This gives correct artifact color and mode-dependent pixel handling, but it
tests substantially more than `apple2.v` and should not be the first repair.

### Validation order

1. Run the focused video timing probe after Fix A.
2. Run the existing level-1 Verilator regression to ensure boot/reset/RAM are
  unchanged.
3. Run Quartus Analysis & Synthesis, then a full compile only after the narrow
  checks pass.
4. Confirm the new RBF timestamp and inspect timing slack.
5. Test on hardware. Automated timing checks cannot prove monitor lock or
  visually correct framing.

## Acceptance (on hardware)

1. `level1.rbf` loads; OSD shows "Apple-II_L1" with CPU / OSD Pause /
   Cold Reset items.
2. Cold reset (OSD or button) → Apple logo + monitor prompt within ~1 s.
3. Typing on the physical PS/2 keyboard reaches the monitor (BIOS latches
   keys to $0030, like tb_l1 T6).
4. CPU option switches 65C02/6502 across a cold reset; both boot.
5. OSD Pause: machine freezes while the OSD is open, resumes on close.
