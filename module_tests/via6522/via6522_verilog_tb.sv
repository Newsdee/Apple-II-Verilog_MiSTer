// via6522_verilog_tb.sv - candidate-side testbench for the via6522 equivalence harness.
//
// DUT: Apple-II-Verilog_MiSTer/rtl/mockingboard/via6522.v (candidate, Verilog).
// Cycle model: see gen_stim.ps1 header. Even cycles are F slots (ce=1), odd
// cycles are R slots (ce=0). All bus accesses occur in F slots via strobe/we.
// Timer decrements therefore align edge-for-edge with the golden's
// falling-phase decrements.
//
// Trace: one CSV row per cycle, sampled at posedge + 1 ns. Columns identical
// to the VHDL side:
//   CYCLE,RESET,STROBE,WE,ADDR,DIN,CA1I,CA2I,CB1I,CB2I,PAI,PBI,
//   DOUT,PAO,PBO,CA2O,CB2O,CB1O,IRQ

`timescale 1ns/1ps

module via6522_verilog_tb;
   localparam string TRACE_FILE = "module_tests/via6522/build/verilog_trace.csv";

   logic clk = 1'b0;
   logic ce;
   logic strobe;
   logic we;
   logic reset_s;
   logic [3:0] addr;
   logic [7:0] din;
   logic [7:0] data_out;
   logic irq;
   logic [7:0] porta_out;
   logic [7:0] porta_in;
   logic [7:0] portb_out;
   logic [7:0] portb_in;
   logic ca1_in;
   logic ca2_out;
   logic ca2_in;
   logic cb1_out;
   logic cb1_in;
   logic cb2_out;
   logic cb2_in;

   via6522 dut (
      .data_out  (data_out),
      .data_in   (din),
      .addr      (addr),
      .strobe    (strobe),
      .we        (we),
      .irq       (irq),
      .porta_out (porta_out),
      .porta_in  (porta_in),
      .portb_out (portb_out),
      .portb_in  (portb_in),
      .ca1_in    (ca1_in),
      .ca2_out   (ca2_out),
      .ca2_in    (ca2_in),
      .cb1_out   (cb1_out),
      .cb1_in    (cb1_in),
      .cb2_out   (cb2_out),
      .cb2_in    (cb2_in),
      .ce        (ce),
      .clk       (clk),
      .reset     (reset_s)
   );

   always #35 clk = ~clk;

   integer f;
   integer cycle;
   logic [35:0] w;

   initial begin
      ce = 1'b0; strobe = 1'b0; we = 1'b0; reset_s = 1'b1;
      addr = 4'h0; din = 8'h0;
      ca1_in = 1'b0; ca2_in = 1'b0; cb1_in = 1'b0; cb2_in = 1'b0;
      porta_in = 8'h0; portb_in = 8'h0;

      f = $fopen(TRACE_FILE);
      if (f == 0) begin
         $display("FATAL: cannot open %s", TRACE_FILE);
         $finish;
      end
      $fdisplay(f, "CYCLE,RESET,STROBE,WE,ADDR,DIN,CA1I,CA2I,CB1I,CB2I,PAI,PBI,DOUT,PAO,PBO,CA2O,CB2O,CB1O,IRQ");

      for (cycle = 0; cycle < via6522_stim::STIM_COUNT; cycle++) begin
         @(negedge clk);

         w = via6522_stim::STIM[cycle];
         reset_s  = w[34];
         strobe   = w[33];
         we       = w[32];
         addr     = w[31:28];
         din      = w[27:20];
         ca1_in   = w[19];
         ca2_in   = w[18];
         cb1_in   = w[17];
         cb2_in   = w[16];
         porta_in = w[15:8];
         portb_in = w[7:0];
         ce       = (cycle % 2 == 0);

         @(posedge clk);
         #1;

         $fdisplay(f, "%0d,%b,%b,%b,%01x,%02x,%b,%b,%b,%b,%02x,%02x,%02x,%02x,%02x,%b,%b,%b,%b",
                   cycle, reset_s, strobe, we, addr, din,
                   ca1_in, ca2_in, cb1_in, cb2_in, porta_in, portb_in,
                   data_out, porta_out, portb_out, ca2_out, cb2_out, cb1_out, irq);
      end

      $fclose(f);
      $finish;
   end

endmodule
