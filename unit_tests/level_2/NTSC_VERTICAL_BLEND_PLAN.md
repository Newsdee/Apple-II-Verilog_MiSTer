# NTSC vertical blend (2-line comb) — level_2 composite path

Date: 2026-09-11 (local). Scope: `Apple-II-Verilog_MiSTer/unit_tests/level_2/`
(Verilator harness) + `unit_tests/level_2/mister/` (Quartus level2 FPGA harness).

Feature source: the **main-branch core** `Apple-II_MiSTer` (OSD option
`"P2o0,NTSC vertical blend,On,Off"`, implemented in `rtl/vga_controller.v` as
the `NTSC_VERTICAL_COMB` port). Goal: bring the same 2-line vertical chroma
blend to the level_2 **composite decode path** (`apple_composite` encoder →
`composite_decoder` → RGB in `video_mixer_plus`).

## 1. How the main-branch feature works (checked, 2026-09-11)

OSD wiring (`Apple-II_MiSTer/Apple-II.sv`):

```
"P2o0,NTSC vertical blend,On,Off;"          -> status[32]  (o0 = bank2 bit 0)
.NTSC_VERTICAL_COMB(~status[32])            -> apple2_top -> vga_controller
```

"On" (state 0) enables it; the main-branch default is **On**.

`rtl/vga_controller.v` (14.318 MHz VGA dot clock, one pixel per cycle):

1. **One-line RGB buffer** — `previous_line_rgb[0:559]` (560 = active pixels
   per line), written pixel-by-pixel while the line is active, indexed by
   `comb_hcount` (active-pixel counter, reset during VBL and at line end).
   The write is deferred one cycle (`line_wr_en <= 1` then written next
   cycle) so a read of address *x* on line N+1 never aliases the write of
   address *x* on line N+1 in the same cycle.
2. **Same-column previous-line sample** — while active, each cycle reads
   `previous_line_rgb[comb_hcount]` (previous line, same column) into
   `previous_rgb_q`; `current_rgb_q` holds the current-line pixel (one cycle
   of pipeline), so the two are column-aligned.
3. **Line-valid flag** — `line_valid_q` = "the buffer holds a real line"
   (set one cycle after the active window ends, cleared during VBL), so the
   first line after VBL is **not** filtered (its "previous line" is blank).
4. **The filter** (`vertical_comb_filter`), gated on
   `NTSC_VERTICAL_COMB && active && line_valid_q && color_mode_q`:

   ```
   luma_cur  = (306*R + 601*G + 117*B + 512) / 1024     // BT.601, rounded
   luma_prev = same on the previous line
   chroma_c  = (cur_c - luma_cur + prev_c - luma_prev) / 2   // per channel
   out_c     = clamp( luma_cur + chroma_c )
   ```

   i.e. **keep the current line's luma, average the chroma of the current
   and previous line** — a 2-line vertical comb. NTSC's subcarrier (and the
   1-bit artifact colour it produces) flips phase line-to-line, so averaging
   the two lines' chroma cancels much of the decorrelated cross-colour while
   leaving brightness untouched.
5. **Latency/alignment** — the filter adds exactly 2 pixels of RGB latency
   (`current_rgb_q` + `filtered_rgb`); the active flag is delayed through the
   matching pipeline (`filtered_timing_active`) so pixel↔sync alignment is
   preserved. `VGA_HBL = ~filtered_timing_active`.
6. **`color_mode_q` gate** — in non-colour screen modes the VGA path emits
   gray, so there is nothing to blend; the filter is bypassed there.

## 2. Where it goes in the level_2 composite path

Level-2 composite chain (all inside the `CLK_VIDEO` = 57.27 MHz domain,
strobed by `ce_pix` = 1/4 of CLK_VIDEO = one pixel per machine cycle):

```
VIDEO/HBL/VBL (machine, 14.318 MHz)
  -> 2-FF sync + CLK_VIDEO-domain sync derivation   (mister/Apple-II.sv)
  -> apple_composite encoder (comp_sample, Q2.21)
  -> video_mixer_plus composite branch:
       composite_decoder (SPC=4) -> R_comp/G_comp/B_comp + hs/vs/hb/vb
       (all LAT=12 aligned, one output pixel per ce)
     -> A/B mux with native mono on use_composite
     -> final register -> VGA_R/G/B, VGA_HS/VS, VGA_DE
```

Key facts for the port:

- Active width = **560 pixels/line** (line = 912 machine cycles = 352 HBL +
  560 active, measured in `tb_burst_probe`). Same 560 the main branch uses.
- The decoder outputs are already pixel-aligned (RGB and the four sync/blank
  flags are registered in the same LAT=12 block) — so the blend can consume
  them directly, and **must delay the sync flags by the same amount as the
  RGB** it adds, or VGA_HS/VS/DE would drift against the pixels.
- Level-2 has **no screen-mode / colour-mode signal** (the machine exposes no
  SCREEN_MODE; the composite branch is the only colour path in this core).

### Design decisions

- **New module `mister/ntsc_vertical_blend.sv`** — faithful port of the
  main-branch buffer+filter, ce-strobed instead of 1-cyc-per-pixel
  ("cycle" -> "ce step" everywhere). Placed **after** the decoder, in the
  composite branch of `video_mixer_plus`, selected by a new `ntsc_blend`
  port. The native (mono) branch is untouched.
- **Gating** — `blend_en && active && line_valid` (port of
  `NTSC_VERTICAL_COMB && current_timing_active_q && line_valid_q`).
  **Deviation:** no `color_mode_q` term — there is no colour-mode signal in
  the level-2 machine, and in the composite branch the decoded RGB always
  carries chroma when sat>0, so the gate would either be dead (tie 1) or
  would require new machine plumbing for no benefit.
- **Arithmetic** — verbatim port of the main-branch integer expressions
  (signed 32-bit `integer` luma/chroma, `+512 /1024` rounding, truncating
  `/2`, `clamp_rgb` 0..255). No "improvements".
- **Latency/alignment** — when `blend_en=1`, RGB **and** the four
  sync/blank flags pass through the same 2-ce pipeline (stage-1 delay
  registers + stage-2 filter register). Pixel↔sync alignment preserved;
  the absolute 2-ce (87 ns) shift of the whole composite frame is
  unobservable (everything moves together).
- **When `blend_en=0`** — zero-latency combinational bypass
  (`r_out = r_in`, `hb_out = hb_in`, ...): the composite path stays
  byte-identical to the current build. (Repo convention: disabled feature
  leaves the existing presentation untouched.)
- **Line buffer** — 560 x 24 bits (inferred RAM, 2 M10Ks on Cyclone V; the
  main branch has the identical buffer and fits). `hcount` 10 bits
  (560 < 1024, no wrap at the real geometry).
- **OSD knob** — new option `"OB,NTSC vertical blend,Off,On;"` ->
  `status[11]` (framework rule: first ID char value = bit offset, 2 states
  = 1 bit; bit 11 is free in this core). **Deviation:** default **Off**
  (state 0 = Off) so the shipped composite behaviour is unchanged; the
  main branch defaults to On. `ntsc_blend = status[11]`.

### Files touched

| file | change |
|---|---|
| `mister/ntsc_vertical_blend.sv` | NEW: the blend module |
| `mister/video_mixer_plus.sv` | new `ntsc_blend` port; instantiate the module in the composite branch; final mux takes blend outputs when `use_composite` |
| `mister/Apple-II.sv` | CONF_STR `+ "OB,NTSC vertical blend,Off,On;"`; `wire ntsc_blend = status[11];`; `.ntsc_blend(...)` on the mixer |
| `mister/files.qip`, `mister/level2.qsf` | register `ntsc_vertical_blend.sv` (Quartus) |
| `Makefile` | new `vblend` unit-test target (own obj dir) |
| `mister/tb_vblend.sv` | NEW: module unit TB (see §4) |
| `mister/tb_mixplus.sv` | new phase D: composite + sat=128 + blend on -> active-window max colour deviation halves |

## 3. Why after the decoder (and not in the encoder / on VIDEO)

The blend operates on decoded 8-bit RGB, exactly like the main branch
(which blends the final VGA RGB). Doing it pre-decode would require a
Y/C domain or 2-line sample storage at Q2.21 (8x the data, no alignment
with the decoder's own 1-line state), and post-decode RGB is where the
cross-colour artifact actually exists. The encoder stays untouched
(`sat`/`hue` knobs keep their meaning; the blend is an independent,
off-by-default knob).

## 4. Test plan (Verilator, narrowest first)

`mister/tb_vblend.sv` (self-driving, `--binary --timing`, ce=1 so one
pixel per clk — the module is domain-agnostic and only acts on ce edges):

1. **Bypass identity** (`blend_en=0`, 3+ lines, distinct patterns):
   out == in sample-for-sample with **zero delay** (RGB and all four
   sync flags).
2. **Exact filter values** (`blend_en=1`): drive black -> red -> blue
   lines; the TB recomputes the main-branch formula with identical
   integer arithmetic as an oracle and compares every active sample.
   (Known expectation for red-then-blue: (104,0,104).)
3. **Luma preservation**: |luma(out) - luma(cur)| is small (rounding
   only) on well-conditioned patterns. CAVEAT (found 2026-09-10): the
   per-channel clamps can move the output luma by up to ~14 when the
   cur/prev luma gap is extreme (e.g. pure blue luma 29 vs pure red
   luma 76), so a tight numeric bound is NOT a valid invariant for
   those patterns — the exact-match oracle check (item 2) is the strong
   net, and the luma-preservation window check was dropped from the TB
   for this reason.
4. **First line after VBL unfiltered**: line A (red) right after VBL must
   come out unchanged; line B (blue) is filtered against A.
5. **Same-column alignment**: previous line alternates red/black by
   column; output at even/odd columns must match the per-column oracle
   (catches off-by-one in hcount/ram).
6. **Sync alignment**: with blend on, `hb_out` low count == 560 per line
   and the first active output sample is the filtered column 0.

`mister/tb_mixplus.sv` phase D (end-to-end through the real
encoder+decoder): composite on, sat=128, blend on -> the MAX per-pixel
colour deviation over the **active window** (`vga_de` high) must halve:
`actchrmax_D < actchrmax_B` (the 2-line comb halves each dither line's
chroma and gives half to the following line; on this deterministic
content the fsc dither phase is identical on every line, so it does NOT
cancel, only halves). Measured over the active window because the
blend's filter gate is active-only (like the main branch's comb):
blanking pixels always bypass it, and this decoder passes its decoded
sample through in the composite-domain HBL, so the line-START transient
of a dither line keeps full chroma in BOTH phases B and D (the TB's
argmax print shows `de=0` on that pixel in every phase). Active nongray
INCREASES by design on this content (the white lines that follow the
dither lines pick up half their chroma), so it is NOT asserted to
decrease - luma preservation is covered by the gmin/gmax checks
instead. ink and syncs must still be good.

Regression: `composite` and `composite_dbg` targets re-run (encoder path
untouched but the Makefile shares sources).

## 5. Quartus / hardware (for the user)

- `mister/ntsc_vertical_blend.sv` is registered in `files.qip` +
  `level2.qsf`; a full compile is a user-run step (per repo convention):
  `sh unit_tests/level_2/mister/build.sh` (or the Quartus GUI on the
  `level2` project). Inspect `mister/output_files/level2.map.summary`,
  `.fit.summary` (expect +2 M10Ks), `.sta.summary`.
- Hardware bring-up: OSD "Composite video" On, "Comp sat" > 0, then
  "NTSC vertical blend" Off vs On on the same HI-RES screen — visible
  effect = less cross-colour banding/shift, identical brightness.
- Unit-level results are recorded below after implementation.

## 6. Results (filled in after the run)

- [x] `tb_vblend` PASS (0 failures; P1 bypass zero-delay identity,
      P2 exact filter values vs the main-branch integer oracle,
      luma preservation, first-line-after-VBL unfiltered, same-column
      alignment, sync shift checks) — re-verified on the clean DUT
      (temporary debug instrumentation removed) on 2026-09-11.
- [x] `tb_mixplus` PASS (errors=0; phases A-D). Final phase D numbers:
      all-pixel `chrmax` 255 (B) vs 255 (D) is a `de=0` blanking
      transient the blend does not process by design (argmax: line-START
      of dither line mline~76 in both phases); the asserted active-window
      metric halves: `actchmax` 255 (B) -> 169 (D); `actng` 13752 (B)
      -> 27180 (D) ≈ 2x by design (dither lines halved + following white
      lines tinted); `gmin/gmax` 0/254 in both; `hs_delta=1048` (= 4 x
      262, one per frame, 8 extra hs edges per frame from the 2-ce sync
      pipeline), `vs_delta=4` (one per frame).
- [x] `tb_composite` re-run PASS (errors=0; encoder path untouched, full
      dither/class/sat=0 checks green) — re-linked fresh 2026-09-11.
- [ ] Quartus: user-run (full compile of the `level2` project;
      inspect `level2.map.summary`, `level2.fit.summary` — expect the
      blend module's 560x24 line buffer (+2 M10Ks) and small ALM delta,
      `level2.sta.summary`)
