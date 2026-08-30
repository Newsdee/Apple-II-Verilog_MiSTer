# Apple-II full-core harness — status

**Status: PASS.** The `apple2` GHDL-vs-Verilator equivalence harness is green and the full
`module_tests` suite is **13/13 pass, 0 fail, 0 skip** (299 s):

```text
APPLE2 EQUIVALENCE PASS rows=22624 fields=429840 ignored_metavalues=16 park=0580 aux_write=1 io_strobe=1 nmi=1 romswitch_01=1 palmode_0=1

Test                     Result Seconds
apple2                   PASS     62.43
apple2_font_rom          PASS      6.77
disk_ii                  PASS    111.66
dpram                    PASS      7.45
hdd                      PASS      4.04
keyboard                 PASS      2.39
mockingboard             PASS      3.44
timing_generator         PASS     21.84
t65                      PASS     14.45
via6522                  PASS      4.34
vga_controller           PASS     54.41
video_generator          PASS      2.43
virtual_keyboard_overlay PASS      3.42
```

The previous failure was a **coverage-gate failure** (`normal park at $0580 was never
reached`), not an RTL divergence — field comparison was always clean because both DUTs
received identical (broken) stimulus. The root cause turned out to be three stacked TB
program/model bugs, all now fixed in BOTH testbenches. No RTL behavior was changed; the
`DBG_*` debug ports added during diagnosis are still present (see "Remaining work").

## Root-cause chain (three layers)

### Layer 1 — boot handoff address (T65 RTS +1)

The ROM boot path ends with `JSR $FE84` / `RTS`. T65 JSR pushes PC+2 and RTS adds +1 to the
popped value, so the deterministic pattern walk lands at **$5858**, not $5857. The TB
override originally put `JMP $C100` at $5857, so the CPU hit a pattern byte (BRK) at $5858
and vector-faulted to $C3FA before Phase A ever ran — which is why "Phase A never executed"
was the original symptom. Fix: boot handoff override now occupies
$5857=$EA (NOP guard), $5858–$585A=`4C 00 C1` (JMP $C100), $585B=$EA.

### Layer 2 — softswitch values come from the ADDRESS, not the data bus

Two separate softswitch mechanisms exist in `rtl/apple2.v`:

- **$C050–$C05F** (`SOFTSWITCH_SELECT`): any access latches
  `soft_switches[A[3:1]] <= A[0]` at PHASE_ZERO_R (no write required).
  $C054/$C055 → `soft_switches[2]` = **PAGE2**; $C050/$C051 = TEXT_MODE;
  $C052/$C053 = MIXED_MODE; $C056/$C057 = HIRES_MODE; $C058–$C05F = AN.
- **$C000–$C00F** (`KEYBOARD_SELECT`): write-only latch (PHASE_ZERO_R & we), value = A[0]:
  $C001=STORE80, $C003=RAMRD, $C005=RAMWRT, $C007=CXROM, $C009=ALTZP, $C00B=C3ROM,
  $C00D=COL80, $C00F=ALTCHAR (each pair's low address clears, high sets).

The old Phase A wrote `$C001` intending RAMRD (actually sets STORE80) and ended with
`STA $C000` intending STORE80=1 (actually **clears** STORE80, because the value is A[0]=0).
Corrected Phase A uses STA $C055 (PAGE2=1), STA $C003 (RAMRD=1), STA $C001 (STORE80=1),
STA $C00C (COL80=0), plus harmless coverage writes to $C0FF (devselect) and main RAM.

### Layer 3 — the AUX RAM bank model (the big one)

`rtl/apple2.v` `RAM_data_latch`:

```verilog
if (AX & ~CAS_N & RAS_N & ~Q3) begin
    if (PHASE_ZERO == 0)      VIDEO_DL_LATCH <= ram_do;   // 16-bit video latch
    else if (aux == 0)        CPU_DL <= ram_do[7:0];      // MAIN RAM half
    else                      CPU_DL <= ram_do[15:8];     // AUX RAM half
end
```

The TB models both banks in one 16-bit `ram_do`. With STORE80=1 and PAGE2=1 (Layer 2 fix),
pages 04–07 route to **AUX** (`aux = (STORE80 & PAGE2) | ...`), so Phase B at $0540, the
parks at $0580/$05A0, and page-03 reads with RAMRD=1 (the NMI trampoline) all come from
`ram_do[15:8]`. The TB had modeled that half as a bare formula `(addr*7+0xA5)` — Phase B
therefore executed formula garbage. (The pre-fix runs only "worked" because the broken
softswitches kept everything on MAIN RAM.)

**Fix:** both banks are preloaded with the SAME image in both TBs:
`ram_do[15:8] = main_byte(addr)` (Verilog) / `ram_do(15 downto 8) <= unsigned(main_byte(addr))`
(VHDL). Writes remain non-persistent (stateless model), which is fine — the program never
checks write-back values.

## What Phase A now does (C100–C14F, 80 code bytes + EA padding to $C1FF)

```text
CLE | STA $C00C (COL80=0) | STA $C0FF (devselect, harmless)
STA $0100 / LDA $0100 (main-RAM write+read coverage)
STA $C055 (PAGE2=1)
LDA $C01C (dummy: latches SF_D := PAGE2) | LDA #0 (normalize A/flags; clears VHDL 'U')
LDA $C01C (test 1: bit7 = SF_D = PAGE2 = 1) | AND #$80 | BNE ok / JMP $05A0 error park
STA $C003 (RAMRD=1)
LDA $C013 (dummy: latches SF_D := RAMRD) | LDA #0
LDA $C013 (test 2: bit7 = SF_D = RAMRD = 1) | AND #$80 | BNE ok / JMP $05A0 error park
LDA $C100 (PD feedback) | LDA $C800 (IO_STROBE read, MUST precede $C300)
LDA $C300 (ROM read; latches C8ROM=1)
STA $C001 (STORE80=1)
JMP $0540 (Phase B)
```

Key core facts the program relies on (all verified in `rtl/apple2.v`):

- **SF_D one-read latency**: SF_D latches at PHASE_ZERO_R (end of PZ=0), but T65 samples DI
  at CPU_EN (start of PZ=0) — a C01x read returns the value latched by the PREVIOUS C01x
  read. Hence each test is preceded by a dummy C01x read. $C01C source = PAGE2, $C013 =
  RAMRD, $C018 = STORE80.
- **SF_D initial state**: VHDL 'U', Verilog 0 — the first read's stale value is never
  checked and LDA #0 normalizes A/flags afterwards (V flag may stay 'U' in VHDL; nothing
  branches on V).
- **C8ROM side effect**: any C3xx access with C3ROM=0 latches C8ROM=1, routing later
  C8xx–CFxx reads to ROM — so $C800 is read before $C300.
- **C1xx PD slot** is `io_select[1]` (decoder bit from A[10:8]), not [0].

## Phase B and park/trampoline layout (main RAM overrides, mirrored in aux bank)

- $0540–$056E: PHASE_B (47 bytes): LDA #$37; STA $0660 (AUX write — auxRamWriteObserved
  gate); LDA $0660; LDA #$5A; STA $0220; LDA $0220; LDA #$6B; STA $C030; LDA $C000;
  LDA $C060/$C070/$C040/$C090; STA $C090; LDA $C200; LDA #$77; JMP $0580.
- $0580–$0582: `4C 80 05` normal park (JMP $0580).
- $05A0–$05A2: `4C A0 05` error park (JMP $05A0) — target of both Phase A test failures.
- $03FB–$03FD: `4C FA C3` NMI trampoline (JMP $C3FA).

## ROM vector mapping (this core: rom_addr = A[13:0])

| CPU access | file offset | bytes | result |
|---|---|---|---|
| reset $FFFC/$FFFD | 0x3FFC/0x3FFD | 62 FA | PC := $FA62 (boot walk) |
| NMI   $FFFA/$FFFB | 0x3FFA/0x3FFB | FB 03 | PC := $03FB (trampoline → $C3FA) |
| IRQ/BRK $FFFE/$FFFF | 0x3FFE/0x3FFF | FA C3 | PC := $C3FA |

The real IIe NMI handler at **$C3FA–$C401** (crosses the page boundary — CLD sits at
$C400): `BIT $C015; STA $C007; CLD; SEI; JSR $0101`. Empirically verified in the final
trace: NMI pulse at c≈8000 → stack pushes → vector reads → fetches at $03FC/$03FD →
$C3FA handler executes (BIT $C015 at c≈8224, STA $C007, CLD at $C400, SEI, JSR $0101) →
deterministic pattern walk. IRQ_N is tied high in both TBs; the only interrupt source is
the TB NMI pulse (NMI_LO=8000..NMI_HI=8009).

## Files changed this session (both uncommitted; user manages git)

- `module_tests/apple2/apple2_verilog_tb.sv`
  - Phase A rewritten (correct softswitch addresses + dummy-read/normalize sequence);
    PHASE_A is exactly 256 bytes, code C100–C14F.
  - `ram_do[15:8] = main_byte(addr)` (AUX bank preloaded with same image).
  - Earlier-session changes retained: TRACE_START=0, boot handoff at $5858, NMI trampoline
    override, io_select[1] PD fix, DBG_* port map entries.
- `module_tests/apple2/apple2_vhdl_tb.vhd` — exact mirrors of all of the above.
  **PHASE_A verified byte-identical between the two TBs (256 bytes each)** via a node
  extraction/comparison one-liner.
- `rtl/apple2.v`, `module_tests/apple2/apple2_ent.vhd` — DBG_* debug ports from earlier
  diagnosis sessions (DBG_T65_REGS, DBG_DI, DBG_ROM_ADDR, DBG_ROM_OUT). Still used by both
  TBs (CSV columns 21–24). Keep-vs-remove decision pending.

## Verification evidence

- Verilog-only trace check after the fix: `rows=22624 C1xx=1036 park0580=224 err05a0=0
  C3FA=2 auxWrites=7 auxWriteAUX1=7` (all $0660 writes have AUX=1).
- Full harness: `APPLE2 EQUIVALENCE PASS rows=22624 fields=429840
  ignored_metavalues=16 park=0580 aux_write=1 io_strobe=1 nmi=1 romswitch_01=1 palmode_0=1`.
- Full suite: `passed=13 failed=0 skipped=0 seconds=299.1` (virtual_keyboard_overlay ran
  and passed this time; it had been SKIP in the earlier 11/1/1 run).

## Remaining work

1. **DBG_* keep-vs-remove decision** (user): the four debug ports are harmless but are
   test-only pins on `apple2`/`apple2_ent`. Removing them means editing both DUTs, both TBs
   (port map + CSV header), and confirming the harness column expectations; keeping them is
   zero-cost for simulation.
2. **Docs**: update `module_tests/README.md` roster line for apple2 (now PASS with gates)
   and this file's status if it moves; the t65 harness docs are unaffected.
3. **User commit** of staged test files + these TB changes (nothing committed yet).

## Commands

```powershell
# full apple2 harness (from E:\MiSTer\Apple-II_FPGAdev\Apple-II-Verilog_MiSTer)
powershell -NoProfile -ExecutionPolicy Bypass -File module_tests/apple2/run_equivalence.ps1

# whole suite
powershell -NoProfile -ExecutionPolicy Bypass -File module_tests/run_tests.ps1
```

Fast Verilog-only iteration (bash/MSYS2, ~35 s build):

```bash
cd E:/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer
export VERILATOR_ROOT="C:/msys64/ucrt64/share/verilator" MAKE="/c/msys64/ucrt64/bin/mingw32-make.exe" SHELL="/c/msys64/usr/bin/sh.exe" PATH="/c/msys64/usr/bin:/c/msys64/ucrt64/bin:$PATH"
/c/msys64/ucrt64/bin/verilator_bin.exe --binary --timing -Wno-fatal --top-module apple2_verilog_tb \
  --Mdir module_tests/apple2/build/verilog \
  module_tests/apple2/apple2_verilog_tb.sv rtl/apple2.v rtl/t65/t65_pack.v rtl/t65/t65_mcode.v \
  rtl/t65/t65_alu.v rtl/t65/t65.v rtl/R65Cx2.sv rtl/timing_generator.v rtl/video_generator.v \
  rtl/rom.v rtl/ramcard.v
./module_tests/apple2/build/verilog/Vapple2_verilog_tb.exe
```

Quick trace gate check (after a Verilog run):

```bash
awk -F, 'NR==1{for(i=1;i<=NF;i++)h[$i]=i} $1!="CYCLE"{
  if ($h["ADDR"]=="0660" && $h["RAM_WE"]=="1") {auxw++; if ($h["AUX"]=="1") auxw1++}
  if ($h["ADDR"]=="0580") park++; if ($h["ADDR"]=="05a0") errp++
  if ($h["ADDR"]=="c3fa") c3fa++; rows++
} END {printf "rows=%d park0580=%d err05a0=%d C3FA=%d auxWrites=%d auxWriteAUX1=%d\n", rows, park, errp, c3fa, auxw, auxw1}' \
  module_tests/apple2/build/verilog_trace.csv
```

## Gotchas (kept from earlier sessions — still true)

- **Stale DI on row 1 of each 14-cycle window**: the first trace row of a window shows the
  PREVIOUS byte; T65 latches on the PZ-fall (last) row. Reading "the vector bytes" from row
  1 misreports them (e.g. NMI window rows showed 24/FB; true latched bytes are FB/03).
- Sparse sampling (16-cycle grid from c=8128) can miss entire 14-cycle windows — a missing
  address in the transition list is not proof it was never fetched.
- `D` column = D_OUT (CPU data output), not read data; read data = T65_DI (col 22).
- VHDL **entity** port lists are semicolon-separated (GHDL: "interfaces must be separated
  by ';'").
- Softswitch writes take effect from the ADDRESS bit A[0], never from the data bus.
- With RAMRD=1, page-02/03 reads route to the AUX half — harmless here because both banks
  hold the same image, but remember it when changing the RAM model.
- Preserve mixed EOLs; use node byte-level splices or the edit tool, not PowerShell
  Get-Content/Set-Content, for these files.
