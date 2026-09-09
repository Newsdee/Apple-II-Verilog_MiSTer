// tb_composite.sv
// =====================================================================
// Unit testbench for rtl/apple_composite.sv (encoder + SPC=4 decoder).
//
// Drives a synthetic Apple-II-geometry line stream (measured on the core:
// line = 912 cycles = 352 HBL + 560 active, hs at HBL[130..197), vs/vb
// for the first 3 lines) and checks the composite -> RGB path:
//
//   1. luma: constant 1 -> bright gray; constant 0 -> black (sat=128)
//   2. 1-pixel dither (4 samples on / 4 off, the 1-bit NTSC colour dot)
//      at sat=128 produces a consistent non-gray colour along the line
//   3. column stability: two consecutive identical lines give
//      sample-for-sample identical RGB (free-running burst phase is
//      column-stable: 912 = 4 * 228 subcarrier cycles)
//   4. complementary dither (~pattern) produces the complementary colour
//      sample for sample: where A is R-heavy, B is B-heavy (or vice
//      versa). The decoder's SPC/2 notch is wide, so the fsc/2 1-bit
//      dither leaks ~-9 dB into the chroma channel and reads as a solid
//      per-class tint; the tint is an exact chroma offset that cancels
//      the luma, so complementary luma patterns give complementary
//      tints at every sample.
//   5. ordinary luma content (a 7-on/14-off text-like pattern) stays
//      predominantly monochrome at sat=128: no false colour on
//      non-fsc energy
//   6. saturation off (sat=0) kills colour: the dither line reads gray
//
// Timing discipline: the checks NEVER race the line driver. Each
// scenario waits on the driver's line_idx at a line boundary, sets the
// pattern there (the driver reads vpat_mode live, so the whole line is
// clean), and then samples by counting negedges from that boundary -
// no edge-waiting on pipeline-delayed outputs, so there is no line
// drift. Lines 0..2 are the vsync lines and are only used as warm-up;
// the first checked line is line 4, well after the vs block, so the
// decoder's burst lock / AGC / black clamp are fully settled.
//
// Run: Vtb_composite.exe from the repo root (no ROMs needed).
// =====================================================================

`timescale 1ns/1ps

module tb_composite;

  // ------------------------------------------------------------------
  // 14.318181 MHz clock (69.84 ns)
  // ------------------------------------------------------------------
  reg clk = 1'b0;
  always #34.92 clk = ~clk;

  // ------------------------------------------------------------------
  // DUT
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

  apple_composite dut (
    .clk    (clk),
    .ce     (1'b1),
    .video  (video),
    .hs     (hs),
    .vs     (vs),
    .hb     (hb),
    .vb     (vb),
    .sat    (sat),
    .hue    (hue),
    .bright (8'd0),
    .contrast (8'd128),
    .r      (r),
    .g      (g),
    .b      (b),
    .ce_out (ce_out),
    .hs_out (hs_out),
    .vs_out (vs_out),
    .hb_out (hb_out),
    .vb_out (vb_out)
  );

  // ------------------------------------------------------------------
  // Synthetic line driver (runs free in its own process)
  // ------------------------------------------------------------------
  localparam HBL_CYC  = 352;
  localparam HS_START = 130;
  localparam HS_LEN   = 68;
  localparam ACT_CYC  = 560;

  // 0 = all 0, 1 = all 1, 2 = 1-pixel dither A (i[2]: 4 on/4 off),
  // 3 = 1-pixel dither B (~i[2]), 4 = text-like 7-on/14-off
  reg [2:0] vpat_mode = 3'd0;

  // vsync lines, and the first line that is safe to check (past the
  // vs block, burst lock / AGC / black clamp fully settled).
  localparam VS_LINES   = 3;
  localparam FIRST_OK   = VS_LINES + 1;

  integer line_idx = 0;
  task automatic drive_lines;
    integer i;
    begin
      forever begin
        vs = (line_idx < VS_LINES);
        vb = (line_idx < VS_LINES);
        // HBL
        for (i = 0; i < HBL_CYC; i = i + 1) begin
          @(negedge clk);
          hb    = 1'b1;
          hs    = (i >= HS_START && i < HS_START + HS_LEN);
          video = 1'b0;
        end
        // active
        for (i = 0; i < ACT_CYC; i = i + 1) begin
          @(negedge clk);
          hb = 1'b0;
          hs = 1'b0;
          case (vpat_mode)
            3'd0    : video = 1'b0;
            3'd1    : video = 1'b1;
            3'd2    : video = i[2];
            3'd3    : video = ~i[2];
            default : video = (i % 21 < 7);
          endcase
        end
        line_idx = line_idx + 1;
      end
    end
  endtask

  // ------------------------------------------------------------------
  // Deterministic line protocol
  //
  // set_line_pattern waits until the driver is exactly at the boundary
  // of line `target` (line_idx == target, the line not yet driven) and
  // sets vpat_mode there; the driver's active region of that line then
  // uses the new pattern for all 560 samples.
  //
  // sample_line, called immediately after set_line_pattern returned
  // (same boundary negedge), counts HBL_CYC+1+SETTLE negedges: the
  // first active negedge is boundary+HBL_CYC+1 (the DUT's hb falls one
  // posedge after that TB negedge; the 13-stage hb_out pipeline and the
  // ~7-stage luma pipeline are covered by SETTLE), then collects NS
  // aligned samples. Pure counting: no drift, no off-by-a-line.
  // ------------------------------------------------------------------
  localparam NS     = 440;
  localparam SETTLE = 24;

  task automatic set_line_pattern (input [2:0] pat);
    integer target;
    begin
      target = line_idx + 1;
      if (target < FIRST_OK) target = FIRST_OK;
      wait (line_idx == target);
      vpat_mode = pat;
    end
  endtask

  reg [7:0] sr [0:NS-1];
  reg [7:0] sg [0:NS-1];
  reg [7:0] sb [0:NS-1];

  task automatic sample_line;
    integer i;
    begin
      repeat (HBL_CYC + 1 + SETTLE) @(negedge clk);
      for (i = 0; i < NS; i = i + 1) begin
        sr[i] = r;
        sg[i] = g;
        sb[i] = b;
        @(negedge clk);
      end
    end
  endtask

  // ------------------------------------------------------------------
  // Checks
  // ------------------------------------------------------------------
  integer errors = 0;

  // all samples gray (R==G==B) and within [lo, hi]
  task automatic check_const (input [7:0] lo, input [7:0] hi,
                              input [7:0] sat_v);
    integer i, bad;
    reg [7:0] lo_v, hi_v;
    begin
      bad  = 0;
      lo_v = 8'hFF;
      hi_v = 8'h00;
      for (i = 0; i < NS; i = i + 1) begin
        if (sr[i] !== sg[i] || sr[i] !== sb[i]) bad = bad + 1;
        if (sr[i] < lo_v) lo_v = sr[i];
        if (sr[i] > hi_v) hi_v = sr[i];
      end
      $display("  sat=%0d const-line: min=%0d max=%0d nongray=%0d/%0d %s",
               sat_v, lo_v, hi_v, bad, NS,
               (bad == 0 && lo_v >= lo && hi_v <= hi) ? "OK" : "FAIL");
      if (bad != 0 || lo_v < lo || hi_v > hi) errors = errors + 1;
    end
  endtask

  // dither hue-family check. A 1-pixel dither line is a solid colour per
  // 8-sample phase class (fixed luma phase vs free-running burst), so
  // the family is the majority over the whole line.
  // Returns 0 = gray, 1 = gold family (R > B), 2 = blue family (B > R),
  // 3 = no consistent family.
  task automatic check_dither (output reg [1:0] family, input [7:0] sat_v);
    integer i, gold, blue, gray;
    reg [7:0] r0, g0, b0;
    begin
      r0 = sr[100]; g0 = sg[100]; b0 = sb[100];
      gold = 0; blue = 0; gray = 0;
      for (i = 0; i < NS; i = i + 1) begin
        if (sr[i] === sg[i] && sr[i] === sb[i]) gray = gray + 1;
        else if ($signed({1'b0,sr[i]}) > $signed({1'b0,sb[i]}) + 8'sd16) gold = gold + 1;
        else if ($signed({1'b0,sb[i]}) > $signed({1'b0,sr[i]}) + 8'sd16) blue = blue + 1;
      end
      family = (gold > (NS/2)) ? 2'd1
               : (blue > (NS/2)) ? 2'd2
               : (gray > (NS/2)) ? 2'd0
               : 2'd3;
      $display("  sat=%0d dither: sample@100=(%0d,%0d,%0d) gold=%0d blue=%0d gray=%0d/%0d family=%0d",
               sat_v, r0, g0, b0, gold, blue, gray, NS, family);
      if (family == 2'd3) begin
        $display("    FAIL: no consistent family");
        errors = errors + 1;
      end
    end
  endtask

  // per-sample identity between the saved line and the current sample
  task automatic check_stable;
    integer i, diff = 0;
    begin
      for (i = 0; i < NS; i = i + 1)
        if (sr[i] !== sr_p[i] || sg[i] !== sg_p[i] || sb[i] !== sb_p[i])
          diff = diff + 1;
      $display("  stability: %0d/%0d samples differ between consecutive lines %s",
               diff, NS, (diff == 0) ? "OK" : "FAIL");
      if (diff != 0) errors = errors + 1;
    end
  endtask

  reg [7:0] sr_p [0:NS-1];
  reg [7:0] sg_p [0:NS-1];
  reg [7:0] sb_p [0:NS-1];
  task automatic save_line;
    integer i;
    begin
      for (i = 0; i < NS; i = i + 1) begin
        sr_p[i] = sr[i];
        sg_p[i] = sg[i];
        sb_p[i] = sb[i];
      end
    end
  endtask

  // complementary-dither check: at every sample, A and B must tilt the
  // opposite way (or both stay within the gray band). The chroma tint is
  // an exact additive offset that negates when the luma pattern
  // negates, so same-family samples mean the decoder lost the
  // per-sample phase relationship.
  task automatic check_complement;
    integer i, bad;
    reg signed [15:0] dA;
    reg signed [15:0] dB;
    begin
      bad = 0;
      for (i = 0; i < NS; i = i + 1) begin
        dA = $signed({8'd0, sr_p[i]}) - $signed({8'd0, sb_p[i]});
        dB = $signed({8'd0, sr[i]})   - $signed({8'd0, sb[i]});
        if ((dA >  16 && dB >  16) || (dA < -16 && dB < -16)) bad = bad + 1;
      end
      $display("  complement: %0d/%0d samples same-family (A vs B) %s",
               bad, NS, (bad <= NS/8) ? "OK" : "FAIL");
      if (bad > NS/8) begin
        $display("    FAIL: dither B not complementary to A");
        errors = errors + 1;
      end
    end
  endtask

  // per 8-sample phase class: average RGB. Documents the per-class tint
  // (1-bit dither artifact colour) for bring-up / hue tuning.
  task automatic dump_classes;
    integer i, c;
    reg [15:0] ar, ag, ab;
    begin
      for (c = 0; c < 8; c = c + 1) begin
        ar = 0; ag = 0; ab = 0;
        for (i = c; i < NS; i = i + 8) begin
          ar = ar + sr[i]; ag = ag + sg[i]; ab = ab + sb[i];
        end
        $display("    class%0d: (%0d,%0d,%0d)", c,
                 ar / 16'd55, ag / 16'd55, ab / 16'd55);
      end
    end
  endtask

  // ------------------------------------------------------------------
  // Scenario runner
  // ------------------------------------------------------------------
  initial begin
    reg [1:0] fam_a, fam_b, fam_text, fam_off;

    fork
      drive_lines;
    join_none

    #100ns;  // let the driver start (line 0 HBL)

    $display("COMPOSITE UNIT TEST START");

    // 1. luma with colour path enabled
    sat = 8'd128;
    set_line_pattern(3'd1);            // all white
    sample_line;
    check_const(8'd200, 8'd255, 8'd128);

    set_line_pattern(3'd0);            // all black
    sample_line;
    check_const(8'd0, 8'd32, 8'd128);

    // 2. 1-pixel dither at unity saturation must produce a consistent colour
    set_line_pattern(3'd2);            // dither A (i[2])
    sample_line;
    save_line;
    check_dither(fam_a, 8'd128);
    dump_classes;  // dither A
    if (fam_a == 2'd0) begin
      $display("  FAIL: dither A produced no colour (family=0)");
      errors = errors + 1;
    end

    // 3. column stability: next dither-A line, sample-for-sample
    set_line_pattern(3'd2);
    sample_line;
    check_stable;

    // 4. complementary dither B: per-sample opposite tilt
    set_line_pattern(3'd3);
    sample_line;
    check_dither(fam_b, 8'd128);
    dump_classes;  // dither B
    check_complement;
    if (fam_b == 2'd0) begin
      $display("  FAIL: dither B produced no colour (family=0)");
      errors = errors + 1;
    end

    // 5. ordinary luma content stays predominantly monochrome
    set_line_pattern(3'd4);
    sample_line;
    check_dither(fam_text, 8'd128);
    if (fam_text != 2'd0) begin
      $display("  FAIL: text-like luma content is not monochrome (family=%0d)",
               fam_text);
      errors = errors + 1;
    end

    // 6. saturation off must kill the colour
    sat = 8'd0;
    set_line_pattern(3'd2);
    sample_line;
    check_dither(fam_off, 8'd0);
    if (fam_off != 2'd0) begin
      $display("  FAIL: sat=0 still shows colour (family=%0d)", fam_off);
      errors = errors + 1;
    end

    $display("COMPOSITE UNIT TEST %s (errors=%0d)",
             (errors == 0) ? "PASS" : "FAIL", errors);
    $finish;
  end

  // hard timeout
  initial begin
    #5ms;
    $display("COMPOSITE UNIT TEST FAIL (timeout)");
    $finish;
  end

endmodule
