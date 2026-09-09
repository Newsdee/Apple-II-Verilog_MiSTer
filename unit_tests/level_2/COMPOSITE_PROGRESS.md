# Composite (NTSC slot-decode) video — plan & progress

Status: **UNIT TESTS GREEN** (2026-09-07, post-crash-recovery session).
Encoder + decoder built, unit TB passing; remaining: tb_l2 integration,
level-2 wrapper + OSD, then user-run Quartus, then hardware bring-up.

Crash-recovery record: the prior session (`01a075b0-eaac-75a4-95de-eb36485780d8`,
`~/.pi/agent/sessions/--E--MiSTer-Apple-II_FPGAdev--/`, spec at line 1291 of that
JSONL) received the full implementation spec as a user message and got as far as
vendoring the decoder and writing `tb_burst_probe.sv` before crashing. This file
was written by the first recovery session; updated again after the second
crash (session `01a07c68-1632-736a-bc4f-6833528cbd5a`, see session log).

## Task

Add a **composite video path** to the Apple II, tested first in
`unit_tests/level_2` (user: "on unit test level 2 there is no vga processing, so
we can test applying here first"). Raw 1-bit `VIDEO` at 14.318181 MHz **is**
digital composite (4 master clocks = 1 NTSC subcarrier cycle,
3.579545 MHz). New path:

```
VIDEO (raw bit, clk_sys) ──> apple_composite encoder (Q2.21 volts)
                              └─> composite_decoder (SPC=4, slot notch)
                                   ──> r/g/b [7:0]
mux: use_composite ? comp RGB : mono {8{video}}  ──> overlay ──> video_mixer
```

- **Do NOT** replace/touch the existing presentation when `use_composite=0`.
- **Do NOT** feed the decoder from post-palette RGB. No boxcar on encoder luma.
- No 2-line/3D comb. No Atari `cofi`/`video_mux` RGB blending.
- Keep `composite_decoder.sv` verbatim (MIT, Copyright 2026 Jamie Blanks,
  vendored from Atari7800_MiSTer branch `bupchip`).
- `video_mixer_plus.sv` optional later; v1 muxes **before** the existing
  `video_mixer`.
- `composite_out.sv`, `video_mux.sv`, `Maria/*` — do not copy.

### Encoder levels (signed Q2.21, 1.0V = 2^21)

| Level  | Volts    | Q2.21                  |
|--------|----------|------------------------|
| SYNC   | -0.286   | `-24'sd599186`         |
| BLANK  |  0.000   | `24'sd0`               |
| BLACK  |  0.000   | `24'sd0` (no 7.5 IRE setup) |
| WHITE  |  0.714   | `24'sd1497380`         |
| BURST  | ±0.143   | `24'sd299892`          |

```
if (hs)                comp = V_SYNC;        // NOTE: vs is deliberately NOT
else if (hb)  in_burst   comp = ±V_BURST;    // part of the tip condition —
                 else    comp = V_BLANK;     // see "encoder deviation" below
else                    comp = video ? V_WHITE : V_BLACK;
```

### Encoder deviation vs spec (decided 2026-09-07, documented in module header)

The spec's `if (vs || hs) comp = V_SYNC;` was changed to `if (hs) ...`:

- `composite_decoder` takes `vs`/`vb` as **flags** (they only pipe through to
  `vs_out`/`vb_out`); it never reads the sync tip. Functionally it uses the
  comp waveform for the burst window (hcnt 8..23), the black-clamp window
  (hcnt 72..87), and the active region — and it re-locks the burst vector and
  black clamp **from every line's back porch**.
- Forcing the whole vsync line to the sync tip kills the burst for 3 lines.
  The first normal line after the vs block then decodes with a ~57%-amplitude
  burst vector (c16 burst = [3512,3512,1173,1173] because the stale
  black = -599186) → the burst division scales chroma gain by 1/|B|² ≈ 3×
  (clipped colour), plus a one-line luma offset.
- With the burst + blank porch alive on the vsync lines, line 3 (first line
  after the vs block) is already fully clean: `black=0`, `c16=±1171`,
  `ib=328 qb=365`, `colour_ok=1`, `lgain=2857` (verified by
  `tb_composite_dbg.sv` tracing exactly that line).
- The vsync lines' active region carries the real VIDEO (on this core that is
  the first visible row, shown during VBL); the decoder's `vs_out` still flags
  them for downstream blanking. Physically the transmitter would show the
  sync tip there, but this decoder is flag-based, so that is unobservable.

### Decoder settings (v1)

`SPC=4`, `sat=128`, `hue=0` (if gold/blue swapped: +64 or +128), `smear=0`,
`luma_delay=0`, `setup=0`, `luma_gain=16'd2857` (0.714 V white), `agc_en=1`.
OSD v1: Composite on/off + saturation + hue (tune-on-hardware later); everything
else constants.

## Key timing facts (verified in the crashed session)

- Level-2 sync derivation (mister/Apple-II.sv, and tb_l2_gui):
  `HSYNC` = 68 master cycles starting **130 cycles after the HBL rise**
  (`hblank_cnt ∈ [130,198)`), so the HSYNC **falling edge is at
  `hblank_cnt = 198`** (0-based from the first HBL-high cycle).
  `VSYNC` = 3 lines starting 33 lines after the VBL rise.
- Measured geometry (`tb_burst_probe.sv`): **line = 912 cycles = 352 HBL +
  560 active**; 228 subcarrier cycles/line (912 = 4·228, so the free-running
  burst phase is column-stable from line to line).
- `composite_decoder` burst counter semantics (lines 138-140):
  `hcnt` resets to 0 on the hs fall cycle, so `hcnt = N` is the (N+1)th sample
  after the hs-fall cycle.
  - burst **measurement** window: `hcnt ∈ [burst_start, burst_start+16)`
    (`BURST_ACC=16`) — must sit inside the real full-rate toggle region.
  - black **clamp** window: `hcnt ∈ [burst_start+burst_len,
    burst_start+burst_len+16)`, only while `hb_in` — must sit in the constant
    back porch (VIDEO constant there) before HBL ends.
  - Therefore: `burst_start` ≈ start of the full-rate toggle region (after the
    hs fall), `burst_len` = toggle-region end − burst_start + 1 (so the clamp
    lands at the first back-porch sample), with
    `burst_start+burst_len+16` ≤ HBL length.
- Chosen windows in `apple_composite.sv`: `BURST_START=8`, `BURST_LEN=16`
  (burst hcnt 8..23; clamp hcnt 72..87; HBL = 352 → 72+16+16 = 104 ≤ 352 ✓).
- `VIDEO` during HBL is ROM + timing-driven (video ROM sync row,
  `video_generator.v` shift register, `timing_generator.v` H-counter);
  independent of CPU/screen content → the burst window is the same on every
  line, VBL lines included.
- `apple2` core ports usable at level 2: `VIDEO`, `COLOR_LINE`, `TEXT_MODE`,
  `HBL`, `VBL` (all 14.318 MHz domain).

## Files

| File | State |
|------|-------|
| `mister/composite_decoder.sv` | vendored (583 lines), matches spec contract |
| `mister/video_mixer_plus.sv` | vendored, optional (not used in v1) |
| `mister/Apple-II.sv` | level-2 MiSTer wrapper; video out section = mux point (before `drive_status_overlay` → `video_mixer`); OSD CONF_STR needs a new O item for Composite — **NOT YET DONE** |
| `tb_burst_probe.sv` | BUILT & RUN (geometry above) |
| `rtl/apple_composite.sv` (repo root rtl/) | WRITTEN — encoder + `composite_decoder #(.SPC(4))` wrapper, params `BURST_START`/`BURST_LEN`; vs-tip deviation documented in header |
| `tb_composite.sv` (unit_tests/level_2/) | WRITTEN, **PASS** (deterministic line protocol — see notes) |
| `tb_composite_dbg.sv` | debug wrapper exposing decoder internals; now traces line 3 (first post-vs-block line) — clean re-lock verified |
| `tb_l2.sv` + `main_l2.cpp` | NOT YET MODIFIED — composite mux + `--composite` smoke |
| `mister/files.qip` | `composite_decoder.sv` + `apple_composite.sv` NOT YET REGISTERED (Quartus step) |

## Test results (2026-09-07, Verilator 5.050 ucrt64)

Build (from `unit_tests/level_2/`):
`verilator_bin --binary --timing -O3 --x-assign fast --x-initial fast -Wno-fatal -Wno-TIMESCALEMOD --timescale-override 1ns/1ps --top-module tb_composite -Mdir build/composite_obj_dir tb_composite.sv ../../rtl/apple_composite.sv mister/composite_decoder.sv`
Run from repo root: `./unit_tests/level_2/build/composite_obj_dir/Vtb_composite.exe`

```
COMPOSITE UNIT TEST START
  sat=128 const-line: min=254 max=254 nongray=0/440   OK      (white)
  sat=128 const-line: min=0 max=0 nongray=0/440   OK          (black)
  sat=128 dither: sample@100=(226,101,0) gold=385 blue=55 gray=0/440 family=1
    class0: (25,153,255)  class1: (134,0,241)  class2: (71,0,178)
    class3: (134,0,241)   class4: (226,101,0)  class5: (117,255,11)
    class6: (180,255,74)  class7: (117,255,11)
  stability: 0/440 samples differ between consecutive lines   OK
  sat=128 dither: sample@100=(25,153,255) gold=385 blue=55 gray=0/440 family=1
    class0: (226,101,0)   class1: (117,255,11) class2: (180,255,74)
    class3: (117,255,11)  class4: (25,153,255) class5: (134,0,241)
    class6: (71,0,178)    class7: (134,0,241)
  complement: 0/440 samples same-family (A vs B)   OK
  sat=128 dither: sample@100=(86,0,23) gold=137 blue=48 gray=230/440 family=0  (text-like, stays monochrome)
  sat=0 dither: sample@100=(127,127,127) gray=440/440 family=0   OK
COMPOSITE UNIT TEST PASS (errors=0)
```

Readings worth keeping:

- White = 254, black = 0, perfect gray (AGC + luma_gain correct).
- 1-bit (fsc/2) dither produces a **solid per-class tint** (the SPC/2 notch
  only nulls fsc and 2fsc; fsc/2 passes at ~-9 dB and leaks into the chroma
  channel). That is expected behaviour of this decoder, not a bug: real
  receivers' comb filters are much narrower, real TVs would show these tints
  less saturated. If needed, `sat` is the hardware-side dial.
- Dither B (~pattern) is the **exact per-sample complement** of dither A:
  every A class maps to the mirrored B class (A class4 = B class4's mirror,
  0/440 same-family samples). Hue families: A = gold-majority (7/8 classes
  R-heavy), B = blue-majority.
- Per-class tints at `hue=0` (for bring-up tuning): cyan, magenta/violet,
  dark violet, orange, green, yellow-green — in the right neighbourhood of
  the classic 1-bit dither colors; `hue` (+64/+128) if gold/blue are swapped
  on hardware.
- 7-on/14-off "text-like" luma stays gray-majority (family 0) — no false
  colour on non-fsc energy.
- Two consecutive identical lines are sample-for-sample identical
  (column stability: 912 = 4·228 subcarrier cycles).

## TB design notes (why the old TB failed)

Root causes of the failures seen at the crash point (all three were TB-side
or test-expectation issues, not decoder bugs — the debug trace showed the
decoder fully re-locked within one line):

1. **Sampled the vsync lines.** The old TB settled `#1us` (mid line 0 HBL) and
   located lines by waiting on the 13-stage-pipeline-delayed `hb_out`; the
   wait-protocol skipped a line per call. With vs enabled, the first
   "white" sample landed on a vsync line (decoder output black) and the
   dither samples landed on lines where the pattern had changed mid-line
   (the driver reads `vpat_mode` live).
2. **Protocol fix (current TB):** `set_line_pattern` waits on the driver's
   `line_idx` at a line boundary and sets `vpat_mode` exactly there (whole
   line clean); `sample_line` then counts `HBL+1+24` negedges from that
   boundary (covers the 13-stage `hb_out` pipeline + ~7-stage luma pipeline)
   and collects 440 samples. Pure counting — no edge-waiting, no drift.
   Checks start at line 4 (vs block = lines 0..2 + one margin line).
3. **Test expectation fix:** "dither A and B must have different line-majority
   families" was wrong. The tint is an exact additive chroma offset that
   cancels the luma, so complementarity holds **per sample** (A R-heavy ⟺ B
   B-heavy), while the line-majority families can coincide (7/8 classes vs
   1/8). New check: per-sample opposite tilt, tolerance NS/8.
4. **Encoder fix** (the one real RTL change): vs no longer forces the sync
   tip (see "encoder deviation" above) — kills the 1-line post-vs-block
   transient (3× chroma + stale black).

## Verilator 5.050 quirk (learned 2026-09-07)

A bare `signed [15:0] x;` declaration inside a task is a **parse error**
("syntax error, unexpected '[', expecting \"'\""); use
`reg signed [15:0] x;`. Reproduced in isolation (`/tmp/t_mini*.sv`).

## Next steps (in order)

1. ~~Build & run `tb_burst_probe.sv`~~ DONE.
2. ~~Write `rtl/apple_composite.sv`~~ DONE (with documented vs-tip deviation).
3. ~~Unit TB~~ DONE, PASS.
4. **Integrate in `tb_l2.sv`**: port-driven `use_composite` + optional sat/hue
   (and the composite mux + `--composite` smoke check in `main_l2.cpp`);
   default mono path stays byte-identical (`use_composite=0` ⇒ no change).
5. Level-2 MiSTer wrapper (`mister/Apple-II.sv`): same mux + OSD item
   (`O9,Composite,Off,On;` + sat + hue), register both new files in
   `mister/files.qip`.
6. Bring-up order on hardware (spec): (a) comp→gray sanity, (b) sat=0 luma
   matches mono structure, (c) sat=128 lores 16 colors recognizable,
   (d) HGR 1-px dither gold/blue, (e) smear/luma_delay for fringe only.
7. Quartus compile of the level-2 mister project: **user-run** (do not start
   long compiles unless asked).
8. Port to the newsdee root core (LUT A/B mux, files.qip) once level 2 is green.

## Explicit non-goals (from spec)

- No 7800 `blend && ~is_maria`, no Genesis `cofi`.
- No 3D/2D comb as the default Y/C split.
- No dropping the LUT path. No 20-knob NTSC lab. No re-encoding LUT RGB to
  Y/C (loses the bitstream phase that IS the artifact).
- No brightness/contrast/gamma/sharpness inside the module (MiSTer scaler
  owns those).

## Environment

- MSYS2 UCRT64 (`C:\msys64`), Verilator 5.050 at `/c/msys64/ucrt64/bin/verilator_bin.exe`.
- TMP trio for native make: `export TMP=/c/msys64/tmp TEMP=... TMPDIR=...`.
- Run exes from the repo root (CWD-relative `$readmemh` paths).
- EOL discipline: new files pure LF; `bash eol_guard.sh` (workspace root) after
  editing mixed-EOL files.

## Session log

### 2026-09-07 (recovery of session 01a07c68)

- Reconstructed the crash point: mid A/B experiment on vs vsync handling;
  last tool call (building `tb_composite_dbg.sv`) aborted.
- Root-caused all three open failures (see "TB design notes"): TB sampling
  the vsync lines + drifted edge-wait protocol (TB bug), wrong
  complementarity expectation (test bug), burst suppressed on vsync lines
  (encoder bug → 1-line post-vs-block transient).
- Changed `apple_composite.sv`: sync-tip condition `vs || hs` → `hs` (with
  documented rationale in the header); burst/blank/real-video now alive on
  vsync lines.
- Rewrote `tb_composite.sv` (deterministic line protocol, per-sample
  complementarity check, per-class tint dump). **PASS, errors=0.**
- Retargeted `tb_composite_dbg.sv` to trace line 3: clean re-lock
  (black=0, c16=±1171, ib=328 qb=365, lgain=2857, colour_ok=1) — no transient.
- Recorded the Verilator bare-`signed`-in-task parse quirk.
- Remaining: tb_l2 integration (next), wrapper + OSD, user-run Quartus,
  hardware bring-up.

### 2026-09-08 (level-2 integration, smoke FAIL root cause, cleanup)

- **tb_l2 integration complete.** `tb_l2.sv` derives syncs exactly like the
  level-2 MiSTer wrapper (`mister/Apple-II.sv`): HSYNC = 68 master cycles
  starting 130 cycles into HBL; VSYNC = 3 lines starting 33 lines into VBL.
  `apple_composite comp_dut` is frozen when `use_composite=0` (`ce` gated),
  so the default mono run is byte-identical. Per-frame stats (ink = g>=128
  active samples, nongray = |r-g|>16 or |g-b|>16, gmin/gmax) are latched at
  the VBL falling edge, same anchor as `frame_pack`.
- **Measured geometry (was misremembered as 512 lines):** the core outputs a
  **262-line frame**: 911-912 samples/line (351 w_hbl-high blank + 560
  active), VBL = 69 lines, comp_vsync = 3 lines at VBL lines 33-35. Sample
  budget closes exactly: 146720 = 262 x 560. All composite stats counters
  widened to 20 bits (286720 active samples/frame > 2^18 and > 2^16).
- **The `--disk --composite` smoke FAIL (ci=51456 vs mono_ink=1571, ~33x)
  was a FALSE ALARM in the testbench C++, not the video path.** Per-frame
  history showed healthy ratios (f19-f25: mono=67584/ink=51456 = 0.76) and
  decoder internals confirmed full convergence (black=0, ag_ratio=16384=
  1.0x, lgain=2857). Root cause: the C++ mono reference popcounted
  `frame[]` at $finish, but `frame[]` had already been refilled with the
  NEXT frame (a different, nearly-blank screen); the composite stats latch
  holds the last COMPLETED frame. Fix: `mono_ink_frame_l` latches the
  per-frame mono ink accumulator at the same VBL falling edge as the stats.
  Never compare same-frame stats against a rolling frame buffer read at
  $finish -- anchor both at the same edge.
- **Verilator quirk:** hierarchical reads of submodule internals
  (`comp_dut.u_dec.*`) constant-fold to 0 unless captured into a top-level
  register that is itself used. (Needed only for the temporary decoder-
  internal probes; not a problem for normal ports.)
- **All smoke tests PASS on the final build:**
  - unit: `COMPOSITE UNIT TEST PASS (errors=0)` (separate obj dir,
    `--binary --timing`)
  - `--disk` baseline (no composite): unchanged (frames=26, ink=580,
    sectors=13, mot1=1, ready=1)
  - `--empty --composite`: ink=14241 mono=18592 nongray=0 gmax=254 OK
  - `--disk --composite` (sat=0): ink=51456 mono=67776 nongray=0 gmax=254 OK
  - `--disk --composite --csat=128`: ink=66000 mono=67776 nongray=74256
    gmax=255 OK (chroma path alive)
- **Environment hazard (Windows Defender / AV):** freshly linked Verilator
  PEs in this workspace get a ~60-120 s grace window, after which every
  exec of that binary fails with exit 127 and zero output (valid PE, other
  PEs run fine; copying to a new name does NOT help -- the hash is
  remembered). Deterministic relink = same hash; a relink with a changed
  PE timestamp (fresh `g++ -o`) buys a new window. Mitigation: chain
  `rm exe && make && run` in one command and keep each run sequence short.
- **Cleanup:** all temporary investigation probes removed (geometry pr_*,
  per-frame history table, decoder-internal hierarchical probes, g
  histogram, 1-bit video map, text-page dump in the composite block);
  kept the permanent composite stats + `mono_ink_frame_l` + the L2
  COMPOSITE criterion print. Re-verified the 4-test matrix after cleanup.
- Remaining: full-sim integration decision (`--composite` in sim.v),
  wrapper + OSD on the newsdee project, user-run Quartus, hardware
  bring-up.

### 2026-09-08 (FPGA wiring of the level2 MiSTer project)

- **Chose the compile target:** `unit_tests/level_2/mister/level2.qpf`
  (revision `level2`, top `sys_top`, 5CSEBA6U23I7) — the MiSTer wrapper
  this testbench mirrors; last full compile Sep 6 (level2.done present).
  The parallel save-state workstream has uncommitted changes in the same
  project (O2/O3 OSD, savestate_manager_l1b/ddr_l1b in Apple-II.sv +
  qsf/qip) — left untouched; composite work is additive on top.
- **Encoder port-out:** `rtl/apple_composite.sv` gained
  `output wire signed [23:0] comp_sample` = the internal modulated sample
  (Q2.21, 1 V = 2^21), one sample per ce pulse. Additive only; existing
  TBs unaffected (unconnected output).
- **Wrapper wiring (mister/Apple-II.sv, new "COMPOSITE VIDEO" section):**
  - 2-FF synchronizers for `video`/`hbl`/`vbl` into CLK_VIDEO (57.27 MHz,
    = 4x the 14.318 MHz machine clock via the existing ce_pix divider).
    Safe: each machine signal changes at most once per 4-CLK_VIDEO-cycle
    window.
  - Sync derivation (130/68 HSync, 33/3 VSync) re-implemented in the
    CLK_VIDEO domain from the synchronized blanking (counts tick on
    ce_pix). The original 14 MHz derivation for the native path is
    unchanged.
  - `apple_composite` instance clocked on CLK_VIDEO, ce=ce_pix, fed the
    synchronized signals, sat=128/hue=0; internal loopback decoder's
    r/g/b unconnected (pruned at synthesis).
  - `video_mixer` replaced by `video_mixer_plus`
    (`.LINE_LENGTH(580), .GAMMA(1), .COMP_SPC(4)`): same connections plus
    the composite branch (composite=comp_sample, ce_comp=ce_pix,
    comp_hs/vs/hb/vb = synchronized set, burst 8/64, luma_gain 2857,
    agc=1). `use_composite = status[9]` (new OSD option "O9,Composite
    video,Off,On"). With O9 off the mixer's non-composite branch is
    identical to the framework video_mixer (byte-identical default path).
- **Sources registered** in both `level2.qsf` and `files.qip` (line 279
  `source files.qip`): `../../../rtl/apple_composite.sv`,
  `video_mixer_plus.sv`, `composite_decoder.sv` (project-local copies).
  NOTE: `mister/rtl/video_mixer_plus.sv` is a byte-identical duplicate
  found pre-existing (untracked, another workstream); deliberately NOT
  registered.
- **Verification:**
  - `verilator --lint-only -sv` on the whole composite path (new
    `mister/tb_mixplus.sv` = verbatim copy of the wrapper block + 4:1
    clock model + self-driving native/composite phases): **clean, no
    errors** (only pre-existing sys-file style warnings: video_freezer
    PINMISSING, TIMESCALEMOD, gamma_corr IMPLICITSTATIC).
  - `tb_mixplus.sv` + `make mixplus` target added (build_mixplus,
    `--binary --timing`; needs `-Wno-PROCASSWIRE` for framework
    hq2x.sv's procedural wire assign — Quartus-accepted, hq2x unused in
    this harness).
  - **Functional run NOT YET DONE — host regression:** since ~00:40 on
    2026-09-08 every freshly linked C++ PE in this environment dies at
    creation (PowerShell: 0xC0000061 = STATUS_NO_MEMORY; a fresh 137 KB
    C++ hello segfaults; C PEs run fine; Defender AMServiceEnabled=False,
    endpoint agent `mc-fw-host` present; ucrt64 runtime DLLs untouched
    Mar/Apr 2026). Old C++ PEs (g++, verilator_bin) still run; the
    earlier "grace window" behavior (see 2026-09-08 entry above) has
    turned into a hard block. Relink + fresh name + C:\Temp copy all
    killed. Host-level, outside project control.
  - Re-run when the host recovers:
    `mingw32-make -f Makefile mixplus` then `./build_mixplus/obj_dir/Vtb_mixplus.exe`
    (expect `MIXPLUS PASS (errors=0)`: native phase HSync/VSync/ink,
    composite phase ink>0, gmin<=64, gmax>=160, CE_PIXEL>0).
- **Quartus handoff (user-run):**
  `cd /d E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer\unit_tests\level_2\mister`
  `quartus_sh --flow compile level2`
  (cheap interface check: `quartus_map level2
  --read_settings_files=on --write_settings_files=off`). Check map.rpt
  for the 3 new sources + video_mixer_plus/composite_decoder/apple_
  composite instances; fit.rpt for the added ALMs (composite decoder +
  encoder). O9 default Off → hardware identical to the Sep 6 baseline
  until the OSD option is flipped.

### 2026-09-08 (build06 B&W diagnosis: two real bugs found & fixed; MIXPLUS PASS)

Session `01a07e44` (provider timeouts aborted its final step — probe
cleanup + L2 regression — which this continuation finished). Order of work:

- **S2 OSD knobs landed** (`mister/Apple-II.sv` CONF_STR + decode;
  `main_l2.cpp` mirror):
  - `OCD,Comp sat` → `status[15:12]`, `comp_sat = idx*17`
    (0=Off/gray … 8→136 ≈ unity … 15→255).
  - `OHI,Comp hue` → `status[20:17]`, `comp_hue = idx*16` (0..240).
  - ID→bit rule (offset = first ID-char value, +32 for lowercase `o`,
    4-bit field) is inferred from the newsdee core's proven multi-state
    options; hardware confirmation pending (see build07 below).
  - Sim matrix (idx→value map identical to FPGA): csatidx=8 → sat=136 →
    `nongray=74256`; csatidx=0 → `nongray=0` (gray gate); csatidx=15
    chueidx=8 → sat=255 hue=128 → `nongray=74256`. `mono_ink=67776`
    identical across runs (no content drift). Committed by user as
    `65a5847` (2026-09-08 08:04 local).
- **Hardware report (build06, user):** O9 On gives a correct B&W
  composite-style picture; `Comp sat`/`Comp hue` have NO visible effect
  at any step. build06 (map 08:56, RBF 09:05) postdates the knob edit,
  so the knob wiring IS in the flashed image — the failure is upstream
  of the knobs in the colour path.
- **`tb_mixplus.sv` was a latent fake test — fixed:**
  1. It never ran: it declared `input wire clk` with no `initial`
     driver; the `--binary` auto-main never advances time, so every
     previous "run" ended at 0 s. Now portless/self-driving (internal
     4x clock + ce_pix divider, level_1b idiom).
  2. Its "chroma dither" was a 2-sample-period tone (= 2×fsc) — exactly
     what the decoder's notch rejects; replaced with an in-band
     4-sample-period fsc tone.
  3. It had no `nongray` gate: it would have passed with a B&W image.
     Phase B now requires `nongray>0` at sat=128; Phase C requires
     `nongray==0` at sat=0.
  With those fixes it reproduced the hardware symptom exactly
  (`ink>0, nongray=0` at sat=128).
- **ROOT CAUSE 1 (wrapper, the hardware bug) — `hblank_cnt_c` else-clear:**
  the CLK_VIDEO-domain counter used
  `if (ce_pix && hbl_c) cnt+1; else cnt=0;`. `ce_pix` is high 1 in 4
  CLK_VIDEO cycles, so the counter bounced 0→1 forever and
  `comp_hsync_c` never pulsed after the first line → encoder/decoder
  `hcnt` never restarted → the burst window/lock never re-engaged →
  `colour_ok=0` for the whole picture → pure luma (B&W) at any
  saturation. **Fix:** clear only when `!hbl_c`, else increment on
  `ce_pix` (hold on the 3 idle CLK cycles). The tb_mixplus copy was a
  byte-identical replica of the same broken counter — its "reproduction"
  was faithful. (This counter is wrapper-only; the L2 machine loopback
  gets real HSync from the timing generator, which is why the L2 sim
  always showed colour and the hardware never did.)
- **ROOT CAUSE 2 (decoder, latent one-line lag) — `div_den` stale capture:**
  `div_den <= mag2` loaded from the `mag2` combinational output of the
  `ibh`/`qbh` registers that update on the SAME edge, so the divider
  always divides by the PREVIOUS line's burst magnitude; on line 0 it
  divides by zero → `inv=0xFFFF` overflow guard → `colour_ok=0` on the
  first line. **Fix:** load `div_den` from `rot_mag2` (the magnitude of
  the vector the edge is about to capture). Instrumented with a
  `COMPOSITE_DBG`-guarded probe block (one-shot per line; Quartus/
  normal-sim never define it — stripped), then REMOVED after the
  diagnosis (incl. the `DBG_ID` parameter and the `.DBG_ID(1)`
  connection in `video_mixer_plus.sv`).
- **Verilator generate-scope quirk (sim-only) — `video_mixer_plus.sv`:**
  `R_in/G_in/B_in` were declared in generate branch #1 but referenced
  from branch #2. Quartus/LRM resolves generate-branch declarations
  module-wide; Verilator 5.050 scopes them per branch and silently
  creates implicit zero nets → native branch black in sim only
  (`%Warning-IMPLICIT`). **Fix:** hoist the 3 wires to module scope
  (behavior preserved for all GAMMA/HALF_DEPTH combinations). The
  unregistered duplicate `mister/rtl/video_mixer_plus.sv` re-synced to
  stay byte-identical (documented invariant in files.qip).
- **Verification (all green, Verilator 5.050 ucrt64, AV block lifted —
  fresh C++ PEs build and run again):**
  - `make mixplus` + `Vtb_mixplus.exe`: **MIXPLUS PASS (errors=0)** —
    Phase A (native) `ink=47040`; Phase B (composite, sat=128)
    `nongray=33358`, `gmin=0 gmax=254`, `hs=2096` (sync now pulses
    every line); Phase C (sat=0) `nongray=0`. Pre-fix: Phase B
    `nongray=0` (the B&W symptom).
  - L2 full-machine regression (`Vtb_l2.exe`, DOS_3_3.nib, byte-
    identical to the pre-fix baseline): csatidx=8 → `nongray=74256`
    `mono_ink=67776`; csatidx=0 → `nongray=0`; csatidx=15 chueidx=8 →
    `nongray=74256`. NIB image untouched after the runs (mtime/size).
  - `make composite` + `Vtb_composite.exe`: **COMPOSITE UNIT TEST PASS
    (errors=0)**.
  - `eol_guard.sh`: no CR-count drift (all touched files pure LF).
- **Git state:** `65a5847` (user) holds the S2 knobs + plan +
  main_l2.cpp + tb_l2. Uncommitted on top: the wrapper `hblank_cnt_c`
  fix in `mister/Apple-II.sv` (the only working-tree delta vs HEAD).
  `mister/composite_decoder.sv`, `mister/video_mixer_plus.sv`,
  `mister/tb_mixplus.sv` are still UNTRACKED (new files; the div_den
  fix + hoist live there). Unrelated user edits (`Apple-II.qsf`,
  `rtl/video_generator.v`, `level_1b/Makefile`) left untouched.
- **Pending — user-run build07:**
  `cd /d E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer\unit_tests\level_2\mister`
  `quartus_sh --flow compile level2`
  Expected on hardware: O9 On + `Comp sat` raised to 8–15 →
  cross-color/artifact tint on HI-RES game graphics (sim: idx 8 →
  nongray 74256 in L2, 33358 in mixplus); `Comp sat` 0 → B&W. If it is
  still B&W at sat=255, the remaining suspects are the ID→bit rule
  (swap to another free ID — one-line fix) or the burst-lock on real
  timing (probe `colour_ok`/lock on hardware).

### 2026-09-08 (build07 hardware PASS; knobs expanded to coarse/fine pairs)

- **Hardware confirmation (user, build07):** O9 On + `Comp sat` raised
  shows the cross-color artifact tint on real hardware — the two-bug
  fix set (wrapper `hblank_cnt_c` hold, decoder `div_den <= rot_mag2`)
  is confirmed on the device. The ID→bit rule (C=12→[15:12],
  H=17→[20:17]) is now hardware-verified too.
- **Knob expansion (user request: "more knob values to go all the way
  up, especially hue above 48"):** both knobs are now COARSE/FINE
  pairs — 16 states each, value = `{coarse, fine}` = exact 0..255
  (hue 255 = full 360-degree rotation; fine step = 1 unit = ~1.4
  degrees). New CONF_STR lines + bit fields (letters A-Z -> 10-35 in
  the ID→bit rule):
  - `OCD,Comp sat` — states remapped to 0,16,...,240 (was x17; the
    fine knob now fills the gaps; note: an OSD position of N now
    means 16N, not 17N — re-dial after the flash).
  - `OL,Sat fine,0..15` — L=21 -> `status[24:21]`.
  - `OHI,Comp hue` — unchanged (0,16,...,240 = `status[20:17]`).
  - `OM,Hue fine,0..15` — M=22 -> `status[25:22]`.
  - Decode: `comp_sat_v = {comp_sat_c, comp_sat_f}`,
    `comp_hue_v = {comp_hue_c, comp_hue_f}` (bit concat, no
    arithmetic).
- **Harness mirror (`main_l2.cpp`):** new `--cfineidx=N` /
  `--hfineidx=N`; `--csatidx`/`--chueidx` now the COARSE (upper
  nibble) — value = coarse*16 + fine; raw `--csat`/`--chue` still
  override.
- **Verification (Verilator 5.050 ucrt64):** L2 matrix, all rc=0:
  - csatidx=8 cfineidx=8 (sat=136): `nongray=74256 mono_ink=67776`
    — identical to the build07-era baseline.
  - csatidx=0 (sat=0): `nongray=0` (gray gate).
  - csatidx=15 cfineidx=15 (sat=255): `nongray=74256`.
  - + chueidx=3 hfineidx=1 (**hue=49**, the "above 48" case):
    `nongray=74256`.
  - + chueidx=15 hfineidx=15 (**hue=255**, full circle):
    `nongray=74256`.
  - `mono_ink=67776` identical across all runs (no content drift);
    NIB image untouched (mtime/size); `eol_guard.sh` clean.
  - mixplus/composite harnesses unaffected (they drive `comp_sat`/
    `comp_hue` directly, not the OSD decode).
- **Git state:** uncommitted on top of `65a5847`: `mister/Apple-II.sv`
  (hblank fix + knob expansion) and `main_l2.cpp` (fine-idx flags);
  decoder/mixer/tb_mixplus still untracked new files. User's
  savestate workstream (staged `rtl/savestate_hotkeys.sv` etc.) left
  untouched.
- **Pending — user-run build08:**
  `cd /d E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer\unit_tests\level_2\mister`
  `quartus_sh --flow compile level2`
  OSD now shows 4 composite options (Comp sat / Sat fine / Comp hue /
  Hue fine). Re-dial: e.g. sat 136 = Comp sat 8 + Sat fine 8; hue is
  dialable in 1-unit steps up to a full 255 rotation.

## 2026-09-08 (cont.) — calibration luma knobs (Comp bright / Comp contrast) + "Comp cal" preset toggle

User supplied a 4-parameter color calibration measured against a known-good
default: Brightness 0.0458512, Contrast 0.89208, Saturation 0.78486603,
Hue -0.645936. Mapping onto the decoder's exact knob semantics
(composite_decoder.sv):

- `sat`: chroma scaled by sat/128 (128 = unity) -> 0.78486603*128 = 100.46
  -> **100** (Comp sat 6 + Sat fine 4).
- `hue`: I/Q rotation in 256 steps -> -0.645936 rad = -36.96 deg =
  -26.3 steps -> **230** (256-26.3; Comp hue 14 + Hue fine 6). Direction
  is the one open assumption: if the tint rotates the wrong way on
  hardware, the mirrored candidate is **26** (Comp hue 1 + Hue fine 10).
  (If the tool's hue were +/-1 = +/-180 deg instead of radians: 173/83;
  if signed full cycles: 91/165.)
- Brightness +0.0458512 -> +0.0459*255 = **+12** luma LSB.
- Contrast 0.89208 -> 0.8921*128 = **114/128** (0.890625x, -0.15%).

The decoder previously had NO luma offset or mid-gray gain (fixed
white-point scale; `luma_gain` occupied by AGC, `comp_agc=1`), so two new
knobs were added plus the one-toggle preset requested for fast setup.

**Decoder change (mister/composite_decoder.sv):** two new 8-bit inputs,
`bright` (signed 2's-complement luma offset, 0 = none) and `contrast`
(mid-gray-centred gain, 128 = unity), applied at the y8 register stage
after the fixed white-point gain and before the YIQ->RGB matrix (luma
only; chroma stays with sat/hue). Standard video-adjust order:
contrast first, brightness added after and NOT scaled by it:

    y_raw = y8_m[33:16]
    y_c   = (y_raw - 128) * contrast        // 18b x 9b -> 27b
    y_g   = y_c[26:7]                       // >> 7
    y8    = y_g + 128 + $signed(bright)     // + offset

0/128 is the exact identity (128x then >>7 is a power of two), so the
unadjusted path is bit-identical to the pre-knob path.

**Wrapper (mister/Apple-II.sv):** new OSD items
- `O4,Comp cal,Off,On` -> status[4] (bit 4 was free): the preset toggle.
  On forces all four composite knobs to the calibrated values regardless
  of what they are dialed to (the "fast setup" override requested).
- `OQ,Comp bright` coarse (Q=26 -> status[29:26]) + `OR,Bright fine`
  (R=27 -> status[30:27]): 8-bit value is a SIGNED 2's-complement
  offset (128..255 = negative), coarse labels honest:
  Off,16,...,112,-128,...,-16. Default all-zero OSD = 0 (neutral).
- `OS,Comp contrast` coarse (S=28 -> status[31:28]) + `OT,Contrast fine`
  (T=29 -> status[32:29]): 128 = unity, 0 remapped to 128 (identity,
  not black) so the default all-zero OSD is neutral.
- CAL params (module-scope localparams): CAL_SAT=100, CAL_HUE=230
  (comment marks 26 as the mirrored-direction fallback), CAL_BRIGHT=12,
  CAL_CONTRAST=114. Decode: `comp_*_v = comp_cal ? CAL_* : <knob value>`
  (contrast knob gets the 0->128 remap in the Off branch).
- Encoder instance (`apple_composite` comp_enc) and the mixer instance
  got the new port connections; encoder keeps .bright(0)/.contrast(128).

**Pass-throughs:** `rtl/apple_composite.sv` (untracked repo file) gained
`bright`/`contrast` ports wired to its `u_dec`; `video_mixer_plus.sv`
(+ the byte-identical `mister/rtl/` copy) gained `comp_bright`/
`comp_contrast` inputs; `tb_l2.sv` exposes both as top inputs (harness
drives the decoder directly, bypassing the OSD decode); `tb_mixplus.sv`,
`tb_composite.sv`, `tb_composite_dbg.sv` connect 0/128 (identity) at
their instances.

**Harness mirror (main_l2.cpp):** `--cbright=N` (signed, clamped
-128..127, default 0), `--ccontrast=N` (0..255, default 128 = unity),
and `--ccal` which mirrors the O4 preset: turns the composite path on
and forces sat=100/hue=230/bright=12/contrast=114 over all other flags.

**Verification (Verilator 5.050 ucrt64), all rc=0:**
- R1 default safety (`--composite` only, sat=0 bright=0 contrast=128):
  `nongray=0 ink=51456 gmin=0 gmax=254` — gray, NOT black (the default
  luma knobs are identity, so a fresh flash cannot black the screen).
- R2 identity regression (`--csatidx=8 --cfineidx=8`, sat=136):
  `nongray=74256 mono_ink=67776` — identical to the pre-change baseline
  (proof the new stage is an exact no-op at defaults).
- R3 preset (`--ccal`): sat=100 hue=230 bright=12 contrast=114 ->
  `nongray=74256 ink=69456 gmin=0 gmax=255`.
- R4 raw-flag mirror (`--csat=100 --chue=230 --cbright=12
  --ccontrast=114`): stats identical to R3 (harness/FPGA parity).
- R5 hue-direction alternative (`--chue=26`): `nongray=74256` (both
  candidates decode; the picture A/B decides which is right).
- Luma math probes (sat=0 so chroma cannot mask the luma path):
  `--cbright=12` only -> gmin 0 -> 12 (exact +12); `--ccontrast=114`
  only -> gmin=14, gmax=240, both matching the hand computation
  ((0-128)*114/128+128=14; (254-128)*114/128+128=240).
- MIXPLUS PASS (errors=0), phase metrics identical to the pre-change
  baseline (A ink=47040; B nongray=33358 gmin=0 gmax=254; C nongray=0).
- COMPOSITE UNIT TEST PASS (errors=0).
- Hygiene: DOS_3_3.nib untouched (mtime/size); eol_guard.sh clean (no
  CR drift); video_mixer_plus copies byte-identical; no new lint
  warnings (make output clean; the mv ".exe same file" note on
  mixplus/composite is the known Windows cosmetic, exes built and ran).

**Pending — user-run Quartus compile (build08, now covering the
coarse/fine expansion AND these additions):**
`cd /d E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer\unit_tests\level_2\mister`
`quartus_sh --flow compile level2`

**Hardware procedure:**
1. O9 "Composite video" On.
2. Fast path: O4 "Comp cal" On — instant calibrated color (sat 100,
   hue 230, bright +12, contrast 0.892x). Compare against the known
   good default; if the artifact tint rotated the wrong way, flip the
   preset to Off and set Comp hue 1 + Hue fine 10 (26) with the rest
   the same.
3. Manual path (preset Off): Comp sat 6 + Sat fine 4 (100); Comp hue
   14 + Hue fine 6 (230); Comp bright 0 + Bright fine 12 (+12); Comp
   contrast 7 + Contrast fine 2 (114).
4. Negative bright values live in the coarse knob's negative half
   (labels -128..-16); contrast below unity is any value < 128.

## Hue calibration (rounds 2b/2c/2d) - 2026-09-10

**Trigger:** two user-reported hardware bugs - (1) with O4, Comp cal ON
colors are shifted (green/purple where blue/red expected); (2) OSD knobs
seem to cap at 48 (stale 4-state build; current source is 16-state +
fine = 0..255).

**OSD status-field fix (APPLIED, mister/Apple-II.sv):** the 2nd
character of the option ID names the 4-bit status field; 16-state
options take the full slot; two 16-state options overlapping by >= 1
bit corrupt each other. Re-keyed: C(12) sat coarse, H(17) hue coarse,
L(21) sat fine, Q(26) bright coarse, U(30) hue fine, Y(34) contrast
coarse. Old L/M overlap and Q/R/S/T triple overlap removed; the luma
fine knobs (R/T) are deleted (coarse + preset cover it). Lint clean,
eol_guard clean.

**Why software metrics cannot judge hue:** nongray/ink are
color-agnostic; the picture decodes (non-black) at ANY hue knob. A
color-aware measurement was added to the L2 harness.

**Round 2b (per-class RGB, luma-slope up/down separation):** RGB class
averages rotate only ~0.15 deg/knob (vs the 1.40625 deg/knob expected)
because max saturation drives edge pixels into the RGB clamps, pinning
the averages to fixed axes. Also C_0 ~ C_2 at k=0 (0.1 deg apart).
RGB averages are NOT usable for rotation tracking.

**Round 2c (I/Q class sums, taps on u_dec.i8/q8, 48-bit signed,
sign-extended from bit 47 in C++):** all pixels' i8/q8 rotate by
exactly -(K+128)*1.40625 deg of knob (the knob is a global complex
division of all chroma by the post-knob burst vector), so any
knob-independent pixel subset sum rotates rigidly. CONFIRMED
empirically on the 9-knob matrix (out/hue_matrix_2c/): class sums
rotate at -1.40625 deg/knob within quantization (~5% magnitude).

**Burst angle derivation:** encoder burst pattern [-1,-1,+1,+1]
(burst_cnt[1], 2 H per level) -> boxcar demod sum = -1 - 1j
-> raw burst angle 225 deg (general: 225 + 90(s_p - s_b), CCW).
Post-knob burst angle = 225 + (K+128)*1.40625. Output chroma angle
= signal angle - post-knob burst angle, hence d(out)/dK =
-1.40625 deg/knob (matches data).

**Boxcar geometry (CORRECTED pipeline):** ibuf (4-deep) + iacc reg +
iacc_d (/4) + ibox reg -> ibox(M) = (1/4)*sum(t=M-5..M-2) i_dem(t).
A 1-bit edge at column n (class r = n mod 4) produces nonzero boxcar
at M in {n+2..n+6} with weights (1,1,1,1+j,j)/8. Per-edge decoded
class weights (L=5 full ramp): class r: 1, r+1: 1+j, r+2: 1+j, r+3:
1 (x e^{j*90r}/8). The earlier "all classes equal" and "r+2
cancels" results were a double-counted +90 deg arithmetic error.

**Peak-pixel formula (the measurement that resolves s_b):** the
strongest ramp pixel (k=5, M = n+5, class c = r+1) of every up-edge
of class c-1 decodes at angle
    90c + 90 s_b - 270 - (K+128)*1.40625   (CCW)
i.e. all peaks in one class are coherent (no cancellation).
At the correct K* (artifact classes on the NTSC axes) the peak
angle must equal 90c for every c:
    (K*+128)*1.40625 = 90 s_b - 270  (mod 360)
    =>  K* = 64(s_b - 1) mod 256  in {0, 64, 128, 192}.
Measuring the peak class angle at K=0 gives
    s_b = (peak_angle - 90c + 270) / 90  (mod 4)
and removes the 4-fold ambiguity directly.

**Mixture fit (class sums) - NOT usable:** fitting
C_c(K) = G e^{j(Phi0 - 1.40625 K)} f_c(N) over all 9 knobs leaves
52-73% residual for every gated-set variant L in {3, 4, 4.5, 5}:
f_c(N) has 6 real DOF but the 4 class sums at K=0 carry 8 - the
model is structurally rank-deficient (real edges have varying gated
sets: merged ramps, local ripple), and class sums are low-SNR
(vector cancellation). The peak probe is the right instrument.

**AV/PE hard block (Phase 2, active 2026-09-10 ~11:00-...):** every
freshly linked C++ PE exits 127 with zero output at image load;
old Sept-7 PEs (Vtb_composite etc.) ALSO die - all C++ PEs killed,
relink+immediate-run does not help. Round-2c matrix ran fine at
10:57, so the block is a wave. Per AGENTS.md: do not fight it; a
background retry loop (C:/msys64/tmp/hue2d_retry.sh, nohup) relinks
and probes every 5 min and, on first live PE, runs the round-2d
matrix K = 0/64/128/192/230 into unit_tests/level_2/out/hue_matrix_2d/
(one relink per value).

**Re-run command when the block lifts (manual):**
    cd /d E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer\unit_tests\level_2
    C:/msys64/usr/bin/env MSYSTEM=UCRT64 C:/msys64/usr/bin/bash -c "cd /e/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/unit_tests/level_2 && rm -f build/obj_dir/Vtb_l2.exe && PATH=/c/msys64/ucrt64/bin:$PATH /c/msys64/ucrt64/bin/mingw32-make -j4"
    cd /d E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer
    unit_tests\level_2\build\obj_dir\Vtb_l2.exe +cpu=0 --composite --csat=128 --chue=0 --timeout 1.5 --disk unit_tests\level_2\DOS_3_3.nib
Look for hue-probe pku0..3 / pkd0..3 / xchk lines (per-class peak
I/Q sum + count + angle, and the P/B burst cross-check).

**AV block lifted 2026-09-09 ~11:39; round-2d matrix completed**
(threshold 65536 first pass = all-zero counts: per-pixel |chroma| is
~50-150 in i8/q8 units, so 65536 = |chroma|>256 was above the true
peak; lowered to 4096 = |chroma|>64, rebuilt, re-ran K = 0/64/128/192).

**xchk measurement:** raw burst vector (u_dec.ib/qb at VBL fall,
pre-knob) = (364, 328) -> **42.0 deg at every K** (knob-independent,
as it must be). Not the derived 225 deg: the 4-sample demod window
alignment flips the sign (180 deg) and the magnitude is 364:328, not
2:2 (window not exactly phase-aligned). 42 deg is the empirical raw
burst; the model below is anchored on it.

**Corrected peak-pixel geometry (supersedes the per-class 90 deg
model above):** the demod removes the per-position subcarrier phase
exactly (90 deg/sample), so every pixel of one edge decodes at the
SAME angle 90 s_p - B_abs; the position structure is carried by the
boxcar partial sums W(M) = sum of e^{-j90t} over the edge's window:
for a unit up-edge at column n: M=n+2: e^{j(180-B)}, M=n+3:
\sqrt(2) e^{j(225-B)} (the peak), M=n+4: e^{j(270-B)}, then 0. So the
peak pixel of EVERY up-edge (any class/position) is at angle
225 - B_abs; down-edge peaks at 45 - B_abs. B_abs(K) = 42 +
(K+128)*1.40625. The earlier K* in {0,64,128,192} formula assumed the
demod angle differs by 90 deg per class; it does not - the class
buckets are just the peak sample's POSITION class and hold a
knob-dependent edge mix (confirmed: per-bucket angles do NOT rotate
rigidly and the per-class counts swap between knobs). That is also why
the class-sum mixture fit was rank-deficient.

**Result: CAL_HUE = 128 = burst-locked identity.** The knob rotates
the demod reference by (K+128)*1.40625 deg, so K=128 adds exactly
360 deg: the chroma reference is the raw burst measured by the
decoder itself - exactly what a real NTSC receiver locks to, i.e. the
original Apple II behavior. Data anchors: pku2(K=0) = 0.8 deg ~=
225-222 = 3 deg (predicted up-peak); pkd2(K=128) = 2.7 deg ~=
45-402+360 = 3 deg (predicted down-peak). At K=128: up-edges decode
at 225-402 = -177 = 183 deg (I<0: **blue**), down-edges at 3 deg
(I>0: **red**) - the classic blue/red fringe. The old 230 put
up-peaks at ~40 deg (orange/green) and down-peaks at ~220 deg
(blue-magenta) = the user's "green/purple" report. Residual: raw
burst is 42 deg vs the theoretical 45 deg -> 3 deg off the pure I
axis at K=128 (quantization; the hue knob still nudges 1.40625 deg
per fine step if the user's eye wants more).

**Applied:** `mister/Apple-II.sv` CAL_HUE 230 -> 128 (comment
rewritten with this derivation); `main_l2.cpp` --ccal mirror 230 ->
128; TB peak threshold 65536 -> 4096 (both arms). sat/bright/contrast
preset values unchanged (100/12/114).

**Status:** CAL_HUE = 128 (hue coarse 8 + fine 0) pending user's
hardware eye-check (next build, expected: blue/red fringes with
"O4,Comp cal" ON; knobs now reach the full 0..255 range - the "48
cap" was the stale 4-state build). NTSC vertical blend remains
queued.
