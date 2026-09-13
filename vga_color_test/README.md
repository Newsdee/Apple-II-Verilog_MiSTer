# vga_color_test

Standalone Verilator + ImGui tester for the Apple II VGA controller
(`vga_controller.v`). It loads 1-bit Apple II images, feeds their video bit
and NTSC timing directly into the controller, and shows the processed RGB
output — for rapid visual development of the artifact-color pipeline without
booting the full machine.

Design and decisions: `PLAN.md`. Live status, findings, and resume point:
`PROGRESS.md` (read that first when picking this up again).

## What is verilated

Four HDL files:

- `rtl/vga_color_test_top.sv` — pass-through wrapper plus the composite
  sync derivation (mirrors the FPGA wrapper)
- `rtl/vga_controller.v` — **snapshot** of `../rtl/vga_controller.v` (see
  "Controller snapshot sync" below)
- `rtl/apple_composite.sv` — **snapshot** of `../rtl/apple_composite.sv`
  (NTSC composite encoder + decoder loopback), extended with the decoder
  knobs the FPGA wrapper hardwires (smear, luma_delay, chroma_map,
  chroma_short, agc_en) as live inputs
- `rtl/composite_decoder.sv` — **snapshot** of
  `../unit_tests/level_2/mister/composite_decoder.sv` (mister's portable
  NTSC composite decoder, SPC=4)

No full-machine sources, no Quartus files, no audio.

## Composite decode branch

The top also instantiates `apple_composite` on the same raw VIDEO/HBL/VBL
feed, in parallel with the VGA controller. The raw stream carries no sync
or burst, so the encoder synthesizes them (sync tip from the hs pulse, a
free-running color burst in the back porch) exactly as the FPGA wrapper
does; the decoder inside `apple_composite` then recovers RGB from the
modulated stream. Capture source is selectable at run time — the GUI
"Composite" box (on by default) or `--no-composite` on the CLI. The VGA
controller path is untouched and still runs every frame.

Notes:

- The composite active window is the full **560** samples (the VGA
  controller drops 1 to 559); the frame buffer still stores 559×192.
- A 1-bit source has no chroma of its own, so what you see is a real
  composite receiver's response to 14.318 MHz 1-bit video: luma plus the
  decoder's artifact-color response (the same physics as the classic Apple
  II composite colors). The hue/sat knobs rotate/scale that chroma.
- The decoder re-locks burst and black clamp every line, so all knobs are
  live with no rebuild; a knob change applies from the next line.

## Build and run

Windows + MSYS2 UCRT64 (same toolchain as the full simulator):

```bat
cd E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer\vga_color_test
build.bat            (or: build.bat clean | build.bat -j4)
run.bat              -> ImGui GUI
```

Prerequisites (MSYS2): `mingw-w64-ucrt-x86_64-verilator`,
`mingw-w64-ucrt-x86_64-SDL2`, `mingw-w64-ucrt-x86_64-gcc`, `make`.
`build.sh` locates the ucrt64 toolchain itself; `run.bat` sets the DLL path.

Stop any running `Vvga_color_test_top.exe` before rebuilding (Windows locks
the linker output — a stale GUI instance is the usual cause of a mysterious
link failure).

## Command-line modes

| Command | Mode |
|---------|------|
| `run.bat` | **GUI** (default) |
| `run.bat --image assets\batman.png` | GUI with that image preloaded |
| `run.bat --dump-frame out.ppm` | headless: simulate, dump PPM |
| `run.bat --dump-png out.png` | headless: simulate, dump PNG |
| `run.bat --smoke-test` | headless automated validation (Phase 4 gates) |
| `run.bat --ppm2png in.ppm out.png` | convert any stb-readable image to PNG |

Useful options: `--display color|bw|green|amber`, `--palette
ntsc|iigs|applewin|custom`, `--sharp-rgb`, `--vertical-blend`, `--color-line
none|text|full`, `--color-line-start N`, `--threshold 0..255` (default 128),
`--phase 0..3` (default **2**), `--align 0..16` (default **12**), `--frames N`
(default 3 = 2 preamble + 1 captured), `--debug`.

Composite branch: `--composite` / `--no-composite` (capture source; composite
is the default), `--comp-sat N` (128=unity), `--comp-hue N` (256=cycle),
`--comp-bright N` (-128..127), `--comp-contrast N` (128=unity),
`--comp-pixel-delay 0..3`, `--comp-smear 0..15`, `--comp-luma-delay 0..15`,
`--comp-chroma-map 0..3`, `--comp-chroma-short`, `--no-comp-agc`. Every
`--comp-*` flag also turns the composite capture on.

Run `validate.bat` for a single-command clean validation build and smoke test.
It uses `obj_dir_validate` so an open GUI does not lock the normal executable.

## Input images

1-bit Apple II frames. Color is ignored after a luminance threshold
(default 128). Supported sizes (anything else is rejected with a visible
error, never rescaled):

| Input | Mapping to the 560 active samples |
|-------|-----------------------------------|
| 280×192 | duplicate each pixel horizontally |
| 284×192 | crop 2 px per side, then duplicate |
| 559×192 | direct, pad the 560th sample with the last column (the DUT drops it anyway) |
| 560×192 | direct |
| 568×192 | crop 4 px per side |

The GUI combo live-rescans `assets/` every frame — drop in a new image and it
appears without a restart.

Bundled examples live in `assets/` (284-px game grabs and 568-px processed
screens). PNG, BMP, and PPM are accepted.

Note: 2×-duplicated (280/284-px) sources can only produce ~2 of the 16
artifact colors — the duplication phase-locks the `hcount[1:0]` color
rotation. Use a native 560/568-px source to see the full palette.

## GUI controls

Controls window (left):

- **Image (bundled)** / **Open image path + Load** — source selection
- **Luminance threshold** — re-thresholds and re-primes the DUT
- **Feed phase (color, mod 4)** — default 2 (verified against real NTSC
  colors; wrong values rotate the palette, e.g. red↔blue)
- **Feed align (samples)** — default 12 (compensates the DUT's ~12-sample
  data/window skew so content lands where the real core's video phase puts
  it). Phase and align are coupled mod 4; both are live, no rebuild.
- **Display** — Color / B&W / Green / Amber. Selecting B&W/Green/Amber
  forces COLOR_LINE off (the DUT would otherwise still show artifact colors
  on color lines — a known divergence under investigation, see PROGRESS.md).
- **Palette** — NTSC //e / IIgs / AppleWin / Custom
- **Sharper RGB** / **NTSC vertical blend** — `GRAY_SEAM_FIX` /
  `NTSC_VERTICAL_COMB`
- **COLOR_LINE** — No color / Text + graphics (+ line slider) / Full color
- **Reset** — reconstructs the DUT model + 2-frame preamble (the controller
  has no reset port)
- **Save frame as PNG** — `output/gui_frame_<timestamp>.png` (same encoder
  as the headless dumps, so GUI and CLI captures are byte-identical)
- Status line: frame count, fps, loop/sim ms, distinct colors

Composite Knobs window (below the controls):

- **Composite decode path (box)** — selects the captured output source
  (composite on by default); the VGA controller keeps running either way
- **Saturation / Hue / Brightness / Contrast** — the decoder's luma and
  chroma adjust knobs (128/0/0/128 = identity)
- **Pixel delay / Chroma smear / Luma delay** — encoder source delay and
  the decoder's chroma-trail / luma-alignment knobs
- **Chroma map / Chroma short / AGC** — I/Q mapping, boxcar length, burst
  level tracking
- **Reset knobs to defaults**

All knobs are live (the decoder re-locks every line); the video window's
first line shows which source is being captured.

Video window (right):

- **Full 559 / Half (scaled)** — half scales the whole frame to 50%
- **4:3 canvas 640×480** — scanline-doubled (192→384), top-left, black
  remainder: the real-output look (zoom auto-halves when toggled)
- **Zoom** 0.5–8×

The sim runs continuously (one 262-line DUT frame per GUI iteration, no
artificial cap — the fps readout is the true DUT throughput). Mode toggles
take effect on the fly; model reconstruction happens only on image/threshold
change and Reset.

## Frame geometry (measured DUT behavior, matches the golden)

- Source: 262 lines × 912 clocks (HBL high for 352 clocks, 560 active).
- Output: **559** px × 192 lines (107,328 px) — the hcount reset latency
  drops one sample; the rightmost source sample never reaches the output.
- The RGB data pipeline leads the timing window by ~12 samples; the feed
  `align` offset compensates (the real core's video phase does this
  implicitly).

## Controller snapshot sync

`rtl/vga_controller.v` is an intentional copy of the active controller.
Never assume parity — compare explicitly:

```powershell
git diff --no-index Apple-II-Verilog_MiSTer/rtl/vga_controller.v `
  Apple-II-Verilog_MiSTer/vga_color_test/rtl/vga_controller.v
```

Workflow when the active controller changes:

1. Run the equivalence harness against the VHDL golden:
   `Apple-II-Verilog_MiSTer\module_tests\vga_controller\run_equivalence.ps1`
2. Re-snapshot: copy `../rtl/vga_controller.v` over
   `rtl/vga_controller.v`, verify the diff above is empty.
3. `build.bat clean && build.bat`, then `run.bat --smoke-test`.

Do not back-port tester changes into `../rtl/vga_controller.v` without the
equivalence harness passing.

## Validation scope

`--smoke-test` covers capture geometry, the settings matrix, B&W mono,
determinism across reconstructions, feeder alignment, and bad-size rejection
(see PROGRESS.md for the gate list). Verilator proves simulated logic
behavior — it does **not** prove Quartus timing, memory inference, or final
hardware image quality. The equivalence harness remains the cycle-level
source of truth against the VHDL reference.
