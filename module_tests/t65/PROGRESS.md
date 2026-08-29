# T65 equivalence harness — progress

Status: IN PROGRESS (building harness files)

## Decisions (final)
- Two runs per side (4 CSVs): PHASE=0 "prog" (320 cyc, real writable RAM + test program
  at $0500, ROM reset vector overridden to $0500, IRQ pulse 120-124, NMI pulse 200-204)
  and PHASE=1 "boot" (500 cyc, stateless main_byte RAM copied verbatim from the apple2
  harness, pure apple2e ROM, no overrides). Phase via VHDL generic / Verilog +PHASE=.
- Memory model: combinational ROM+RAM, Enable=1 continuously. This reproduces the
  full-core instruction stream (full core uses 1-cycle-latency ROM but CPU steps only
  every 14th cycle, so q settles within the step => same one-step address/data pipeline).
- RAM reads >= $F000 come from apple2e.hex; < $F000 from real RAM (phase A) or
  main_byte pattern (phase B, writes discarded — matches apple2 harness stateless RAM).
  $C000-$DFFF IO reads return the pattern byte in this standalone TB (no peripherals);
  stream identity vs full core is verified by matching the pre-divergence ADDR sequence.
- Trace columns (both TBs): CYCLE,PC,SP,P,Y,X,A,ADDR,DI,DO,RW,NMI_N,IRQ_N.
  Sampled at posedge+1ns. Hex zero-padded (VHDL to_hstring / Verilog %0NX).
- Reset: Res_n=0 cycles 0-3, released cycle 4 (keyboard convention). Post-reset S=$FD
  expected in 6502 mode (reset BRK-like mcode Dec_S x3, writes suppressed).
- Verilog T65 has no BCD_en port; PRINT left unconnected. VHDL BCD_en left at default '1'
  (same as full core).

## Known finding to reproduce (apple2 harness, module_tests/apple2/build/*_trace.csv)
- First bus-level divergence at full-core cycle 358: ADDR 01FB (VHDL) vs 01FE (Verilog),
  D=84, RAM_ADDR 007F9. Preceding steps (14-cyc each): FA65 R, FE84 R, FE85 R, FE86 R,
  FE87 R, 0032 W(D=FF), FE88 R, FE89 R, then the divergent $01xx stack read.
- ROM bytes there: FE84=2C FE85=AC FE86=CE FE87=F0 FE88=02 FE89=49 (verified via
  _inspect_rom.ps1; NOTE: hex file line N covers indices (N-1)*16, address = F000+index).
- Expectation in standalone run: same instruction context, SP off by 1 (FB vs FE),
  absolute cycle differs (1 step/cycle here vs 14 in full core).

## TODO
- [x] Locate files, verify ROM mapping, reset/NMI/IRQ vectors ($6B4C/$D0B4/$DFCF)
- [x] Decode apple2 trace around divergence (step boundaries = PHZ falling edges +1)
- [ ] gen_rom_array.ps1 -> build/t65_rom_array.vhd
- [ ] t65_vhdl_tb.vhd, t65_verilog_tb.sv
- [ ] run_equivalence.ps1 (build once per side, run 2 phases each, compare, gates)
- [ ] Run; analyze first divergence; identify instruction + suspect side
- [ ] README.md
