// =============================================================================
// tb_mixplus.sv - 2026-09-08
//
// Verifies the wrapper's composite-video block (the "COMPOSITE VIDEO" section
// of unit_tests/level_2/mister/Apple-II.sv) in isolation:
//
//   machine-domain source (hbl/vbl/video at 14.318 MHz = clk/4)
//     -> 2-FF synchronizers into CLK_VIDEO (57.27 MHz)
//     -> sync derivation in the CLK_VIDEO domain (130/68, 33/3)
//     -> apple_composite (one modulated sample per ce_pix)
//     -> video_mixer_plus A/B select (native mono vs. composite decode)
//
// Clock model: a single 57.27 MHz clock; ce_pix is the wrapper's 4:1
// divider.  The machine-domain source updates once per ce_pix, exactly as
// the real machine's outputs update once per 14.318 MHz cycle.
//
// Self-driving (--binary --timing): the module is portless - the generated
// main has no C++ driver, so the clock and reset are generated inside
// (a portless top with no time-advancing logic just "ends at 0s").
//   phase A: use_composite=0 (native) for 2 frames - expect HSync/VSync
//            edges and the native pattern on VGA.
//   phase B: use_composite=1 (composite) for 4 frames - expect CE_PIXEL
//            pulses, HSync/VSync edges, black/white contrast (gmax>=160),
//            ink on the decoded frame, and ARTIFACT COLOR (nongray>0 at
//            sat=128: the fsc dither lines must decode with chroma).
//   phase C: sat=0 (OSD knob "Off") for 2 frames - expect pure gray:
//            ink present, nongray == 0.
//   phase D: back to sat=128 with the "NTSC vertical blend" knob ON
//            for 4 frames.  On this deterministic content the fsc
//            dither phase is identical on every line (no per-line
//            180-degree flip), so the comb does NOT cancel the
//            dither chroma: it halves each dither line's chroma and
//            gives half to the following line.  The robust property
//            is therefore that the MAX per-pixel colour deviation
//            (max(r,g,b)-min(r,g,b)) halves: actchrmax_D < actchrmax_B,
//            measured over the ACTIVE WINDOW only (vga_de high):
//              * the blend's filter gate is active-only (like the
//                main branch's comb, which acts on the active window
//                of the vga_controller); blanking pixels always
//                bypass it (2 ce late when the knob is on);
//              * this decoder passes its decoded sample through in
//                the composite-domain HBL, so the line-START
//                transient of a dither line (residual subcarrier
//                state) keeps full chroma in BOTH phases B and D -
//                the all-pixel chrmax is that transient (the argmax
//                print shows de=0 on it in every phase) and is
//                excluded from the assertion;
//              * active nongray INCREASES by design on this content
//                (the white lines that follow the dither lines pick
//                up half their chroma), so it is NOT asserted to
//                decrease - luma preservation is covered by the
//                gmin/gmax checks instead.
//            (ink, white, black, syncs must all remain good.)
// =============================================================================

module tb_mixplus;
  reg clk = 1'b0;     // CLK_VIDEO (57.27 MHz model; ratios matter, not rate)
  always #1 clk = ~clk;
  reg reset = 1'b1;
  reg [3:0] rst_cnt = 4'd0;
  always @(posedge clk) begin
    rst_cnt <= rst_cnt + 4'd1;
    if (rst_cnt >= 4'd8) reset <= 1'b0;
  end

  localparam HSYNC_FRONT_PORCH = 130;
  localparam HSYNC_WIDTH       = 68;
  localparam VSYNC_FRONT_PORCH = 33;
  localparam VSYNC_LINES       = 3;

  localparam integer LINE_CYC  = 912;  // machine cycles per line
  localparam integer HBL_CYC   = 352;  // machine cycles of HBL
  localparam integer FRAME_LN  = 262;  // lines per frame
  localparam integer VBL_LN    = 69;   // lines of VBL

  // ------------------------------------------------------------------
  // 4:1 divider - exactly the wrapper's video_div/ce_pix.
  // ------------------------------------------------------------------
  reg [1:0] video_div = 2'd0;
  reg       ce_pix;
  always @(posedge clk) begin
    video_div <= video_div + 2'd1;
    ce_pix    <= &video_div;
  end

  // ------------------------------------------------------------------
  // Machine-domain source: one update per ce_pix (machine cycle).
  // Line luma = luma of line[3:0]: lines 8-15 white, 16-23 black, ...
  // so the decoded composite frame must show both extremes.  Lines with
  // line[2]=1 in the active area also get a 1-bit dither (chroma when
  // sat=128).  All counts are machine cycles.
  // ------------------------------------------------------------------
  reg [9:0] mcyc  = 10'd0;   // machine cycle within line
  reg [8:0] mline = 9'd0;    // line within frame
  always @(posedge clk) begin
    if (reset) begin
      mcyc  <= 10'd0;
      mline <= 9'd0;
    end else if (ce_pix) begin
      if (mcyc == LINE_CYC - 1) begin
        mcyc  <= 10'd0;
        mline <= (mline == FRAME_LN - 1) ? 9'd0 : mline + 9'd1;
      end else begin
        mcyc  <= mcyc + 10'd1;
      end
    end
  end

  wire hbl   = (mcyc < HBL_CYC);
  wire vbl   = (mline < VBL_LN);
  wire [3:0] lluma = mline[3:0];
  wire active = ~hbl & ~vbl;
  // Dithered lines (mline[2]=1, mline[0]=0): a 2-high/2-low square wave with
  // a 4-sample period = exactly one subcarrier cycle (encoder/decoder run
  // at SPC=4; 912 machine cycles per line = 228 whole cycles, so the tone's
  // phase relative to the burst is identical on every line -> a stable
  // artifact hue).  A 2-sample period would sit at 2*fsc, which the
  // decoder's notch rejects - it could never produce chroma.
  wire video = active & (lluma >= 4'd8) &
              ((~mline[2]) | (mcyc[1:0] < 2'd2) | mline[0]);

  wire [7:0] native_rgb = {8{video}};

  // Native syncs (machine domain - the wrapper's 14 MHz derivation).
  reg [9:0] hblank_cnt = 10'd0;
  always @(posedge clk) begin
    if (ce_pix) begin
      if (hbl)
        hblank_cnt <= hblank_cnt + 10'd1;
      else
        hblank_cnt <= 10'd0;
    end
  end
  reg         hbl_d      = 1'b0;
  wire        hbl_rise   = hbl & ~hbl_d;
  always @(posedge clk) if (ce_pix) hbl_d <= hbl;
  reg [6:0]   vblank_lines = 7'd0;
  always @(posedge clk) begin
    if (ce_pix) begin
      if (vbl) begin
        if (hbl_rise)
          vblank_lines <= vblank_lines + 7'd1;
      end else begin
        vblank_lines <= 7'd0;
      end
    end
  end
  wire native_hsync = hbl & (hblank_cnt >= HSYNC_FRONT_PORCH) &
                      (hblank_cnt < HSYNC_FRONT_PORCH + HSYNC_WIDTH);
  wire native_vsync = vbl & (vblank_lines >= VSYNC_FRONT_PORCH) &
                      (vblank_lines < VSYNC_FRONT_PORCH + VSYNC_LINES);

  // ==================================================================
  // WRAPPER BLOCK (verbatim from mister/Apple-II.sv, CLK_VIDEO=clk)
  // ==================================================================
  wire CLK_VIDEO = clk;

  reg video_s1, video_s2;
  always @(posedge CLK_VIDEO) begin
    video_s1 <= video;
    video_s2 <= video_s1;
  end
  wire video_c = video_s2;
  reg hbl_s1, hbl_s2;
  always @(posedge CLK_VIDEO) begin
    hbl_s1 <= hbl;
    hbl_s2 <= hbl_s1;
  end
  wire hbl_c = hbl_s2;
  reg vbl_s1, vbl_s2;
  always @(posedge CLK_VIDEO) begin
    vbl_s1 <= vbl;
    vbl_s2 <= vbl_s1;
  end
  wire vbl_c = vbl_s2;

  // Must HOLD on non-ce_pix cycles (ce_pix is high one cycle in four);
  // else-clear would pin the counter at 0/1 and comp_hsync_c would never
  // pulse (see the matching comment in the wrapper).
  reg [9:0] hblank_cnt_c = 10'd0;
  always @(posedge CLK_VIDEO) begin
    if (!hbl_c)
      hblank_cnt_c <= 10'd0;
    else if (ce_pix)
      hblank_cnt_c <= hblank_cnt_c + 10'd1;
  end
  reg         hbl_c_d    = 1'b0;
  wire        hbl_c_rise = hbl_c & ~hbl_c_d;
  always @(posedge CLK_VIDEO) hbl_c_d <= hbl_c;
  reg [6:0]   vblank_lines_c = 7'd0;
  always @(posedge CLK_VIDEO) begin
    if (vbl_c) begin
      if (hbl_c_rise)
        vblank_lines_c <= vblank_lines_c + 7'd1;
    end else begin
      vblank_lines_c <= 7'd0;
    end
  end
  wire comp_hsync_c = hbl_c & (hblank_cnt_c >= HSYNC_FRONT_PORCH) &
                      (hblank_cnt_c < HSYNC_FRONT_PORCH + HSYNC_WIDTH);
  wire comp_vsync_c = vbl_c & (vblank_lines_c >= VSYNC_FRONT_PORCH) &
                      (vblank_lines_c < VSYNC_FRONT_PORCH + VSYNC_LINES);

  wire signed [23:0] comp_sample;
  apple_composite #(
    .BURST_START(8),
    .BURST_LEN  (64)
  ) comp_enc (
    .clk         (CLK_VIDEO),
    .ce          (ce_pix),
    .video       (video_c),
    .hs          (comp_hsync_c),
    .vs          (comp_vsync_c),
    .hb          (hbl_c),
    .vb          (vbl_c),
    .sat         (8'd128),
    .hue         (8'd0),
    .bright      (8'd0),
    .contrast    (8'd128),
    .r           (),
    .g           (),
    .b           (),
    .ce_out      (),
    .hs_out      (),
    .vs_out      (),
    .hb_out      (),
    .vb_out      (),
    .comp_sample (comp_sample)
  );
  // ================= end wrapper block =================

  // ------------------------------------------------------------------
  // video_mixer_plus - exactly the wrapper's instance.  gamma_bus = 0
  // (gamma_en = bit19 = 0 -> gamma_corr bypasses its LUT and passes the
  // input through, matching an OSD with no gamma programmed).  Do NOT
  // use GAMMA(0) here: Verilator scopes the generate-block R_in wire
  // per-branch (LRM/Quartus treat it as module scope), so the GAMMA=0
  // pass-through elaborates to an implicit 0 net and blacks the native
  // branch in simulation only.
  // ------------------------------------------------------------------
  wire use_composite;
  reg  use_composite_r = 1'b0;
  always @(posedge clk) if (reset) use_composite_r <= 1'b0;
  assign use_composite = use_composite_r;

  // "NTSC vertical blend" knob (default Off = zero-latency bypass;
  // turned ON only in phase D).
  reg ntsc_blend_r = 1'b0;

  // Decoder saturation knob: 128 in phase B, 0 in phase C (mirrors the
  // FPGA OSD "Comp sat" at states 8 and 0).
  reg [7:0] comp_sat_v = 8'd128;

  wire [21:0] gamma_bus = 22'd0;
  wire        ce_pix_out;
  wire [7:0]  vga_r, vga_g, vga_b;
  wire        vga_vs, vga_hs, vga_de;

  video_mixer_plus #(.LINE_LENGTH(580), .GAMMA(1), .COMP_SPC(4)) vm (
    .CLK_VIDEO (CLK_VIDEO),
    .CE_PIXEL  (ce_pix_out),
    .ce_pix    (ce_pix),
    .scandoubler(1'b0),
    .hq2x      (1'b0),
    .use_composite(use_composite),
    .ce_comp   (ce_pix),
    .composite (comp_sample),
    .comp_hs   (comp_hsync_c),
    .comp_vs   (comp_vsync_c),
    .comp_hb   (hbl_c),
    .comp_vb   (vbl_c),
    .comp_burst_start(10'd8),
    .comp_burst_len  (10'd64),
    .comp_sat    (comp_sat_v),
    .comp_hue    (8'd0),
    .comp_bright (8'd0),
    .comp_contrast(8'd128),
    .comp_smear  (4'd0),
    .comp_luma_delay(4'd0),
    .comp_setup  (16'sd0),
    .comp_luma_gain(16'sd2857),
    .comp_agc    (1'b1),
    .ntsc_blend  (ntsc_blend_r),
    .gamma_bus (gamma_bus),
    .R         (native_rgb),
    .G         (native_rgb),
    .B         (native_rgb),
    .HSync     (native_hsync),
    .VSync     (native_vsync),
    .HBlank    (hbl),
    .VBlank    (vbl),
    .HDMI_FREEZE(1'b0),
    .freeze_sync(),
    .VGA_R     (vga_r),
    .VGA_G     (vga_g),
    .VGA_B     (vga_b),
    .VGA_VS    (vga_vs),
    .VGA_HS    (vga_hs),
    .VGA_DE    (vga_de)
  );

  // ------------------------------------------------------------------
  // Frame/stat collection (CLK_VIDEO domain), latched on the VBL
  // falling edge of the machine source (like tb_l2).
  // ------------------------------------------------------------------
  localparam integer FRAME_CYC = LINE_CYC * FRAME_LN; // machine cycles
  reg [17:0] fcnt = 18'd0;   // machine cycles since frame start
  always @(posedge clk) begin
    if (reset) fcnt <= 18'd0;
    else if (ce_pix) fcnt <= (fcnt == FRAME_CYC - 1) ? 18'd0 : fcnt + 18'd1;
  end

  reg [19:0] ink_acc    = 20'd0;
  reg [19:0] ink_frame  = 20'd0;
  reg [19:0] nongray_acc = 20'd0;
  reg [19:0] nongray_frame = 20'd0;
  reg [7:0]  gmin       = 8'hFF;
  reg [7:0]  gmin_frame = 8'hFF;
  reg [7:0]  gmax       = 8'h00;
  reg [7:0]  gmax_frame = 8'h00;
  // Max per-pixel colour deviation (max(r,g,b)-min(r,g,b)) per frame:
  // the "chroma strength" of the strongest pixel.  Phase D asserts it
  // halves vs phase B (see header).
  reg [7:0]  chrmax_acc = 8'd0;
  reg [7:0]  chrmax_frame = 8'd0;
  // Active-window-only stats (vga_de high).  The vertical blend only
  // defines its behavior over the active image: its filter gate is
  // blend_en && cur_active_q && line_valid_q, so blanking pixels always
  // bypass the filter (2 ce late when the knob is on).  The Phase D
  // halving assertion must compare active-window chroma, not all pixels.
  reg [19:0] act_nongray_acc = 20'd0;
  reg [19:0] act_nongray_frame = 20'd0;
  reg [7:0]  act_chrmax_acc = 8'd0;
  reg [7:0]  act_chrmax_frame = 8'd0;
  // Where did the all-pixel chrmax argmax live?  vga_de classifies the
  // observed VGA pixel exactly; hbl_c/vbl_c are the wrapper's blank
  // flags at the same instant; mline/mcyc are the machine source
  // position a few cycles AHEAD of the VGA pixel (2FF sync + enc/dec
  // pipeline), so treat them as an approximate location.
  reg        argmax_seen = 1'b0;
  reg        argmax_de = 1'b0;
  reg        argmax_hbl = 1'b0;
  reg        argmax_vbl = 1'b0;
  reg [8:0]  argmax_mline = 9'd0;
  reg [9:0]  argmax_mcyc = 10'd0;
  reg        argmax_seen_frame = 1'b0;
  reg        argmax_de_frame = 1'b0;
  reg        argmax_hbl_frame = 1'b0;
  reg        argmax_vbl_frame = 1'b0;
  reg [8:0]  argmax_mline_frame = 9'd0;
  reg [9:0]  argmax_mcyc_frame = 10'd0;
  reg [19:0] ce_count   = 20'd0;
  reg [19:0] ce_frame   = 20'd0;
  reg [19:0] hs_edges   = 20'd0;
  reg [19:0] vs_edges   = 20'd0;

  reg vga_r_d = 1'b0, vga_hs_d = 1'b0, vga_vs_d = 1'b0;
  wire vga_hs_rise = vga_hs & ~vga_hs_d;
  wire vga_vs_rise = vga_vs & ~vga_vs_d;
  always @(posedge clk) begin
    vga_r_d  <= vga_r[7];
    vga_hs_d <= vga_hs;
    vga_vs_d <= vga_vs;
  end

  // Frame boundary: vbl falling (machine domain, registered for stats).
  reg vbl_d = 1'b0;
  always @(posedge clk) vbl_d <= vbl;
  wire vbl_fall = vbl_d & ~vbl;

  integer gi;
  integer cmax, cmin, cdiff;
  always @(posedge clk) begin
    if (reset) begin
      ink_acc <= 20'd0; ink_frame <= 20'd0;
      nongray_acc <= 20'd0; nongray_frame <= 20'd0;
      gmin <= 8'hFF; gmin_frame <= 8'hFF;
      gmax <= 8'h00; gmax_frame <= 8'h00;
      chrmax_acc <= 8'd0; chrmax_frame <= 8'd0;
      act_nongray_acc <= 20'd0; act_nongray_frame <= 20'd0;
      act_chrmax_acc <= 8'd0; act_chrmax_frame <= 8'd0;
      argmax_seen <= 1'b0; argmax_seen_frame <= 1'b0;
      argmax_de <= 1'b0; argmax_hbl <= 1'b0; argmax_vbl <= 1'b0;
      argmax_mline <= 9'd0; argmax_mcyc <= 10'd0;
      argmax_de_frame <= 1'b0; argmax_hbl_frame <= 1'b0;
      argmax_vbl_frame <= 1'b0; argmax_mline_frame <= 9'd0;
      argmax_mcyc_frame <= 10'd0;
      ce_count <= 20'd0; ce_frame <= 20'd0;
      hs_edges <= 20'd0; vs_edges <= 20'd0;
    end else begin
      if (ce_pix_out) begin
        ce_count <= ce_count + 20'd1;
        // stats from the VGA output (the decoded/composited pixel)
        ink_acc   <= ink_acc + (vga_r[7] ? 20'd1 : 20'd0);
        nongray_acc <= nongray_acc +
          ((vga_r != vga_g || vga_g != vga_b) ? 20'd1 : 20'd0);
        if (vga_r[7:0] < gmin) gmin <= vga_r;
        if (vga_r[7:0] > gmax) gmax <= vga_r;
        cmax = vga_r;
        if (vga_g > cmax) cmax = vga_g;
        if (vga_b > cmax) cmax = vga_b;
        cmin = vga_r;
        if (vga_g < cmin) cmin = vga_g;
        if (vga_b < cmin) cmin = vga_b;
        cdiff = cmax - cmin;
        if (cdiff > chrmax_acc) begin
          chrmax_acc <= cdiff;
          // Argmax classification of the max-deviation pixel (diagnostic).
          argmax_seen <= 1'b1;
          argmax_de   <= vga_de;
          argmax_hbl  <= hbl_c;
          argmax_vbl  <= vbl_c;
          argmax_mline<= mline;
          argmax_mcyc <= mcyc;
        end
        if (vga_de) begin
          act_nongray_acc <= act_nongray_acc +
            ((vga_r != vga_g || vga_g != vga_b) ? 20'd1 : 20'd0);
          if (cdiff > act_chrmax_acc) act_chrmax_acc <= cdiff;
        end
      end
      if (vga_hs_rise) hs_edges <= hs_edges + 20'd1;
      if (vga_vs_rise) vs_edges <= vs_edges + 20'd1;
      if (vbl_fall) begin
        ink_frame     <= ink_acc;
        nongray_frame <= nongray_acc;
        gmin_frame    <= gmin;
        gmax_frame    <= gmax;
        chrmax_frame  <= chrmax_acc;
        ce_frame      <= ce_count;
        ink_acc   <= 20'd0;
        nongray_acc <= 20'd0;
        gmin <= 8'hFF;
        gmax <= 8'h00;
        chrmax_acc <= 8'd0;
        ce_count <= 20'd0;
        act_nongray_frame <= act_nongray_acc;
        act_chrmax_frame  <= act_chrmax_acc;
        act_nongray_acc <= 20'd0;
        act_chrmax_acc <= 8'd0;
        argmax_seen_frame <= argmax_seen;
        argmax_de_frame   <= argmax_de;
        argmax_hbl_frame  <= argmax_hbl;
        argmax_vbl_frame  <= argmax_vbl;
        argmax_mline_frame<= argmax_mline;
        argmax_mcyc_frame <= argmax_mcyc;
        argmax_seen <= 1'b0;
      end
    end
  end

  // ------------------------------------------------------------------
  // Test sequence.
  // ------------------------------------------------------------------
  reg [31:0] total = 32'd0;
  localparam integer FRAME_X4   = FRAME_CYC * 4;   // clk cycles per frame
  localparam integer A_END_CLK  = 2  * FRAME_X4;   // end of native phase
  localparam integer B_END_CLK  = 6  * FRAME_X4;   // end of composite watch
  localparam integer C_END_CLK  = 8  * FRAME_X4;   // end of the sat=0 watch
  localparam integer D_END_CLK  = 12 * FRAME_X4;   // end of the blend watch
  localparam integer FIN_CLK    = 13 * FRAME_X4;   // finish
  always @(posedge clk) total <= total + 32'd1;

  reg phase_b = 1'b0;
  integer errcnt = 0;
  reg nat_checked = 1'b0;
  reg nat_hs_seen = 1'b0, nat_vs_seen = 1'b0;
  reg nat_ink_seen = 1'b0;
  reg native_hsync_d = 1'b0;
  integer native_hsync_width = 0;
  always @(posedge clk) begin
    if (ce_pix) begin
      native_hsync_d <= native_hsync;
      if (native_hsync)
        native_hsync_width <= native_hsync_width + 1;
      if (native_hsync_d && !native_hsync) begin
        if (native_hsync_width != HSYNC_WIDTH) begin
          errcnt = errcnt + 1;
          $display("  ERR: native HSync width=%0d expected=%0d",
                   native_hsync_width, HSYNC_WIDTH);
        end
        native_hsync_width <= 0;
      end
    end
  end

  // Native phase: watch 2 full frames of the machine source.
  always @(posedge clk) begin
    if (!reset && !phase_b && !nat_checked && fcnt == 18'd0 && total > 32'd100) begin
      if (total > A_END_CLK) begin
        nat_checked <= 1'b1;
        phase_b     <= 1'b1;
        use_composite_r <= 1'b1;
        $display("MIXPLUS PHASE A (native): hs=%0d vs=%0d ink=%0d",
                 hs_edges, vs_edges, ink_frame);
        if (hs_edges < 20'd200) begin errcnt = errcnt + 1; $display("  ERR: native HSync edges too few"); end
        if (vs_edges < 2'd1)  begin errcnt = errcnt + 1; $display("  ERR: native VSync missing"); end
        if (ink_frame == 20'd0) begin errcnt = errcnt + 1; $display("  ERR: native ink == 0"); end
      end
    end
  end

  // Composite phase: after 4 frames of decode, check the latched frame.
  reg comp_checked = 1'b0;
  always @(posedge clk) begin
    if (phase_b && !comp_checked && fcnt == 18'd0 && total > 32'd100) begin
      if (total > B_END_CLK) begin
        comp_checked <= 1'b1;
        chrmax_b     <= chrmax_frame;
        chrmax_b_act <= act_chrmax_frame;
        $display("MIXPLUS PHASE B (composite): ink=%0d nongray=%0d gmin=%0d gmax=%0d ce=%0d hs=%0d vs=%0d chrmax=%0d actng=%0d actchmax=%0d",
                 ink_frame, nongray_frame, gmin_frame, gmax_frame,
                 ce_frame, hs_edges, vs_edges, chrmax_frame,
                 act_nongray_frame, act_chrmax_frame);
        if (argmax_seen_frame)
          $display("  B chrmax argmax: de=%b hbl_c=%b vbl_c=%b mline~%0d mcyc~%0d",
                   argmax_de_frame, argmax_hbl_frame, argmax_vbl_frame,
                   argmax_mline_frame, argmax_mcyc_frame);
        else
          $display("  B chrmax argmax: (none)");
        if (ink_frame == 20'd0)     begin errcnt = errcnt + 1; $display("  ERR: composite ink == 0"); end
        if (nongray_frame == 20'd0) begin errcnt = errcnt + 1; $display("  ERR: composite nongray == 0 at sat=128 (no artifact color - B&W)"); end
        if (gmax_frame < 8'd160)    begin errcnt = errcnt + 1; $display("  ERR: composite gmax < 160 (no white)"); end
        if (gmin_frame > 8'd64)     begin errcnt = errcnt + 1; $display("  ERR: composite gmin > 64 (no black)"); end
        if (ce_frame == 20'd0)      begin errcnt = errcnt + 1; $display("  ERR: composite CE_PIXEL == 0"); end
        if (hs_edges < 20'd400)     begin errcnt = errcnt + 1; $display("  ERR: composite HSync edges too few"); end
        if (vs_edges < 2'd2)        begin errcnt = errcnt + 1; $display("  ERR: composite VSync missing"); end
      end
    end
  end

  // Phase C: sat=0 must decode to pure gray (ink present, no chroma).
  reg c_started = 1'b0;
  always @(posedge clk) begin
    if (phase_b && !c_started && !comp_checked && fcnt == 18'd0 && total > 32'd100) begin
      if (total > B_END_CLK) begin
        c_started   <= 1'b1;
        comp_sat_v  <= 8'd0;
        $display("MIXPLUS PHASE C start (sat=0)");
      end
    end
  end

  // Phase B chroma strength, saved for the phase D halving assertion.
  reg [7:0] chrmax_b = 8'd0;
  reg [7:0] chrmax_b_act = 8'd0;

  reg c_checked = 1'b0;
  reg d_started = 1'b0;
  reg [19:0] hs_d_start = 20'd0;
  reg [19:0] vs_d_start = 20'd0;
  always @(posedge clk) begin
    if (c_started && !c_checked && fcnt == 18'd0 && total > 32'd100) begin
      if (total > C_END_CLK) begin
        c_checked <= 1'b1;
        $display("MIXPLUS PHASE C (sat=0): ink=%0d nongray=%0d gmin=%0d gmax=%0d chrmax=%0d",
                 ink_frame, nongray_frame, gmin_frame, gmax_frame,
                 chrmax_frame);
        if (ink_frame == 20'd0)      begin errcnt = errcnt + 1; $display("  ERR: sat=0 ink == 0"); end
        if (nongray_frame != 20'd0)  begin errcnt = errcnt + 1; $display("  ERR: sat=0 nongray != 0 (chroma with sat off)"); end
        if (chrmax_frame != 8'd0)    begin errcnt = errcnt + 1; $display("  ERR: sat=0 chrmax != 0 (coloured pixels with sat off)"); end
        // Phase D start: back to sat=128, blend ON.  4 frames to watch.
        d_started      <= 1'b1;
        comp_sat_v     <= 8'd128;
        ntsc_blend_r   <= 1'b1;
        hs_d_start     <= hs_edges;
        vs_d_start     <= vs_edges;
        $display("MIXPLUS PHASE D start (composite, sat=128, blend ON)");
      end
    end
  end

  reg d_checked = 1'b0;
  always @(posedge clk) begin
    if (d_started && !d_checked && fcnt == 18'd0 && total > 32'd100) begin
      if (total > D_END_CLK) begin
        d_checked <= 1'b1;
        $display("MIXPLUS PHASE D (composite+blend): ink=%0d nongray=%0d gmin=%0d gmax=%0d chrmax=%0d (phase B chrmax=%0d) actng=%0d actchmax=%0d (phase B actchmax=%0d) hs_delta=%0d vs_delta=%0d",
                 ink_frame, nongray_frame, gmin_frame, gmax_frame,
                 chrmax_frame, chrmax_b,
                 act_nongray_frame, act_chrmax_frame, chrmax_b_act,
                 hs_edges - hs_d_start, vs_edges - vs_d_start);
        if (argmax_seen_frame)
          $display("  D chrmax argmax: de=%b hbl_c=%b vbl_c=%b mline~%0d mcyc~%0d",
                   argmax_de_frame, argmax_hbl_frame, argmax_vbl_frame,
                   argmax_mline_frame, argmax_mcyc_frame);
        else
          $display("  D chrmax argmax: (none)");
        if (ink_frame == 20'd0)     begin errcnt = errcnt + 1; $display("  ERR: blend ink == 0"); end
        if (nongray_frame == 20'd0) begin errcnt = errcnt + 1; $display("  ERR: blend nongray == 0 (screen went gray)" ); end
        if (gmax_frame < 8'd160)    begin errcnt = errcnt + 1; $display("  ERR: blend gmax < 160 (white lost - luma not preserved)"); end
        if (gmin_frame > 8'd64)     begin errcnt = errcnt + 1; $display("  ERR: blend gmin > 64 (black lost)"); end
        // The key property (active window - see header): the strongest
        // active pixel's colour deviation is halved by the 2-line comb.
        // All-pixel chrmax is excluded: its argmax is a de=0 blanking
        // transient the blend does not process by design (same in B).
        if (act_chrmax_frame >= chrmax_b_act)
          begin errcnt = errcnt + 1;
                 $display("  ERR: blend actchrmax %0d not below phase B %0d (no halving)" ,
                          act_chrmax_frame, chrmax_b_act); end
        if (hs_edges < hs_d_start + 20'd400)
          begin errcnt = errcnt + 1; $display("  ERR: blend HSync edges too few"); end
        if (vs_edges < vs_d_start + 20'd4)
          begin errcnt = errcnt + 1; $display("  ERR: blend VSync missing"); end
      end
    end
  end

  always @(posedge clk) begin
    if (d_checked && fcnt == 18'd0 && total > FIN_CLK) begin
      if (errcnt == 0)
        $display("MIXPLUS PASS (errors=0)");
      else
        $display("MIXPLUS FAIL (errors=%0d)", errcnt);
      $finish;
    end
  end

endmodule
