# Keyboard VHDL/Verilog equivalence test

Black-box differential test for the PS/2 + virtual keyboard module. The MiSTer
VHDL implementation (`../Apple-II_MiSTer_newsdee/rtl/keyboard.vhd`) is the
reference model; the active Verilog implementation
(`../../rtl/keyboard.v` + `../../rtl/rom.v`) is the candidate.

Run from PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\module_tests\keyboard\run_equivalence.ps1
```

To rerun only the comparison and coverage checks against existing traces:

```powershell
.\module_tests\keyboard\run_equivalence.ps1 -CompareOnly
```

## ROM handling

- Golden: `keyboard.vhd` instantiates `work.spram` with
  `"rtl/roms/keyboard.mif"`. Per the module-test rules (GHDL 6.0.0 does not
  honor `ram_init_file`), the runner analyzes
  `module_tests/shared/spram_const.vhd` instead of `rtl/spram.vhd`; the shim
  selects the keyboard.mif segment via the `init_file` generic.
- GHDL 6.0.0 additionally rejects the LRM-legal shorthand entity
  instantiation `keyboard_rom : work.spram` (line 85) with "component name
  expected, found entity", while Quartus accepts it. The golden RTL is never
  modified: the runner generates a parse-normalized copy
  (`build/vhdl/keyboard_golden.vhd`) that only adds the explicit `entity`
  keyword to that one instantiation (a semantic no-op), verified by an exact
  single-occurrence string replacement plus a length check.
- Candidate: `rtl/keyboard.v` has no `#ifdef` — it unconditionally
  instantiates the `rom` helper with `"rtl/roms/keyboard.hex"` (the spram/mif
  branch is commented out), so Verilator compiles the rom + keyboard.hex path.
- `keyboard.hex` and `keyboard.mif` were re-verified byte-identical
  (2048 x 8 bits) on 2026-08-28, the day this harness was built.

## Stimulus (hardcoded identically in both testbenches, 320 cycles)

- PS/2 byte stream (strobe held 6 cycles per byte, so break bytes are still on
  the bus at the KEY_UP state where modifiers/caplock act on the live code):
  - make A (0x1C), make left shift (0x12), make A with shift held, break left
    shift
  - make/break extended up arrow (ext 0x75)
  - make/break F2 (soft reset), make/break F8 (palette toggle), make/break
    F9 (video toggle)
  - make/break caps lock (break toggles the caplock latch), then make A with
    caplock set
- `reads` strobes at cycles 20, 52, 84, 220, 248, 272 to clear key_pressed.
- Virtual keyboard window (cycles 232..271): press of code 0x2A with control,
  open apple (240..249), closed apple (250..255), then release and
  deassertion.

## Trace

`CYCLE,K,READ_KEY,AKD,OPEN_APPLE,CLOSED_APPLE,SOFT_RESET,VIDEO_TOGGLE,PALETTE_TOGGLE`
— one row per traced posedge of CLK_14M (rows for cycles 0..3 under reset are
skipped, matching the disk_ii pattern). K is the latched decoded keyboard byte
(bit7 = key_pressed); READ_KEY is the `reads` input, traced to prove stimulus
alignment.

## Coverage gates

The runner fails unless all of the following hold:

1. `soft_reset` pulse: asserted on the F2 make byte (HAVE_CODE) and
   deasserted by the F2 break byte (KEY_UP).
2. `video_toggle` pulse: F9 make then break.
3. `palette_toggle` pulse: F8 make then break.
4. Full key make/break: K bit7 observed high, AKD observed high, and an
   AKD 1->0 transition after the first key make (key-up path executed).
   Note on DUT semantics: in this design the PS2 strobe falling edge itself
   is seen as a key-up of whatever code is on the bus (IDLE re-arms on
   `old_stb /= ps2_key(10)`), so AKD is cleared by the byte's own deassertion;
   explicit break bytes (F0-style, bit9=0) additionally reach KEY_UP where
   they clear shift/ctrl/apple and the F2/F8/F9 toggles and toggle caplock —
   all of which are gated separately below.
5. Extended key: decoded value K=8B (up arrow, ROM[0x10F]) observed — only
   reachable through the extended junction mapping.
6. Caplock path: decoded value K=E1 (A with caplock set, ROM[0x253]) observed.
7. Virtual keyboard: decoded value K=AA (virtual code 0x2A press) observed.
8. Open and closed apple outputs both asserted via the virtual interface.
9. At least 1500 initialized fields compared (316 rows x 8 columns).

VHDL metavalue fields are skipped and counted as `ignored_metavalues`.

All generated executables, object files, and traces live in
`module_tests/keyboard/build`, keeping test collateral out of the core RTL
directories.
