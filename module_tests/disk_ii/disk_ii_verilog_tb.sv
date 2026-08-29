`timescale 1ns/1ps

module disk_ii_verilog_tb;
   reg clk_14m = 0;
   reg clk_2m = 0;
   reg phase_zero = 0;
   reg io_select = 0;
   reg device_select = 0;
   reg reset = 1;
   reg [1:0] disk_ready = 2'b11;
   reg [15:0] address_bus = 0;
   reg [7:0] data_in = 0;
   wire [7:0] data_out;
   wire drive1_active;
   wire drive2_active;
   wire drive1_motor_on;
   wire drive2_motor_on;
   wire drive1_io_active;
   wire drive2_io_active;
   wire drive1_step_active;
   wire drive2_step_active;
   wire drive1_track_zero_step;
   wire drive2_track_zero_step;
   reg drive1_write_protected = 0;
   reg drive2_write_protected = 0;
   wire [5:0] track1;
   wire [12:0] track1_addr;
   wire [7:0] track1_di;
   wire [7:0] track1_do = track1_addr[7:0] ^ 8'h5A;
   wire track1_we;
   reg track1_busy = 0;
   wire [5:0] track2;
   wire [12:0] track2_addr;
   wire [7:0] track2_di;
   wire [7:0] track2_do = track2_addr[7:0] ^ 8'hA5;
   wire track2_we;
   reg track2_busy = 0;

   always #5 clk_14m = ~clk_14m;
   initial begin
      #17;
      forever #35 clk_2m = ~clk_2m;
   end

   disk_ii dut (
      .CLK_14M(clk_14m),
      .CLK_2M(clk_2m),
      .PHASE_ZERO(phase_zero),
      .IO_SELECT(io_select),
      .DEVICE_SELECT(device_select),
      .RESET(reset),
      .DISK_READY(disk_ready),
      .A(address_bus),
      .D_IN(data_in),
      .D_OUT(data_out),
      .D1_ACTIVE(drive1_active),
      .D2_ACTIVE(drive2_active),
      .D1_MOTOR_ON(drive1_motor_on),
      .D2_MOTOR_ON(drive2_motor_on),
      .D1_IO_ACTIVE(drive1_io_active),
      .D2_IO_ACTIVE(drive2_io_active),
      .D1_STEP_ACTIVE(drive1_step_active),
      .D2_STEP_ACTIVE(drive2_step_active),
      .D1_TRACK_ZERO_STEP(drive1_track_zero_step),
      .D2_TRACK_ZERO_STEP(drive2_track_zero_step),
      .D1_WP(drive1_write_protected),
      .D2_WP(drive2_write_protected),
      .TRACK1(track1),
      .TRACK1_ADDR(track1_addr),
      .TRACK1_DI(track1_di),
      .TRACK1_DO(track1_do),
      .TRACK1_WE(track1_we),
      .TRACK1_BUSY(track1_busy),
      .TRACK2(track2),
      .TRACK2_ADDR(track2_addr),
      .TRACK2_DI(track2_di),
      .TRACK2_DO(track2_do),
      .TRACK2_WE(track2_we),
      .TRACK2_BUSY(track2_busy)
   );

   task automatic apply_stimulus(input integer cycle);
      integer step_group;
      begin
         reset = 0;
         io_select = 0;
         device_select = 0;
         phase_zero = 0;
         disk_ready = 2'b11;
         drive1_write_protected = 0;
         drive2_write_protected = 0;
         track1_busy = 0;
         track2_busy = 0;
         address_bus = 16'hC080;
         data_in = (cycle * 13 + 7) & 8'hFF;

         if(cycle < 4) begin
            reset = 1;
         end else if(cycle <= 259) begin
            io_select = 1;
            address_bus = 16'hC600 + cycle - 4;
         end else if(cycle == 260) begin
            device_select = 1; address_bus = 16'hC089;
         end else if(cycle == 261) begin
            device_select = 1; address_bus = 16'hC08D;
         end else if(cycle == 262) begin
            drive1_write_protected = 1;
         end else if(cycle == 263) begin
            drive1_write_protected = 0;
         end else if(cycle == 264) begin
            device_select = 1; address_bus = 16'hC08B;
         end else if(cycle == 265) begin
            drive2_write_protected = 1;
         end else if(cycle == 266) begin
            device_select = 1; address_bus = 16'hC08D; drive2_write_protected = 1;
         end else if(cycle == 267) begin
            drive2_write_protected = 1;
         end else if(cycle == 268) begin
            device_select = 1; address_bus = 16'hC08A;
         end else if(cycle == 269) begin
            drive1_write_protected = 1;
         end else if(cycle == 270) begin
            device_select = 1; address_bus = 16'hC08C;
         end else if(cycle == 271) begin
            device_select = 1; address_bus = 16'hC081;
         end else if(cycle == 272) begin
            device_select = 1; address_bus = 16'hC080;
         end else if(cycle == 273) begin
            device_select = 1; address_bus = 16'hC088;
         end else if(cycle >= 274 && cycle <= 413) begin
            step_group = (cycle - 274) / 4;
            if((cycle - 274) % 4 == 0) begin
               device_select = 1;
               case(step_group % 4)
                  0: address_bus = 16'hC083;
                  1: address_bus = 16'hC081;
                  2: address_bus = 16'hC087;
                  default: address_bus = 16'hC085;
               endcase
            end else if((cycle - 274) % 4 == 2) begin
               device_select = 1;
               case(step_group % 4)
                  0: address_bus = 16'hC082;
                  1: address_bus = 16'hC080;
                  2: address_bus = 16'hC086;
                  default: address_bus = 16'hC084;
               endcase
            end
         end else if(cycle == 414) begin
            device_select = 1; address_bus = 16'hC08B;
         end else if(cycle >= 415 && cycle <= 554) begin
            step_group = (cycle - 415) / 4;
            if((cycle - 415) % 4 == 0) begin
               device_select = 1;
               case(step_group % 4)
                  0: address_bus = 16'hC083;
                  1: address_bus = 16'hC081;
                  2: address_bus = 16'hC087;
                  default: address_bus = 16'hC085;
               endcase
            end else if((cycle - 415) % 4 == 2) begin
               device_select = 1;
               case(step_group % 4)
                  0: address_bus = 16'hC082;
                  1: address_bus = 16'hC080;
                  2: address_bus = 16'hC086;
                  default: address_bus = 16'hC084;
               endcase
            end
         end else if(cycle == 555) begin
            device_select = 1; address_bus = 16'hC08A;
         end else if(cycle == 556) begin
            device_select = 1; address_bus = 16'hC089;
         end else if(cycle <= 1299) begin
            device_select = 1; phase_zero = 1;
            address_bus = cycle % 8 == 0 ? 16'hC08F : 16'hC08C;
            if(cycle % 37 == 0) track1_busy = 1;
         end else if(cycle == 1300) begin
            device_select = 1; address_bus = 16'hC08B;
         end else if(cycle <= 2099) begin
            device_select = 1; phase_zero = 1;
            address_bus = cycle % 8 == 0 ? 16'hC08F : 16'hC08C;
            if(cycle % 41 == 0) track2_busy = 1;
         end else if(cycle == 2100) begin
            device_select = 1; address_bus = 16'hC08E;
         end else if(cycle == 2101) begin
            device_select = 1; address_bus = 16'hC08A;
         end else if(cycle <= 3099) begin
            device_select = 1; address_bus = 16'hC08C;
            if(cycle % 7 == 0) phase_zero = 1;
            if(cycle % 29 == 0) disk_ready[0] = 0;
         end else if(cycle == 3100) begin
            device_select = 1; address_bus = 16'hC08B;
         end else if(cycle <= 4099) begin
            device_select = 1; address_bus = 16'hC08C;
            if(cycle % 7 == 0) phase_zero = 1;
            if(cycle % 31 == 0) disk_ready[1] = 0;
         end else if(cycle == 4100) begin
            device_select = 1; address_bus = 16'hC088;
         end else begin
         end
      end
   endtask

   initial begin
      integer trace_output;
      integer cycle;
      reg [11:0] flags;

      trace_output = $fopen("module_tests/disk_ii/build/verilog_trace.csv", "w");
      if(!trace_output) $fatal(1, "could not open Verilog trace output");
      $fdisplay(trace_output, "CYCLE,D_OUT,FLAGS,TRACK1,TRACK1_ADDR,TRACK1_DI,TRACK2,TRACK2_ADDR,TRACK2_DI");

      for(cycle = 0; cycle < 14005200; cycle = cycle + 1) begin
         @(negedge clk_14m);
         apply_stimulus(cycle);
         @(posedge clk_14m);
         #1;

         if(cycle >= 4 && (cycle < 5000 || cycle >= 14003100)) begin
            flags = {drive1_active, drive2_active, drive1_motor_on, drive2_motor_on,
               drive1_io_active, drive2_io_active, drive1_step_active, drive2_step_active,
               drive1_track_zero_step, drive2_track_zero_step, track1_we, track2_we};
            $fdisplay(trace_output, "%0d,%02X,%03X,%02X,%04X,%02X,%02X,%04X,%02X",
               cycle, data_out, flags, track1, track1_addr, track1_di,
               track2, track2_addr, track2_di);
         end
      end

      $fclose(trace_output);
      $display("Verilog trace complete");
      $finish;
   end
endmodule
