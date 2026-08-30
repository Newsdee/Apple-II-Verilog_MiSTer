# video_generator equivalence harness

Cycle-equivalence test for the Apple II video generator, proving the VHDL
golden (`Apple-II_MiSTer_newsdee/rtl/old/video_generator.vhd`) and the Verilog
candidate (`rtl/video_generator.v`) behave identically on their full port
interface.

## Run

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
Set-Location E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer
.\module_tests\video_generator\run_equivalence.ps1
# re-check existing traces without rebuilding:
.\module_tests\video_generator\run_equivalence.ps1 -CompareOnly
```

Known good result:

```text
VIDEO_GENERATOR EQUIVALENCE PASS rows=1020 fields=5079 ignored_metavalues=21 sync_ff=1 wndw_ff_load=1 ioctl_readback=1 romswitch_halves=1 mixed_rom_loads=21/27 video_transitions=164
```

## Files

- `video_generator_vhdl_tb.vhd` — golden-side testbench (ports only, see below).
- `video_generator_verilog_tb.sv` — candidate-side testbench, identical schedule.
- `run_equivalence.ps1` — builds both sides, runs both sims, compares CSVs,
  enforces coverage gates. Supports `-CompareOnly`.
- `build/` — generated artifacts (ignored): `vhdl/` (GHDL workdir,
  parse-normalized golden copy), `verilog/` (Verilator Mdir),
  `vhdl_trace.csv`, `verilog_trace.csv`.

## ROM parity

`rtl/roms/video2.hex` (candidate, 8192 words) is byte-identical to
`Apple-II_MiSTer_newsdee/rtl/roms/video2.mif` (golden source for the shim) —
verified 2026-08-29 (0 diffs). The golden side uses
`module_tests/shared/spram_const.vhd` (video2.mif segment) instead of
`rtl/spram.vhd` per the shared GHDL workaround.

## GHDL 6.0.0 quirks handled

1. **Shorthand entity instantiation** — `videorom : work.spram` in
   `video_generator.vhd:73` is rejected by GHDL; the runner generates
   `build/vhdl/video_generator_golden.vhd` adding only the explicit `entity`
   keyword (strict single-occurrence + length check; RTL untouched).
2. **No hierarchical instance selection** — this GHDL build rejects ALL
   hierarchical selection of signals/ports through an instance (verified with
   minimal repros: entity and component instantiations, port and internal
   signals, std 93c and 08). The testbench therefore traces **ports only**
   and recovers internal state behaviorally:
   - The shift register walks a loaded byte out LSB-first inverted on VIDEO
     (one bit per shift cycle; `CLK_7M=1` hold cycles repeat the current bit,
     never skip or reorder).
   - The schedule uses 25-cycle blocks (odd, so SEGA/SEGB/SEGC and DL(5:0)
     vary between loads) with a 14-shift/14-hold CLK_7M phase
     (shift for `(N mod 28)` in 14..27).
3. **Pre-first-load metavalue** — the module has no reset; cycles 4..24 show
   `'U'` on the golden side (21 ignored metavalue fields) until the first
   load effective under the CLK_7M phase (cycle 25, an FF sync load).

## Stimulus (identical in both testbenches, 1024 cycles)

- `LDPS_N=0` (load) when `N mod 25 = 0`; `CLK_7M` toggled at `N mod 14 = 0`.
- `DL=(N*7) mod 256`, SEGA/SEGB/SEGC/GR2/ALTCHAR/ROMSWITCH/FLASH_CLK toggled
  at divisors 1/2/4/8/16/64/32 — sweeps the ROM address space.
- `WNDW_N=1` for `N <= 49` (FF sync load at 25) and `100..124` (FF load at
  100); `0` otherwise (ROM-data loads).
- ioctl write window `504..513`: `addr=0x234`, `data=(N*3) mod 256` (last
  write stores `0x03`).
- Readback window `748..773`: forces `video_rom_input_addr=0x234`
  (`dl=0x46, altchar=1, segc=1`, all else 0 — address math verified by
  script); the load at 750 reads the written byte.
- ROMSWITCH window `799..975`: forces `addr=0x118` (romswitch=0, `799..822`)
  / `0x1118` (romswitch=1, `823..975`) via `dl=0x23`; loads at 800 and 950
  read the two halves, which differ exactly at these offsets
  (ROM[0x118]=0x38, ROM[0x1118]=0x14; the halves differ at 14 total bytes,
  0x118-0x11E and 0x518-0x51E).

## Trace and gates

CSV columns: `CYCLE, VIDEO, LDPS_N, WNDW_N, DL, MODE`
(`MODE = ROMSWITCH GR2 ALTCHAR FLASH_CLK SEGC SEGB SEGA`), sampled at
rising edge + 1 ns from cycle 4. All columns compared field-by-field
(case-insensitive; golden metavalue rows skipped and counted).

Coverage gates (run on the golden trace; equivalence with the candidate is
the field comparison):

- `sync_ff` — FF sync load at 25 visible (VIDEO all 0 over 25..49).
- `wndw_ff_load` — WNDW_N=1 load at 100 visible (VIDEO all 0 over 100..127).
- `ioctl_readback` — the byte written at 0x234 (0x03) walks out with the
  exact run-length pattern `0x2,1x20,0x2,1x1` over 750..774.
- `romswitch_halves` — ROM[0x118]=0x38 (`1x3,0x3,1x5,0x17,1x5,0x3` over
  800..835) and ROM[0x1118]=0x14 (`1x16,0x1,1x1,0x1,1x5,0x1` over 950..974)
  each walk out with their exact run-length pattern.
- `mixed_rom_loads` — >= 20 of the general 25k load blocks show a
  non-constant walkout (loaded byte was neither 0x00 nor 0xFF).
- `video_transitions` — >= 100 VIDEO 0/1 transitions.
- `fields` — >= 4000 compared fields.

## Scope

- Proves: full port-level cycle equivalence (VIDEO for all inputs), ROM
  read/write semantics (registered output, write-new-data), shift register
  load/shift/hold behavior, ROMSWITCH half selection, ioctl ROM rewrite.
- Does not prove: visual correctness on hardware, Quartus synthesis of the
  Verilog candidate, behavior of the `work.spram` entity itself (covered by
  the shared shim verification and the dpram harness).
