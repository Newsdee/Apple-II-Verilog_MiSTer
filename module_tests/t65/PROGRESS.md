# T65 equivalence harness — progress (handoff 2026-08-30, session restart)

## Where things stand
1. **User ordered alignment; fix APPLIED** to `rtl/t65/t65.v` line ~550:
   `if (Dec_S == 1'b1 & (RstCycle == 1'b0 | Mode == 2'b00))` (+ comment referencing T65.vhd line ~418).
   CRLF preserved via node byte-splice. Working tree change, NOT committed (user manages git).
   Roster/README in module_tests still say "pending user decision" -- README was updated to
   "aligned, Phase A PASS"; roster row needs a refresh when Phase B is done.
2. **Phase A (directed program): FULL MATCH** after the fix.
   `phaseA=match rowsA=320 fieldsA=3072 gate_checks=17` (row-level metavalue skip; 64 rows skipped).
   All 17 gates pass: park, SBC/ADC flags, JSR/RTS SP recovery, IRQ $FFFE/$FFFF, NMI $FFFA/$FFFB, etc.
3. **Phase B (boot walk): diverges at cycle 84, PC: VHDL=6BC8 Verilog=6BCA** -- but this is a
   SIMULATION ARTIFACT, not an RTL divergence:
   - Golden T65 resets ONLY P (T65.vhd register process ~line 455). ABC/X/Y have no reset ->
     'UUUU' in VHDL sim until first LDA/LDX/LDY; Verilator starts them at 0.
   - The pattern walk from $6B4C executes indexed/RMW/ALU garbage opcodes while X/Y/A are still
     'U'. GHDL's numeric_std maps metavalue->1 in unsigned conversions, so the golden computes
     defined-but-garbage values (e.g. BAL <= BAL(7:0) + X with X='U'); Verilog adds 0.
     Both "defined" but different -> permanent walk desync (PC off by 2 by cycle 84).
   - On real FPGA both sides power up 0, so this class of difference cannot occur in silicon.
   - Evidence it is NOT a logic bug: Phase A matches bit-for-bit on every defined field and
     exercises ALU/flags/stack/interrupts/branches.

## The fix (designed, NOT yet implemented)
Boot preamble in BOTH testbenches' read mux (TB-side only, no RTL change), Phase B only:
- $6B4C: A9 21   (LDA #$21)
- $6B4E: A2 32   (LDX #$32)
- $6B50: A0 43   (LDY #$43)
- Pattern walk (main_byte) then starts at $6B52.
VHDL: add a region in `main_byte()` in t65_vhdl_tb.vhd (it already has override regions for
$5857-$585B, $0540-$056E, $0580-$0582, $05A0-$05A2; main_byte is only used by the Phase B
generate branch -- Phase A reads ram[]).
Verilog: mirror the same region in t65_verilog_tb.sv's di mux. Values must be byte-identical.
After that: re-run full harness (not -CompareOnly); expect Phase B rows ~cycle 20 onward to
compare clean. Early rows (reset seq + preamble, X/Y/A still 'U') are skipped by the row-level
metavalue rule and counted.

## Runner state (run_equivalence.ps1) -- current version is verified working
- Row-level metavalue skip: if ANY VHDL field in a row matches [UXWZ-], skip whole row,
  count as ignored (field-level skip was insufficient: DI becomes defined-garbage downstream
  of an 'X' address via the TB read mux).
- Gates added: total ignored rows < 400; phase A >= 3000 compared fields; phase B >= 4800.
- SP-divergence hint block (cycle <= 10) still in Invoke-PhaseCompare -- now only relevant
  pre-alignment; harmless to keep.
- CompareOnly mode works; traces in build/ are post-alignment.

## Environment / gotchas (cumulative)
- t65.v is 100% CRLF -- use node byte-splice for edits, never the edit tool.
- GHDL 6.0.0: -fsynopsys required (removes std.env -> use --stop-time); no generic-map
  (wrapper entities t65_vhdl_tb_prog/_boot); multi-driver array bug -> static RAM aggregate
  from gen_rom_array.ps1.
- Verilog TB needs sim_go guard on write-back (Verilator zero-inits R_W_n pre-stimulus).
- MSYS2 PATH: unix-style for bash, windows-style for native children; runner sets both itself.
- PowerShell: Write-Host not Write-Output inside functions whose output is captured.

## Exact resume steps
1. Add the preamble region to t65_vhdl_tb.vhd main_byte() AND t65_verilog_tb.sv di mux
   (identical bytes A9 21 A2 32 A0 43 at $6B4C-$6B51, Phase B only).
2. Full run: `.\module_tests\t65\run_equivalence.ps1` (from Apple-II-Verilog_MiSTer root).
3. If Phase B matches: update t65/README.md status to PASS + numbers, roster row in
   module_tests/README.md, then suite check:
   `powershell -File module_tests/run_tests.ps1 -ContinueOnFailure` (expect 12 PASS, 1 FAIL=apple2).
4. Re-run the apple2 full-core harness -- the S fix likely resolves its cycle-358 divergence
   (ADDR 01FB vs 01FE); if it passes, flip apple2 roster to PASS and report.
   (apple2 is registered compareOnly:true in manifest; traces exist.)
5. Then: R65C02 separate harness (planned row already in roster; entity/module R65C02,
   12 ports, dout vs do naming, reset active-low, Regs={PC,8'h01,S[7:0],P,Y,X,A}, S is 8-bit).

## Files touched this session (Verilog repo)
- rtl/t65/t65.v -- THE alignment fix (1 line, CRLF preserved)
- module_tests/t65/run_equivalence.ps1 -- row-level skip + gates + SP hint
- module_tests/t65/README.md -- rewritten (design, finding, proposed fix -- status section
  now says Phase A PASS; refresh after Phase B resolves)
- module_tests/t65/PROGRESS.md -- this file
- module_tests/README.md -- roster rows (t65 + r65c02 planned row)
- module_tests/test_manifest.json -- t65 registered (CRLF preserved, 13 tests)
