# vga_color_test — PROGRESS (resume point)

Standalone Verilator+ImGui tester for the Apple II VGA controller
(`vga_controller.v`). Goal: rapid visual development of the active Verilog
VGA controller — load 1-bit Apple II images, feed video+timing into the DUT,
show the processed RGB in an ImGui window. See `PLAN.md` for the full design
and decisions.

**Last updated: 2026-08-30. Phase 1 and Phase 2 COMPLETE and verified.**

---

## Where we are

- **Phase 1 (headless DUT + feeder): DONE.** Builds, runs, captures a clean
  559×192 frame, dumps PPM, all gates pass, output is deterministic.
- **Phase 2 (image source): DONE and verified (see Phase 2 results below).**
- **Phase 3 (ImGui GUI): NOT STARTED.**
- **Phase 4 (automated validation / --smoke-test): NOT STARTED.**

### Open question (BLOCKING a design decision, not the build)
The user was shown a 9-row contact sheet (`contact_sheet.png`) and asked to
interpret one behavior: **in the DUT, the artifact-color branch runs whenever
`COLOR_LINE=1`, independent of `SCREEN_MODE`.** So "B&W" display mode still
shows NTSC artifact colors on color lines; green/amber show artifact colors on
top of the phosphor tint. Only `COLOR_LINE=0` gives true monochrome/phosphor.

Awaiting the user's read on which is intended:
- (a) genuine golden-matching behavior → just document it;
- (b) GUI "Display" combo is misleading → relabel or couple with COLOR_LINE;
- (c) latent bug in candidate+golden → flag as a divergence to fix.

Do NOT change the controller for this; it is a read-only snapshot.

---

## Files created (all under `vga_color_test/`)

| File | Purpose |
|------|---------|
| `PLAN.md` | Full design + decisions (Q1/Q2/Q3, PNG-dump button). Read first. |
| `PROGRESS.md` | This file. |
| `Makefile` | Verilator `-cc -exe --timing` build of top+controller + C++ harness. |
| `build.sh` | Locates MSYS2 ucrt64 toolchain, sets MAKE/VERILATOR_ROOT/V, runs make. |
| `build.bat` | Windows wrapper → `build.sh` (default `-j2`). |
| `run.bat` | Sets ucrt64 DLL path, `cd`s to its dir, runs `obj_dir\Vvga_color_test_top.exe %*`. |
| `rtl/vga_controller.v` | **Snapshot** of `../rtl/vga_controller.v` (byte-identical, verified). |
| `rtl/vga_color_test_top.sv` | Thin 1:1 pass-through top around the DUT (no logic). |
| `src/main.cpp` | Headless driver: clock/blanking gen, capture, PPM dump, gates, CLI (incl. `--image`, `--threshold`). |
| `src/image_source.h` / `src/image_source.cpp` | stb_image loader → luminance threshold → 1-bit 560×192 source (4 size profiles). |
| `third_party/stb_image.h` | stb_image v2.30 (public domain), downloaded 2026-08-30. |
| `assets/*.png` | Four 284×192 examples copied from `../../apple2ntsc/python/` (monochrome_input, arena, robocop, total_replay). |

Generated/scratch (regenerable, safe to delete): `obj_dir/`, all `*.ppm`,
`*.png` (contact_sheet.png, out_*.png), `m*.ppm`, `d*.ppm`, `c_*.ppm`, etc.

---

## Build & run (verified working)

From an MSYS2-capable shell (this repo's bash maps `/c/msys64`, not `/ucrt64`):
```
cd E:/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/vga_color_test
bash build.sh -j2                 # builds obj_dir/Vvga_color_test_top.exe
./obj_dir/Vvga_color_test_top.exe --dump-frame frame.ppm
```
From a Windows terminal (the intended interface):
```
cd E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer\vga_color_test
build.bat
run.bat --dump-frame frame.ppm
```
Note: invoking a `.bat` from MSYS2 bash needs `cmd.exe //c run.bat ...`
(double slash) — single `/c` gets path-mangled and silently no-ops.

Expected Phase 1 output:
```
frame 0: pixels=0 lines=192 bad_widths=0 ...
frame 1: pixels=0 lines=192 bad_widths=0 ...
frame 2: pixels=107328 lines=192 bad_widths=0 distinct=11 w[first=559 last=559 min=559 max=559]
PHASE1 OK pixels=107328 lines=192 distinct=11 dump=frame.ppm
```

### CLI (Phases 1+2, already implemented)
`--dump-frame <ppm>` (default frame.ppm) `--frames <n>` (default 3 = 2
preamble + 1 captured) `--display color|bw|green|amber` `--palette
ntsc|iigs|applewin|custom` `--sharp-rgb` `--vertical-blend` `--color-line
none|text|full` `--color-line-start <0..192>` `--image <png|bmp|ppm>`
`--threshold <0..255>` (default 128) `--debug`.
Without `--image` the deterministic Phase 1 synthetic pattern is used.

### Phase 2 results (verified 2026-08-30)
- All four bundled 284×192 PNGs load via the `284x192 crop2+dup` profile and
  produce clean 192-line × 559-px frames (107,328 px, 0 bad widths, no
  shifted line boundaries).
- B&W + `--color-line none` gate: byte-level check of the dumped PPM confirms
  every one of the 107,328 pixels has R=G=B (2 distinct values).
- Unsupported size (100×100 PPM) fails cleanly: `PHASE2 FAIL: unsupported
  image size ...`, exit 1.
- Synthetic fallback (no `--image`) unchanged and still passes.
- Build quirk: Verilator's generated .mk compiles from inside `obj_dir/`, so
  CFLAGS need an ABSOLUTE include dir (`-I$(CURDIR)` in the Makefile), not
  `-I.`.
- Windows path quirk: passing backslash paths through the bash→`cmd.exe //c`
  bridge mangles them (`can't fopen`); use forward slashes (`assets/arena.png`)
  in test commands. `run.bat` itself is unaffected for normal Windows use.

---

## Key technical findings (DO NOT re-derive from scratch)

### 1. Output is 559 px/line, not 560
The DUT does `raw_active <= !HBL && hcount < 560;` with `hcount` reset to 0 on
the HBL falling edge. The reset takes effect one cycle late, so the first
active clock (the falling-edge clock) has `raw_active=0` (old hcount ~911).
Net: with HBL=0 for 560 clocks (352..911), `raw_active` is high for only
**559** clocks (353..911). This is deterministic DUT behavior, not a bug in the
harness. `kOutWidth=559`, `kExpectedPixels=107328`. (If exact 560 is ever
required, the source active period would need to be 561 clocks — a 1-clock
phase shift — but do not do that without the user's OK.)

### 2. Frame must have TRAILING blanking (the fix that made Phase 1 pass)
The DUT delays `raw_active` by **19 cycles** (seam window + timing_active_delay
+ filter) before `filtered_timing_active`/`VGA_HBL`. So each VGA window spans
into the NEXT source line. If the frame were all-leading-blank (70 VBL + 192
active), the last active line's window bleeds across the frame boundary and the
per-frame `prev_vga_hbl` re-init splits it into a spurious 19-px line.
**Fix:** split the 262-line frame as **40 leading VBL + 192 active + 30
trailing VBL**. The last line's 19-cycle tail then lands in the same-frame
trailing VBL (where `vbl_delayed` is still 0 for the first 352 clocks), so it
is captured as part of that line. Result: clean 192×559, no spurious lines.
Constants in main.cpp: `kLeadingVbl=40, kActiveLines=192, kTrailingVbl=30`.

### 3. Capture logic (correct, keep it)
Drive inputs, `CLK=1; eval();` sample `VGA_HBL`/`VGA_VBL`; detect VGA line
start (1→0) / end (0→1); capture RGB only when `!VGA_HBL && !VGA_VBL &&
line_active`. `prev_vga_hbl` is a per-`runFrame` local re-inited to `true`
(safe now that trailing VBL keeps each window inside one frame). Sample
outputs after the posedge (all DUT outputs are register-driven).

### 4. B&W / green / amber still show artifact colors when COLOR_LINE=1
See open question above. Pixel generator (`pixel_generator` block): base color
set by SCREEN_MODE; `if (!COLOR_LINE)` → mono (mode-specific white/black);
`else if (artifact condition)` → `palette_color(COLOR_PALETTE, shift_color)`
**regardless of SCREEN_MODE**; else white/gray/black by `shift_reg[3:2]`.

### 5. The controller snapshot is a NEWER version than the equivalence test
`rtl/vga_controller.v` (active) has the **palette download already fixed** to
match the golden: `color_addr < 2'b11` (4 beats) and `BUFFER_COLx <=
palette_rgb_in` (pre-cycle value), with a comment noting the golden behavior.
The `module_tests/vga_controller/` equivalence harness was run against the OLD
version (3-beat wrap + new-value latch) and reported the expected divergence.
So the active controller may now be equivalent — **re-running the equivalence
harness is a good idea** to confirm, but that is separate from this tester.

### 6. Verilator 5.050 build quirks (all already handled in Makefile/build.sh)
- Use `verilator_bin` (the Perl `verilator` wrapper needs Pod::Usage, missing).
  → `export V=verilator_bin` in build.sh.
- Class name is `V<top>` = `Vvga_color_test_top` (NOT `VerilatedVgaColorTestTop`).
- Use `-cc -exe` (own main in src/main.cpp), NOT `--binary` (auto-generates a
  conflicting main; `--nomain`/`--main off` are not valid in 5.050).
- `-CFLAGS` (not `-CXXFLAGS`) for app C++ flags.
- Add `--timing` and a `double sc_time_stamp(){return 0;}` stub in main.cpp
  (runtime time fallback for non-SystemC).
- `export MAKE=<ucrt>/bin/mingw32-make.exe` and
  `export VERILATOR_ROOT=<ucrt>/share/verilator` (make is `mingw32-make`).
- This bash maps `/c/msys64/...`; build.sh also handles a real MSYS2 shell
  where `/ucrt64` is mapped.

---

## Decisions already made (in PLAN.md)
- **Q1:** snapshot the active controller AS-IS; user fixes the palette
  divergence separately and will bring the updated version. (Turns out the
  active version is already the fixed one — see finding #5.)
- **Q2:** COLOR_LINE = 3-position combo + boundary slider:
  `none` (0 all lines) / `text` (0 for lines<N, 1 for lines>=N, N default 1) /
  `full` (1 all lines). Polarity: COLOR_LINE=0 → mono, =1 → color-capable.
- **Q3:** full 262-line NTSC frame, **continuous live display** (keep feeding;
  toggles take effect on the fly, no rebuild on mode change; rebuild+preamble
  only on image change / Reset button).
- **PNG-dump button** (user request): GUI button to save the current frame as
  PNG, reusing the same encoder as `--dump-frame` so GUI and headless dumps are
  byte-identical.

---

## Next steps (when resuming)

1. **Resolve the open question** (B&W/green/amber artifact-color behavior) with
   the user → decide (a)/(b)/(c) above. (Still open as of Phase 2 completion.)
2. **Phase 3 — ImGui GUI:**
   - Copy needed SDL/OpenGL2/ImGui from `../verilator/sim/imgui/` (relative
     build paths, do not duplicate the whole harness) and `sim_video.{cpp,h}`
     texture/zoom behavior (strip audio/input/bus/storage).
   - Controls window (image dropdown, open-image, threshold slider, display
     combo, palette combo, Composite/Sharper-RGB, vertical-blend checkbox,
     COLOR_LINE combo + N slider, reload/reset, **Save-frame-as-PNG button**,
     status text) + video window (zoom/rotate/flip, DUT texture, optional mono
     preview).
   - Continuous sim loop feeding the selected image every frame; live toggles.
   - Add ImGui sources + SDL2 to the Makefile.
4. **Phase 4 — validation:** `--smoke-test` (headless, no SDL), load all
   bundled images, all display modes + 3 built-in palettes, seam/comb on/off,
   deterministic frame hashes across two clean reconstructions, unsupported-size
   failure, optional PPM on failure.
5. **README.md** for vga_color_test (build/run/image requirements/controls +
   the copied-controller sync workflow).

## Reference
- Equivalence harness (cycle-vs-VHDL): `../module_tests/vga_controller/`
  (`run_equivalence.ps1`). Complements, does not replace, this tester.
- Active controller: `../rtl/vga_controller.v`. Snapshot:
  `rtl/vga_controller.v`. Compare after any edit to either:
  `git diff --no-index rtl/vga_controller.v ../rtl/vga_controller.v`.
