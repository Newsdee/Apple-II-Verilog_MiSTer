# apple2_font_rom equivalence

Black-box differential test: Verilog `rtl/apple2_font_rom.v` must behave
identically, cycle for cycle, to golden VHDL
`../Apple-II_MiSTer_newsdee/rtl/apple2_font_rom.vhd`.

Status: **PASS - 2026-08-29 (candidate aligned per user decision)**

```
APPLE2_FONT_ROM EQUIVALENCE PASS rows=4228 fields=38052 ignored_metavalues=0
writes=37 divergent_write_probes=36 equal_writes=1 readbacks_ok=64 rom_values=103
```

- All 36 new != old read-during-write probes now match: both sides show the
  NEW value on the write cycle (golden write-first `spram` semantics).
  The one equal write (B2 probe 0) matches as designed.
- All 38,052 fields match; 64/64 readback checks pass (both sides show the
  written value from the first pure-read cycle after the write).

## Alignment (2026-08-29, per user decision)

Pre-alignment result (retained for reference):

```
APPLE2_FONT_ROM DIVERGENCE (expected write-first signature) first=cycle 4104,
GLYPH_DATA: VHDL=A5, Verilog=1C rows=4228 fields=38052 ignored_metavalues=0
divergent_writes=36 equal_writes=1 readbacks_ok=64
```

- Every new != old ioctl write cycle (36 of 37 writes) diverged on
  `GLYPH_DATA` for exactly that one cycle: golden showed the NEW value
  (continuous `glyph_data <= rom_out` from write-first `q`), candidate showed
  the PRE-WRITE value (registered `glyph_data <= font_rom[rom_addr]` reads
  the pre-edge memory). Real RTL difference, not a harness artifact.
- Fix applied to `rtl/apple2_font_rom.v` (one line):
  `glyph_data <= ioctl_wr ? ioctl_data : font_rom[rom_addr];`
- Runner updated from signature-enforcement mode to strict equivalence:
  on divergent writes both sides must now show the NEW value; any other
  combination is a hard failure. Full harness re-run (GHDL + Verilator):
  PASS, identical result via `-CompareOnly`.

Implementation: `gen_stim.ps1` (identical 4228-cycle table + stim_meta.csv
for the runner's memory tracking), `apple2_font_rom_vhdl_tb.vhd`,
`apple2_font_rom_verilog_tb.sv`, `run_equivalence.ps1` (strict comparison
that classifies write-cycle GLYPH_DATA mismatches against the tracked
memory model; any non-signature mismatch is an error). Golden copy
adds only the explicit `entity` keyword to the spram instantiation.

## What the module is

Writable 8192x8 single-port RAM (font ROM for the virtual keyboard overlay,
instantiated in the MiSTer wrapper / sim harness, NOT in `apple2.vhd`/`apple2.v`).

- Clock: `CLK_14M`, **no reset port**. Initial state = ROM contents only.
- Read address (combinational):
  `ROMSWITCH & "00" & (alternate_character OR lowercase_character) & character_code(5 downto 0) & glyph_row`
  - bits 11:10 are constant `00` on reads; `character_code(6)` is unused.
- Write: `ioctl_wr=1` writes `ioctl_data` to `ioctl_addr(12:0)` (host ioctl bus,
  shared with the VGA palette download in real use — writes can occur any cycle).
- Output `glyph_data` is registered (1-cycle read latency) on both sides.

## Golden-side requirements (read before writing the VHDL TB)

- Golden instantiates `work.spram(13, 8, "rtl/roms/video2.mif")`. Per top-level
  rule 8 (GHDL bugs), analyze **`shared/spram_const.vhd`** instead of
  `rtl/spram.vhd`. VERIFIED 2026-08-29: the shim's write path is
  `mem(...) <= data; q <= data;` — same write-first (`q` = NEW data on a write
  cycle) semantics as `rtl/spram.vhd`, so no semantic drift. If the shim is ever
  regenerated, re-verify this before running.
- Candidate loads `$readmemh("rtl/roms/video2.hex")`; run the Verilator sim with
  CWD = `Apple-II-Verilog_MiSTer` (rule 3 layout). Golden runs with CWD =
  `Apple-II_MiSTer_newsdee`.
- **Pre-check (rule 7):** verify `video2.mif` (newsdee) and `video2.hex`
  (Verilog repo) hold byte-identical content; report if not. (video_generator
  already verified this pair 2026-08-29 — re-verify, it is cheap.)

## Known risk — EXPECTED FINDING (design the stimulus to expose it)

Read-during-write divergence:

- Golden `spram.vhd`: on `wren='1'`, `q <= data` -> `glyph_data` shows the NEW
  value on the write cycle.
- Candidate `apple2_font_rom.v`: nonblocking `font_rom[rom_addr] <= ioctl_data`
  plus `glyph_data <= font_rom[rom_addr]` -> RHS reads the OLD value, so
  `glyph_data` shows the PRE-WRITE value on the write cycle.

Every cycle of this module is a read, and an ioctl write always targets the
read address, so **any write with new != old diverges on `GLYPH_DATA` for that
one cycle**. This was confirmed by the first run (2026-08-29) and resolved
by the one-line candidate fix recorded above (applied per user decision);
the runner now enforces strict equivalence.

The stimulus therefore contains deliberate read-during-write probes, plus one
write with new == old (must NOT diverge — sanity check on the signature).

## Stimulus (identical deterministic table in both TBs; no randomness)

Clock period arbitrary and identical (e.g. 70 ns). Inputs defined from cycle 0
(no metavalues on inputs). Phases:

- **A — read sweep (~4100 cyc):** `ROMSWITCH` x {ALT,LOWER} x `character_code[5:0]`
  x `glyph_row`: {0,1} x {00,01,10,11} x 0..63 x 0..7 = 4096 cycles covering the
  entire reachable read space. Then a short second pass (CH = 0..7, one
  ROMSWITCH/flag combo) with `character_code(6)=1` to prove bit 6 is ignored on
  both sides.
- **B — write + readback (32 pairs):** write addresses spread across all four
  quadrants (ROMSWITCH x flag bit), character codes stepping by 7 mod 64, rows
  cycling 0..7; every address has bits 11:10 = 00 so it is reachable through the
  read decode. Write data = `8'hA5 XOR addr[7:0]`. After each write, drive the
  normal decode to that same address for 2 cycles and capture `glyph_data`
  (registered read: expected value appears 1 cycle after the first pure-read
  cycle at that address).
- **B2 — read-during-write probes (4 writes):** 3 writes with data != current
  ROM content at that address, 1 write with data == current content.
- **C — interleave (~16 cyc):** normal reads, one ioctl write mid-stream, more
  reads; end on a stable pure read.

Total ~4200 rows.

## Trace schema (both TBs, sampled at posedge + 1 ns)

```
CYCLE,ROMSWITCH,ALT,LOWER,CH,ROW,IOCTL_WR,IOCTL_ADDR,IOCTL_DATA,GLYPH_DATA
```

Hex; CH = 2 digits, IOCTL_ADDR = 3 digits. Inputs are traced so the comparator
can identify read-during-write cycles in divergence reports.

## Coverage gates (runner must fail without them)

1. rows >= 4200 (full sweep present).
2. distinct `GLYPH_DATA` values across the trace >= 100 (ROM content is not
   degenerate / ROM load path works on both sides).
3. All four {ALT,LOWER} pairs present; both ROMSWITCH values present;
   rows with CH(6)=1 >= 8.
4. ioctl write cycles >= 36; readback capture cycles = 32, and each side
   independently shows the written value at the expected latency (a side failing
   its own readback is a harness error — report it, do not cross-compare).
5. `ignored_metavalues` <= 6 (only cycle-0 `GLYPH_DATA`: VHDL U / Verilator X).

## Runner contract

Standard shape (`disk_ii/run_equivalence.ps1` pattern), fixed tool paths,
`-CompareOnly` supported. Ends with:

```
APPLE2_FONT_ROM EQUIVALENCE PASS rows=<n> fields=<n> ignored_metavalues=<n> writes=<n> readbacks=32 rom_values=<n>
```

or a terminating error naming the first divergence (cycle, column, expected
VHDL value vs actual Verilog value). Given the known risk above, the expected
first result is a divergence on `GLYPH_DATA` at the first B2 write with
new != old — that is a correct, reportable outcome, not a harness failure.

## How to run (once implemented)

```powershell
Set-Location E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer
.\module_tests\apple2_font_rom\run_equivalence.ps1
.\module_tests\apple2_font_rom\run_equivalence.ps1 -CompareOnly
```
