# MiSTer FPGA / OSD Notes (Apple-II core)

Working notes for the newsdee MiSTer integration (Quartus project in
`../Apple-II_MiSTer_newsdee/`). Verified against the MiSTer firmware source
(`E:\MiSTer\Main_MiSTer\menu.cpp`, `user_io.cpp`) and the core's own
`sys/hps_io.sv`, 2026-09-01.

## 1. How MiSTer OSD option bits actually work

The ARM-side menu parses each `CONF_STR` entry. The relevant functions in
`menu.cpp`:

```cpp
int getOptIdx(char *opt)
{
    if ((opt[1] >= '0') && (opt[1] <= '9')) return opt[1] - '0';
    if ((opt[1] >= 'A') && (opt[1] <= 'V')) return opt[1] - 'A' + 10;
    return 0;
}

uint32_t getStatus(char *opt, uint32_t status)
{
    char idx1 = getOptIdx(opt);      // char right after 'O'
    char idx2 = getOptIdx(opt + 1);  // second char after 'O'
    ...
    if (idx2 > idx1) { x = status >> idx1; x &= range_mask(idx1..idx2); }
```

Facts that matter when assigning bits:

1. **Bit characters are `0-9` = 0..9 and `A-V` = 10..31.** Up to 32 option
   bits per page. `A`=10, `B`=11, ..., `F`=15, `G`=16, `H`=17, `I`=18,
   `J`=19, `K`=20, `L`=21, `M`=22, `N`=23, `O`=24, `P`=25, `Q`=26, `R`=27,
   `S`=28, `T`=29, `U`=30, `V`=31.
2. **`OXY` is a bit *range* X..Y (inclusive), and only the first two
   characters after `O` are parsed.** `O9B` = bits 9,10,11 (3 bits, 5-8
   values). `O78` = bits 7,8. A single character `O4` = bit 4 only.
   **Trap:** `O1234` does *not* mean "bits 1,2,3,4" — it means range 1..2
   (chars `1`,`2`); `34` is silently ignored.
3. **Uppercase `O` and lowercase `o` use two different 32-bit status
   words.** In `menu.cpp`: `int ex = (p[0] == 'o');` selects
   `status[ex]` in `user_io_8bit_set_status(...)`. Both words are written to
   the FPGA (`UIO_SET_STATUS2`, two `spi32_w` calls). On the 128-bit
   `hps_io` status bus this maps to:
   - uppercase `O` bit N  →  `status[N]`        (FPGA bits 31:0)
   - lowercase `o` bit N  →  `status[32+N]`     (FPGA bits 63:32)
4. **`R0` (reset button) owns bit 0** of the main word — never assign an
   option to bit 0.
5. **Cycling wraps by the option's bit mask, not just the label count.**
   `x = (getStatus+1) & mask` — so an `OXY` option with more labels than
   2^(Y-X+1) cycles through only the low values; extra labels are never
   shown. (This is how the old `P2O1234,H shift,Off,1..15` silently became a
   4-position option.)
6. All P1/P2/P3 pages and the unnumbered option pages (`OJK,`, `OQR,`,
   `OOP,`, `-;` with `R0`) share the same two 32-bit words — **bit
   allocation is global across the whole menu, not per page.** Two options
   on different pages may not use the same bit.

## 2. Apple-II core: current status-bit allocation (after 2026-09-01 fixes)

Main word (uppercase `O`, FPGA `status[31:0]`):

| Bits | Option | Core use |
|------|--------|----------|
| 0 | `R0` Cold Reset | `.reset(RESET \| status[0])` |
| 1..2 | *(free — was H shift, removed 2026-09-01)* | |
| 3 | `P2O3` Sharp RGB (fill) | `SEAM_RUN_FILL(~status[3])` — moved from bit 9 |
| 4 | `P2O4` Color sharpness (RGB/Composite) | `GRAY_SEAM_FIX(~status[4])` |
| 5 | `P1O5` CPU (65C02/6502) | `cpu_type(~status[5])` |
| 6 | `P3O6` Analog X/Y swap | `swap_axes(status[6])` |
| 7..8 | `P2O78` Stereo mix | `AUDIO_MIX = status[8:7]` |
| 9..11 | `P2O9B` Scandoubler Fx | `scale = status[11:9]` |
| 12..13 | `P2OCD` Aspect ratio | `ar = status[13:12]` |
| 14..15 | `P2OEF` Scale | `.SCALE(status[15:14])` |
| 16 | `P2OG` Pixel Clock | `ce_pix <= status[16] ? ...` |
| 17..18 | `P3OHI` Paddle as analog | `paddle_as_x(status[17])` / `paddle_as_y(status[18])` |
| 19..20 | `OJK` Display mode | `screen_mode = status[20:19]` |
| 21 | `P2OL` Lo-Res Text | (vga_controller) |
| 22 | `P1OM` PAL Mode | `PALMODE(status[22])` |
| 23 | `P1ON` Video Rom | `ROMSWITCH(~status[23])` |
| 24..25 | `OOP` Color palette | `palette_mode = status[25:24]` |
| 26..27 | `OQR` Write Protect | `D1_WP/D2_WP` |
| 28..29 | `P3OST` Slot 4 | `status[29:28]` |
| 30..31 | `P3OUV` Slot 5 | `status[31:30]` |

Extended word (lowercase `o`, FPGA `status[63:32]`, i.e. char bit N →
`status[32+N]`):

| Char bit | Option | Core use |
|----------|--------|----------|
| 0 | `P2o0` NTSC vertical blend | `NTSC_VERTICAL_COMB(~status[32])` |
| 1..2 | `P3o12` Disk drive sound | `status[34:33]` |
| 3 | `P3o3` Disk LED overlay | `~status[35]` |
| 4..6 | `P3o46` Analog X center | `x_center(status[38:36])` |
| 7 | `P3o7` Joystick mode | `relative_mode(status[39])` |
| 8..9 | `P1o89` Keypad visibility | `status[41:40]` |
| 10 | `P1oA` Virtual keyboard | `status[42]` |
| 11 | `P3oB` Joystick to keys (joy-to-key enable) | `JOY_TO_KEY_EN(status[43])` — new 2026-09-01 |

File slots (ioctl index): 0/2 = NIB (S0/S2), 1 = video ROM `.bin` (P1F1),
2 = `.a2p` palette (FC2), **3 = joy map `.jkm` (P3F3, new 2026-09-01)**.

## 3. Bugs found in newbase09 (2026-09-01) and fixes

Both were OSD bit collisions — the menu has no way to tell you two options
share a bit; it just flips the shared bit.

**Warning 10027 (vga_controller.v, TAD feed):** `seam_valid_window[? 5 : 7]`
— Quartus sizes the conditional index to 3 bits, which cannot address the
9-deep window. Fixed with an explicit `wire [3:0] tad_feed_idx` (declared at
module scope — `wire` is illegal inside an always block). Introduced by
`a35c735`, present in newbase09.

**Bug 1 — "Sharp RGB (fill)" toggled Scandoubler Fx.**
`P2O9` (fill) and `P2O9B` (Scandoubler Fx, bits 9-11) shared bit 9.
Turning fill On/Off flipped the Fx LSB (None ↔ HQ2x).
**Fix:** fill moved to bit 3 (`P2O3`, `SEAM_RUN_FILL(~status[3])`) — the
only free single bits in the main word after the H-shift removal are 1, 2
and 3 (bit 4 = Color sharpness, 5 = CPU, 6 = Analog X/Y, 7+ all taken).

**Bug 2 — switching Color sharpness to Composite shifted the image left;
"H shift" moved it further left.**
The H-shift feature (added in commit `a35c735`) connected
`HSHIFT(status[4:1])` — a 4-bit value whose **bit 4 is the Color sharpness
option** and whose bits 1..2 are the H-shift option (bit 3 unused). So the
rendered content delay changed by 8 samples every time Color sharpness was
toggled, and the "H shift" option (itself mis-declared as `O1234` = range
1..2 only, i.e. a 4-position option) added 0-3 more.
**Fix (per user decision): H shift removed entirely** — reverted the
HSHIFT-only parts of `a35c735` (the RGB-fill/`SEAM_RUN_FILL` feature stays):
- `Apple-II.sv`: removed `P2O1234` line and `.HSHIFT(status[4:1])`
- `rtl/apple2_top.vhd`: removed `HSHIFT` entity port, component port, map
- `rtl/vga_controller.v`: removed the 15-stage `hshift_pipe` delay + mux +
  `hsel_*` taps; seam window and `seam_vbl_d`/`seam_color_mode_d` fed from
  `raw_*` again (pre-`a35c735` behavior)

If horizontal positioning is ever needed again: give it a dedicated free
range (bits 1..2 are free in the main word; the extended word is almost
empty) and do **not** reuse a bit that another option owns.

## 4. joy_to_key port status (2026-09-01)

Feature developed and Verilator-verified in this repo
(`JOY_TO_KEY_PLAN.md`, `JOY_TO_KEY_PROGRESS.md`); ported into the newsdee
Quartus project the same day:

- `rtl/joy_to_key.v` copied into newsdee; `rtl/keyboard.v` synced
  (byte-identical content; newsdee copy kept LF EOLs per repo convention)
- `rtl/apple2_top.vhd`: VHDL `component joy_to_key` + gated instantiation
  (CLK_14M, `reset_cold`, `enable='1'`, existing `joy` + `ioctl` buses),
  gated `joy_key_code/joy_key_press` on the `keyboard` component/instantiation
- `files.qip` + `Apple-II.qsf` source section: `rtl/joy_to_key.v` registered
- `Apple-II.qsf`: `VERILOG_MACRO "JOY_TO_KEY=1"`
- `Apple-II.sv` CONF_STR: `P3F3,JKM,Load Joy Map;` (file slot 3)

- **Runtime enable via OSD:** `P3oB,Joystick to keys,Off,On;` →
  `JOY_TO_KEY_EN(status[43])` → `enable` port of `joy_to_key` (was tied to 1).

**Quartus 17.0.2 compatibility fixes** (found on first compile, 2026-09-01):
- Quartus 17 does **not** process Verilog-style `` `ifdef ``/`` `endif ``
  directives in **VHDL** files (Error 10500 on every backtick line). The
  `joy_to_key` wiring in `apple2_top.vhd` is therefore **unconditional**;
  the `JOY_TO_KEY` macro in `Apple-II.qsf` must stay defined, because the
  Verilog `keyboard` module only has the `joy_key_*` ports when the macro is
  on (the VHDL component declaration lists them unconditionally).
- Quartus 17's Verilog parser does **not** accept the SystemVerilog
  `'{...}` unpacked-array assignment pattern (Error 10170 in
  `joy_to_key.v`). The default IJKM+UO table is now written as explicit
  `joy_map[i] <= 8'hXX` assignments in the reset branch. The newsdee copy of
  `joy_to_key.v` therefore diverges slightly from this repo's copy (which
  still uses `'{...}` and is Verilator-only).

Pending: user-run Quartus compile (validates mixed-language binding + macro),
then hardware test of joystick→key (with OSD "Joystick to keys" set to On).

## 5. Open issues / follow-ups

- The main status word is nearly full (free: bits 1, 2). New options should
  go in the extended word (lowercase `o`, bits 11..31 free) or reuse an
  existing multi-bit option's range.
- `P2o0` NTSC vertical blend declares char bit 0 but the core reads
  `status[32]` (extended-word bit 0) — consistent per §1.3, but the `o0`
  declaration is confusing since main-word bit 0 is R0; consider renaming to
  a free extended bit later.
- joy_to_key: runtime OSD `enable` toggle and `.jkm` profile files are
  still future work (see `JOY_TO_KEY_PLAN.md` §9).
