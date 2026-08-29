// mockingboard_verilog_tb.sv - candidate-side testbench for the mockingboard
// equivalence harness.
//
// DUT: Apple-II-Verilog_MiSTer/rtl/mockingboard/mockingboard.v (candidate,
// Verilog) with the real via6522.v and the deterministic PSG stub
// (ym2149_stub.v, module name YM2149 so it binds to the board's
// instantiation; the real rtl/mockingboard/YM2149.sv is NOT in the source
// list).
//
// Phase schedule (dense alternating, from cycle parity):
//   even cycles: PHASE_ZERO_R=1 -> golden VIA falling slot (bus work)
//   odd cycles:  PHASE_ZERO_F=1 -> golden VIA rising slot, PSG CE (with ENA)
// All stimulus bus accesses occur in even cycles.
//
// Trace: one CSV row per cycle, sampled at posedge + 1 ns. Columns identical
// to the VHDL side:
//   CYCLE,RESET,IOSL,ENA,RW,ADDR,DIN,ODATA,OE,IRQ,NMI,AUDL,AUDR

`timescale 1ns/1ps

module mockingboard_verilog_tb;
   localparam string TRACE_FILE = "module_tests/mockingboard/build/verilog_trace.csv";

   logic clk = 1'b0;
   logic phase_zero = 1'b0;
   logic phase_r;
   logic phase_f;
   logic [7:0] i_addr;
   logic [7:0] i_data;
   logic [7:0] o_data;
   logic oe;
   logic i_rw_l;
   logic o_irq_l;
   logic o_nmi_l;
   logic i_iosel_l;
   logic i_reset_l;
   logic i_ena_h;
   logic [9:0] o_audio_l;
   logic [9:0] o_audio_r;

   MOCKINGBOARD dut (
      .CLK_14M      (clk),
      .PHASE_ZERO   (phase_zero),
      .PHASE_ZERO_R (phase_r),
      .PHASE_ZERO_F (phase_f),
      .I_ADDR       (i_addr),
      .I_DATA       (i_data),
      .O_DATA       (o_data),
      .OE           (oe),
      .I_RW_L       (i_rw_l),
      .O_IRQ_L      (o_irq_l),
      .O_NMI_L      (o_nmi_l),
      .I_IOSEL_L    (i_iosel_l),
      .I_RESET_L    (i_reset_l),
      .I_ENA_H      (i_ena_h),
      .O_AUDIO_L    (o_audio_l),
      .O_AUDIO_R    (o_audio_r)
   );

   always #35 clk = ~clk;

   integer f;
   integer cycle;
   logic [23:0] w;

   initial begin
      phase_r = 1'b0; phase_f = 1'b0;
      i_addr = 8'h0; i_data = 8'h0;
      i_rw_l = 1'b1; i_iosel_l = 1'b1; i_reset_l = 1'b0; i_ena_h = 1'b0;

      f = $fopen(TRACE_FILE);
      if (f == 0) begin
         $display("FATAL: cannot open %s", TRACE_FILE);
         $finish;
      end
      $fdisplay(f, "CYCLE,RESET,IOSL,ENA,RW,ADDR,DIN,ODATA,OE,IRQ,NMI,AUDL,AUDR");

      for (cycle = 0; cycle < mockingboard_stim::STIM_COUNT; cycle++) begin
         @(negedge clk);

         w = mockingboard_stim::STIM[cycle];
         i_reset_l = ~w[23];
         i_iosel_l = w[22];
         i_ena_h   = w[21];
         i_rw_l    = w[20];
         i_addr    = w[19:12];
         i_data    = w[11:4];
         phase_r   = (cycle % 2 == 0);
         phase_f   = (cycle % 2 == 1);

         @(posedge clk);
         #1;

         $fdisplay(f, "%0d,%b,%b,%b,%b,%02x,%02x,%02x,%b,%b,%b,%03x,%03x",
                   cycle, i_reset_l, i_iosel_l, i_ena_h, i_rw_l,
                   i_addr, i_data, o_data, oe, o_irq_l, o_nmi_l,
                   o_audio_l, o_audio_r);
      end

      $fclose(f);
      $finish;
   end

endmodule
