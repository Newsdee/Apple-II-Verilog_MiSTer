# Apple II Verilator Harness

This directory contains a desktop simulation harness for the MiSTer Apple II
core. Verilator builds the RTL model, while the C++ harness supplies the MiSTer
wrapper services needed for video, audio, keyboard input, ROM loading, floppy
images, and HDD images.

The supported Windows build uses MSYS2 UCRT64, Verilator, GCC, Make, and SDL2.
It does not require a separate Verilator template checkout or the vendored
legacy Verilator runtime under `sim/vinc`.

## Prerequisites

Install MSYS2 in `C:\msys64`, then install the UCRT64 packages from an MSYS2
shell:

```sh
pacman -S --needed mingw-w64-ucrt-x86_64-verilator \
  mingw-w64-ucrt-x86_64-SDL2 mingw-w64-ucrt-x86_64-gcc make
```

The Windows scripts currently expect these locations:

- MSYS2 Bash: `C:\msys64\usr\bin\bash.exe`
- UCRT64 runtime DLLs: `C:\msys64\ucrt64\bin`

## Build

From Command Prompt or PowerShell:

```bat
build_verilator.bat
```

The script enters the UCRT64 environment and invokes `verilate.sh`. The output
is `obj_dir\Vemu.exe`; `obj_dir` is generated and ignored by Git. Arguments are
forwarded to Make, so targets and job counts can also be supplied:

```bat
build_verilator.bat clean
build_verilator.bat -j4
```

Verilator 5 reports several warnings from legacy RTL. The Makefile uses
`-Wno-fatal` so those warnings remain visible without preventing generation.

## Run

Use the launcher rather than starting `Vemu.exe` directly:

```bat
run_verilator.bat
```

The launcher adds the UCRT64 DLL directory to `PATH`, changes to this directory
so relative ROM/media paths resolve, and forwards all arguments to the
simulator. With no arguments, `floppy.nib` is mounted in Drive 1.

Available media options:

```text
--floppy FILE     Mount FILE as floppy Drive 1 (slot index 0)
--floppy2 FILE    Mount FILE as floppy Drive 2 (slot index 2)
--hdd FILE        Mount FILE as the HDD (slot index 1)
--no-floppy       Do not mount the default floppy
--palette FILE    Load a 48-byte custom A2P palette through ioctl index 2
--smoke-test      Run the finite automated runtime check and exit
--help            Print command usage
```

Examples:

```bat
run_verilator.bat --floppy "C:\Images\diagnostics.nib"
run_verilator.bat --floppy "C:\Images\disk1.nib" --floppy2 "C:\Images\disk2.nib"
run_verilator.bat --no-floppy --hdd "C:\Images\system.hdv"
run_verilator.bat --palette "C:\Palettes\PICO-8.a2p"
```

Media files are currently opened read/write. Use a disposable copy when an
image must remain pristine. A requested file that cannot be opened stops
startup and returns exit code 1; malformed arguments return exit code 2.

## Automated Smoke Test

Run the default floppy test with:

```bat
run_verilator.bat --smoke-test
```

To include HDD mounting without modifying the source image, first make a copy
and pass the copy:

```bat
run_verilator.bat --no-floppy --hdd "C:\Temp\test.hdv" --smoke-test
```

A passing smoke test verifies that:

- ROM loading and simulator startup complete.
- Requested media reaches the MiSTer-style mount handshake.
- The default floppy services sector reads when present.
- A PS/2 key press and release traverse the harness event queue.
- Soft reset is asserted and released.
- At least six video frames render.
- SDL2 audio playback opens and core audio samples reach the bounded queue.
- F6-F9 video shortcuts cycle through their complete state ranges and return
  to the initial state.
- F10 opens and closes the on-screen keyboard.
- A requested custom palette finishes its ioctl transfer before exit.

The result line includes frame count, audio sample count and peak, remaining key
events, and reset state. Exit code 0 means all automated checks passed.

The smoke test does not prove that the rendered picture is visually correct,
that software acted on the injected key, that HDD contents boot correctly, or
that the core generated a nonzero audible signal. Check those interactively.

## Interactive Controls

The simulation window contains:

- Simulation controls for full reset, soft reset, run/stop, single-step, and
  batch size.
- A VGA window with zoom, rotation, and vertical flip controls.
- Left/right audio waveform plots.
- A debug log window.

The Pixel clock control matches the MiSTer `Double`/`Normal` option. Double
captures all 560 active horizontal samples. Normal captures every other sample
and doubles it in the 640-pixel simulator framebuffer, preserving screen size.

SDL keyboard events are translated to MiSTer-style PS/2 events. Keep the
simulation window focused when testing the Apple II keyboard. The harness also
maps arrows, `A`, `B`, `X`, `Y`, `L`, `E`, `1`, `2`, and `M` to its generic
joystick/menu inputs.

The MiSTer OSD and its `status[]` register are not simulated. Equivalent video
settings are available in the Simulation control window and through shortcuts:

- `F8`: cycle NTSC //e, IIgs, AppleWin, and Custom palettes; force Color mode.
- `F9`: cycle Color, B&W, Green, and Amber display modes.
- `F6`: toggle sharper RGB artifact-color transitions.
- `F7`: toggle NTSC vertical chroma blending.
- `F10`: show or hide the on-screen keyboard.

F8, F9, and F10 match the original newsdee core bindings. F6 and F7 expose the
newer OSD-only video filters directly because no OSD exists in the harness.

## Enhanced VGA Port

`rtl/vga_controller.v` is a structurally aligned Verilog translation of the
active `Apple-II_MiSTer_newsdee/rtl/vga_controller.vhd`. It retains the VHDL
process boundaries and signal names where practical to support the eventual
whole-core SystemVerilog migration. The port includes:

- NTSC //e, IIgs, AppleWin, and downloaded custom palettes.
- Custom `.a2p` palette loading over MiSTer ioctl index 2.
- Optional sharper artifact-color transitions without gray seams.
- The seam-cleanup timing pipeline from the original controller.
- A 560-pixel previous-line RGB buffer and optional vertical chroma comb.
- Original line-doubler blanking and sync generation.

The simulator wrapper exposes video settings as top-level model inputs in place
of MiSTer `status[]` bits. `rtl/apple2_top.v` passes those controls and the ioctl
bus to the translated controller.

## Implementation Map

- `sim.v`: simulation-specific MiSTer wrapper, video settings, ioctl bus, and
  block-device slot wiring.
- `sim_main.cpp`: core lifecycle, CLI parsing, GUI, clocks, resets, and smoke
  test orchestration.
- `sim/sim_blkdevice.*`: MiSTer block-device mount/read/write handshake.
- `sim/sim_input.*`: SDL/DirectInput keyboard state and PS/2 event delivery.
- `sim/sim_video.*`: SDL2/OpenGL video and Dear ImGui integration on UCRT64.
- `sim/sim_audio.*`: 44.1 kHz stereo sampling, waveform data, and bounded SDL2
  queued playback.
- `Makefile`: RTL source closure, Verilator generation, C++ compilation, and
  platform libraries.
- `build_verilator.bat`, `verilate.sh`: reproducible Windows build entry points.
- `run_verilator.bat`: Windows runtime entry point and DLL-path setup.

The SDL audio queue is capped at approximately 100 ms. When simulation runs
faster than playback, new samples are dropped until the queue drains instead of
allowing memory usage to grow without bound.