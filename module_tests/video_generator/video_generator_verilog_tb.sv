// video_generator_verilog_tb.sv
//
// Cycle-equivalence testbench (candidate side) for the Verilog
// video_generator. The golden side is video_generator_vhdl_tb.vhd, which
// drives the VHDL video_generator with the IDENTICAL stimulus schedule
// below and writes the same CSV schema.
//
// Run with CWD = this repository root so that "rtl/roms/video2.hex"
// resolves for the DUT's $readmemh.
//
// Machine model / stimulus / trace: see the header of
// video_generator_vhdl_tb.vhd (identical on both sides).
//
// Trace (sampled at rising edge + 1 ns, from cycle 4):
//   CYCLE, VIDEO, LDPS_N, WNDW_N, DL, MODE
//   MODE = ROMSWITCH GR2 ALTCHAR FLASH_CLK SEGC SEGB SEGA (7 bits)

`timescale 1ns/1ps

module video_generator_verilog_tb;

   localparam integer TOTAL = 1024;

   localparam string TRACE_FILE = "module_tests/video_generator/build/verilog_trace.csv";

   reg         clk_14m    = 1'b0;
   reg         clk_7m     = 1'b0;
   reg         altchar    = 1'b0;
   reg         romswitch  = 1'b0;
   reg         gr2        = 1'b0;
   reg         sega       = 1'b0;
   reg         segb       = 1'b0;
   reg         segc       = 1'b0;
   reg         wndw_n     = 1'b0;
   reg  [7:0]  dl         = 8'h00;
   reg         ldps_n     = 1'b1;
   reg  [24:0] ioctl_addr = 25'h000;
   reg  [7:0]  ioctl_data = 8'h00;
   reg         ioctl_wr   = 1'b0;
   reg         flash_clk  = 1'b0;
   wire        video_out;

   video_generator dut (
      .CLK_14M(clk_14m),
      .CLK_7M(clk_7m),
      .ALTCHAR(altchar),
      .ROMSWITCH(romswitch),
      .GR2(gr2),
      .SEGA(sega),
      .SEGB(segb),
      .SEGC(segc),
      .WNDW_N(wndw_n),
      .DL(dl),
      .LDPS_N(ldps_n),
      .ioctl_addr(ioctl_addr),
      .ioctl_data(ioctl_data),
      .ioctl_wr(ioctl_wr),
      .FLASH_CLK(flash_clk),
      .VIDEO(video_out)
   );

   always #5 clk_14m = ~clk_14m;

   integer f;
   integer cycle;

   initial begin
      f = $fopen(TRACE_FILE);
      if (f == 0) begin
         $display("FATAL: cannot open %s", TRACE_FILE);
         $finish;
      end
      $fdisplay(f, "CYCLE,VIDEO,LDPS_N,WNDW_N,DL,MODE");

      for (cycle = 0; cycle < TOTAL; cycle++) begin
         @(negedge clk_14m);

         // General schedule (must match video_generator_vhdl_tb.vhd).
         ldps_n    = 1'b1;
         wndw_n    = 1'b0;
         dl        = (cycle * 7) % 256;
         sega      = cycle % 2; segb = 1'b0; segc = 1'b0;
         gr2       = 1'b0; altchar = 1'b0;
         romswitch = 1'b0; flash_clk = 1'b0;
         ioctl_wr  = 1'b0; ioctl_addr = 25'h000; ioctl_data = 8'h00;

         if (cycle % 25 == 0) ldps_n = 1'b0;
         if (cycle % 2 == 1) sega = 1'b1;
         if ((cycle / 2) % 2 == 1) segb = 1'b1;
         if ((cycle / 4) % 2 == 1) segc = 1'b1;
         if ((cycle / 8) % 2 == 1) gr2 = 1'b1;
         if ((cycle / 16) % 2 == 1) altchar = 1'b1;
         if ((cycle / 64) % 2 == 1) romswitch = 1'b1;
         if ((cycle / 32) % 2 == 1) flash_clk = 1'b1;
         if (cycle <= 49 || (cycle >= 100 && cycle <= 124)) wndw_n = 1'b1;
         if (cycle >= 504 && cycle <= 513) begin
            ioctl_wr   = 1'b1;
            ioctl_addr = 25'h00234;
            ioctl_data = (cycle * 3) % 256;
         end
         if (cycle >= 748 && cycle <= 773) begin
            // Readback window: force video_rom_input_addr = 0x234.
            romswitch = 1'b0; gr2 = 1'b0; altchar = 1'b1; flash_clk = 1'b0;
            dl = 8'h46; segc = 1'b1; segb = 1'b0; sega = 1'b0;
         end
         if (cycle >= 799 && cycle <= 975) begin
            // ROMSWITCH window: force addr = 0x118 / 0x1118.
            romswitch = 1'b0; gr2 = 1'b0; altchar = 1'b0; flash_clk = 1'b0;
            dl = 8'h23; segc = 1'b0; segb = 1'b0; sega = 1'b0;
            if (cycle >= 823) romswitch = 1'b1;
         end
         if (cycle % 14 == 0) clk_7m = ~clk_7m;

         @(posedge clk_14m);
         #1;

         if (cycle >= 4) begin
            $fdisplay(f, "%0d,%b,%b,%b,%02h,%h",
                      cycle, video_out, ldps_n, wndw_n, dl,
                      {romswitch, gr2, altchar, flash_clk, segc, segb, sega});
         end
      end

      $fclose(f);
      $finish;
   end

endmodule
