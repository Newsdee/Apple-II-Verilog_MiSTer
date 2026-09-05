// ============================================================================
// unit_tests/level_1/tb_l1_gui.sv
//
// Level-1 (config 1) *GUI* testbench: the same DUT as tb_l1.sv - the
// UNMODIFIED machine core (rtl/apple2.v, both CPU cores muxed on `cpu`)
// plus the real PS/2 keyboard (rtl/keyboard.v), monochrome native video
// only - but with NO test sequence and NO $finish: this process is the
// driver (gui/main_gui.cpp).
//
// What the machine does here: it COLD-BOOTS at t=0 (the power-on chain
// below mirrors rtl/apple2_top.v, including the 2^22-cycle power-on
// hold), and the BIOS ROM should draw the striped Apple logo on the text
// screen.  The "Cold reboot" button in the GUI pulses `reset_cold` -
// the same input the host's "Cold Reset" uses - so the whole cold
// power-on sequence (POR hold + ROM boot + logo) can be re-run.
//
// Video capture
//   The native VIDEO signal is sampled once per master cycle (negedge,
//   14.318 MHz domain) - correct for TEXT-mode content, which is what
//   the boot displays.  Hires content (7.159 MHz pixel rate) would be
//   half-sampled; out of scope for the boot-logo GUI.
//   Frame anchor: the VBL FALLING edge (retrace end, first active line
//   of the new frame).  frame_lines (the V-period in lines) is measured
//   free-running and shown live - no pinning needed.
//
// C++ <-> TB interface (module-scope regs, exposed by -public)
//   in : stall        pause: holds the CPU on the next master edge; the
//                      video keeps scanning (as on the machine)
//   in : reset_cold   one posedge with this high re-arms the power-on
//                      chain (cold reboot); the GUI clears it
//   out: frame_valid  a complete frame is in frame[0..frame_lines-1];
//                      C++ copies it, then clears this flag
//   out: frame[512]   1024-bit lines; the first 560 bits are rendered
//   out: frame_lines  measured V-period in lines for the last frame
//   out: frame_count  completed frames since the first VBL fall
//   out: last_len/last_act, vbl_lines, text_mode_s  geometry readouts
//
// Headless smoke (no window):  Vtb_l1_gui.exe +cpu=0 --headless [N]
// runs the machine until N video frames completed (default 3) and
// checks the last captured frame is not blank (ink > 0 = the ROM drew
// the logo / cursor).  Prints L1_GUI SMOKE PASS/FAIL.
//
// The binary MUST run with the process CWD at the REPO ROOT: the DUT's
// $readmemh ROM paths (rtl/roms/*.hex) are CWD-relative.
// ============================================================================

module tb_l1_gui;

  // ------------------------------------------------------------------
  // CPU selection: the DUT instantiates BOTH cores and muxes on `cpu`.
  // +cpu=0 -> nmos6502, +cpu=1 -> wdc65c02.
  // ------------------------------------------------------------------
  reg         cpu_sel  = 1'b0;
  string      cpu_name = "nmos";
  initial begin
    integer plus_cpu;
    if ($value$plusargs("cpu=%d", plus_cpu)) begin
      cpu_sel = (plus_cpu != 0);
      if (plus_cpu == 0)
        cpu_name = "nmos";
      else
        cpu_name = "wdc";
    end
    $display("L1_GUI CPU=%0d %s", cpu_sel, cpu_name);
  end

  // ------------------------------------------------------------------
  // 14.3 MHz master clock (35 ns period).  Verilator has no timing
  // checks; only edge counts matter.
  // ------------------------------------------------------------------
  reg clk_14m = 1'b0;
  always #35_000 clk_14m = ~clk_14m;

  // ------------------------------------------------------------------
  // DUT wires
  // ------------------------------------------------------------------
  wire [15:0] w_addr;
  wire [17:0] w_ram_addr;
  wire [7:0]  w_ram_di;
  wire [15:0] ram_do;
  wire        w_ram_aux;
  wire        w_ram_we;
  wire        w_cpu_we;
  wire        w_video;
  wire        w_col_line;
  wire        w_text_mode;
  wire        w_hbl;
  wire        w_vbl;
  wire        read_key;
  wire [7:0]  kb_K;
  wire        kb_akd;
  wire        soft_reset;
  wire [3:0]  w_an;
  wire        w_pdl;
  wire        w_stb;
  wire [7:0]  w_io_sel;
  wire [7:0]  w_dev_sel;
  wire        w_io_str;
  wire        w_spk;
  wire [63:0] w_dbg_regs;
  wire [7:0]  w_dbg_di;
  wire [13:0] w_dbg_roma;
  wire [7:0]  w_dbg_romo;
  wire        w_clk_2m;
  wire        w_pz;
  wire        w_pzr;
  wire        w_pzf;

  // TB-controlled DUT inputs
  reg  [22:0] flash_div  = 23'b0;
  wire        flash_clk  = flash_div[22];
  reg         romsw      = 1'b0;
  reg         stall      = 1'b0;   // GUI pause (C++ writes)
  reg         reset_cold = 1'b0;   // GUI "cold reboot" (C++ pulses)
  reg         reset_warm = 1'b0;   // host warm-reset button (left 0)

  // ------------------------------------------------------------------
  // 60Hz IRQ - real Apple II hardware pulses the CPU IRQ line once per
  // frame (derived from VBL sync); the II ROM's 60Hz interrupt handler
  // uses it to maintain the OS 1-second counter ($30-$31) and 60Hz
  // flags that the power-up/boot path waits on.  The pulse must be
  // short (a few cycles): if IRQ_n stayed low past the handler's RTI
  // the 6502 would take the interrupt back-to-back forever.  We pulse
  // it 16 master cycles on the w_vbl rising edge (~14.3 MHz domain).
  // ------------------------------------------------------------------
  reg     [4:0] irq_60hz_cnt = 5'd0;
  reg         vbl_d          = 1'b0;
  wire        irq_60hz_pulse = (irq_60hz_cnt != 5'd0);
  always @(posedge clk_14m) begin
    vbl_d <= w_vbl;
    if (w_vbl && !vbl_d)          // true rising edge only - w_vbl stays high
      irq_60hz_cnt <= 5'd16;      // for the whole blank, so a level check
    else if (irq_60hz_cnt != 5'd0)// would re-arm the pulse every cycle
      irq_60hz_cnt <= irq_60hz_cnt - 5'd1;
  end

  // ------------------------------------------------------------------
  // apple2: the machine core
  // ------------------------------------------------------------------
  apple2 d1 (
    .CLK_14M     (clk_14m),
    .CLK_2M      (w_clk_2m),
    .PALMODE     (1'b0),
    .ROMSWITCH   (romsw),
    .CPU_WAIT    (1'b0),
    .PHASE_ZERO  (w_pz),
    .PHASE_ZERO_R(w_pzr),
    .PHASE_ZERO_F(w_pzf),
    .FLASH_CLK   (flash_clk),
    .reset       (reset_sync),
    .cpu         (cpu_sel),
    .STALL       (stall),
    .ADDR        (w_addr),
    .ram_addr    (w_ram_addr),
    .D           (w_ram_di),
    .ram_do      (ram_do),
    .aux         (w_ram_aux),
    .PD          (8'h00),
    .CPU_WE      (w_cpu_we),
    .IRQ_n       (~irq_60hz_pulse),
    .NMI_n       (1'b1),
    .ram_we      (w_ram_we),
    .VIDEO       (w_video),
    .COLOR_LINE  (w_col_line),
    .TEXT_MODE   (w_text_mode),
    .HBL         (w_hbl),
    .VBL         (w_vbl),
    .K           (kb_K),
    .READ_KEY    (read_key),
    .AKD         (kb_akd),
    .AN          (w_an),
    .GAMEPORT    (8'h00),
    .PDL_STROBE  (w_pdl),
    .STB         (w_stb),
    .IO_SELECT   (w_io_sel),
    .DEVICE_SELECT(w_dev_sel),
    .IO_STROBE   (w_io_str),
    .ioctl_addr  (25'b0),
    .ioctl_data  (8'b0),
    .ioctl_index (8'b0),
    .ioctl_download(1'b0),
    .ioctl_wr    (1'b0),
    .saturn_5_inslot(1'b0),
    .speaker     (w_spk),
    .DBG_T65_REGS(w_dbg_regs),
    .DBG_DI      (w_dbg_di),
    .DBG_ROM_ADDR(w_dbg_roma),
    .DBG_ROM_OUT (w_dbg_romo)
  );

  // ------------------------------------------------------------------
  // keyboard: real PS/2 interface (virtual-keyboard + joystick ports
  // tied off; no JOY_TO_KEY in this build).  ps2_key is driven from
  // C++ (gui/main_gui.cpp, like stall): the Apple //e scan-code
  // protocol {stb[10], pressed[9], ext[8], code[7:0]} - each queued
  // event is held 60 master cycles (press has bit 9 set, release
  // cleared), then dropped to 0 (keyboard.v latches on the stb edge).
  // ------------------------------------------------------------------
  reg  [10:0] ps2_key = 11'b0;   // {stb, ext, code[7:0]}, C++-driven
  wire        kb_ooa, kb_coa, kb_vt, kb_pt;

  keyboard kb (
    .CLK_14M           (clk_14m),
    .PS2_Key           (ps2_key),
    .virtual_active    (1'b0),
    .virtual_event     (1'b0),
    .virtual_pressed   (1'b0),
    .virtual_code      (7'b0),
    .virtual_control   (1'b0),
    .virtual_open_apple(1'b0),
    .virtual_closed_apple(1'b0),
    .reads             (read_key),
    .reset             (reset_cold),
    .akd               (kb_akd),
    .K                 (kb_K),
    .open_apple        (kb_ooa),
    .closed_apple      (kb_coa),
    .soft_reset        (soft_reset),
    .video_toggle      (kb_vt),
    .palette_toggle    (kb_pt)
  );

  // ------------------------------------------------------------------
  // TEMPORARY A/B (2026-09-05, +define+L1_VGA builds only): route the
  // machine's native video through the REAL vga_controller - the same
  // module and wiring as rtl/apple2_top.v:445-471 (controls tied to
  // stock defaults) - so the GUI can be checked against the
  // whole-machine image path (verilator/sim.v + sim_video.cpp).
  // The C++ harness samples VGA_R/G/B + HBL/VBL/VS exactly like
  // SimVideo::Clock (one sample per vga pixel strobe = every 2nd
  // master cycle).
  // ------------------------------------------------------------------
`ifdef L1_VGA
  wire [7:0] vga_r, vga_g, vga_b;
  wire       vga_hs, vga_vs, vga_hb, vga_vb, vga_ioctl_wait;
  vga_controller vga (
    .CLK_14M            (clk_14m),
    .VIDEO              (w_video),
    .COLOR_LINE         (w_col_line),
    .SCREEN_MODE        (2'b00),
    .COLOR_PALETTE      (2'b00),
    .GRAY_SEAM_FIX      (1'b0),
    .SEAM_RUN_FILL      (1'b0),
    .SEAM_RUN_WIDE      (1'b0),
    .RUN_FILL_OK        (1'b0),
    .NTSC_VERTICAL_COMB (1'b0),
    .HBL                (w_hbl),
    .VBL                (w_vbl),
    .VGA_HS             (vga_hs),
    .VGA_VS             (vga_vs),
    .VGA_HBL            (vga_hb),
    .VGA_VBL            (vga_vb),
    .VGA_R              (vga_r),
    .VGA_G              (vga_g),
    .VGA_B              (vga_b),
    .ioctl_addr         (25'b0),
    .ioctl_data         (8'b0),
    .ioctl_index        (8'b0),
    .ioctl_download     (1'b0),
    .ioctl_wr           (1'b0),
    .ioctl_wait         (vga_ioctl_wait)
  );
  // Note: the simulator aliases/prunes top-level wires that only C++
  // reads (its C++ fields then stay stale), so capture the vga outputs
  // into TB-level REGISTERS instead - the C++ harness samples those,
  // exactly like the other dbg_* readouts.  Sampling at the master
  // posedge captures the value the output registers held during the
  // preceding master cycle (they are stable between edges).
  reg [7:0] dbg_vga_r, dbg_vga_g, dbg_vga_b;
  reg       dbg_vga_hs, dbg_vga_vs, dbg_vga_hb, dbg_vga_vb;
  always @(posedge clk_14m) begin
    dbg_vga_r <= vga_r;
    dbg_vga_g <= vga_g;
    dbg_vga_b <= vga_b;
    dbg_vga_hs <= vga_hs;
    dbg_vga_vs <= vga_vs;
    dbg_vga_hb <= vga_hb;
    dbg_vga_vb <= vga_vb;
  end
`endif

  // ------------------------------------------------------------------
  // Reset chain - mirrors apple2_top.v:315-330 exactly.  power_on_reset
  // starts held and releases only after flash_div reaches 2^22 (~147 ms
  // of machine time); a reset_cold pulse re-arms the whole sequence.
  // ------------------------------------------------------------------
  reg power_on_reset = 1'b1;   // power-on: start held
  reg reset_sync;
  always @(posedge clk_14m) begin: reset_chain
    reset_sync <= reset_warm | power_on_reset;
    if (reset_cold == 1'b1 || soft_reset == 1'b1) begin
      power_on_reset <= 1'b1;
      flash_div      <= 23'b0;
    end else begin
      if (flash_div[22] == 1'b1)
        power_on_reset <= 1'b0;
      flash_div <= flash_div + 1'b1;
    end
  end

  // ------------------------------------------------------------------
  // Cold-reset RAM force - mirrors apple2_top.v:385-387: while
  // reset_cold the RAM interface is held at (we=1, addr=$3F4, data=0).
  // This is what clears the ROM's cold-boot flag so the Apple logo is
  // drawn on cold boot.
  // ------------------------------------------------------------------
  wire        ram_we_eff   = reset_cold ? 1'b1   : w_ram_we;
  wire [17:0] ram_addr_eff = reset_cold ? 18'h03F4 : w_ram_addr;
  wire [7:0]  ram_di_eff   = reset_cold ? 8'b0    : w_ram_di;

  // ------------------------------------------------------------------
  // TB RAM - the verilator/sim.v pattern: 1-ce latch, main + aux
  // ------------------------------------------------------------------
  reg [7:0] ram0 [0:65535];
  reg [7:0] ram1 [0:65535];
  always @(posedge clk_14m) begin: tb_ram
    if (ram_we_eff & ~w_ram_aux) begin
      ram0[ram_addr_eff[15:0]] <= ram_di_eff;
      ram_do[7:0]              <= ram_di_eff;
    end else begin
      ram_do[7:0]              <= ram0[ram_addr_eff[15:0]];
    end
    if (ram_we_eff & w_ram_aux) begin
      ram1[ram_addr_eff[15:0]] <= ram_di_eff;
      ram_do[15:8]             <= ram_di_eff;
    end else begin
      ram_do[15:8]             <= ram1[ram_addr_eff[15:0]];
    end
  end

  // ------------------------------------------------------------------
  // Video sampler: 1 sample per master cycle (negedge), lines assembled
  // from the HBL falling edge into a rolling 512-line buffer.
  //   lines[i]  : samples 0..1023 of line i (bit 1 = white)
  //   line_len  : full line length (samples from HBL-fall to HBL-rise,
  //               incl. the last sample)
  //   line_act  : HBL-low (active) sample count
  //   vbl_lines : lines completed while VBL sampled high (line-based)
  // ------------------------------------------------------------------
  reg [1023:0] lines   [0:511];
  reg [15:0]   line_len[0:511];
  reg [15:0]   line_act[0:511];
  integer      line_cnt = 0;      // free-running: next line index
  integer      vbl_lines = 0;     // lines completed while VBL high

  reg  hbl_s = 1'b0, vbl_s = 1'b0;
  reg  hbl_p = 1'b0;
  reg  [15:0] smp = 16'd0;
  reg  [15:0] act = 16'd0;

  always @(negedge clk_14m) begin: video_sampler
    hbl_s <= w_hbl;
    vbl_s <= w_vbl;
    hbl_p <= hbl_s;
    if (hbl_p == 1'b1 && hbl_s == 1'b0) begin
      // line start (HBL falling)
      lines[line_cnt & 511] <= 1024'b0;
      smp                   <= 16'd0;
      act                   <= 16'd0;
    end else if (hbl_p == 1'b0 && hbl_s == 1'b1) begin
      // line end (HBL rising): commit, count VBL, advance
      line_len[line_cnt & 511] <= smp + 1;
      line_act[line_cnt & 511] <= act;
      if (vbl_s == 1'b1) vbl_lines <= vbl_lines + 1;
      smp          <= 16'd0;
      line_cnt     <= line_cnt + 1;
    end else if (hbl_s == 1'b0) begin
      if (smp < 1024) lines[line_cnt & 511][smp] <= w_video;
      smp <= smp + 1;
      act <= act + 1;
    end
  end

  // ------------------------------------------------------------------
  // Frame packer: anchor each frame at the VBL falling edge (retrace
  // end) and copy every committed line into frame[] while it falls
  // inside the current frame.  frame_lines is MEASURED (lines between
  // successive VBL falling edges) - no pinning.  frame_valid latches
  // for the C++ side, which copies frame[] and clears it.
  // ------------------------------------------------------------------
  reg [15:0]   frame_base = 16'd0;  // line_cnt at the last VBL fall
  reg [1023:0] frame      [0:511];  // last complete frame (C++ reads)
  reg          frame_valid = 1'b0;  // C++: a complete frame is waiting
  reg [15:0]   frame_lines = 16'd0; // measured V-period (lines/frame)
  integer      frame_count = 0;     // completed frames since first VBL fall
  reg          vbl_p = 1'b0;        // vbl_s delayed one sample tick
  reg [15:0]   last_len = 16'd0;    // last committed line length (samples)
  reg [15:0]   last_act = 16'd0;    // last committed line active count
  reg          text_mode_s = 1'b0;  // TEXT_MODE sampled (1 = text mode)

  always @(negedge clk_14m) begin: frame_pack
    vbl_p <= vbl_s;
    text_mode_s <= w_text_mode;
    if (vbl_p == 1'b1 && vbl_s == 1'b0) begin
      // VBL falling: retrace done, first active line of a new frame.
      // The frame that started at the previous VBL fall is complete.
      if (frame_count > 0) begin
        frame_valid <= 1'b1;
        frame_lines <= line_cnt - frame_base;
      end
      frame_base  <= line_cnt;
      frame_count <= frame_count + 1;
    end
    // line commit (the same HBL rising edge the sampler uses): the
    // just-finished line is at the CURRENT line_cnt index (the
    // sampler's increment is still pending this tick).
    if (hbl_p == 1'b0 && hbl_s == 1'b1) begin
      last_len <= smp + 1;
      last_act <= act;
      if (line_cnt >= frame_base && line_cnt < frame_base + 512)
        frame[line_cnt - frame_base] <= lines[line_cnt & 511];
    end
  end

  // ------------------------------------------------------------------
  // Diagnostics (headless smoke + GUI readouts):
  //   phzf_cnt    : CPU cycle count (PHASE_ZERO_F rising edges)
  //   screen_ink  : non-zero bytes in the text page (ram0 $0400-$07FF),
  //                 refreshed on every completed frame
  //   dbg_addr    : last observed ADDR bus value
  // ------------------------------------------------------------------
  reg      pzf_p2   = 1'b0;
  reg [31:0] phzf_cnt = 32'd0;
  always @(posedge clk_14m) begin: phzf_count
    pzf_p2 <= w_pzf;
    if (w_pzf == 1'b1 && pzf_p2 == 1'b0) phzf_cnt <= phzf_cnt + 32'd1;
  end

  reg [15:0] screen_ink = 16'd0;
  reg [15:0] dbg_addr   = 16'd0;
  integer    si;
  always @(negedge clk_14m) begin: diag
    dbg_addr <= w_addr;
    if (vbl_p == 1'b1 && vbl_s == 1'b0 && frame_count > 0) begin
      integer n;
      n = 0;
      for (si = 0; si < 1024; si = si + 1)
        if (ram0[16'h0400 + si] !== 8'h00) n = n + 1;
      screen_ink <= n;
    end
  end

  // How often the ADDR bus changes (cumulative): ~0 while the CPU is held
  // in reset (bus frozen), large once it executes.
  reg [15:0] dbg_addr_chg  = 16'd0;
  reg [15:0] dbg_addr_last = 16'd0;
  always @(posedge clk_14m) begin: addr_chg
    if (w_addr !== dbg_addr_last) begin
      dbg_addr_last <= w_addr;
      dbg_addr_chg  <= dbg_addr_chg + 16'd1;
    end
  end

  // Clock rate + flash divider readouts (C++ heartbeat) - settle the
  // clk_14m period and POR-release timing questions directly.
  reg [31:0] dbg_clk_cnt = 32'd0;
  always @(posedge clk_14m) dbg_clk_cnt <= dbg_clk_cnt + 32'd1;
  wire [22:0] dbg_flash_div = flash_div;

  // Keyboard diagnostics (key-forwarding debugging): count the DUT's
  // keyboard reads ($CNOP strobes), capture the K byte seen on the last
  // read, and count master cycles in which the keyboard module reports a
  // key down (akd).  If dbg_rd_cnt keeps climbing with no key pressed, the
  // machine is in a keyboard-polling loop; if it is frozen, the ROM is not
  // running one.
  reg [31:0] dbg_rd_cnt  = 32'd0;
  reg [7:0]  dbg_rd_k    = 8'd0;
  reg [7:0]  dbg_rd_k_hi = 8'd0;  // sticky: last read with K[7] (key_pressed) set
  reg [31:0] dbg_akd_cnt = 32'd0;
  always @(posedge clk_14m) begin
    if (read_key) begin
      dbg_rd_cnt <= dbg_rd_cnt + 32'd1;
      dbg_rd_k   <= kb_K;
      if (kb_K[7]) dbg_rd_k_hi <= kb_K;
    end
    if (kb_akd)
      dbg_akd_cnt <= dbg_akd_cnt + 32'd1;
  end

  // $C000-$C00F keyboard DATA reads - the port the ROM monitor actually
  // polls (LDA $C000; BPL loop).  Note: the READ_KEY port above only
  // pulses on $C010-$C01F (AKD/softswitch) accesses, so dbg_rd_cnt is NOT
  // a keyboard-polling indicator.  This probe mirrors the core's
  // KEYBOARD_SELECT decode (A[15:4]==12'hC00, !we) and latches D_IN
  // (w_dbg_di) - the byte the CPU actually reads - so it proves the full
  // chain: keyboard module -> core K mux -> CPU data bus.
  wire     dbg_k_rd      = (w_addr[15:4] == 12'hC00) && !w_cpu_we;
  reg [31:0] dbg_k_rd_cnt    = 32'd0;
  reg [7:0]  dbg_k_rd_val    = 8'd0;   // last D_IN on a $C000-$C00F read
  reg [7:0]  dbg_k_rd_caught = 8'd0;   // sticky: last $C000 read with bit7 set
  always @(posedge clk_14m) begin
    if (dbg_k_rd) begin
      dbg_k_rd_cnt <= dbg_k_rd_cnt + 32'd1;
      dbg_k_rd_val <= w_dbg_di;
      if (w_dbg_di[7]) dbg_k_rd_caught <= w_dbg_di;
    end
  end

  // Reset chain state (C++ heartbeat): both 0 = reset released.
  wire dbg_rst = reset_sync;
  wire dbg_por = power_on_reset;

endmodule
