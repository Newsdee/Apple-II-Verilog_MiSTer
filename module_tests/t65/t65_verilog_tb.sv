// T65 (VHDL golden) vs t65 (Verilog candidate) cycle-equivalence testbench.
//
// Mirror of t65_vhdl_tb.vhd. Instantiates the Verilog T65 from rtl/t65/t65.v
// with Mode="00" (6502), Rdy/Abort_n/SO_n tied high — the same connections the
// full core uses (the Verilog port has no BCD_en input; PRINT is unconnected).
// Same memory model, stimulus timelines, and trace schema as the VHDL bench:
//   CYCLE,PC,SP,P,Y,X,A,ADDR,DI,DO,RW,NMI_N,IRQ_N
// PC is the full 16-bit program counter (4 hex digits). The T65 Regs port is
// {PC[15:0], S[15:0], P, Y, X, A} = exactly 64 bits (S is a 16-bit register
// whose high byte stays FF). So P/Y/X/A live at regs[31:24]/[23:16]/[15:8]/
// [7:0] and the SP column is the low byte of S.
// P bits follow T65_Pack: C=0,Z=1,I=2,D=3,B=4,V=6,N=7.
//
// Phase selection via +PHASE=0|1 (default 0). Output file follows the phase:
//   module_tests/t65/build/verilog_prog.csv / verilog_boot.csv

`timescale 1ns/1ps

module t65_verilog_tb;
   reg clk = 0;
   reg res_n = 0;
   // Set once stimulus has begun; keeps the write-back from firing on the
   // pre-stimulus posedge when DUT outputs are still at their (zero) init
   // values. The VHDL side never sees this: rw_n is U there, so its
   // "rw_n = '0'" guard is false before stimulus.
   reg sim_go = 0;
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
   reg [7:0] ram [0:61439];

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
      end else if (a >= 24'h6B4C && a <= 24'h6B51) begin
         // Boot preamble (phase B only): define A/X/Y deterministically at the
         // reset vector before the pattern walk starts. The golden T65 resets
         // only P; A/X/Y are 'U' in VHDL sim until first written, while Verilator
         // zero-initializes them, so an immediate walk would desync on garbage
         // ALU/indexed opcodes (simulation artifact, see PROGRESS.md). The walk
         // then starts at $6B52. Must stay byte-identical to t65_vhdl_tb.vhd.
         case (a - 24'h6B4C)
            0:       main_byte = 8'hA9;   // LDA #$21
            1:       main_byte = 8'h21;
            2:       main_byte = 8'hA2;   // LDX #$32
            3:       main_byte = 8'h32;
            4:       main_byte = 8'hA0;   // LDY #$43
            default: main_byte = 8'h43;
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
      if (sim_go && !rw_n && phase == 0 && a24[15:0] < 16'hF000)
         ram[a24[15:0]] <= do_sig;
   end

   initial begin
      integer i;
      $value$plusargs("PHASE=%d", phase);
      $readmemh("rtl/roms/apple2e.hex", rom);
      // RAM contents (pattern byte + phase-A program) come from the generated hex file;
      // gen_rom_array.ps1 is the single source of truth and also emits the VHDL
      // RAM_INIT constant, so both sides are byte-identical by construction.
      $readmemh("module_tests/t65/build/t65_ram_init_lf.hex", ram);
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
         sim_go = 1;
         apply_stimulus(cycle);
         @(posedge clk);
         #1;

         $fdisplay(trace_output, "%0d,%04X,%02X,%02X,%02X,%02X,%02X,%04X,%02X,%02X,%b,%b,%b",
            cycle,
            regs[63:48], regs[39:32], regs[31:24], regs[23:16], regs[15:8], regs[7:0],
            a24[15:0], di, do_sig, rw_n, nmi_n, irq_n);
      end

      $fclose(trace_output);
      $display("Verilog trace complete (phase=%0d)", phase);
      $finish;
   end
endmodule
