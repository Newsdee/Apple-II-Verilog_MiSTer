// T65 (VHDL golden) vs t65 (Verilog candidate) cycle-equivalence testbench.
//
// Mirror of t65_vhdl_tb.vhd. Instantiates the Verilog T65 from rtl/t65/t65.v
// with Mode="00" (6502), Rdy/Abort_n/SO_n tied high — the same connections the
// full core uses (the Verilog port has no BCD_en input; PRINT is unconnected).
// Same memory model, stimulus timelines, and trace schema as the VHDL bench:
//   CYCLE,PC,SP,P,Y,X,A,ADDR,DI,DO,RW,NMI_N,IRQ_N
// P bits follow T65_Pack: C=0,Z=1,I=2,D=3,B=4,V=6,N=7.
//
// Phase selection via +PHASE=0|1 (default 0). Output file follows the phase:
//   module_tests/t65/build/verilog_prog.csv / verilog_boot.csv

`timescale 1ns/1ps

module t65_verilog_tb;
   reg clk = 0;
   reg res_n = 0;
   reg irq_n = 1;
   reg nmi_n = 1;
   wire rw_n;
   wire [23:0] a24;
   wire [7:0] di;
   wire [7:0] do_sig;
   wire [63:0] regs;

   integer phase = 0;

   // ROM $F000-$FFFF from the shared apple2e.hex (CWD = repo root).
   reg [7:0] rom [0:16383];

   // Real RAM $0000-$EFFF (phase A only; phase B is stateless).
   reg [7:0] ram [0:6143];

   // Phase B program override region, copied verbatim from apple2_vhdl_tb.vhd.
   localparam [7:0] PHASE_B_PROG [0:46] = '{
      8'hA9, 8'h37,             // 0540 LDA #$37
      8'h8D, 8'h60, 8'h06,      // 0542 STA $0660   AUX RAM write
      8'hAD, 8'h60, 8'h06,      // 0545 LDA $0660   AUX RAM read
      8'hA9, 8'h5A,             // 0548 LDA #$5A
      8'h8D, 8'h20, 8'h02,      // 054A STA $0220   main RAM write
      8'hAD, 8'h20, 8'h02,      // 054D LDA $0220   main RAM read
      8'hA9, 8'h6B,             // 0550 LDA #$6B
      8'h8D, 8'h30, 8'hC0,      // 0552 STA $C030   speaker toggle
      8'hAD, 8'h00, 8'hC0,      // 0555 LDA $C000   keyboard read
      8'hAD, 8'h60, 8'hC0,      // 0558 LDA $C060   gameport read
      8'hAD, 8'h70, 8'hC0,      // 055B LDA $C070   PDL (floating bus)
      8'hAD, 8'h40, 8'hC0,      // 055E LDA $C040   STB (floating bus)
      8'hAD, 8'h90, 8'hC0,      // 0561 LDA $C090   devselect read
      8'h8D, 8'h90, 8'hC0,      // 0564 STA $C090   devselect write
      8'hAD, 8'h00, 8'hC2,      // 0567 LDA $C200   ioselect(2) read
      8'hA9, 8'h77,             // 056A LDA #$77
      8'h4C, 8'h80, 8'h05       // 056C JMP $0580   normal park
   };

   // Stateless pattern RAM, copied verbatim from apple2_vhdl_tb.vhd main_byte.
   function automatic [7:0] main_byte(input integer a);
      if (a >= 24'h5857 && a <= 24'h585B) begin
         case (a - 24'h5857)
            0:       main_byte = 8'h4C;
            1:       main_byte = 8'h00;
            2:       main_byte = 8'hC1;
            default: main_byte = 8'hEA;
         endcase
      end else if (a >= 24'h0540 && a <= 24'h056E) begin
         main_byte = PHASE_B_PROG[a - 24'h0540];
      end else if (a >= 24'h0580 && a <= 24'h0582) begin
         case (a - 24'h0580)
            0:       main_byte = 8'h4C;
            1:       main_byte = 8'h80;
            default: main_byte = 8'h05;
         endcase
      end else if (a >= 24'h05A0 && a <= 24'h05A2) begin
         case (a - 24'h05A0)
            0:       main_byte = 8'h4C;
            1:       main_byte = 8'hA0;
            default: main_byte = 8'h05;
         endcase
      end else begin
         main_byte = ((a + a/16 + 60) % 256);
      end
   endfunction

   function automatic [7:0] rom_byte(input integer i);
      if (phase == 0 && i == 16'hFFC) rom_byte = 8'h00;
      else if (phase == 0 && i == 16'hFFD) rom_byte = 8'h05;
      else rom_byte = rom[i];
   endfunction

   always #5 clk = ~clk;

   T65 dut (
      .Mode(2'b00),
      .Res_n(res_n),
      .Enable(1'b1),
      .Clk(clk),
      .Rdy(1'b1),
      .Abort_n(1'b1),
      .IRQ_n(irq_n),
      .NMI_n(nmi_n),
      .SO_n(1'b1),
      .R_W_n(rw_n),
      .Sync(),
      .EF(),
      .MF(),
      .XF(),
      .ML_n(),
      .VP_n(),
      .VDA(),
      .VPA(),
      .A(a24),
      .DI(di),
      .DO(do_sig),
      .Regs(regs),
      .DEBUG_I(),
      .DEBUG_A(),
      .DEBUG_X(),
      .DEBUG_Y(),
      .DEBUG_S(),
      .DEBUG_P(),
      .NMI_ack(),
      .PRINT()
   );

   // Memory model: combinational ROM/RAM read mux.
   assign di = (a24[15:0] >= 16'hF000) ? rom_byte(a24[15:0] - 16'hF000)
               : (phase == 0)          ? ram[a24[15:0]]
                                       : main_byte(a24[15:0]);

   // Phase A: commit writes at the end of the step RW_n is low in (the write
   // strobe is registered inside T65, so it is stable for the whole step).
   always @(posedge clk) begin
      if (!rw_n && phase == 0 && a24[15:0] < 16'hF000)
         ram[a24[15:0]] <= do_sig;
   end

   initial begin
      integer i;
      $value$plusargs("PHASE=%d", phase);
      $readmemh("rtl/roms/apple2e.hex", rom);
      for (i = 0; i < 6144; i++)
         ram[i] = ((i + i/16 + 60) % 256);
      if (phase == 0) begin
         // $0500: A9 05   LDA #$05
         ram['h0500] = 8'hA9; ram['h0501] = 8'h05;
         // $0502: 18      CLC
         ram['h0502] = 8'h18;
         // $0503: E9 07   SBC #$07   (A=FD C=0 N=1)
         ram['h0503] = 8'hE9; ram['h0504] = 8'h07;
         // $0505: 69 03   ADC #$03   (A=00 C=1 Z=1)
         ram['h0505] = 8'h69; ram['h0506] = 8'h03;
         // $0507: 38      SEC
         ram['h0507] = 8'h38;
         // $0508: 69 FF   ADC #$FF   (A=00 C=1 Z=1 V=0)
         ram['h0508] = 8'h69; ram['h0509] = 8'hFF;
         // $050A: A9 7F   LDA #$7F
         ram['h050A] = 8'hA9; ram['h050B] = 8'h7F;
         // $050C: 69 00   ADC #$00   (A=80 N=1 V=1 C=0)
         ram['h050C] = 8'h69; ram['h050D] = 8'h00;
         // $050E: B8      CLV
         ram['h050E] = 8'hB8;
         // $050F: A9 00   LDA #$00   (Z=1)
         ram['h050F] = 8'hA9; ram['h0510] = 8'h00;
         // $0511: F0 03   BEQ +3 -> $0516 (taken)
         ram['h0511] = 8'hF0; ram['h0512] = 8'h03;
         // $0513/$0514: EA EA  (must never execute)
         ram['h0513] = 8'hEA; ram['h0514] = 8'hEA;
         // $0516: A9 01   LDA #$01   (Z=0)
         ram['h0516] = 8'hA9; ram['h0517] = 8'h01;
         // $0518: D0 03   BNE +3 -> $051D (taken)
         ram['h0518] = 8'hD0; ram['h0519] = 8'h03;
         // $051A/$051B: EA EA  (must never execute)
         ram['h051A] = 8'hEA; ram['h051B] = 8'hEA;
         // $051D: A9 01   LDA #$01   (Z=0)
         ram['h051D] = 8'hA9; ram['h051E] = 8'h01;
         // $051F: F0 FE   BEQ -2 (not taken; if taken it would self-loop)
         ram['h051F] = 8'hF0; ram['h0520] = 8'hFE;
         // $0521: A9 02   LDA #$02
         ram['h0521] = 8'hA9; ram['h0522] = 8'h02;
         // $0523: 85 34   STA $34
         ram['h0523] = 8'h85; ram['h0524] = 8'h34;
         // $0525: A5 34   LDA $34
         ram['h0525] = 8'hA5; ram['h0526] = 8'h34;
         // $0527: A2 0A   LDX #$0A
         ram['h0527] = 8'hA2; ram['h0528] = 8'h0A;
         // $0529: 8E 34 06 STX $0634
         ram['h0529] = 8'h8E; ram['h052A] = 8'h34; ram['h052B] = 8'h06;
         // $052C: AE 34 06 LDX $0634
         ram['h052C] = 8'hAE; ram['h052D] = 8'h34; ram['h052E] = 8'h06;
         // $052F: A0 05   LDY #$05
         ram['h052F] = 8'hA0; ram['h0530] = 8'h05;
         // $0531: 98      TYA
         ram['h0531] = 8'h98;
         // $0532: 20 49 05 JSR $0549 (pushes $0535, RTS returns to $0536)
         ram['h0532] = 8'h20; ram['h0533] = 8'h49; ram['h0534] = 8'h05;
         // $0535: EA      NOP (skipped by RTS+1)
         ram['h0535] = 8'hEA;
         // $0536: A9 77   LDA #$77   (resume point after RTS)
         ram['h0536] = 8'hA9; ram['h0537] = 8'h77;
         // $0538: 58      CLI
         ram['h0538] = 8'h58;
         // $0539: 4C 46 05 JMP $0546 (to park)
         ram['h0539] = 8'h4C; ram['h053A] = 8'h46; ram['h053B] = 8'h05;
         // $053C-$0545: EA padding
         for (i = 'h053C; i <= 'h0545; i++) ram[i] = 8'hEA;
         // $0546: 4C 46 05 JMP $0546 (park)
         ram['h0546] = 8'h4C; ram['h0547] = 8'h46; ram['h0548] = 8'h05;
         // $0549: A9 5A   LDA #$5A   (subroutine)
         ram['h0549] = 8'hA9; ram['h054A] = 8'h5A;
         // $054B: 48      PHA
         ram['h054B] = 8'h48;
         // $054C: 68      PLA
         ram['h054C] = 8'h68;
         // $054D: 60      RTS
         ram['h054D] = 8'h60;
      end
   end

   task automatic apply_stimulus(input integer cycle);
      begin
         res_n = (cycle < 4) ? 1'b0 : 1'b1;
         if (phase == 0) begin
            irq_n = (cycle >= 120 && cycle <= 124) ? 1'b0 : 1'b1;
            nmi_n = (cycle >= 200 && cycle <= 204) ? 1'b0 : 1'b1;
         end else begin
            irq_n = 1'b1;
            nmi_n = 1'b1;
         end
      end
   endtask

   initial begin
      integer trace_output;
      integer cycle;
      string trace_name;

      if (phase == 0)
         trace_name = "module_tests/t65/build/verilog_prog.csv";
      else
         trace_name = "module_tests/t65/build/verilog_boot.csv";
      trace_output = $fopen(trace_name, "w");
      if (!trace_output) $fatal(1, "could not open Verilog trace output");
      $fdisplay(trace_output, "CYCLE,PC,SP,P,Y,X,A,ADDR,DI,DO,RW,NMI_N,IRQ_N");

      for (cycle = 0; cycle < (phase == 0 ? 320 : 500); cycle = cycle + 1) begin
         @(negedge clk);
         apply_stimulus(cycle);
         @(posedge clk);
         #1;

         $fdisplay(trace_output, "%0d,%04X,%02X,%02X,%02X,%02X,%02X,%04X,%02X,%02X,%b,%b,%b",
            cycle,
            regs[63:56], regs[55:48], regs[47:40], regs[39:32], regs[31:24], regs[23:16],
            a24[15:0], di, do_sig, rw_n, nmi_n, irq_n);
      end

      $fclose(trace_output);
      $display("Verilog trace complete (phase=%0d)", phase);
      $finish;
   end
endmodule
