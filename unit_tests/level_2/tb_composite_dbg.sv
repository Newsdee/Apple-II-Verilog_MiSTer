// tb_composite_dbg.sv
// =====================================================================
// Debug testbench: wraps apple_composite and exposes the decoder's
// internal state so a failing bring-up run can be inspected without
// touching the vendored decoder.
// =====================================================================

`timescale 1ns/1ps

module tb_composite_dbg;

  reg clk = 1'b0;
  always #34.92 clk = ~clk;

  // ------------------------------------------------------------------
  // Wrapper around the DUT exposing internals
  // ------------------------------------------------------------------
  reg        video = 1'b0;
  reg        hs    = 1'b0;
  reg        vs    = 1'b0;
  reg        hb    = 1'b0;
  reg        vb    = 1'b0;
  reg  [7:0] sat   = 8'd128;
  reg  [7:0] hue   = 8'd0;
  wire [7:0] r, g, b;
  wire       ce_out, hs_out, vs_out, hb_out, vb_out;

  wire signed [23:0] dbg_comp;
  wire signed [23:0] dbg_black;
  wire signed [15:0] dbg_c16;
  wire signed [15:0] dbg_yc;
  wire signed [16:0] dbg_ylp;
  wire        [16:0] dbg_lgain;
  wire        [15:0] dbg_bpp;
  wire        [15:0] dbg_ag_ratio;
  wire        dbg_colour_ok;
  wire signed [15:0] dbg_ib;
  wire signed [15:0] dbg_qb;
  wire [9:0]         dbg_hcnt;

  ac_dbg_wrap u_w (
    .clk(clk), .ce(1'b1),
    .video(video), .hs(hs), .vs(vs), .hb(hb), .vb(vb),
    .sat(sat), .hue(hue),
    .r(r), .g(g), .b(b),
    .ce_out(ce_out), .hs_out(hs_out), .vs_out(vs_out),
    .hb_out(hb_out), .vb_out(vb_out),
    .dbg_comp(dbg_comp), .dbg_black(dbg_black), .dbg_c16(dbg_c16),
    .dbg_yc(dbg_yc), .dbg_ylp(dbg_ylp), .dbg_lgain(dbg_lgain),
    .dbg_bpp(dbg_bpp), .dbg_ag_ratio(dbg_ag_ratio),
    .dbg_colour_ok(dbg_colour_ok), .dbg_ib(dbg_ib), .dbg_qb(dbg_qb),
    .dbg_hcnt(dbg_hcnt)
  );

  // ------------------------------------------------------------------
  // Line driver (same geometry as tb_composite)
  // ------------------------------------------------------------------
  localparam HBL_CYC  = 352;
  localparam HS_START = 130;
  localparam HS_LEN   = 68;
  localparam ACT_CYC  = 560;

  // 0 = all 0, 1 = all 1
  reg [1:0] vpat_mode = 2'd1;

  integer line_idx = 0;
  task automatic drive_lines;
    integer i;
    begin
      forever begin
        vs = (line_idx < 3);
        vb = (line_idx < 3);
        for (i = 0; i < HBL_CYC; i = i + 1) begin
          @(negedge clk);
          hb    = 1'b1;
          hs    = (i >= HS_START && i < HS_START + HS_LEN);
          video = 1'b0;
        end
        for (i = 0; i < ACT_CYC; i = i + 1) begin
          @(negedge clk);
          hb = 1'b0;
          hs = 1'b0;
          video = (vpat_mode == 2'd0) ? 1'b0 : 1'b1;
        end
        line_idx = line_idx + 1;
      end
    end
  endtask

  // ------------------------------------------------------------------
  // Probe: at a set of taps inside the active region of the line
  // following the hs, print the internal state.
  // ------------------------------------------------------------------
  integer errors = 0;

  initial begin
    fork
      drive_lines;
    join_none

    #1us;

    // skip to the 3rd hs rise (line 2 = last vsync line), then take the
    // NEXT hs rise (line 3 = first line after the vs block) and trace it
    begin : skip3
      integer n;
      for (n = 0; n < 3; n = n + 1) begin
        wait (hs == 1'b0);
        wait (hs == 1'b1);
      end
    end

    $display("COMPOSITE DBG (line 3: all-white active line, FIRST line after the vs block)");
    // take the next hs rise (line 3), then its fall (= hcnt 0)
    wait (hs == 1'b0);                   // end of line 2's hs pulse
    wait (hs == 1'b1);                   // line 3 hs rise
    wait (hs == 1'b0);                   // line 3 hs fall = hcnt 0
    // hcnt 0 at hs fall; sample taps relative to that:
    // t = hcnt value (approx, 1:1 with cycles after hs fall)
    begin : taps
      integer t;
      for (t = 0; t < 400; t = t + 20) begin
        repeat (20) @(negedge clk);
        $display("  hcnt=%0d comp=%0d black=%0d c16=%0d yc=%0d ylp=%0d lgain=%0d bpp=%0d agr=%0d colour_ok=%b ib=%0d qb=%0d rgb=(%0d,%0d,%0d)",
                 dbg_hcnt, dbg_comp, dbg_black, dbg_c16, dbg_yc,
                 dbg_ylp, dbg_lgain, dbg_bpp, dbg_ag_ratio,
                 dbg_colour_ok, dbg_ib, dbg_qb, r, g, b);
      end
    end
    $display("COMPOSITE DBG done");
    $finish;
  end

  initial begin
    #5ms;
    $display("COMPOSITE DBG FAIL (timeout)");
    $finish;
  end

endmodule

// =====================================================================
// Debug wrapper: apple_composite + exposed decoder internals
// =====================================================================
module ac_dbg_wrap #(
  parameter BURST_START = 8,
  parameter BURST_LEN   = 64
)(
  input        clk, ce, video, hs, vs, hb, vb,
  input  [7:0] sat, hue,
  output [7:0] r, g, b,
  output       ce_out, hs_out, vs_out, hb_out, vb_out,
  output signed [23:0] dbg_comp,
  output signed [23:0] dbg_black,
  output signed [15:0] dbg_c16,
  output signed [15:0] dbg_yc,
  output signed [16:0] dbg_ylp,
  output       [16:0] dbg_lgain,
  output       [15:0] dbg_bpp,
  output       [15:0] dbg_ag_ratio,
  output       dbg_colour_ok,
  output signed [15:0] dbg_ib,
  output signed [15:0] dbg_qb,
  output [9:0] dbg_hcnt
);
  apple_composite u (.clk(clk), .ce(ce), .video(video), .hs(hs),
                     .vs(vs), .hb(hb), .vb(vb), .sat(sat), .hue(hue),
                     .bright(8'd0), .contrast(8'd128),
                     .r(r), .g(g), .b(b),
                     .ce_out(ce_out), .hs_out(hs_out), .vs_out(vs_out),
                     .hb_out(hb_out), .vb_out(vb_out));
  assign dbg_comp        = u.comp;
  assign dbg_black       = u.u_dec.black;
  assign dbg_c16         = u.u_dec.c16;
  assign dbg_yc          = u.u_dec.yc;
  assign dbg_ylp         = u.u_dec.y_lp;
  assign dbg_lgain       = u.u_dec.lgain;
  assign dbg_bpp         = u.u_dec.bpp;
  assign dbg_ag_ratio    = u.u_dec.ag_ratio;
  assign dbg_colour_ok   = u.u_dec.colour_ok;
  assign dbg_ib          = u.u_dec.ib;
  assign dbg_qb          = u.u_dec.qb;
  assign dbg_hcnt        = u.u_dec.hcnt;
endmodule
