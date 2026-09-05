// ============================================================================
// unit_tests/level_1/tb_l1.sv
//
// Level 1 (config 1): the MACHINE CORE (rtl/apple2.v, unmodified: both CPU
// cores, RAM decode, BIOS ROM, timing HAL, native video pipeline) plus the
// real PS/2 keyboard (rtl/keyboard.v, unmodified).  MONOCHROME video only -
// the DUT's native VIDEO + HBL/VBL ports are sampled directly; the color
// pipeline (vga_controller, which lives in apple2_top) is NOT pulled in.
// No slots, no drives, no host I/O.
//
// DUT composition
// ---------------
//   apple2 d1   <- the whole machine core; its `cpu` input selects
//                  nmos/wdc at runtime, so ONE build covers both cores
//                  (+cpu=0 nmos / +cpu=1 wdc).
//   keyboard kb <- the real PS/2 interface; PS2_Key is driven by this TB.
//   TB RAM      <- 64K main + 64K aux, 1-ce latch (the verilator/sim.v
//                  pattern).  The TB owns the RAM, so it can write text
//                  screens directly and read $0030 etc.  While STALL=1 the
//                  CPU is held (the OSD-pause port) so the TB's writes
//                  race nothing; the video pipeline is not CPU-clocked and
//                  keeps scanning.
//
// Machine-parity wiring (mirrors rtl/apple2_top.v)
// ------------------------------------------------
//   - reset chain (apple2_top:315-330): reset_sync <= reset_warm |
//     power_on_reset; power_on_reset is set by reset_cold OR soft_reset
//     (keyboard F2) and held until the 23-bit flash divider reaches bit 22
//     (~2^22 cycles ~= 294 ms at 14.3 MHz) - the "power-on" hold.
//   - FLASH_CLK = flash divider bit 22 (apple2_top:325-332), same period;
//     the video ROM cursor blink is driven by it.
//   - cold-reset RAM force (apple2_top:385-387): while reset_cold, the RAM
//     interface is forced to (we=1, addr=$3F4, data=0) - the cold-boot
//     flag the ROM checks.
//   - keyboard.reset = reset_cold only (apple2_top:513) so a warm reset
//     does not lose keyboard state.
//   - PD (peripheral data) tied 0, IRQ_n/NMI_n tied 1 (no slots at this
//     level), GAMEPORT/saturn/rom-ioctl tied off.
//
// Video
// -----
// The timing HAL distorts the pixel clock mode-dependently (full-rate in
// text, half rate in hi-res; see timing_generator.v VID7M), so NO
// analytical pixel model is attempted.  The TB samples VIDEO on the
// negedge of the 14 MHz clock (1 sample per master cycle), assembles lines
// from HBL edges into a rolling 512-line buffer, and runs
// geometry-INDEPENDENT content tests:
//   T1  geometry: line-length stability, HBL/VBL structure (expect 48
//       VBL-high lines over any 780-line window: 24 per 390-line NTSC
//       frame, from the V counter V_RESET=122 -> 390-line period)
//   T2  text screen: per-row repetition with period 8 (character rows)
//   T3  glyph change: 'A' vs 'B' screens differ; re-filling 'A' is
//       bit-identical (captures are cursor-phase-aligned via the flash
//       divider the TB itself drives)
//   T4  ROMSWITCH: the upper 4K video-ROM half (LOCAL font) vs lower
//       (US) must produce a different screen for the same text
//   T5  cursor blink: screens a half blink period apart differ only in
//       the cursor cell; a full blink period apart are identical
//   T6  keyboard: PS/2 scancodes -> K vs a TB-side oracle (TB copy of
//       keyboard.hex, indexed like keyboard.v:368; expected junctions
//       from the table comments keyboard.v:370-445); end-to-end the BIOS
//       must store the key in RAM $0030
//   T7  monitor experiment: F2 (this core's reset key) held through the
//       reset, released, PC traced for 4000 CPU cycles + screen captured.
//       REPORT ONLY (no assert) - the trace and screen are the data.
//
// CWD: the DUT's $readmemh paths ("rtl/roms/*.hex" in rom.v /
// video_generator.v / keyboard.v) resolve against the process CWD, so the
// binary MUST run from the repo root (the runners cd there).  Output files
// go to unit_tests/level_1/out/ (the runner creates the dir).
//
// Runs to $finish; module-scope `errors` is the status (0 = pass), read by
// main.cpp.
// ============================================================================

`timescale 1ns / 1ps

module tb_l1;

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
  reg         stall      = 1'b0;
  reg         reset_cold = 1'b0;   // host "Cold Reset" button
  reg         reset_warm = 1'b0;   // host warm-reset button (left 0)
  reg         cur_phase  = 1'b0;   // seen flash phase (T5)

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
    .IRQ_n       (1'b1),
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
  // tied off; no JOY_TO_KEY in this build)
  // ------------------------------------------------------------------
  reg  [10:0] ps2_key = 11'b0;   // {stb, ext, code[7:0]}
  wire        kb_ooa, kb_coa, kb_vt, kb_pt;

  keyboard kb (
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
  // Reset chain - mirrors apple2_top.v:315-330 exactly
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
  // File handles (Verilator: bare $fopen("file") form only; paths are
  // CWD-relative = repo root; the runner creates the out dir)
  // ------------------------------------------------------------------
  integer fd_rep  = 0;
  integer fd_boot = 0;
  integer fd_mon  = 0;

  // ------------------------------------------------------------------
  // PC trace: one entry per CPU cycle boundary (PHASE_ZERO_F pulse = the
  // PHI0 falling edge that starts a CPU cycle; the L0 ce model)
  // ------------------------------------------------------------------
  reg  pzf_p = 1'b0;
  always @(posedge clk_14m) begin
    pzf_p <= w_pzf;
    if (w_pzf == 1'b1 && pzf_p == 1'b0) begin
      if (tracing_boot && boot_pc < 4000) begin
        $fwrite(fd_boot, "%0d %h %h %b\n", boot_pc, w_addr[15:8], w_addr[7:0], w_cpu_we);
        boot_pc = boot_pc + 1;
      end
      if (tracing_mon && mon_pc < 4000) begin
        $fwrite(fd_mon, "%0d %h %h %b\n", mon_pc, w_addr[15:8], w_addr[7:0], w_cpu_we);
        mon_pc = mon_pc + 1;
      end
    end
  end

  // ------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------
  // Wait until a given number of master cycles has passed.
  task wait_cycles (input [31:0] n);
    integer i;
    begin
      for (i = 0; i < n; i = i + 1) @(posedge clk_14m);
    end
  endtask

  // Wait for the BIOS idle loop: 300 consecutive PC samples all inside
  // [$FCA0, $FFBF] (the L0 steady state: $FCA8-$FFAF body + the gated
  // $FF80-$FFAF keyboard routine).
  task wait_idle;
    integer ok;
    begin
      ok = 0;
      while (ok < 300) begin
        @(posedge clk_14m);
        if (w_pzf == 1'b1) begin
          if (w_addr[15:8] >= 8'hFC && w_addr[15:8] <= 8'hFF)
            ok = ok + 1;
          else
            ok = 0;
        end
      end
    end
  endtask

  // Cursor-phase alignment: capture only during a fixed window of the
  // flash (blink) phase so every capture sees the same cursor state.
  task wait_flash_window;
    begin
      while (flash_div[21:0] < 22'd400_000 || flash_div[21:0] > 22'd3_400_000)
        @(posedge clk_14m);
    end
  endtask

  // Advance the blink phase by exactly half a period (2^22 master
  // cycles) and settle in the window.
  task wait_half_blink;
    begin
      while (flash_div[22] == cur_phase) @(posedge clk_14m);
      wait_flash_window;
      cur_phase = ~cur_phase;
    end
  endtask

  // Capture 250 lines into cap[] starting at the next HBL falling edge,
  // phase-aligned to the cursor blink.
  reg [1023:0] cap [0:249];
  reg [15:0]   cap_len [0:249];
  reg [15:0]   cap_act [0:249];

  task do_capture;
    integer base, i;
    begin
      wait_flash_window;
      repeat (2) @(posedge clk_14m);
      while (hbl_p == 1'b0) @(posedge clk_14m);   // wait HBL high
      while (hbl_s == 1'b1) @(posedge clk_14m);   // wait HBL falling
      repeat (2) @(posedge clk_14m);              // let the sampler latch
      base = line_cnt;
      while (line_cnt < base + 250) @(posedge clk_14m);
      for (i = 0; i < 250; i = i + 1) begin
        cap[i]     = lines[(base + i) & 511];
        cap_len[i] = line_len[(base + i) & 511];
        cap_act[i] = line_act[(base + i) & 511];
      end
    end
  endtask

  // Copy the capture buffer into a saved array.
  task save_cap (output [1023:0] dst [0:249]);
    integer i;
    begin
      for (i = 0; i < 250; i = i + 1) dst[i] = cap[i];
    end
  endtask

  // Write a text screen: 40x24 page 0 ($0400-$05BF), one character.
  // The CPU is STALLed so the TB's writes race nothing; the video
  // pipeline keeps scanning (it is not CPU-clocked).
  task write_screen (input [7:0] chr);
    integer row, col;
    begin
      stall <= 1'b1;
      repeat (16) @(posedge clk_14m);
      for (row = 0; row < 24; row = row + 1)
        for (col = 0; col < 40; col = col + 1)
          ram0[16'h0400 + row*40 + col] = chr;
      stall <= 1'b0;
      wait_cycles(400_000);   // ~2.8 frames of rescan
    end
  endtask

  // PS/2 event: one stb pulse with the given code.  A second identical
  // pulse is a key-UP (keyboard.v state machine).
  task ps2_send (input [7:0] code);
    begin
      @(posedge clk_14m);
      ps2_key <= {1'b1, 1'b0, code};
      repeat (3) @(posedge clk_14m);
      ps2_key <= {1'b0, 1'b0, code};
      repeat (5) @(posedge clk_14m);
      ps2_key <= 11'b0;
      repeat (2) @(posedge clk_14m);
    end
  endtask

  // Bit diff between two 250x1024 captures (total + worst line).
  task diff_captures (input [1023:0] A [0:249], input [1023:0] B [0:249],
                      output [31:0] total, output [31:0] worst);
    integer i, cnt;
    reg [1023:0] x;
    begin
      total = 0;
      worst = 0;
      for (i = 0; i < 250; i = i + 1) begin
        x   = A[i] ^ B[i];
        cnt = $countones(x);
        if (cnt > worst) worst = cnt;
        total = total + cnt;
      end
    end
  endtask

  // Write a 250-line capture as a PBM (P1, ASCII).
  task dump_pbm (input string filename, input [1023:0] src [0:249]);
    integer f, i;
    begin
      f = $fopen(filename);
      $fwrite(f, "P1\n1024 250\n");
      for (i = 0; i < 250; i = i + 1) $fwrite(f, "%b\n", src[i]);
      $fclose(f);
    end
  endtask

  // ------------------------------------------------------------------
  // Keyboard oracle: TB copy of keyboard.hex, indexed exactly like
  // keyboard.v:368  rom_addr = {1'b0, caplock, junction[6:0], ~ctrl, ~shift}
  // ------------------------------------------------------------------
  reg [7:0] kb_rom [0:2047];
  initial $readmemh("rtl/roms/keyboard.hex", kb_rom);

  function [10:0] kb_addr (input [6:0] jc, input caps, input ctrl, input shift);
    kb_addr = {1'b0, caps, jc, ~ctrl, ~shift};
  endfunction

  // Video ROM files for the consistency report (the DUT reads its own
  // copies via rom.v/video_generator.v; these are TB-side references)
  reg [7:0] vid2 [0:8191];
  reg [7:0] vid1 [0:4095];
  initial begin
    $readmemh("rtl/roms/video2.hex", vid2);
    $readmemh("rtl/roms/video.hex",  vid1);
  end

  // ------------------------------------------------------------------
  // Status
  // ------------------------------------------------------------------
  reg [15:0] errors = 16'd0;
  reg        tracing_boot = 1'b0;
  reg        tracing_mon  = 1'b0;
  integer    boot_pc = 0;
  integer    mon_pc  = 0;

  task note (input string msg);
    begin
      $display("L1: %s", msg);
      if (fd_rep) $fwrite(fd_rep, "%s\n", msg);
    end
  endtask

  task err (input string msg);
    begin
      errors = errors + 1;
      $display("L1 ERROR: %s", msg);
      if (fd_rep) $fwrite(fd_rep, "ERROR: %s\n", msg);
    end
  endtask

  // ------------------------------------------------------------------
  // Main sequence
  // ------------------------------------------------------------------
  reg [1023:0] saved_a  [0:249];   // 'A', US half
  reg [1023:0] saved_b  [0:249];   // 'B', US half
  reg [1023:0] saved_up [0:249];   // 'A', LOCAL half
  reg [1023:0] saved_at0[0:249];   // '@', US half
  reg [1023:0] saved_at1[0:249];   // '@', LOCAL half
  reg [1023:0] saved_x  [0:249];   // blink phase X
  reg [1023:0] saved_y  [0:249];   // blink phase Y (half period later)
  reg [31:0]   d_tot, d_worst;
  reg [31:0]   d_at_halves;        // T4: 'A' US vs LOCAL diff
  integer      i, ink_lines, diff_lines;

  initial begin
    fd_rep  = $fopen("unit_tests/level_1/out/l1_report.txt");
    fd_boot = $fopen("unit_tests/level_1/out/l1_boot_trace.txt");
    fd_mon  = $fopen("unit_tests/level_1/out/l1_monitor_trace.txt");
    note($sformatf("level_1 start cpu=%s", cpu_name));

    // ================= boot =================
    reset_cold = 1'b1;
    wait_cycles(100);
    tracing_boot = 1'b1;
    reset_cold = 1'b0;
    // POR hold (~2^22 cycles) + ROM boot + settle into the idle loop
    wait_idle;
    tracing_boot = 1'b0;
    note($sformatf("boot: idle loop reached; boot PC trace (%d cycles) in l1_boot_trace.txt", boot_pc));

    // ================= T1: geometry =================
    note("--- T1 geometry ---");
    wait_cycles(300_000);   // let ~390 lines commit (line-based below)
    begin : t1
      integer base, j, lo, hi, alo, ahi, v780, v_before, v_after;
      lo = 16'hFFFF; hi = 16'd0; alo = 16'hFFFF; ahi = 16'd0;
      base = line_cnt - 390;
      for (j = 0; j < 390; j = j + 1) begin
        if (line_len[(base+j) & 511] < lo)  lo = line_len[(base+j) & 511];
        if (line_len[(base+j) & 511] > hi)  hi = line_len[(base+j) & 511];
        if (line_act[(base+j) & 511] < alo) alo = line_act[(base+j) & 511];
        if (line_act[(base+j) & 511] > ahi) ahi = line_act[(base+j) & 511];
      end
      note($sformatf("T1: line length (samples/HBL period): min=%d max=%d", lo, hi));
      note($sformatf("T1: active window (HBL-low samples): min=%d max=%d", alo, ahi));
      if (hi - lo > 8)
        err($sformatf("T1: line length unstable (spread %d)", hi - lo));
      if (ahi < 200 || ahi > 500)
        err($sformatf("T1: active window implausible (%d samples)", ahi));
      // VBL: 24 high lines per 390-line V period.  The vbl_lines counter
      // is event-based (one count per completed line with VBL high), so
      // take a before/after snapshot over ~850 lines (400k cycles).
      v_before = vbl_lines;
      wait_cycles(400_000);
      v_after  = vbl_lines;
      v780 = v_after - v_before;
      note($sformatf("T1: VBL-high lines over 400k master cycles: %d (expect ~52 = 24 per 390-line frame)", v780));
      if (v780 < 44 || v780 > 56)
        err($sformatf("T1: VBL count implausible (%d, expect ~52)", v780));
    end

    // ================= T2: text screen 'A', row consistency =================
    note("--- T2 text screen 'A' ---");
    write_screen(8'h41);
    do_capture;
    save_cap(saved_a);
    begin : t2
      integer k, ink, d0;
      reg [1023:0] modal, r;
      integer m, best, cand;
      ink_lines = 0;
      for (i = 0; i < 250; i = i + 1)
        if ($countones(cap[i]) > 0) ink_lines = ink_lines + 1;
      note($sformatf("T2: ink lines in 250-line capture: %d (expect ~192 = 24 rows x 8)", ink_lines));
      if (ink_lines < 150 || ink_lines > 230)
        err($sformatf("T2: ink line count implausible (%d)", ink_lines));
      // modal (most common) row among ink rows
      modal = 1024'b0; m = 0; best = 0;
      for (i = 0; i < 250; i = i + 1) begin
        if ($countones(cap[i]) != 0) begin
          r = cap[i];
          cand = 0;
          for (k = 0; k < 250; k = k + 1)
            if (cap[k] == r) cand = cand + 1;
          if (cand > best) begin best = cand; modal = r; m = i; end
        end
      end
      note($sformatf("T2: modal row = line %d, occurs %d times, ink=%d", m, best, $countones(modal)));
      if ($countones(modal) < 50)
        err($sformatf("T2: modal row has too little ink (%d)", $countones(modal)));
      // period-8 row repetition (character rows); cursor cells (8 px wide
      // x 8 rows) may differ from their +8 partner by <= ~16 samples
      diff_lines = 0;
      for (i = 0; i < 242; i = i + 1) begin
        if ($countones(cap[i]) != 0 && $countones(cap[i+8]) != 0) begin
          d0 = $countones(cap[i] ^ cap[i+8]);
          if (d0 > 0) begin
            diff_lines = diff_lines + 1;
            if (d0 > 16)
              err($sformatf("T2: row %d differs from row %d by %d samples (> 16, beyond the cursor region)", i, i+8, d0));
          end
        end
      end
      note($sformatf("T2: rows differing from +8 partner: %d (expect <= 8 = cursor rows)", diff_lines));
      if (diff_lines > 8)
        err($sformatf("T2: %d rows break period-8 repetition (cursor spans 8 rows)", diff_lines));
    end

    // ================= T3: glyph change B, back to A =================
    note("--- T3 glyph change ---");
    write_screen(8'h42);
    do_capture;
    save_cap(saved_b);
    diff_captures(saved_a, saved_b, d_tot, d_worst);
    note($sformatf("T3: 'A' vs 'B' screens: diff=%d total, %d worst line", d_tot, d_worst));
    if (d_tot < 2000)
      err($sformatf("T3: 'A' vs 'B' too similar (diff=%d) - font ROM not addressed?", d_tot));
    write_screen(8'h41);
    do_capture;
    diff_captures(saved_a, cap, d_tot, d_worst);
    note($sformatf("T3: 'A' re-fill vs first 'A': diff=%d (expect 0, cursor phase aligned)", d_tot));
    if (d_tot != 0)
      err($sformatf("T3: 'A' screen not reproducible (diff=%d)", d_tot));

    // ================= T4: ROMSWITCH halves =================
    note("--- T4 ROMSWITCH (video ROM halves) ---");
    romsw = 1'b1;
    write_screen(8'h41);
    do_capture;
    save_cap(saved_up);
    diff_captures(saved_a, saved_up, d_tot, d_worst);
    d_at_halves = d_tot;
    note($sformatf("T4: 'A' US-half vs LOCAL-half: diff=%d", d_tot));
    romsw = 1'b0;
    write_screen(8'h41);
    do_capture;
    diff_captures(saved_a, cap, d_tot, d_worst);
    if (d_tot != 0)
      err($sformatf("T4: ROMSWITCH back to 0 did not restore the US screen (diff=%d)", d_tot));
    // '@' on both halves (A and @ must not BOTH be identical across halves)
    romsw = 1'b0;
    write_screen(8'h40);
    do_capture;
    save_cap(saved_at0);
    romsw = 1'b1;
    write_screen(8'h40);
    do_capture;
    save_cap(saved_at1);
    diff_captures(saved_at0, saved_at1, d_tot, d_worst);
    note($sformatf("T4: '@' US vs LOCAL: diff=%d", d_tot));
    if (d_at_halves == 0 && d_tot == 0)
      err("T4: ROMSWITCH makes no visible difference for A or @ (both halves identical?)");
    // restore US half
    romsw = 1'b0;

    // video ROM file consistency (TB-side reference copies)
    begin : t4files
      integer same, nz, j2;
      same = 0; nz = 0;
      for (j2 = 0; j2 < 4096; j2 = j2 + 1)
        if (vid1[j2] == vid2[j2]) same = same + 1;
      for (j2 = 5488; j2 < 8192; j2 = j2 + 1)
        if (vid2[j2] != 8'h00) nz = nz + 1;
      note($sformatf("T4 files: video.hex == video2.hex[0:4095] for %d/4096 entries", same));
      note($sformatf("T4 files: video2.hex entries 5488..8191 non-zero: %d (file is the 5488-byte 'Part1')", nz));
    end

    // ================= T5: cursor blink =================
    note("--- T5 cursor blink ---");
    write_screen(8'h41);
    wait_cycles(100_000);
    do_capture;                    // X: current phase, mid-window
    save_cap(saved_x);
    wait_half_blink;               // Y: half blink period later
    do_capture;
    save_cap(saved_y);
    wait_half_blink;               // Z: full period after X
    do_capture;
    diff_captures(saved_x, cap, d_tot, d_worst);
    note($sformatf("T5: X vs Z (full blink period): diff=%d (expect 0)", d_tot));
    if (d_tot != 0)
      err($sformatf("T5: full blink period not periodic (diff=%d)", d_tot));
    diff_captures(saved_x, saved_y, d_tot, d_worst);
    note($sformatf("T5: X vs Y (half blink period): diff=%d worst=%d (expect a small cursor-only diff)", d_tot, d_worst));
    if (d_tot == 0)
      err("T5: cursor did not blink (half-period screens identical)");
    if (d_worst > 16 || d_tot > 64)
      err($sformatf("T5: blink diff too large to be one cursor cell (total=%d worst=%d)", d_tot, d_worst));

    // ================= T6: keyboard translation =================
    note("--- T6 keyboard ---");
    begin : t6
      // {ps2_code, expected junction} from the table comments
      // (keyboard.v:370-445)
      integer n, t;
      reg [6:0] kcode;
      reg       kpressed;
      reg [6:0] vec_jc [0:10];
      integer   vec_code [0:10];
      reg [10:0] kb_a;
      integer   got30;
      vec_code[0] = 8'h1C; vec_jc[0] = 7'h14;   // A
      vec_code[1] = 8'h1D; vec_jc[1] = 7'h0C;   // W
      vec_code[2] = 8'h21; vec_jc[2] = 7'h20;   // C
      vec_code[3] = 8'h32; vec_jc[3] = 7'h22;   // B
      vec_code[4] = 8'h1A; vec_jc[4] = 7'h1E;   // Z
      vec_code[5] = 8'h16; vec_jc[5] = 7'h01;   // 1
      vec_code[6] = 8'h1E; vec_jc[6] = 7'h02;   // 2
      vec_code[7] = 8'h45; vec_jc[7] = 7'h30;   // 0
      vec_code[8] = 8'h5A; vec_jc[8] = 7'h42;   // CR
      vec_code[9] = 8'h29; vec_jc[9] = 7'h44;   // Space
      vec_code[10]= 8'h76; vec_jc[10]= 7'h00;   // Esc (remapped to 0)

      for (n = 0; n < 11; n = n + 1) begin
        // prime the latch location with a sentinel before presenting the
        // key (CPU STALLed so the write races nothing)
        stall <= 1'b1;
        repeat (8) @(posedge clk_14m);
        ram0[16'h0030] = 8'hFF;
        stall <= 1'b0;
        wait_cycles(200);
        ps2_send(vec_code[n]);
        kpressed = 1'b0;
        for (t = 0; t < 1_000_000 && kpressed == 1'b0; t = t + 1) begin
          @(posedge clk_14m);
          kpressed = (kb_K[7] == 1'b1);
        end
        if (kpressed == 1'b0) begin
          err($sformatf("T6[%d]: code %02x never presented (K[7] never rose)", n, vec_code[n]));
        end else begin
          kcode = kb_K[6:0];
          kb_a  = kb_addr(vec_jc[n], 1'b0, 1'b0, 1'b0);
          if (kcode != kb_rom[kb_a][6:0])
            err($sformatf("T6[%d]: code %02x K=%02x expected %02x (jc=%02x rom[%d])",
                          n, vec_code[n], kcode, kb_rom[kb_a][6:0], vec_jc[n], kb_a));
          else
            note($sformatf("T6[%d]: %02x -> K=%02x (jc=%02x) OK", n, vec_code[n], kcode, vec_jc[n]));
          ps2_send(vec_code[n]);   // key up
          for (t = 0; t < 1_000_000 && kb_akd == 1'b1; t = t + 1) @(posedge clk_14m);
          wait_cycles(3000);
          got30 = ram0[16'h0030];
          if (got30 != kcode)
            err($sformatf("T6[%d]: RAM[$0030]=%02x after keyup, expected %02x (BIOS did not latch the key)", n, got30, kcode));
        end
        if (kb_akd == 1'b1)
          err($sformatf("T6[%d]: akd stuck after key up", n));
      end

      // shift-held: shift down, then 'A'
      ps2_send(8'h12);   // LEFT_SHIFT
      wait_cycles(500);
      ps2_send(8'h1C);   // 'A' with shift held
      kpressed = 1'b0;
      for (t = 0; t < 1_000_000 && kpressed == 1'b0; t = t + 1) begin
        @(posedge clk_14m);
        kpressed = (kb_K[7] == 1'b1);
      end
      if (kpressed == 1'b1) begin
        kcode = kb_K[6:0];
        kb_a  = kb_addr(7'h14, 1'b0, 1'b0, 1'b1);
        if (kcode != kb_rom[kb_a][6:0])
          err($sformatf("T6[sh]: shift+A K=%02x expected %02x (addr %d)", kcode, kb_rom[kb_a][6:0], kb_a));
        else
          note($sformatf("T6[sh]: shift+A -> K=%02x (addr %d) OK", kcode, kb_a));
      end else err("T6[sh]: shift+A never presented");
      ps2_send(8'h1C);   // A up
      ps2_send(8'h12);   // shift up
      wait_cycles(2000);

      // ctrl-held: ctrl down, then 'A'
      ps2_send(8'h14);   // LEFT_CTRL
      wait_cycles(500);
      ps2_send(8'h1C);   // 'A' with ctrl held
      kpressed = 1'b0;
      for (t = 0; t < 1_000_000 && kpressed == 1'b0; t = t + 1) begin
        @(posedge clk_14m);
        kpressed = (kb_K[7] == 1'b1);
      end
      if (kpressed == 1'b1) begin
        kcode = kb_K[6:0];
        kb_a  = kb_addr(7'h14, 1'b0, 1'b1, 1'b0);
        if (kcode != kb_rom[kb_a][6:0])
          err($sformatf("T6[ct]: ctrl+A K=%02x expected %02x (addr %d)", kcode, kb_rom[kb_a][6:0], kb_a));
        else
          note($sformatf("T6[ct]: ctrl+A -> K=%02x (addr %d) OK", kcode, kb_a));
      end else err("T6[ct]: ctrl+A never presented");
      ps2_send(8'h1C);
      ps2_send(8'h14);
      wait_cycles(2000);

      // caps lock on, then 'A', then restore
      ps2_send(8'h58);   // CAPS_LOCK down
      wait_cycles(500);
      ps2_send(8'h58);   // CAPS_LOCK up (toggles caplock)
      wait_cycles(500);
      ps2_send(8'h1C);   // 'A' with caps on
      kpressed = 1'b0;
      for (t = 0; t < 1_000_000 && kpressed == 1'b0; t = t + 1) begin
        @(posedge clk_14m);
        kpressed = (kb_K[7] == 1'b1);
      end
      if (kpressed == 1'b1) begin
        kcode = kb_K[6:0];
        kb_a  = kb_addr(7'h14, 1'b1, 1'b0, 1'b0);
        if (kcode != kb_rom[kb_a][6:0])
          err($sformatf("T6[cp]: caps+A K=%02x expected %02x (addr %d)", kcode, kb_rom[kb_a][6:0], kb_a));
        else
          note($sformatf("T6[cp]: caps+A -> K=%02x (addr %d) OK", kcode, kb_a));
      end else err("T6[cp]: caps+A never presented");
      ps2_send(8'h1C);
      ps2_send(8'h58);   // caps down again
      wait_cycles(500);
      ps2_send(8'h58);   // caps up (restores)
      wait_cycles(2000);
      note("T6 keyboard done (modifiers restored)");
    end

    // ================= T7: monitor experiment =================
    note("--- T7 monitor experiment (REPORT only) ---");
    begin : t7
      // F2 down (this core's reset key): soft_reset feeds the reset chain
      ps2_send(8'h06);
      wait_cycles(200);
      if (soft_reset == 1'b0)
        note("T7: soft_reset did not assert on F2 (unexpected - check)");
      wait_cycles(2_000_000);   // hold ~0.14 s: CPU held in reset
      // F2 up: POR hold ~2^22 cycles, then the ROM boots
      ps2_send(8'h06);
      wait_cycles(200);
      tracing_mon = 1'b1;
      while (mon_pc < 4000) @(posedge clk_14m);   // trace 4000 CPU cycles
      tracing_mon = 1'b0;
      wait_idle;
      do_capture;
      dump_pbm("unit_tests/level_1/out/l1_monitor.pbm", cap);
      note("T7 REPORT: F2 held 0.14 s through the reset, released; PC trace (4000 CPU cycles) in l1_monitor_trace.txt, screen in l1_monitor.pbm. If the ROM entered the monitor, PC should visit $F000-$F07F and the screen should show the monitor prompt.");
    end

    // ================= dump reference screen =================
    write_screen(8'h41);
    do_capture;
    dump_pbm("unit_tests/level_1/out/l1_screen_a.pbm", cap);

    // ================= done =================
    if (fd_rep) $fclose(fd_rep);
    if (fd_boot) $fclose(fd_boot);
    if (fd_mon) $fclose(fd_mon);
    if (errors == 0)
      $display("L1 PASS cpu=%s (errors=0)", cpu_name);
    else
      $display("L1 FAIL cpu=%s (errors=%d)", cpu_name, errors);
    $finish;
  end

endmodule
