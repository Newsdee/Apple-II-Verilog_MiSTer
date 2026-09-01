// cpu_65c02 (new GameKing 65C02 core) under the t65 harness stimulus.
//
// Divergence-test companion to module_tests/t65: identical memory model
// (apple2e.hex ROM at $F000-$FFFF + t65_ram_init_lf.hex RAM for phase 0,
// stateless main_byte() pattern for phase 1), identical stimulus timelines
// (reset cycles 0..3; phase 0 IRQ window 120..124 and NMI window 200..204;
// phase 1 no interrupts) and the same 13-column trace schema:
//   CYCLE,PC,SP,P,Y,X,A,ADDR,DI,DO,RW,NMI_N,IRQ_N
// so the CSVs can be diffed field-for-field against t65/build/verilog_prog.csv
// (phase 0, 320 cycles) and t65/build/verilog_boot.csv (phase 1, 500 cycles).
//
// The PHASE_B_PROG array, main_byte() and rom_byte() are copied verbatim from
// t65_verilog_tb.sv — any edit there must be mirrored here to keep the
// stimulus byte-identical.
//
// DUT mapping: ce=1 (one bus access per posedge), rdy=1, stall=0, ce_n=0,
// stp_nop=1, savestate bus tied off. reset is active-HIGH synchronous for
// cycles 0..3 (mirrors the T65 bench's res_n low window). P byte emitted as
// {N,V,1,1,D,I,Z,C} = T65's packing with B hardwired 1 in this core.
// Internal registers read via hierarchical refs (core has no Regs port).
//
// Output: module_tests/cpu_65c02/build/t65_prog_trace.csv (phase 0) /
//         module_tests/cpu_65c02/build/t65_boot_trace.csv (phase 1).

`timescale 1ns/1ps

module cpu65_t65_tb;
   reg clk = 0;
   // DUT reset is active-HIGH, synchronous.
   reg reset_sig = 0;
   reg sim_go = 0;
   reg irq_n = 1;
   reg nmi_n = 1;
   wire rw_n;
   wire [7:0] di;
   wire [7:0] do_sig;

   integer phase = 0;

   // ROM $F000-$FFFF from the shared apple2e.hex (CWD = repo root).
   reg [7:0] rom [0:16383];

   // Real RAM $0000-$EFFF (phase 0 only; phase 1 is stateless).
   reg [7:0] ram [0:61439];

   // Phase B program override region, copied verbatim from t65_verilog_tb.sv.
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

   // Stateless pattern RAM, copied verbatim from t65_verilog_tb.sv main_byte.
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

   cpu_65c02 dut (
      .clk(clk),
      .ce(1'b1),
      .ce_n(1'b0),
      .reset(reset_sig),
      .stall(1'b0),
      .irq_n(irq_n),
      .nmi_n(nmi_n),
      .rdy(1'b1),
      .stp_nop(1'b1),
      .addr(addr),
      .dout(do_sig),
      .din(di),
      .we(rw_w),
      .sync(sync),
      .vector_pull(vector_pull),
      .int_seq(int_seq),
      .rti_done(rti_done),
      .in_wai(in_wai),
      .in_stp(in_stp),
      .ss_addr(10'd0),
      .ss_wdata(64'd0),
      .ss_wren(1'b0),
      .ss_rdata(ss_rdata)
   );

   wire [15:0] addr;
   wire rw_w;
   wire sync;
   wire int_seq;
   wire vector_pull;
   wire rti_done;
   wire in_wai;
   wire in_stp;
   wire [63:0] ss_rdata;

   // Trace RW column uses the T65 convention: 1 = read, 0 = write.
   assign rw_n = !rw_w;

   wire unused_ok = &{1'b0, vector_pull, rti_done, in_wai, in_stp, ss_rdata, sync, int_seq};

   // Memory model: combinational ROM/RAM read mux (mirror of t65_verilog_tb.sv).
   assign di = (addr >= 16'hF000) ? rom_byte(addr - 16'hF000)
              : (phase == 0)      ? ram[addr]
                                  : main_byte(addr);

   // Phase 0: commit writes where the (registered) we strobe is high and the
   // address is in RAM.
   always @(posedge clk) begin
      if (sim_go && rw_w && phase == 0 && addr < 16'hF000)
         ram[addr] <= do_sig;
   end

   initial begin
      integer i;
      $value$plusargs("PHASE=%d", phase);
      $readmemh("rtl/roms/apple2e.hex", rom);
      $readmemh("module_tests/t65/build/t65_ram_init_lf.hex", ram);
   end

   task automatic apply_stimulus(input integer cycle);
      begin
         reset_sig = (cycle < 4) ? 1'b1 : 1'b0;
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
         trace_name = "module_tests/cpu_65c02/build/t65_prog_trace.csv";
      else
         trace_name = "module_tests/cpu_65c02/build/t65_boot_trace.csv";
      trace_output = $fopen(trace_name, "w");
      if (!trace_output) $fatal(1, "could not open cpu_65c02 t65 trace output");
      $fdisplay(trace_output, "CYCLE,PC,SP,P,Y,X,A,ADDR,DI,DO,RW,NMI_N,IRQ_N");

      for (cycle = 0; cycle < (phase == 0 ? 320 : 500); cycle = cycle + 1) begin
         @(negedge clk);
         sim_go = 1;
         apply_stimulus(cycle);
         @(posedge clk);
         #1;

         $fdisplay(trace_output, "%0d,%04X,%02X,%02X,%02X,%02X,%02X,%04X,%02X,%02X,%b,%b,%b",
            cycle,
            dut.reg_pc, dut.reg_s, {dut.fl_n, dut.fl_v, 1'b1, 1'b1, dut.fl_d, dut.fl_i, dut.fl_z, dut.fl_c},
            dut.reg_y, dut.reg_x, dut.reg_a,
            addr, di, do_sig, rw_n, nmi_n, irq_n);
      end

      $fclose(trace_output);
      $display("cpu_65c02 t65-stimulus trace complete (phase=%0d)", phase);
      $finish;
   end
endmodule
