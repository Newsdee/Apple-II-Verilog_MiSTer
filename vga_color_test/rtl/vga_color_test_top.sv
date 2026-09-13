//-----------------------------------------------------------------------------
// Standalone VGA color tester top.
//
// Pass-through around vga_controller plus the composite decode branch
// (apple_composite + composite_decoder) on the same raw feed, so the tester
// can iterate on the composite image without the full machine. The C++ side
// drives the exact DUT ports and selects which output set to capture; frame
// capture and DUT priming live in C++ (src/main.cpp). The only logic added
// here is the composite sync derivation (mirrors the FPGA wrapper).
//
// The sibling vga_controller.v is an intentional snapshot of
// ../rtl/vga_controller.v. Compare them explicitly after any change to
// either copy:
//
//   git diff --no-index rtl/vga_controller.v ../rtl/vga_controller.v
//-----------------------------------------------------------------------------

module vga_color_test_top (
    input             CLK_14M,
    input             VIDEO,
    input             VGA_VIDEO,
    input             COLOR_LINE,
    input      [1:0]  SCREEN_MODE,
    input      [1:0]  COLOR_PALETTE,
    input             GRAY_SEAM_FIX,
    input             SEAM_RUN_FILL,
    input             SEAM_RUN_WIDE,
    input             RUN_FILL_OK,
    input             NTSC_VERTICAL_COMB,
    input             HBL,
    input             VBL,
    output            VGA_HS,
    output            VGA_VS,
    output            VGA_HBL,
    output            VGA_VBL,
    output     [7:0]  VGA_R,
    output     [7:0]  VGA_G,
    output     [7:0]  VGA_B,
    input      [24:0] ioctl_addr,
    input      [7:0]  ioctl_data,
    input      [7:0]  ioctl_index,
    input             ioctl_download,
    input             ioctl_wr,
    output            ioctl_wait,

    // ---- Composite decode branch (apple_composite + composite_decoder) ----
    // Runs in parallel with the VGA controller on the same raw VIDEO/HBL/VBL
    // feed; the C++ harness selects which output set to capture (the GUI
    // "Composite" box, on by default).  The VGA controller path is untouched.
    // Knob inputs map 1:1 to the composite_decoder adjust ports.
    input      [7:0]  COMPOSITE_SAT,        // 128 = unity
    input      [7:0]  COMPOSITE_HUE,        // 256 = one full cycle
    input      [7:0]  COMPOSITE_BRIGHT,     // signed luma offset, 0 = none
    input      [7:0]  COMPOSITE_CONTRAST,   // mid-gray-centred gain, 128 = unity
    input      [1:0]  COMPOSITE_PIXEL_DELAY,// source delay in composite samples
    input      [3:0]  COMPOSITE_SMEAR,      // chroma trail length, 0 = off
    input      [3:0]  COMPOSITE_LUMA_DELAY, // luma delay, samples
    input             COMPOSITE_I_MIRROR,   // 1 = I-mirror chirality fix; 0 = normal (upstream)
    input             COMPOSITE_CHROMA_SHORT,
    input             COMPOSITE_AGC_EN,     // track level off the burst
    input             COMPOSITE_COLOR_LINE, // 1 = color on; 0 = color kill (suppress burst)
    input             COMPOSITE_COMB_EN,    // two-line comb average before the notch
    input      [3:0]  COMPOSITE_LUMA_SHARPEN, // horizontal luma unsharp (0=off); color lines only
    output     [7:0]  COMP_R,
    output     [7:0]  COMP_G,
    output     [7:0]  COMP_B,
    output            COMP_HB,             // decoder-delayed blanking;
    output            COMP_VB              // capture window (560 samples wide)
);

// ---------------------------------------------------------------------------
// Sync derivation for the composite encoder - same structure and windows as
// the FPGA wrapper (unit_tests/level_2/mister/Apple-II.sv): the hs pulse
// sits in the middle of HBL (hblank 130..197) so the generated color burst
// (hcnt 8..72 after the hs fall) and the decoder's black clamp (hcnt 72..88)
// both land inside the back porch, and vs pulses 3 lines into the VBL block.
// The raw VIDEO stream carries no sync of its own (see apple_composite.sv).
// ---------------------------------------------------------------------------
// Vector-width so the counter comparisons stay width-clean (the FPGA
// wrapper uses integers in a 32-bit-clean context; here the counters are
// 10/7-bit).
localparam [9:0] HSYNC_FRONT_PORCH = 130;
localparam [9:0] HSYNC_WIDTH       = 68;
localparam [6:0] VSYNC_FRONT_PORCH = 33;
localparam [6:0] VSYNC_LINES       = 3;

reg [9:0] hblank_cnt = 10'd0;
always @(posedge CLK_14M)
    if (!HBL) hblank_cnt <= 10'd0;
    else      hblank_cnt <= hblank_cnt + 10'd1;

reg         hbl_d    = 1'b0;
wire        hbl_rise = HBL & ~hbl_d;
always @(posedge CLK_14M) hbl_d <= HBL;

reg [6:0] vblank_lines = 7'd0;
always @(posedge CLK_14M)
    if (VBL)
        if (hbl_rise) vblank_lines <= vblank_lines + 7'd1;
    else
        vblank_lines <= 7'd0;

wire comp_hsync = HBL & (hblank_cnt >= HSYNC_FRONT_PORCH) &
                  (hblank_cnt < HSYNC_FRONT_PORCH + HSYNC_WIDTH);
wire comp_vsync = VBL & (vblank_lines >= VSYNC_FRONT_PORCH) &
                  (vblank_lines < VSYNC_FRONT_PORCH + VSYNC_LINES);

apple_composite #(
    .BURST_START(8),
    .BURST_LEN  (64)
) u_comp (
    .clk            (CLK_14M),
    .ce             (1'b1),
    .video          (VIDEO),
    .pixel_delay    (COMPOSITE_PIXEL_DELAY),
    .hs             (comp_hsync),
    .vs             (comp_vsync),
    .hb             (HBL),
    .vb             (VBL),
    .color_line     (COMPOSITE_COLOR_LINE),
    .sat            (COMPOSITE_SAT),
    .hue            (COMPOSITE_HUE),
    .bright         (COMPOSITE_BRIGHT),
    .contrast       (COMPOSITE_CONTRAST),
    .i_mirror       (COMPOSITE_I_MIRROR),
    .chroma_short   (COMPOSITE_CHROMA_SHORT),
    .smear          (COMPOSITE_SMEAR),
    .luma_delay     (COMPOSITE_LUMA_DELAY),
    .agc_en         (COMPOSITE_AGC_EN),
    .comb_en        (COMPOSITE_COMB_EN),
    .luma_sharpen   (COMPOSITE_LUMA_SHARPEN),
    .r              (COMP_R),
    .g              (COMP_G),
    .b              (COMP_B),
    .ce_out         (),
    .hs_out         (),
    .vs_out         (),
    .hb_out         (COMP_HB),
    .vb_out         (COMP_VB),
    .comp_sample    ()
);

vga_controller dut (
    .CLK_14M            (CLK_14M),
    .VIDEO              (VGA_VIDEO),
    .COLOR_LINE         (COLOR_LINE),
    .SCREEN_MODE        (SCREEN_MODE),
    .COLOR_PALETTE      (COLOR_PALETTE),
    .GRAY_SEAM_FIX      (GRAY_SEAM_FIX),
    .SEAM_RUN_FILL      (SEAM_RUN_FILL),
    .SEAM_RUN_WIDE      (SEAM_RUN_WIDE),
    .RUN_FILL_OK        (RUN_FILL_OK),
    .NTSC_VERTICAL_COMB (NTSC_VERTICAL_COMB),
    .HBL                (HBL),
    .VBL                (VBL),
    .VGA_HS             (VGA_HS),
    .VGA_VS             (VGA_VS),
    .VGA_HBL            (VGA_HBL),
    .VGA_VBL            (VGA_VBL),
    .VGA_R              (VGA_R),
    .VGA_G              (VGA_G),
    .VGA_B              (VGA_B),
    .ioctl_addr         (ioctl_addr),
    .ioctl_data         (ioctl_data),
    .ioctl_index        (ioctl_index),
    .ioctl_download     (ioctl_download),
    .ioctl_wr           (ioctl_wr),
    .ioctl_wait         (ioctl_wait)
);

endmodule
