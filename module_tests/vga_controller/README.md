# vga_controller equivalence — TEST PLAN (not yet implemented)

Black-box differential test: Verilog `rtl/vga_controller.v` must behave
identically, cycle for cycle, to golden VHDL
`../Apple-II_MiSTer_newsdee/rtl/vga_controller.vhd`.

Status: **PLANNED**. No files exist yet besides this plan. Implement by
copying the `disk_ii/` structure (TBs + `run_equivalence.ps1` + `build/`).

## What the module is

VGA line-doubler + artifact-colorizer (instantiated as `tv:` in
`apple2_top.vhd`/`apple2_top.v`): palette-encodes Apple II video via a 6-bit
shift register and hcount-rotated LUT, handles 4 SCREEN_MODEs x 4
COLOR_PALETTEs, GRAY_SEAM_FIX, NTSC_VERTICAL_COMB (luma/chroma vertical comb
with a one-line RGB history RAM), generates VGA HS/VS/HBL/VBL + RGB, and has an
ioctl custom-palette download state machine (4 data beats per color x 16
colors, selected by `ioctl_index = 8'h02`).

- Clock: `CLK_14M`, **no reset port**. Initial state is defined only by the
  stimulus. VHDL signals start as U; Verilog regs start at 0. The power-up
  preamble below makes the first HBL falling edge clean `hcount`/`vcount`;
  early-cycle metavalues are skipped and counted (rule 5), never mismatches.
- No ROM/spram dependency -> no GHDL shim needed on either side.

## Pre-implementation checks

1. Use `rtl/vga_controller.v` in the Verilog repo — NOT the stale copy under
   `rtl/newrtl/`. Confirm it is the file registered in `files.qip`/
   `Apple-II.qsf`.
2. Port list must match the golden entity exactly (the `tv:` map in
   `apple2_top.vhd` is the reference), including `ioctl_addr` which is unused
   by the logic on both sides (candidate has a lint-silencer wire for it).
3. For interpreting finding #2 below, record what the real MiSTer host sends as
   the 4th palette byte (check `Apple-II.sv` config-string / custom A2P
   palette download handling in both wrappers).

## Known risks the stimulus MUST expose

1. **Power-up metavalues.** VHDL `shift_reg`/`hcount`/`last_hbl`/windows start
   U; Verilog starts 0. Handled by preamble + rule-5 skipping; gate bounds
   `ignored_metavalues`.
2. **Palette download beat timing (expected finding).** Traced manually
   2026-08-29: with beats d0..d3 per color, golden's final buffer value is
   {d0,d1,d2} (buffer write at beat 4 samples the fully assembled
   `palette_rgb_in`); the candidate also writes the buffer at beat 4 but with
   `{old[23:8], ioctl_data}` = {d0,d1,**d3**}. If d3 != d2, the B byte of every
   custom palette entry differs after download. The P3 stimulus uses d3 = 0x5A
   (!= d2 for all colors) to expose this deliberately. Per rule 1: report as
   first divergence, do not fix either side.
3. **`ioctl_wait`.** Golden is U until the first download beat (assigned only
   inside the download branch), then 0; candidate holds 0 always. Metavalues
   skipped; gate bounds the count.
4. **14-stage `timing_active_delay` chain.** VHDL enters at index 13 / exits at
   0; Verilog enters at bit 0 / exits at bit 13. Manual derivation says both
   yield `seam_timing_active = raw_active(n-15)` — the sim must confirm it;
   any off-by-one shows up immediately as a shifted `VGA_HBL` edge.
5. **Signed division in the comb filter.** `(cur - luma + prev - prev_luma)/2`
   on possibly-negative values: VHDL integer `/` and Verilog signed integer
   `/` both truncate toward zero — include saturated chroma cases (pure red vs
   pure blue adjacent lines) to exercise negative-odd dividends.

## Stimulus (identical deterministic schedule in both TBs; no randomness)

Line geometry (TB-defined, identical both sides): each Apple line = 912 cycles:
HBL=1 for cycles 0..351, HBL=0 for cycles 352..911 (`hcount` counts from the
HBL falling edge; active window = hcount 0..559). VIDEO is a hardcoded
deterministic function V(line, c) — same table in both TBs.

- **P0 — preamble (2 lines):** HBL=1, VBL=1, VIDEO=0, all controls at default
  (SM=00, CP=00, GSF=0, NVC=0). Cleans counters; metavalues skipped.
- **P1 — frame, defaults (61 lines):** 40 VBL lines (extended blanking: forces
  `vcount` to 33..36 so `VGA_VS` asserts and deasserts) + 8 active lines +
  5 VBL lines (realistic short blanking: VS must NOT re-assert) + 8 active
  lines. Active-line VIDEO mix (hardcoded per line): >=2 fully alternating
  lines, >=3 periodic-color lines with different bit phases (LUT rotation
  coverage across all hcount mod 4 classes), 1 all-1s line, 1 all-0s line,
  >=1 monochrome-dot line (COLOR_LINE=0), >=1 line with short '01'/'10' seam
  islands in a mono field (GRAY_SEAM path).
- **P2 — control sweep:**
  - All 16 {SM,CP} combinations x 4 lines each (1 COLOR_LINE=0 line + 3 color
    lines) = 64 lines.
  - GSF=1: 6 lines at SM=00/CP=00 and 6 lines at SM=01/CP=01.
  - NVC=1: one full two-segment sequence (4 VBL + 8 active + 5 VBL + 8 active)
    at SM=00/CP=00 (comb active on segment 2 via `line_valid_q`), plus 4
    active lines at SM=01/CP=00 (color_mode_q=0 -> comb must bypass; negative
    test). Include adjacent pure-red/pure-blue lines to force negative-odd
    chroma dividends (risk 5).
- **P3 — custom palette download (CP=11, GSF=0):** ioctl_download=1,
  ioctl_index=8'h02, 64 beats: color i gets d0=i*17+1, d1=i*13+2, d2=i*11+3,
  d3=0x5A. Deassert download; trace the boundary cycle (golden updates
  CURRENT_COLx from BUFFER on the first non-download cycle). Then 8 active
  lines with periodic patterns hitting all 16 LUT entries under CP=11 so each
  downloaded color must appear on VGA RGB.

Scale: ~160k rows total (~3-4 MB CSV); comparable to timing_generator's run.

## Trace schema (both TBs, sampled at posedge + 1 ns)

```
CYCLE,VIDEO,HBL,VBL,SM,CP,GSF,NVC,IOCTL_DL,IOCTL_IDX,IOCTL_WR,IOCTL_DATA,VGA_HS,VGA_VS,VGA_HBL,VGA_VBL,VGA_R,VGA_G,VGA_B,IOCTL_WAIT
```

Hex; IOCTL_IDX = 2 digits, VGA_R/G/B = 2 digits each. Inputs traced so the
comparator can annotate divergence context (e.g. "during download beat 4 of
color i").

## Coverage gates (runner must fail without them)

1. `VGA_HS` rising edges >= 200 (line timing actually ran).
2. `VGA_VS` high for >= 1 line and back low (extended blanking exercised;
   proves the vcount=33/36 path on both sides).
3. Distinct {SM,CP} pairs observed >= 16.
4. Active cycles with GSF=1 >= 560*2; active cycles with NVC=1 and SM=00 >=
   560*8 (comb segment present); active cycles with NVC=1 and SM=01 >= 560
   (bypass case).
5. Distinct `VGA_R` values >= 24 (palette variety; catches all-black output).
6. Post-download: distinct {R,G,B} triples matching the 16 downloaded colors >=
   12 (custom palette path works end-to-end). Note: if risk 2 fires, the first
   divergence is reported before gates are evaluated.
7. COLOR_LINE=0 active lines >= 4 (monochrome path).
8. `ignored_metavalues` <= 200 (power-up + ioctl_wait only; if much larger,
   something else is unclean at t=0 — investigate before trusting the pass).

## Runner contract

Standard shape (`disk_ii/run_equivalence.ps1` pattern), fixed tool paths,
`-CompareOnly` supported. Ends with:

```
VGA_CONTROLLER EQUIVALENCE PASS rows=<n> fields=<n> ignored_metavalues=<n> hs_edges=<n> vs_pulses=1 combos=16 dl_colors=16
```

or a terminating error naming the first divergence (cycle, column, expected
VHDL value vs actual Verilog value, plus the input context for that cycle).
Given known risk 2, the expected first result is a `VGA_B` divergence in the
P3 post-download lines — a correct, reportable outcome, not a harness failure.

## How to run (once implemented)

```powershell
Set-Location E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer
.\module_tests\vga_controller\run_equivalence.ps1
.\module_tests\vga_controller\run_equivalence.ps1 -CompareOnly
```
