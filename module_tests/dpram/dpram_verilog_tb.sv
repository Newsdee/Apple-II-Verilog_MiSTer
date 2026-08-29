`timescale 1ns/1ps

module dpram_verilog_tb;
   localparam int N = 8192; // 2 ** 13, full address space
   reg clk = 0;
   reg [12:0] addr_a = 0;
   reg [12:0] addr_b = 0;
   reg [7:0] data_a = 0;
   reg [7:0] data_b = 0;
   reg wren_a = 0;
   reg wren_b = 0;
   wire [7:0] q_a;
   wire [7:0] q_b;

   always #5 clk = ~clk;

   // Both clocks tied to the same oscillator, exactly as in floppy_track.sv.
   // enable_a/enable_b left at their default 1'b1 (unconnected in real use).
   dpram #(13, 8) dut (
      .address_a(addr_a),
      .address_b(addr_b),
      .clock_a(clk),
      .clock_b(clk),
      .data_a(data_a),
      .data_b(data_b),
      .enable_a(1'b1),
      .enable_b(1'b1),
      .wren_a(wren_a),
      .wren_b(wren_b),
      .q_a(q_a),
      .q_b(q_b)
   );

   // Phase schedule (identical in dpram_vhdl_tb.vhd):
   //   0..7       INIT:  no writes, read address 0 on both ports (init contents)
   //   8..23      AW:    port A writes addr i     <- 0xA0+i ; B reads addr 1000
   //   24..39     ARB:   port B reads back addr i (expect 0xA0+i); A reads 1000
   //   40..55     BW:    port B writes addr 16+i  <- 0xB0+i ; A reads addr 1000
   //   56..71     BRB:   port A reads back 16+i (expect 0xB0+i); B reads 1000
   //   72..95     SIM:   even i: both ports write simultaneously, distinct addrs
   //                    odd  i: A writes 300+i while B reads 300+i (conflict)
   //   96..8287   SW:    port A sweep write addr i <- P(i); B reads (i-1) mod N
   //   8288..16479 SRB:  port B reads back addr i; A reads (i-1) mod N
   //   16480..24671 BSW: port B sweep write addr i <- P(i); A reads (i-1) mod N
   //   24672..32863 ARBB: port A reads back addr i; B reads (i-1) mod N
   // with P(i) = (7*i + 3) mod 256.
   task automatic apply_stimulus(input integer cycle);
      integer i;
      begin
         data_a = 0;
         data_b = 0;
         wren_a = 0;
         wren_b = 0;
         addr_a = 0;
         addr_b = 0;

         if(cycle < 8) begin
            // INIT: everything zero
         end else if(cycle < 24) begin
            i = cycle - 8;
            wren_a = 1;
            addr_a = i & 13'h1FFF;
            data_a = (160 + i) & 8'hFF;
            addr_b = 13'd1000;
         end else if(cycle < 40) begin
            i = cycle - 24;
            addr_b = i & 13'h1FFF;
            addr_a = 13'd1000;
         end else if(cycle < 56) begin
            i = cycle - 40;
            wren_b = 1;
            addr_b = (16 + i) & 13'h1FFF;
            data_b = (176 + i) & 8'hFF;
            addr_a = 13'd1000;
         end else if(cycle < 72) begin
            i = cycle - 56;
            addr_a = (16 + i) & 13'h1FFF;
            addr_b = 13'd1000;
         end else if(cycle < 96) begin
            i = cycle - 72;
            if(i % 2 == 0) begin
               wren_a = 1;
               addr_a = (100 + i) & 13'h1FFF;
               data_a = (192 + i) & 8'hFF;
               wren_b = 1;
               addr_b = (200 + i) & 13'h1FFF;
               data_b = (208 + i) & 8'hFF;
            end else begin
               wren_a = 1;
               addr_a = (300 + i) & 13'h1FFF;
               data_a = (224 + i) & 8'hFF;
               addr_b = (300 + i) & 13'h1FFF;
            end
         end else if(cycle < 96 + N) begin
            i = cycle - 96;
            wren_a = 1;
            addr_a = i & 13'h1FFF;
            data_a = (7 * i + 3) & 8'hFF;
            addr_b = ((i - 1 + N) % N) & 13'h1FFF;
         end else if(cycle < 96 + 2 * N) begin
            i = cycle - (96 + N);
            addr_b = i & 13'h1FFF;
            addr_a = ((i - 1 + N) % N) & 13'h1FFF;
         end else if(cycle < 96 + 3 * N) begin
            i = cycle - (96 + 2 * N);
            wren_b = 1;
            addr_b = i & 13'h1FFF;
            data_b = (7 * i + 3) & 8'hFF;
            addr_a = ((i - 1 + N) % N) & 13'h1FFF;
         end else begin
            i = cycle - (96 + 3 * N);
            addr_a = i & 13'h1FFF;
            addr_b = ((i - 1 + N) % N) & 13'h1FFF;
         end
      end
   endtask

   initial begin
      integer trace_output;
      integer cycle;

      trace_output = $fopen("module_tests/dpram/build/verilog_trace.csv", "w");
      if(!trace_output) $fatal(1, "could not open Verilog trace output");
      $fdisplay(trace_output, "CYCLE,Q_A,Q_B,WREN_A,WREN_B,ADDR_A,ADDR_B");

      for(cycle = 0; cycle < 32864; cycle = cycle + 1) begin
         @(negedge clk);
         apply_stimulus(cycle);
         @(posedge clk);
         #1;
         $fdisplay(trace_output, "%0d,%02X,%02X,%b,%b,%04X,%04X",
            cycle, q_a, q_b, wren_a, wren_b, addr_a, addr_b);
      end

      $fclose(trace_output);
      $display("Verilog trace complete");
      $finish;
   end
endmodule
