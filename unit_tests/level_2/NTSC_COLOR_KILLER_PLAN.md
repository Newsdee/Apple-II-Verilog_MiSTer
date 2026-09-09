# Apple II "color killer" — level_2 composite path (plan)

Status: PLANNING (2026-09-11). No RTL written yet.
Scope: `unit_tests/level_2` composite path only. The main-branch core
(`Apple-II_MiSTer/`) is a read-only reference for this work.

Goal: implement the Apple II "color killer" — a feature that can disable
the 1-bit dither artifacting — in the level_2 composite decode branch,
following the established post-decoder pattern (composite_decoder ->
new module -> video_mixer_plus). Section 6 lists the decisions the user
must confirm before RTL starts.

## 1. Review of the original core's vga_* logic (the COLOR_LINE wire)

Checked in `Apple-II_MiSTer/rtl/` (2026-09-11).

### The wire: COLOR_LINE (a.k.a. GR1)

- `timing_generator.v`: `output reg GR1`, updated once per line at
  `RASRISE1` (line start, one machine cycle):
  `GR1 <= ~(TEXT_MODE | (V2 & V4 & MIXED_MODE));`
  (plus a savestate-restore path `ss_addr==6, ss_wdata[3]`). V2/V4 are
  vertical-counter bits, so the result is a fixed per-line pattern:
  never a color line in TEXT_MODE; otherwise a periodic mask of the
  line number.
- `apple2_top.v` forms `COLOR_LINE_CONTROL` from GR1 and drives
  `vga_controller.COLOR_LINE` (and `apple2.v` also exposes a
  `COLOR_LINE` output, driven from the timing generator).
- So COLOR_LINE is "the wire that defines the color line": it marks,
  per line, which interlace line type the 1-bit video is on.

### What it does inside vga_controller.v

- Line 347: `if (!COLOR_LINE)` — the non-color line: 2-color/white
  decode straight from `shift_reg[2]`. No dither color is produced on
  these lines; color is "switched off" by this branch.
- `else` (color line): if the raw video is settled
  (`shift_reg[0]==shift_reg[4] && shift_reg[5]==shift_reg[1]` = stable
  over a subcarrier period) -> full 16-color palette decode of the
  4-bit dither; while dithering -> coarse 4-color decode.
- Line 421: `raw_settled <= (!COLOR_LINE) || (settled)` — non-color
  lines are always treated as settled (no dither to wait out).
- `raw_color_line` feeds the 8-line `seam_color_line_window` used by
  the gray-seam fix.

### The color killer itself: NOT in the original core

Searched `Apple-II_MiSTer/rtl/` + `Apple-II.sv` for a bus-address
decode of the killer address (any `$C054`-style compare, "kill"
signals): nothing. The original core implements COLOR_LINE (decode
phasing + seam logic) only; the CPU-triggered border color kill is not
ported there. In real hardware, a 6502 bus access to the magic address
(generally documented as $C054, read or write) during the horizontal
border pulses the color-kill line and suppresses the border's 1-bit
dither chroma for that line — the border renders as clean black.
Nothing in this repo's cores models that circuit yet; that is what this
plan adds.

### Relevance of COLOR_LINE to the killer

The killer's line bookkeeping is "per line, re-latched at each line
start". In the original core, COLOR_LINE/GR1 is the line-structure
reference (it is re-latched at the same line boundary). In the
level_2 composite path the subcarrier phase is column-stable on EVERY
line (912 cycles = 228 subcarrier cycles; the encoder header and the
mixplus content model both confirm the dither phase does not flip per
line), so the composite killer needs only the HBL line boundary for
alignment — not the GR1 pattern. COLOR_LINE would matter if we later
model real border color (a dithered border whose phase alternates with
the color line); see open question 1.

## 2. What "artifacting" is in the level_2 composite path

Established from the mixplus runs (2026-09-11):

- The encoder (`rtl/apple_composite.sv`) emits a FLAT border:
  `comp = ... : (hb) ? V_BLANK : (video ? V_WHITE : V_BLACK)` — the
  HBL region carries no chroma source at all (sync tip + generated
  burst only).
- The composite decoder (`sat=128`) applies 1-bit dither chroma to
  every level it decodes, including the flat border. Result: the
  decoded border carries dither chroma — mixplus phase B measured
  nongray=33358 total vs actng=13752 inside the active window, i.e.
  ~19.6k non-gray BORDER pixels.
- Display gating (`video_mixer_plus.sv`): the composite branch latches
  R/G/B for every ce pixel (no RGB blanking), but VGA_DE (hde/vde from
  `hb_blend`/`vb_blend`) is high only over the active window. The
  MiSTer display scans DE=1 pixels only, so the border dither is
  NOT SCANNED — it is invisible in the presented picture.
- What IS visible from the composite branch:
  1. the content dither color inside the active window (1-bit dither
     lines) — this is the picture's actual color, not an artifact;
  2. line-start/line-end chroma transients at the active-window edges
     (the decoder's chroma state coming out of HBL: the all-pixel
     chrmax=255 argmax blob sits at decoder-hb pixels
     mcyc~364/366, i.e. the last blank pixels right before the window
     and the fringe that bleeds into the first displayed pixels).

Consequence for the feature: a faithful border kill visibly removes the
line-edge chroma transients on killed lines (the visible part of the
"artifacting" in this model); the border dither itself is already
invisible (unscanned). If the goal is a large visible "disable
artifacting" effect in the picture, the kill must extend into the
active window (a B&W mode) — that is variant (B) in open question 1.

## 3. Design (default: faithful border kill, variant A)

### 3.1 Trigger detection (machine domain, in the wrapper)

`mister/Apple-II.sv` already has everything at the top level of
`rtl/apple2.v` (checked: ports `ADDR` out, `CPU_WE` out, `HBL`/`VBL`
out, `COLOR_LINE` out — the wrapper connects `.ADDR(w_addr)`,
`.HBL(hbl)`, `.VBL(vbl)`, and leaves `.COLOR_LINE()` unconnected):

```systemverilog
parameter KILL_ADDR = 16'hC054;   // documented killer address (open #2)
wire kill_pulse = hbl & (w_addr == KILL_ADDR);   // CPU owns the bus in HBL
```

- No R/W gate by default: the real circuit is an address decode (any
  bus cycle) — open #3.
- ADDR is a continuously updated top-level output; the HBL gate is the
  real-circuit condition (CPU cycles during the border). CPU_WAIT is
  tied 0 in this wrapper, so no wait-state qualification is needed.

### 3.2 Per-line kill state (machine domain)

```systemverilog
reg kill_line_q = 1'b0;
always @(posedge clk_sys) begin
  if (machine_line_rise)  kill_line_q <= 1'b0;  // re-latch at each line start
  else if (kill_pulse)    kill_line_q <= 1'b1;
end
```

- A pulse during line N's border kills from the pulse to line end;
  demos trigger at border start, so the whole border is black —
  matches the real behavior for both early and late pulses.
- Alternative persistence (until the next COLOR_LINE boundary) is open #4.

### 3.3 Clock crossing

`kill_line_q` is line-stable (changes at most at line start + at the
pulse). Synchronize with the same 2-FF pattern the wrapper already uses
for `video_s1/s2` / `hbl_s1/s2` into CLK_VIDEO. The synced flag lags by
2 cycles, exactly like the existing `video_c`/`hbl_c` pipeline, so its
valid window aligns with the decoder-domain border.

### 3.4 Post-decoder chroma kill module (`mister/color_killer.sv`)

Same architecture as `ntsc_vertical_blend.sv` (post-decoder,
composite branch only):

- Ports: clk, ce, `color_kill` (synced line flag), r/g/b in, hb in
  (decoder `hb_out`), r/g/b out.
- Combinational datapath, ZERO latency: `kill=0` -> byte-identical
  pass-through (the off state must be the exact pre-feature composite
  path, like the blend's bypass).
- When `hb && color_kill`: force each channel to the preserved luma,
  `out_c = clamp(luma)`, with the same BT.601 luma expression + clamp
  the blend module uses (so the bright/contrast knobs' shifted black
  level is preserved — the killed border renders as the current black,
  not a hard 0).
- hb gate = the decoder's border, which includes the line-start blob
  and the back-porch burst region. Burst-region samples are unscanned
  (de=0) and the kill is post-decode, so the decoder's per-line burst
  re-lock/AGC is untouched. Active-window pixels are never modified
  (variant A is border-only).
- Insertion point in `video_mixer_plus.sv` composite branch:
  `comp_dec` -> `color_killer` -> `ntsc_vblend` -> final stage.
  (Order vs the blend is functionally irrelevant — disjoint pixel
  sets: killer touches hb pixels, blend touches active pixels only.)
- New module inputs for the mixer: one line-stable `color_kill` wire
  (the mixer already takes `ntsc_blend` the same way).

### 3.5 OSD (optional force knob)

- No knob is required for the real feature: the CPU trigger is always
  armed and is inert with ordinary software (nobody writes $C054 in
  the border).
- For a hardware A/B without a $C054 program, add an OSD option
  "Color kill force" on the next free status bit (check the full
  CONF_STR first; candidates: status[2/3/6/7/8/16/23]) that ORs into
  `kill_line_q`. Default Off. With it on, every line's border +
  line-edge fringe renders black — visible with any software when
  "Composite video" + "Comp sat" > 0. (Open #6: confirm.)

### 3.6 Files touched

| File | Change |
|---|---|
| `mister/color_killer.sv` | NEW: post-decoder chroma kill (pure LF) |
| `mister/Apple-II.sv` | detector + line register + 2-FF sync + (force knob) + new mixer port; connect the now-useful `.COLOR_LINE()` only if variant B is chosen |
| `mister/video_mixer_plus.sv` | new `color_kill` input + killer instance in the composite branch |
| `mister/tb_ckill.sv` | NEW: unit TB for the killer (pattern: tb_vblend.sv) |
| `mister/tb_mixplus.sv` | synthetic kill line + phase E assertions |
| `mister/files.qip` / `mister/level2.qsf` | register `color_killer.sv` (Quartus; CRLF-safe targeted edit) |
| `NTSC_COLOR_KILLER_PROGRESS.md` | NEW: progress doc (pattern of the blend pair) |

NOT touched: `rtl/apple2.v` (core — the needed ports already exist),
`rtl/apple_composite.sv` (encoder), `composite_decoder.sv` (vendored),
everything in the main-branch `Apple-II_MiSTer/` project, and all
unrelated in-flight changes.

## 4. Test plan (Verilator, narrowest first)

1. `tb_ckill` (new unit target, `make ckkill`):
   - kill=0: output byte-identical to input for all patterns
     (bypass guard).
   - kill=1, hb=1: black/gray/white lumas with dither chroma -> out
     gray(luma), chroma exactly zero; luma preserved through
     bright/contrast-equivalent offsets.
   - kill=1, hb=0 (active): untouched.
2. `tb_mixplus` phase E (synthetic machine; add a machine-domain
   `kill_line` driven on one chosen line K, fed through the same
   2-FF sync the wrapper gets):
   - line K decoder-hb pixels: nongray ~= 0 (all black at default
     bright/contrast).
   - line K active window: pixel-identical to the no-kill phase B run.
   - every other line: pixel-identical (per-line stats, like the blend
     phase checks).
   - visible-effect metric: nongray in the first 8 displayed pixels of
     line K < same pixels in the no-kill run (the edge-fringe removal).
   - (optional) kill pulse late in the border -> only the remainder of
     the border killed.
3. Full smoke (`tb_l2` / `run_l2`): no $C054 access in normal boot ->
   composite output byte-identical to the pre-feature build (the
   feature must be fully dormant by default) — regression guard.
4. Hardware (user-run, after Quartus): "Composite video" On,
   "Comp sat" > 0, "Color kill force" Off vs On on the same screen.
   Stretch: a real 6502 border routine (STA $C054 at border start) to
   exercise the authentic trigger.

## 5. Quartus / hardware (for the user)

- Register `mister/color_killer.sv` in `files.qip` and the source
  section of `level2.qsf` (CRLF preserved; verify with `eol_guard.sh`).
- Expect: < ~100 ALMs + ~4 FFs (16-bit comparator, 1 line flag, 2 sync
  FFs, 3x luma-mux in the comp branch), no M10Ks. The datapath change
  sits in the composite branch that already carries the decoder +
  blend and is timing-clean; verify slack in `level2.sta.summary`
  after the user's compile of `mister/level2.qsf`.

## 6. Open questions (confirm before RTL)

1. INTENT — which killer?
   (A) FAITHFUL border kill (default): CPU access at the magic address
       during the border kills that line's border chroma. In this
       core's composite presentation the border is unscanned, so the
       visible effect is removal of the line-edge chroma transients on
       killed lines (modest but authentic; §2).
   (B) COLOR-LINE / B&W kill: extend the kill into the active window
       (gate `hb` -> `1'b1` or COLOR_LINE-gated) so the 1-bit dither
       color of the picture itself is killed (large visible effect:
       the dither lines render gray). This is where the original
       core's COLOR_LINE wire comes in as the line reference.
   (C) Both: (A) as the always-on authentic behavior plus (B) as an
       OSD switch.
2. MAGIC ADDRESS: $C054 (the generally documented color-kill address;
   parameterized, trivially changeable). Confirm against the chosen
   hardware reference; some docs cite the $C054 area.
3. READ vs WRITE: any CPU cycle at the address (default, matches an
   address-decode circuit) vs read-only vs write-only.
4. PERSISTENCE: remainder of line N, cleared at line start (default)
   vs until the next COLOR_LINE/GR1 boundary (not believed authentic).
5. VBL GATE: none (default, faithful — the real decode is HBL-only
   and borders during VBL are unscanned anyway) vs suppress during VBL.
6. OSD FORCE KNOB: include it (default plan, Off by default) for
   hardware A/B — confirm, and pick the status-bit slot.
7. SCOPE: composite path only (default); the native VGA path of this
   core and the main-branch core are unchanged.

## 7. Line discipline / safety

- New files pure LF; `level2.qsf` is CRLF -> targeted perl edit only,
  then `git diff --check` + `eol_guard.sh`.
- No edits to vendored `composite_decoder.sv`, the encoder, the
  level_2 machine core, or the main-branch project.
- Preserve all unrelated in-flight user changes.

## 8. Results (filled in after the run)

(not started)
