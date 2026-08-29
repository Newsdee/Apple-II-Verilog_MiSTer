// vga_controller_verilog_tb.sv
//
// Cycle-equivalence testbench (candidate side) for the Verilog
// vga_controller. The golden side is vga_controller_vhdl_tb.vhd. The
// procedural stimulus (schedule + pattern functions) and CSV schema are
// IDENTICAL - see the VHDL TB header for the machine model, the schedule,
// and the known expected palette-download divergence.
//
// Trace (every cycle), 21 columns:
//   CYCLE,VIDEO,HBL,VBL,SM,CP,GSF,NVC,CL,IOCTL_DL,IOCTL_IDX,IOCTL_WR,
//   IOCTL_DATA,VGA_HS,VGA_VS,VGA_HBL,VGA_VBL,VGA_R,VGA_G,VGA_B,IOCTL_WAIT

`timescale 1ns/1ps

module vga_controller_verilog_tb;

   localparam integer TOTAL = 163248;
   localparam string TRACE_FILE = "module_tests/vga_controller/build/verilog_trace.csv";

   reg         clk            = 1'b0;
   reg         video          = 1'b0;
   reg         color_line     = 1'b1;
   reg  [1:0]  screen_mode    = 2'b00;
   reg  [1:0]  color_palette  = 2'b00;
   reg         gray_seam_fix  = 1'b0;
   reg         nvc            = 1'b0;
   reg         hbl            = 1'b1;
   reg         vbl            = 1'b1;
   wire        vga_hs;
   wire        vga_vs;
   wire        vga_hbl;
   wire        vga_vbl;
   wire [7:0]  vga_r;
   wire [7:0]  vga_g;
   wire [7:0]  vga_b;
   reg  [24:0] ioctl_addr     = 25'h0;
   reg  [7:0]  ioctl_data     = 8'h0;
   reg  [7:0]  ioctl_index    = 8'h0;
   reg         ioctl_download = 1'b0;
   reg         ioctl_wr       = 1'b0;
   wire        ioctl_wait;

   vga_controller dut (
      .CLK_14M(clk),
      .VIDEO(video),
      .COLOR_LINE(color_line),
      .SCREEN_MODE(screen_mode),
      .COLOR_PALETTE(color_palette),
      .GRAY_SEAM_FIX(gray_seam_fix),
      .NTSC_VERTICAL_COMB(nvc),
      .HBL(hbl),
      .VBL(vbl),
      .VGA_HS(vga_hs),
      .VGA_VS(vga_vs),
      .VGA_HBL(vga_hbl),
      .VGA_VBL(vga_vbl),
      .VGA_R(vga_r),
      .VGA_G(vga_g),
      .VGA_B(vga_b),
      .ioctl_addr(ioctl_addr),
      .ioctl_data(ioctl_data),
      .ioctl_index(ioctl_index),
      .ioctl_download(ioctl_download),
      .ioctl_wr(ioctl_wr),
      .ioctl_wait(ioctl_wait)
   );

   always #5 clk = ~clk;

   function automatic logic video_bit(input integer pat, input integer ph, input integer c);
      case (pat)
         0:  video_bit = (c % 2) == 1;
         4:  video_bit = ((c + ph) % 4) < 2;
         5:  video_bit = 1'b1;
         6:  video_bit = 1'b0;
         7:  video_bit = (c == ph);
         8:  video_bit = ((c + ph) % 8) < 4;
         9:  video_bit = (c >= 100 && c <= 101) || (c >= 300 && c <= 301);
         10: video_bit = !(c >= 500 && c <= 501);
         11: video_bit = ((c + ph) % 4) < 3;
         12: video_bit = ((c + ph) % 4) == 0;
         default: video_bit = 1'b0;
      endcase
   endfunction

   integer f;
   integer n, li, c, k, j, d;
   integer pat, ph;
   logic vbl_v, gsf_v, nvc_v, cl_v;
   logic [1:0] sm_v, cp_v;

   initial begin
      f = $fopen(TRACE_FILE);
      if (f == 0) begin
         $display("FATAL: cannot open %s", TRACE_FILE);
         $finish;
      end
      $fdisplay(f, "CYCLE,VIDEO,HBL,VBL,SM,CP,GSF,NVC,CL,IOCTL_DL,IOCTL_IDX,IOCTL_WR,IOCTL_DATA,VGA_HS,VGA_VS,VGA_HBL,VGA_VBL,VGA_R,VGA_G,VGA_B,IOCTL_WAIT");

      for (n = 0; n < TOTAL; n++) begin
         @(negedge clk);

         li = n / 912;
         c  = n % 912;

         vbl_v = 1'b1; sm_v = 2'b00; cp_v = 2'b00;
         gsf_v = 1'b0; nvc_v = 1'b0; cl_v = 1'b1;
         pat = 0; ph = 0; d = 0;
         ioctl_download = 1'b0;
         ioctl_index = 8'h0;
         ioctl_wr = 1'b0;
         ioctl_data = 8'h0;

         if (li == 2 && c < 64) begin
            ioctl_download = 1'b1;
            ioctl_index = 8'h02;
            ioctl_wr = 1'b1;
            k = c / 4; j = c % 4;
            if (j == 0)      d = (17 * k + 1) % 256;
            else if (j == 1) d = (13 * k + 2) % 256;
            else if (j == 2) d = (11 * k + 3) % 256;
            else             d = 90;
            ioctl_data = d[7:0];
         end

         if (li >= 3 && li <= 4) begin
            vbl_v = 1'b0;
            if (li == 3) begin pat = 4; ph = 0; end else begin pat = 0; end
         end else if (li >= 5 && li <= 44) begin
            vbl_v = 1'b1;
         end else if (li >= 45 && li <= 52) begin
            vbl_v = 1'b0;
            case (li - 45)
               0: pat = 0;
               1: begin pat = 4; ph = 1; end
               2: begin pat = 4; ph = 2; end
               3: begin pat = 4; ph = 3; end
               4: pat = 5;
               5: pat = 6;
               6: begin pat = 7; ph = 200; cl_v = 1'b0; end
               default: begin pat = 8; ph = 0; end
            endcase
         end else if (li >= 53 && li <= 57) begin
            vbl_v = 1'b1;
         end else if (li >= 58 && li <= 65) begin
            vbl_v = 1'b0;
            case (li - 58)
               0: pat = 9;
               1: pat = 10;
               2: begin pat = 4; ph = 0; end
               3: begin pat = 7; ph = 400; cl_v = 1'b0; end
               4: pat = 0;
               5: begin pat = 8; ph = 4; end
               6: pat = 5;
               default: pat = 9;
            endcase
         end else if (li >= 66 && li <= 129) begin
            vbl_v = 1'b0;
            k = (li - 66) / 4; j = (li - 66) % 4;
            sm_v = k[1:0];
            cp_v = k[3:2];
            if (j == 0)       begin pat = 7; ph = 200; cl_v = 1'b0; end
            else if (j == 1)  begin pat = 4; ph = k % 4; end
            else if (j == 2)  begin pat = 0; end
            else              begin pat = 9; end
         end else if (li >= 130 && li <= 141) begin
            vbl_v = 1'b0; gsf_v = 1'b1;
            if (li <= 135) begin sm_v = 2'b00; cp_v = 2'b00; end
            else           begin sm_v = 2'b01; cp_v = 2'b01; end
            j = (li - 130) % 6;
            case (j)
               0: pat = 9;
               1: pat = 10;
               2: begin pat = 4; ph = 0; end
               3: begin pat = 7; ph = 300; cl_v = 1'b0; end
               4: pat = 9;
               default: pat = 0;
            endcase
         end else if (li >= 142 && li <= 145) begin
            vbl_v = 1'b1; nvc_v = 1'b1;
         end else if (li >= 146 && li <= 153) begin
            vbl_v = 1'b0; nvc_v = 1'b1;
            case (li - 146)
               0: begin pat = 4; ph = 0; end
               1: begin pat = 4; ph = 2; end
               2: begin pat = 4; ph = 1; end
               3: begin pat = 4; ph = 3; end
               4: pat = 0;
               5: begin pat = 8; ph = 0; end
               6: pat = 9;
               default: pat = 5;
            endcase
         end else if (li >= 154 && li <= 158) begin
            vbl_v = 1'b1; nvc_v = 1'b1;
         end else if (li >= 159 && li <= 166) begin
            vbl_v = 1'b0; nvc_v = 1'b1;
            case (li - 159)
               0: begin pat = 4; ph = 2; end
               1: begin pat = 4; ph = 0; end
               2: begin pat = 4; ph = 3; end
               3: begin pat = 4; ph = 1; end
               4: pat = 0;
               5: begin pat = 8; ph = 4; end
               6: pat = 10;
               default: begin pat = 7; ph = 200; cl_v = 1'b0; end
            endcase
         end else if (li >= 167 && li <= 170) begin
            vbl_v = 1'b0; nvc_v = 1'b1; sm_v = 2'b01;
            case (li - 167)
               0: begin pat = 4; ph = 0; end
               1: begin pat = 4; ph = 2; end
               2: pat = 0;
               default: pat = 9;
            endcase
         end else if (li >= 171 && li <= 178) begin
            vbl_v = 1'b0; cp_v = 2'b11;
            case (li - 171)
               0: begin pat = 4; ph = 0; end
               1: begin pat = 11; ph = 0; end
               2: begin pat = 12; ph = 0; end
               3: pat = 0;
               4: pat = 5;
               5: pat = 6;
               6: begin pat = 11; ph = 2; end
               default: begin pat = 12; ph = 2; end
            endcase
         end else begin
            vbl_v = 1'b1;
         end

         hbl = (c < 352);
         vbl = vbl_v;
         screen_mode = sm_v;
         color_palette = cp_v;
         gray_seam_fix = gsf_v;
         nvc = nvc_v;
         color_line = cl_v;
         video = (vbl_v == 1'b0) ? video_bit(pat, ph, c) : 1'b0;

         @(posedge clk);
         #1;

         $fdisplay(f, "%0d,%b,%b,%b,%b,%b,%b,%b,%b,%b,%02h,%b,%02h,%b,%b,%b,%b,%02h,%02h,%02h,%b",
                   n, video, hbl, vbl, screen_mode, color_palette,
                   gray_seam_fix, nvc, color_line, ioctl_download,
                   ioctl_index, ioctl_wr, ioctl_data,
                   vga_hs, vga_vs, vga_hbl, vga_vbl,
                   vga_r, vga_g, vga_b, ioctl_wait);
      end

      $fclose(f);
      $finish;
   end

endmodule
