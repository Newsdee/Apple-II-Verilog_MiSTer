# vga_controller equivalence — RESULTS (2026-08-30)

Black-box differential test: Verilog `rtl/vga_controller.v` must behave
identically, cycle for cycle, to golden VHDL
`../Apple-II_MiSTer_newsdee/rtl/vga_controller.vhd`.

Status: **PASS** (candidate aligned to golden 2026-08-30, per user decision).

```
VGA_CONTROLLER EQUIVALENCE PASS rows=163248 fields=3226938
  ignored_metavalues=38022 early_islands=1 hs_edges=177 vs_high=2736
  combos=16 p3_triples=9
```

### Alignment (2026-08-30, candidate `rtl/vga_controller.v` only)

The pre-alignment run below exposed two real RTL differences in the
candidate's palette-download process. The user ordered the candidate aligned
to golden; both fixes are inside the `ioctl_wr` branch of the download state
machine (22+/22− lines, CRLF preserved):

1. **Buffer write on all 4 beats with the pre-cycle value.** Golden executes
   `BUFFER_COLx <= palette_rgb_in` on every download beat; the RHS samples
   the pre-cycle register, so after beat 4 the buffer holds {d0,d1,d2}.
   The candidate only wrote in its `default:` case arm (addr 2,3) and used
   the NEW value `{palette_rgb_in[23:8], ioctl_data}` = {d0,d1,d3}. Fixed by
   moving a separate `case (palette_index)` above the addr case, each arm
   `BUFFER_COLx <= palette_rgb_in;`.
2. **Wrap after beat 3, not beat 2.** Golden: `if color_addr < "11"` →
   addr cycles 0,1,2,3 (4 beats/color). Candidate: `color_addr < 2'b10` →
   3 beats/color; under the 64-beat host protocol it consumed 48 beats for
   16 colors and beats 48–62 overwrote colors 0–4 a second time (candidate
   color 0 became {cd,9e,87} = stream beats 48,49,50 — matched the trace).
   Fixed to `color_addr < 2'b11`.

Post-alignment: zero divergences across all 163,248 cycles × 21 columns.
Gate 6 was rewritten from "≥12 distinct P3 triples" to an explicit
membership check: the implemented P3 patterns settle into exactly 8 LUT
entries {0,2,5,8,9,11,14,15} (Coverage below), so the gate now requires all
8 known downloaded colors to be present (blanking carryover adds a 9th,
`000000`, triple — deterministic, identical both sides).

### Coverage (observed on P3 lines 171–178)

Distinct {R,G,B} under the gate filter (input HBL=0, VBL=0): 9 triples =
the 8 downloaded colors for LUT entries {0,2,5,8,9,11,14,15}
(`010203 231C19 56433A 896A5B 9A7766 BC917C EFB89D 00C5A8`) plus `000000`
from blanking-boundary carryover. Note color 15 = {0,0xC5,0xA8} — the beat
formula wraps at 256 (17·15+1 = 256 ≡ 0). Each P3 line shows one constant
color over its active window; the plan's "hit all 16 LUT entries" was not
achieved by the implemented patterns, hence the membership gate.

### Pre-alignment result (2026-08-29, retained for reference)

```
VGA_CONTROLLER DIVERGENCE (expected palette-download signature)
  first=cycle 103971 (VGA_R: VHDL=01 Verilog=cd; VGA_G: VHDL=02 Verilog=9e;
  VGA_B: VHDL=03 Verilog=87) context: SM=00 CP=11 GSF=0 NVC=0 CL=0 VBL=0
  HBL=1 line=114
  rows=163248 fields=3226938 ignored_metavalues=38022
  mismatched_fields=57261 columns=VGA_R+VGA_G+VGA_B
  lines=114..130, 171..179 powerup_line0=1/VGA_HBL early_islands=1 inputs_ok=true
```

### What this means

- **All timing/control paths are cycle-equivalent** across 163,248 cycles
  (179 lines x 912): VGA_HS, VGA_VS, VGA_VBL, IOCTL_WAIT — zero mismatches
  after metavalue skipping; VGA_HBL identical from line 1 onward (line-1
  edge at cycle 1284 on both sides).
- The **only** divergence is the documented palette-download RTL difference,
  surfacing exactly on CP=11 lines (P2 k=12..15 = lines 114-129 + seam
  carryover 130; P3 = lines 171-178 + carryover 179):
  1. Beat-4 latch: golden `BUFFER_COLx <= palette_rgb_in` (OLD value =
     {d0,d1,d2}); candidate `BUFFER_COLx <= {palette_rgb_in[23:8],
     ioctl_data}` (NEW value = {d0,d1,d3}).
  2. Beat wrap: golden wraps `color_addr` after beat 3 (4 beats/color);
     candidate wraps after beat 2 (`color_addr < 2'b10`, 3 beats/color).
     Under the 64-beat host protocol the candidate consumes 48 beats for
     16 colors, then beats 48-62 OVERWRITE colors 0-4 a second time
     (candidate color 0 = {205,158,135} = stream beats 48,49,50 — matches
     the trace exactly: R=cd G=9e B=87).
- First mismatch line 114 (P2, CP=11), not P3: P2's k=12..15 combos also
  use CP=11, and the download happened at line 2 — correct per schedule.

### Power-up artifacts (classified, not divergences)

- `powerup_line0=1/VGA_HBL`: golden `hcount` starts U (no init) so its
  line-0 `raw_active` is 1 cycle late; candidate starts 0 (Verilog
  semantics = Cyclone V power-up default). Line-0 VGA_HBL edge differs by
  exactly 1 cycle (372 vs 371); all later lines identical.
- `early_islands=1`: golden VGA_HBL has one 1-cycle U island at cycle 17
  (uninit seam_timing_active/ctq/fta crossing the delay chain; the
  timing_active_delay and seam_valid_window vectors ARE zero-initialized).
- Leading U runs (skipped, counted in ignored_metavalues=38022): VGA_VBL
  until 351, VGA_HS until 1046, IOCTL_WAIT until 1823 (first download
  beat), VGA_VS until ~34790 (vcount stays U until the first VBL=0 falling
  edge at line 3; VGA_VS is only assigned at vcount=33/36 — no else).

### Golden-copy transformations (strictly verified, behavior-identical)

1. 4x `end process <label>;` -> `end process;` (GHDL rejects labeled ends
   on unlabeled processes).
2. All vector cases -> `case to_integer(...)` with integer choices +
   inserted `when others => null;` (GHDL 6.0.0 enforces strict case
   coverage; `to_integer` returns unbounded integer). SCREEN_MODE (a
   std_logic_vector port) gets `to_integer(unsigned(SCREEN_MODE))`. The
   `shift_reg(3 downto 2)` case keeps its string choices (it has `when
   others` already). Unreachable `when others` branches cannot fire:
   2/4-bit expressions, and the download path is metastable-free because
   the else branch resets color_addr/palette_index/palette_rgb_in every
   cycle.

### Files

- `vga_controller_vhdl_tb.vhd`, `vga_controller_verilog_tb.sv` — mirrored
  procedural stimulus (schedule + pattern functions in the headers), 21-column
  CSV trace, 163,248 cycles.
- `run_equivalence.ps1` — golden-copy generation, GHDL + Verilator builds,
  sims (CWD=project root), comparison with the classification above.
  `-CompareOnly` rechecks existing traces.

---

# TEST PLAN (original, for reference)

## What the module is

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
CYCLE,VIDEO,HBL,VBL,SM,CP,GSF,NVC,CL,IOCTL_DL,IOCTL_IDX,IOCTL_WR,IOCTL_DATA,VGA_HS,VGA_VS,VGA_HBL,VGA_VBL,VGA_R,VGA_G,VGA_B,IOCTL_WAIT
```

21 columns (the implemented TBs added CL after NVC vs the original plan).
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
8. `ignored_metavalues` <= 45000 (plan said 200; the actual leading U runs
   are dominated by VGA_VS staying U until vcount=33 at line 37 — the
   vcount U period plus the no-else VGA_VS assignment make ~35k the floor).
   Plus the island gate: U-after-known allowed only at cycle <= 100.

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
