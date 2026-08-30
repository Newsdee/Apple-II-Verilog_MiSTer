# Apple-II full-core harness — investigation progress

Status as of this handoff: **T65 harness PASS, suite 12/13 pass; `apple2` is the only failure.**
The `apple2` failure is a **coverage-gate failure, not a field-level mismatch**: GHDL and
Verilator traces still match field-for-field. The gate that throws:

```text
Coverage failure: normal park at $0580 was never reached (program did not complete)
(run_equivalence.ps1 line 154)
```

Everything below is from the instrumented debug runs. No commits were made; the user manages git.

## Where the CPU actually goes

Boot walk reaches the TB override at `$5857` (JMP $C100 intended), but then:

1. Fetch windows at `$5857/$5858/$5859` — DI shows `4C/00/C1` on the **last** row of each
   window (rows 413/427/441). Early rows of each window still show the *previous* window's
   byte (one-cycle ROM/settling latency: e.g. row 428 of the $5859 window shows DI=00, the
   $5858 byte).
2. Three stack writes: `58`→$01FD, `5A`→$01FC, `B4`→$01FB (rows 442–483). S: FFFD→FFFA.
3. Vector reads: A=$FFFE (rows 484–497) then A=$FFFF (rows 498–511).
4. PC := **$C3FA** from row 512; CPU then executes real ROM code at $C3xx/ROM[03xx] and
   never returns to main RAM → park at $0580 never reached → gate fails.

The pushed return address is $585A (hi 58 @01FD, lo 5A @01FC), i.e. the CPU behaved as if a
BRK sat at **$5859** — but DI on the latch row of the $5857 window was 4C. See "Mystery 1".

## The ROM_ADDR anomaly (Mystery 2) — the big one

New debug columns (this session): `ROM_ADDR` = DUT `rom_addr` wire, `ROM_OUT` = DUT
`rom_out`. Trace rows 478–516:

```text
478-483 A=01FB ROM_ADDR=01FB ROM_OUT=24   (correct: ROM[0x01FB]=24)
484     A=FFFE ROM_ADDR=3FFE ROM_OUT=24   (stale, 1-cycle latency)
485-497 A=FFFE ROM_ADDR=3FFE ROM_OUT=FA   (FA = ROM[0x3FFE])
498     A=FFFF ROM_ADDR=3FFF ROM_OUT=FA   (stale)
499-511 A=FFFF ROM_ADDR=3FFF ROM_OUT=C3   (C3 = ROM[0x3FFF])
512+    A=C3FA ROM_ADDR=03FA ROM_OUT=...  (normal slice again)
```

So the simulated ROM address is **$3FFE/$3FFF when A=$FFFE/$FFFF**, but a plain A(13:0)
slice for $C3FA→$03FA and $01FB→$01FB. Both GHDL and Verilator show identical values.

### Ruled out (verified this session)

- ROM file contents: `apple2e.mif`/`apple2e.hex` byte-identical; [0x0FFE]=CF,
  [0x0FFF]=DF, [0x3FFE]=FA, [0x3FFF]=C3, [0x01FB]=24.
- `module_tests/shared/spram_const.vhd`: clean shim, `q <= mem(base + to_integer(unsigned(address)))`,
  base=10240 for apple2e; entries[14334]=CF verified in file.
- `rtl/rom.v`: clean `data_out <= d[a]`.
- `HRAM_READ_EN`/`CPU_DL` path: at $FFFE, `HRAM_READ_EN = HRAM_READ and A(15) and A(14) and (A(13) or A(12))`
  (apple2_ent.vhd line 376) could route D_IN to CPU_DL, but the TB RAM byte functions give
  main_byte($FFFE)=0x39/($FFFF)=0x3A and aux=(ai*7+165)%256 → 0x97/0x9E — none equal FA/C3.
- Multiple drivers: `grep -i rom_addr` in `rtl/apple2.v` → single `wire [13:0] rom_addr;`
  (line 165), single `assign rom_addr = A[13:0];` (line 257), single use `.a(rom_addr)` (606).
  `A` single-driven: line 553 `assign A = (cpu == 1'b0) ? (T65_A[15:0]) : R65C02_A;`,
  `assign ADDR = A;` (line 250). VHDL copy: single `A <= ...` (line 508), single
  `rom_addr <= A(13 downto 0);` (line 231), `ADDR <= A` (line 226).
- Stale build: the new debug ports appear in the traces, so both simulators compiled the
  current edited files.

### The paradox

Measured same-instant values: `ADDR`=FFFE and `ROM_ADDR`=3FFE, with `rom_addr = A[13:0]` as
the only driver. Under standard Verilog semantics that requires A=$F3FE (or similar) at that
instant — which ADDR should then also show. **Not yet explained.**

## Instrumentation added this session (all uncommitted)

- `rtl/apple2.v`: ports `DBG_T65_REGS [63:0]`, `DBG_DI [7:0]` (previous session) plus
  `DBG_ROM_ADDR [13:0]`, `DBG_ROM_OUT [7:0]` (this session); assigns from `rom_addr`/`rom_out`;
  `.Regs(DBG_T65_REGS)` on the cpu6502 instance.
- `module_tests/apple2/apple2_ent.vhd`: same four ports (**entity port list uses semicolons** —
  hit the GHDL "interfaces must be separated by ';'" error twice with commas); assignments at
  end of arch.
- Both TBs: debug signals/wires, DUT port-map entries, CSV header now ends
  `...,NMI_N,T65_REGS,T65_DI,ROM_ADDR,ROM_OUT`, per-cycle writes (SV format `%016h,%02h,%04h,%02h`).

### Trace column map (24 columns, 1-based)

1 CYCLE, 2 ADDR, 3 D(D_OUT), 4 RAM_ADDR, 5 RAM_WE, 6 AUX, 7 CPU_WE, 8 PD, 9 IO_SELECT,
10 DEVICE_SELECT, 11 IO_STROBE, 12 SPEAKER, 13 VIDEO, 14 PHASE_ZERO, 15 PHASE_ZERO_R,
16 PHASE_ZERO_F, 17 ROMSWITCH, 18 PALMODE, 19 CPU_WAIT, 20 NMI_N, 21 T65_REGS (16 hex:
PC[0:4] S[4:8] P[8:10] Y[10:12] X[12:14] A[14:16]), 22 T65_DI, 23 ROM_ADDR, 24 ROM_OUT.

Traces: `module_tests/apple2/build/vhdl_trace.csv` and `build/verilog_trace.csv`.

## Timing model facts (verified earlier)

- `CPU_EN` = 1-cycle pulse on the cycle where PHASE_ZERO just fell (`PHASE_ZERO_D='1' and
  PHASE_ZERO='0'`). In the $FFFE window PZ falls at **row 497** (last row); T65's clocked
  process latches at the rising edge with enable high, so the latched byte = DI on the
  PZ-fall row.
- **PZ timing is address-dependent** (timing generator), so the latch row differs per window.
  Earlier dumps sampled fixed rows (c%14===3) and misread which byte was latched.
- ROM is synchronous, 1-cycle latency (first row of each window shows previous address's data).

## Next steps (in order)

1. **Re-dump trace rows ~395–520 with column 14 (PHASE_ZERO)**; for each 14-cycle window find
   the PZ-fall row (CPU_EN) and record DI on that exact row → reconstruct the true latched
   instruction stream. This may dissolve Mystery 1 (the "BRK at $5859" reading came from a
   fixed-row sample; the real latch row may show a different byte).
2. **Resolve the A vs rom_addr paradox**: zero-cost pre-checks first —
   - `grep -rn "module apple2"` over all Verilog sources in the Verilator build list (rule out
     a shadowing second definition / stale copy); confirm the runner's exact source list.
   Then add debug ports `DBG_T65_A` (full 24 bits), `DBG_R65C02_A`, `DBG_CPU` to both DUTs +
   TBs, re-run, and compare against ADDR/ROM_ADDR during the $FFFE window: is A really FFFE
   when rom_addr=3FFE, or is A=$F3FE with ADDR sampled stale?
3. Apply the fix (likely TB program/gate-side once root cause is known; only touch RTL if a
   genuine common bug is proven — remember both sides match, so prefer shared-environment causes).
4. Re-run harness to green; then decide keep-vs-remove for the debug ports (document choice).
5. Update `module_tests/README.md` roster + this file's status. Do **not** commit.

## Comparison-tool audit (all 13 harnesses)

After the overlapping-slice bug in my ad-hoc `decode_trace.js` (this session only — never
part of any harness, affected no results), all harness comparison scripts were audited for
the same defect classes:

- Column access: all header-driven by name, no positional offsets.
- Case: all ToUpperInvariant both sides.
- Metavalue skip: only on VHDL/golden side `[UXWZ-]`, always counted.
- Row counts: all throw on mismatch; t65 enforces exact expected rows; dpram checks CYCLE per row.
- Anti-vacuous gates: apple2 ≥50k fields+8 behavioral · disk_ii ≥40k+flags · hdd ≥90k ·
  keyboard ≥1.5k+8 behavioral · video_generator ≥4k+ROM/transition · t65 exact rows+17 gates ·
  timing_generator VBLANK/PHI0/per-column · vga_controller ≥163k rows+HS≥170 · via6522
  transition/IRQ/DOUT · mockingboard rw counts · apple2_font_rom ≥4200 rows+glyphs ·
  dpram INIT zero-readback (no min-fields gate — optional hardening).
- virtual_keyboard_overlay: not a GHDL/Verilator equivalence harness (single Verilator build,
  reference vs candidate modules).

Independent re-check of apple2 match via `decode_trace.js --diff` (mirrors harness rules):
compared_fields=535761 ignored_metavalues=1071 mismatches=0.

## decode_trace.js (this session, new tool)

`module_tests/apple2/decode_trace.js` — deterministic trace decoder:
- `node module_tests/apple2/decode_trace.js <trace.csv> --cpu-en [--from N] [--to N]`
  prints one line per CPU_EN event (PZ-fall row = T65 latch edge) with decoded registers.
- `node module_tests/apple2/decode_trace.js --diff a.csv b.csv` re-verifies equivalence
  independently of the PowerShell harness (same rules: per-field, case-insensitive,
  skip fields where VHDL value has [UXWZ-]).
- T65_REGS layout pinned from source (t65.vhd line 275 / t65.v line 407):
  [0:4]=PC [4:8]=S [8:10]=P [10:12]=Y [12:14]=X [14:16]=A. Parse fails loudly on bad input.
- Known fixed bug history: first version used overlapping slice windows (slice(n*2,n*2+4))
  which mislabeled S/P/Y/X/A — do not reuse that pattern; the current file is correct.

## Commands

```powershell
# full harness (from E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer)
powershell -NoProfile -ExecutionPolicy Bypass -File module_tests/apple2/run_equivalence.ps1

# fast GHDL-analysis-only check (prints errors without running sims)
C:/msys64/ucrt64/bin/ghdl.exe -a --std=08 -fsynopsys "--workdir=module_tests/apple2/build/vhdl" `
  module_tests/shared/spram_const.vhd module_tests/apple2/ramcard_stub.vhd `
  module_tests/apple2/timing_generator_init.vhd module_tests/apple2/video_generator_ent.vhd `
  ../Apple-II_MiSTer_newsdee/rtl/t65/T65_Pack.vhd ../Apple-II_MiSTer_newsdee/rtl/t65/T65_MCode.vhd `
  ../Apple-II_MiSTer_newsdee/rtl/t65/T65_ALU.vhd ../Apple-II_MiSTer_newsdee/rtl/t65/T65.vhd `
  module_tests/apple2/R65C02_ent.vhd module_tests/apple2/apple2_ent.vhd module_tests/apple2/apple2_vhdl_tb.vhd
```

Trace analysis: node one-liners over `build/vhdl_trace.csv` (split on `,`; columns above).

## TB environment reference

- Main RAM low byte `main_byte(a)`: pattern `(ai + ai/16 + 60) mod 256`, overrides:
  $5857–$585B = `4C 00 C1 EA EA` (JMP $C100), $0540–$056E = PHASE_B, $0580–$0582 = `4C 80 05`
  (normal park JMP $0580), $05A0–$05A2 = `4C A0 05` (error park JMP $05A0).
- Main RAM high byte: `(ai*7 + 165) mod 256`.
- Reset vector: ROM[0x0FFC]/ROM[0x0FFD] → PC=$6B4C (boot walk through real ROM reaches $5857).
- `cpu='0'` in both TBs (T65 active, R65C02 parked).

## Gotchas learned

- VHDL **entity** port lists are semicolon-separated (component port maps too); GHDL errors:
  "interfaces must be separated by ';'". Hit twice this session.
- Use node byte-level splices with an occurrence-count check (`split(old).length-1 === 1`) to
  preserve CRLF/mixed EOLs in these files.
- The `D` column is D_OUT (CPU data output), **not** read data; read data is T65_DI (col 22)
  and raw ROM out is col 24.
- Fixed-row sampling of a 14-cycle window misreads latched bytes — always use the PZ-fall row.
