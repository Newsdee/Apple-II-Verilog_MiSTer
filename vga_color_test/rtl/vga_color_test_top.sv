//-----------------------------------------------------------------------------
// Standalone VGA color tester top.
//
// Thin 1:1 pass-through around vga_controller so the tester's Verilator top
// is its own module. The C++ side drives the exact DUT ports; frame capture
// and DUT priming live in C++ (src/main.cpp). Keep this file free of logic
// so the DUT port list stays the single source of truth.
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
    output            ioctl_wait
);

vga_controller dut (
    .CLK_14M            (CLK_14M),
    .VIDEO              (VIDEO),
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
