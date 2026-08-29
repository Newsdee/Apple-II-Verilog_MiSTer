`timescale 1ns/1ps

module keyboard_verilog_tb;
   reg clk_14m = 0;
   reg [10:0] ps2_key = 0;
   reg virtual_active = 0;
   reg virtual_event = 0;
   reg virtual_pressed = 0;
   reg [6:0] virtual_code = 0;
   reg virtual_control = 0;
   reg virtual_open_apple = 0;
   reg virtual_closed_apple = 0;
   reg reads = 0;
   reg reset = 1;
   wire akd;
   wire [7:0] K;
   wire open_apple;
   wire closed_apple;
   wire soft_reset;
   wire video_toggle;
   wire palette_toggle;

   always #5 clk_14m = ~clk_14m;

   keyboard dut (
      .CLK_14M(clk_14m),
      .PS2_Key(ps2_key),
      .virtual_active(virtual_active),
      .virtual_event(virtual_event),
      .virtual_pressed(virtual_pressed),
      .virtual_code(virtual_code),
      .virtual_control(virtual_control),
      .virtual_open_apple(virtual_open_apple),
      .virtual_closed_apple(virtual_closed_apple),
      .reads(reads),
      .reset(reset),
      .akd(akd),
      .K(K),
      .open_apple(open_apple),
      .closed_apple(closed_apple),
      .soft_reset(soft_reset),
      .video_toggle(video_toggle),
      .palette_toggle(palette_toggle)
   );

   task automatic apply_stimulus(input integer cycle);
      begin
         reset = 0;
         ps2_key = 11'h000;
         reads = 0;
         virtual_active = 0;
         virtual_event = 0;
         virtual_pressed = 0;
         virtual_code = 7'h00;
         virtual_control = 0;
         virtual_open_apple = 0;
         virtual_closed_apple = 0;

         if(cycle < 4) begin
            reset = 1;
         end else if(cycle >= 8 && cycle <= 13) begin
            ps2_key = {1'b1, 1'b1, 1'b0, 8'h1C};  // make A
         end else if(cycle >= 28 && cycle <= 33) begin
            ps2_key = {1'b1, 1'b1, 1'b0, 8'h12};  // make left shift
         end else if(cycle >= 40 && cycle <= 45) begin
            ps2_key = {1'b1, 1'b1, 1'b0, 8'h1C};  // make A (shift held)
         end else if(cycle >= 60 && cycle <= 65) begin
            ps2_key = {1'b1, 1'b0, 1'b0, 8'h12};  // break left shift
         end else if(cycle >= 72 && cycle <= 77) begin
            ps2_key = {1'b1, 1'b1, 1'b1, 8'h75};  // make extended up arrow
         end else if(cycle >= 92 && cycle <= 97) begin
            ps2_key = {1'b1, 1'b0, 1'b1, 8'h75};  // break extended up arrow
         end else if(cycle >= 104 && cycle <= 109) begin
            ps2_key = {1'b1, 1'b1, 1'b0, 8'h06};  // make F2 (soft reset)
         end else if(cycle >= 124 && cycle <= 129) begin
            ps2_key = {1'b1, 1'b0, 1'b0, 8'h06};  // break F2
         end else if(cycle >= 136 && cycle <= 141) begin
            ps2_key = {1'b1, 1'b1, 1'b0, 8'h0A};  // make F8 (palette toggle)
         end else if(cycle >= 148 && cycle <= 153) begin
            ps2_key = {1'b1, 1'b0, 1'b0, 8'h0A};  // break F8
         end else if(cycle >= 160 && cycle <= 165) begin
            ps2_key = {1'b1, 1'b1, 1'b0, 8'h01};  // make F9 (video toggle)
         end else if(cycle >= 172 && cycle <= 177) begin
            ps2_key = {1'b1, 1'b0, 1'b0, 8'h01};  // break F9
         end else if(cycle >= 184 && cycle <= 189) begin
            ps2_key = {1'b1, 1'b1, 1'b0, 8'h58};  // make caps lock
         end else if(cycle >= 196 && cycle <= 201) begin
            ps2_key = {1'b1, 1'b0, 1'b0, 8'h58};  // break caps lock (toggles caplock)
         end else if(cycle >= 208 && cycle <= 213) begin
            ps2_key = {1'b1, 1'b1, 1'b0, 8'h1C};  // make A (caplock set)
         end else if(cycle >= 232 && cycle <= 271) begin
            virtual_active = 1;
            if(cycle >= 240 && cycle <= 255) begin
               virtual_event = 1;
               virtual_pressed = 1;
               virtual_code = 7'h2A;
               virtual_control = 1;
            end
            if(cycle >= 240 && cycle <= 249) begin
               virtual_open_apple = 1;
            end
            if(cycle >= 250 && cycle <= 255) begin
               virtual_closed_apple = 1;
            end
         end

         if(cycle == 20 || cycle == 52 || cycle == 84 ||
            cycle == 220 || cycle == 248 || cycle == 272) begin
            reads = 1;
         end
      end
   endtask

   initial begin
      integer trace_output;
      integer cycle;

      trace_output = $fopen("module_tests/keyboard/build/verilog_trace.csv", "w");
      if(!trace_output) $fatal(1, "could not open Verilog trace output");
      $fdisplay(trace_output, "CYCLE,K,READ_KEY,AKD,OPEN_APPLE,CLOSED_APPLE,SOFT_RESET,VIDEO_TOGGLE,PALETTE_TOGGLE");

      for(cycle = 0; cycle < 320; cycle = cycle + 1) begin
         @(negedge clk_14m);
         apply_stimulus(cycle);
         @(posedge clk_14m);
         #1;

         if(cycle >= 4) begin
            $fdisplay(trace_output, "%0d,%02X,%X,%X,%X,%X,%X,%X,%X",
               cycle, K, reads, akd, open_apple, closed_apple, soft_reset, video_toggle, palette_toggle);
         end
      end

      $fclose(trace_output);
      $display("Verilog trace complete");
      $finish;
   end
endmodule
