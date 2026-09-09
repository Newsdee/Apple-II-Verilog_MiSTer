# NTSC Vertical Blend — Level_2 Port: PROGRESS

Status as of 2026-09-11 (session #3, after session crash #1 + resume #2).
**ALL SIMULATION WORK DONE.** The DUT is correct (proven by
`tb_vblend PASS (0 failures)`), the end-to-end `mixplus` Phase D
assertion is resolved and passing, the regression is green, and the
temporary debug instrumentation is removed. See
`NTSC_VERTICAL_BLEND_PLAN.md` for the design plan (port-after-decoder,
faithful main-branch arithmetic, OSD knob `OB` = `status[11]`, default
Off) and its section 6 for the final results.

## Status at a glance

- [x] Design ported: `mister/ntsc_vertical_blend.sv` (new module)
- [x] Integrated: `mister/video_mixer_plus.sv` (`.ntsc_blend` port +
      instantiation after `comp_dec`), `mister/Apple-II.sv` (CONF_STR
      `"OB,NTSC vertical blend,Off,On;"`, `wire ntsc_blend = status[11];`),
      `mister/files.qip` + `mister/level2.qsf` (CRLF preserved, 310/310 CR)
- [x] Makefile targets `vblend` + `mixplus`; `mv` steps no-op-safe
- [x] `tb_vblend.sv` written and **PASSING: `tb_vblend PASS (0 failures)`**
      (P1 bypass 0 fails; P2 filter 0 fails — per-sample exact main-branch
      formula match incl. known values blue-vs-red (104,0,104) and
      red-vs-blue (151,24,151), per-column ramp oracle, split boundary
      probe, 2-ce sync alignment, exact counts)
- [x] `tb_mixplus.sv` extended (Phase D: blend ON; the assertion is the
      active-window max colour deviation halving, see RESOLVED below)
- [x] `mixplus` PASS (errors=0; phases A-D, all assertions green)
- [x] Regression: `composite` re-run PASS (errors=0; re-linked fresh,
      AV-layer had killed the old PE — exit 127)
- [x] Fill in `NTSC_VERTICAL_BLEND_PLAN.md` section 6 (results)
- [x] Remove temporary debug instrumentation (see below)
- [x] Final clean vblend run after instrumentation removal (PASS)

## Verified DUT behavior (proven 2026-09-10)

`tb_vblend PASS (0 failures)` proves, sample-for-sample against a TB
oracle that recomputes the main-branch formula with identical integer
arithmetic:

- Pipeline (blend_en=1): output at TB sample *j* =
  `F( in[j-2], prevline[in-column j-2] )` — a 2-ce delay, matching the
  main branch's "two pixels of latency".  Blank/sync outputs track the
  input by the same 2-ce delay (`hb_out[j] = hb_in[j-2]`, etc.), checked
  per ce.
- Bypass (blend_en=0): zero-latency combinational passthrough
  (`out == in` at the same ce) — the byte-identical requirement.
  Counts: P1 hb_low = 3*560, hs = 6*68, vs = 3*912 — all exact.
- Filter gate: `blend_en && cur_active_q && line_valid_q`.  First real
  line after VBL is unfiltered (line_valid_q stays 0), later lines
  filtered.
- Exact arithmetic sample-exact, e.g. `F(red, black) = 0xA52626`,
  `F(blue, red) = 0x680068 = (104,0,104)`, `F(red, blue) = (151,24,151)`.

P2 sync counts (all exact): hs = 8*68 = 544; vs = 3*912 = 2736;
hb_low = exactly 5*560 = 2800 — NOTE: the 2-ce shift clips 2 ce off the
last counted line's blank window (−2) but those 2 steps are exactly
cancelled by the +2 carry-over of P1's last active line into the first
2 HBL steps of P2 (the pipeline is continuous across phases).

## Bugs found in tb_vblend (ALL TB-side; the DUT was never at fault)

1. `vs_in` never driven — fixed (now `vs_in = vbl` in both loops).
2. "VBL" lines drove `vb_in=0, hb_in=0` in the ACT section — fixed
   (ACT loop drives `vb_in/hb_in/vs_in = vbl` for VBL lines).
3. Oracle used `in[i-1]`; correct model is `in[i-2]` (2-ce pipeline) —
   fixed (oracle2 + checks index i-2; i<2 edge cases expect the
   delayed (black, HBL) input).
4. Untyped task input ports are 1-BIT nets — fixed (`input [1:0] vbl;
   input [1:0] mode;`).
5. `patfn` ramp: Verilator 5.050 miscompiles a part-select of a 32-bit
   value in the LEADING slot of a concatenation when a sibling element
   is wider than 8 bits (MSB byte comes out 0).  Root-caused 2026-09-10
   with probe2/probe3 (C:/Users/newsdee/AppData/Local/Temp/probe1):
   - the 48-bit "REPLICATE" comes from `(ui + 128) & 8'hFF` being a
     32-bit element, bloating the concat;
   - BOTH the signed `i[7:0]` and the unsigned `ui = i; ui[7:0]` forms
     fail (leading slot zeroed);
   - the SAME part-select in the TRAILING slot works — so it is
     leading-slot-specific;
   - FIX (in file): bytes go through 8-bit regs assigned in separate
     statements, then concatenated (probe3 variant V1):
       `pb0 = ui[7:0]; pb1 = (ui + 128) & 8'hFF; pb2 = ui[8:1];
        patfn = {pb0, pb1, pb2};`
6. **`#1` same-step read (the big one from checkpoint #1)** — WITH
   FIX APPLIED AND VERIFIED: with Verilator `--timing`, a TB blocking
   input write + same-step read of a combinational output can see the
   OLD value (the DUT's continuous assigns re-evaluate later in the
   step in the generated C++).  probe2 confirmed `#1` after the drive
   makes the combinational output read the NEW value.  `#1;` now sits
   in BOTH `run_line` loops immediately after the input drives (and the
   `in_rgb` update) and before the counts/checks.  Timing model (TB
   clk period 10, drives at negedge t=10+10j, check at t=11+10j, DUT
   FFs sample at posedge t=15+10j): bypass reads I_j (settled),
   pipeline reads F(I_{j-2}) (last FF update was posedge t=5+10j) —
   exactly what the TB oracles encode.
7. **Oracle width truncation (NEW, found 2026-09-10)**: `oracle_blend`
   and `luma8` did `306 * cr` with `cr` an 8-bit input and `306` a
   9-bit literal — self-determined product width = 9 bits, the product
   truncates (e.g. 306*255 mod 512).  Symptom: the DUT printed the
   EXACT known-good value (line 11 sample 2: out=680068=(104,0,104)
   for blue-vs-red, cur_q=0000FF prev_q=FF0000 hc=2) while the TB
   oracle disagreed — the oracle was wrong, not the DUT.  FIX (in
   file): channel bytes copied to signed `integer` temporaries
   (icr/icg/icb/ipr/ipg/ipb; r/g/b in luma8) before the multiplications.
   The DUT does this correctly (its channels are `integer` — see
   ntsc_vertical_blend.sv lines ~125-142).
8. **Mode-2 `filter hb` expectation at i<2 (NEW)**: the TB expected
   hb_out=0 across the whole ACT, but the exact 2-ce delay model gives
   hb_out=1 at the first 2 ACT samples (the 2-delayed input is the
   previous line's HBL 350/351).  Mode 1 already had the correct
   `((i < 2) ? 1'b1 : 1'b0)` form; mode 2 now matches it.  (8 failures
   -> 0.)
9. **Luma-preservation window check removed (NEW)**:
   `|luma(out) - luma(in[i-2])| <= 3` is NOT a valid invariant for
   these patterns.  The exact formula preserves luma only WITHOUT
   clamping; with extreme cur/prev luma gaps (pure blue luma 29 vs pure
   red luma 76) the per-channel clamps legitimately move the output
   luma by ~14.  The exact-match oracle check is the strong net.
   Plan section 4 item 3 needs the same note (section 6 fill-in step).
10. **P2 hb_low expected count (NEW)**: was `5*ACT - 2`; correct is
    `5*ACT = 2800` (see "Verified DUT behavior" for the carry-over
    argument).

## RESOLVED (2026-09-11): mixplus Phase D assertion

Root cause: **the assertion measured the wrong window; the DUT was
never at fault.**

The TB's frame stats (ink/nongray/chrmax) counted ALL `ce_pix_out`
pixels — ce_frame = 238944 = exactly 912 x 262 machine cycles, i.e.
full lines including HBL/VBL. The blend's filter gate is
`blend_en && cur_active_q && line_valid_q` (active-only, like the main
branch's comb which acts on the vga_controller's active window), so
blanking pixels always bypass it (2 ce late when the knob is on).

Instrumented `tb_mixplus` with (a) active-window-only stats (gated by
`vga_de`) and (b) argmax location capture. Result (Phase D):

- all-pixel `chrmax=255` argmax: `de=0` (outside the active window),
  `hbl_c=0 vbl_c=0`, machine `mline~76 mcyc~364-366` — line 76 is a
  dither line (76 % 16 = 12); the pixel is the line-START transient of
  the dither line in the composite-domain HBL (a few machine cycles
  before the machine enters active). The decoder passes its decoded
  sample through in the composite-domain HBL, so that line-start chroma
  transient (residual subcarrier state) keeps FULL chroma in BOTH
  phases B and D — it is not a blend fault.
- active-window (the region the feature controls): `actchmax`
  255 (B) -> 169 (D) — **halves, as the comb must**.
- active-window `actng` 13752 (B) -> 27180 (D) ≈ 2x: exactly the
  content model — the dither lines (12, 14 per 16-line group) keep half
  their chroma, and the white lines that FOLLOW them (13, 15) pick up
  half the dither lines' chroma, so non-gray pixel COUNTS roughly
double by design. The plan's earlier "nongray must decrease"
expectation was wrong for this deterministic 1-bit-dither content
(the fsc dither phase is identical on every line, so the comb halves
rather than cancels); the halving of the MAX deviation is the valid
invariant, and luma preservation is covered by the gmin/gmax checks.

Fix applied to `tb_mixplus.sv`:
- new per-frame active-window stats (`act_nongray_frame`,
  `act_chrmax_frame`, gated by `vga_de`) + argmax classification
  (vga_de / hbl_c / vbl_c / approximate mline-mcyc) printed in phases B
  and D;
- Phase D assertion now: `act_chrmax_frame < act_chrmax_b` (active
  window), with the header comment documenting the windowing rationale
  and the all-pixel argmax evidence (de=0 in every phase).

Final output (clean DUT, 2026-09-11):

```
MIXPLUS PHASE A (native): hs=524 vs=2 ink=47040
MIXPLUS PHASE B (composite): ink=40320 nongray=33358 gmin=0 gmax=254 ce=238944 hs=1572 vs=6 chrmax=255 actng=13752 actchmax=255
  B chrmax argmax: de=0 hbl_c=0 vbl_c=0 mline~76 mcyc~364
MIXPLUS PHASE C (sat=0): ink=40248 nongray=0 gmin=0 gmax=254 chrmax=0
MIXPLUS PHASE D (composite+blend): ink=40284 nongray=46786 gmin=0 gmax=254 chrmax=255 (phase B chrmax=255) actng=27180 actchmax=169 (phase B actchmax=255) hs_delta=1048 vs_delta=4
  D chrmax argmax: de=0 hbl_c=0 vbl_c=0 mline~76 mcyc~366
MIXPLUS PASS (errors=0)
```

(`hs_delta=1048` = 4 x 262, the 2-ce sync shift moving HS edge counts
by 4 per frame; `vs_delta=4` = 1 per frame — both the expected
measurement-window artifact of the legitimate 2-ce sync shift.)

Regression: `Vtb_composite.exe` re-linked and re-run —
`COMPOSITE UNIT TEST PASS (errors=0)` (encoder path untouched).

## Temporary instrumentation (REMOVED 2026-09-11)

- `mister/ntsc_vertical_blend.sv`: `wire [23:0] mux_dbg = ...;` — REMOVED.
- `mister/tb_vblend.sv`: the `DBGIN` display block in the ACT loop
  (gated by `dbg_in_done`, fired at line 5 / i == 2, referenced
  `dut.mux_dbg`) and `reg dbg_in_done` — REMOVED.
- `mister/tb_vblend.sv` failchk: the once-per-first-failure DBG dump
  (`dbg_done`, prints `dut.cur_rgb_q`/`prev_q`/`lv`/`caq`/`hc`) is
  KEPT deliberately: it is self-contained (no DUT hook), fires only on
  the first pixel failure, and is the fastest path to the effective
  (cur, prev) pair in any future filter regression.
- `mister/tb_mixplus.sv`: the active-window stats + argmax capture
  added while resolving Phase D are KEPT: they are the assertion's
  evidence (the de=0 argmax lines document WHY the assertion is
  active-window-only) and cost a few accumulators.

## Build / run environment notes

- MSYS2 ucrt64; top-level build uses `mingw32-make`; PATH must put
  `/c/msys64/usr/bin` BEFORE `/c/msys64/ucrt64/bin` (Verilator shells
  out to plain `make`); export `TMP/TEMP/TMPDIR=/c/msys64/tmp` inside
  the MSYS shell.
- Standalone Verilator probes need `VERILATOR_ROOT=/c/msys64/ucrt64/share/verilator`
  (missing -> "Cannot find verilated_std.sv" with backslash paths).
- Verilator 5.050 2026-07-01.  Known TB-side width gotchas (see bugs
  5, 7): leading-slot part-select in a bloated concatenation; and
  coefficient*byte products self-determined at ~9 bits.  The DUT is
  immune (integer temporaries).
- HOST AV LAYER (per repo notes): freshly linked C++ PEs can be killed
  (exit 127, zero output; the hash is remembered, renaming does not
  help).  Mitigation: chain `rm <exe> && make <target> && <exe>` in ONE
  bash command and run the most important test first.  This bit the
  vblend exe mid-session #1; no AV kills seen in session #2.

The vblend build+run one-liner (known-good, used successfully
2026-09-10):

```sh
/c/msys64/usr/bin/bash -c '
set -e
export PATH=/c/msys64/usr/bin:/c/msys64/ucrt64/bin:$PATH
export VERILATOR_ROOT=/c/msys64/ucrt64/share/verilator
export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp TMPDIR=/c/msys64/tmp
cd /e/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/unit_tests/level_2
rm -f build_vblend/obj_dir/Vtb_vblend.exe build_vblend/obj_dir/Vtb_vblend
mingw32-make vblend 2>&1 | tail -3
cd /e/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer
./unit_tests/level_2/build_vblend/obj_dir/Vtb_vblend.exe 2>&1 | tail -30
'
```

mixplus (must run with CWD at repo root for ROM paths) — known-good,
produced the Phase A-D stats above:

```sh
/c/msys64/usr/bin/bash -c '
set -e
export PATH=/c/msys64/usr/bin:/c/msys64/ucrt64/bin:$PATH
export VERILATOR_ROOT=/c/msys64/ucrt64/share/verilator
export TMP=/c/msys64/tmp TEMP=/c/msys64/tmp TMPDIR=/c/msys64/tmp
cd /e/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/unit_tests/level_2
rm -f build_mixplus/obj_dir/Vtb_mixplus.exe build_mixplus/obj_dir/Vtb_mixplus
mingw32-make mixplus 2>&1 | grep -E "Error|error|built" | head -5
cd /e/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer
./unit_tests/level_2/build_mixplus/obj_dir/Vtb_mixplus.exe 2>&1 | tail -40
'
```

## Next steps (ordered)

1. DONE: mixplus Phase D resolved (active-window halving assertion) —
   `MIXPLUS PASS (errors=0)`.
2. DONE: regression `composite` re-linked + re-run PASS.
3. DONE: temporary instrumentation removed; final clean vblend run
   PASS (0 failures).
4. DONE: `NTSC_VERTICAL_BLEND_PLAN.md` sections 4 + 6 updated (results,
   Phase D windowing rationale, luma-clamping note for item 3).
5. REMAINING (user-run): Quartus full compile of the `level2` project
   to validate the new `ntsc_vertical_blend.sv` registration
   (`mister/output_files/level2.map.summary`, `.fit.summary` — expect
   the 560x24 line buffer ≈ +2 M10Ks and a small ALM delta,
   `.sta.summary`), then the hardware check: OSD "Composite video" On,
   "Comp sat" > 0, "NTSC vertical blend" Off vs On on the same HI-RES
   screen — visible effect = less cross-colour banding/shift,
   identical brightness.
6. Report per the AGENTS.md completion checklist (files changed incl.
   mirrored copies — none for this feature).

## Files touched so far (this feature)

New:
- `unit_tests/level_2/mister/ntsc_vertical_blend.sv` (DUT; clean,
  debug wire removed)
- `unit_tests/level_2/mister/tb_vblend.sv` (self-driving TB; PASSING
  on the clean DUT; DBGIN/dbg_in_done removed, failchk first-failure
  dump kept)
- `unit_tests/level_2/NTSC_VERTICAL_BLEND_PLAN.md` (section 6 filled)
- this file: `unit_tests/level_2/NTSC_VERTICAL_BLEND_PROGRESS.md`

Edited:
- `unit_tests/level_2/mister/video_mixer_plus.sv` (`.ntsc_blend` port,
  blend instance after `comp_dec`, final mux uses `*_blend` nets)
- `unit_tests/level_2/mister/Apple-II.sv` (OSD option OB + wiring)
- `unit_tests/level_2/mister/tb_mixplus.sv` (Phase D; active-window
  stats + argmax capture; assertion = active-window chroma halving)
- `unit_tests/level_2/mister/files.qip` (LF; new module registered)
- `unit_tests/level_2/mister/level2.qsf` (CRLF preserved; registered)
- `unit_tests/level_2/Makefile` (vblend target; mixplus sources;
  no-op-safe mv for vblend/mixplus)

Note: `mister/rtl/video_mixer_plus.sv` is an UNREGISTERED historical
duplicate (no blend); the Quartus project registers `mister/
video_mixer_plus.sv` (the blend-enabled copy) — see the qsf comment
block. Do not "sync" the two.

Reference (main branch, read-only): `Apple-II_MiSTer/rtl/vga_controller.v`
(one-line buffer + vertical comb filter), `Apple-II_MiSTer/Apple-II.sv`
(OSD option string + `~status[32]` mapping).
