// ============================================================================
// unit_tests/level_2/tb_l2.sv
//
// Level-2 (config 2) testbench: the level_1 machine core (rtl/apple2.v,
// unmodified - both CPU cores muxed on `cpu`, RAM decode, BIOS ROM, timing
// HAL, native video) + the real PS/2 keyboard (rtl/keyboard.v) + the real
// Disk II slot controller (rtl/disk_ii.v, unmodified - two drive_ii MFM
// decoders + the controller ROM) + one real floppy_track per drive
// (rtl/floppy_track.sv + rtl/dpram.v, unmodified).
//
//   drive 1 : the disk under test - the C++ host (main_l2.cpp) mounts a
//             .nib image on it for the "preloaded" scenario, or leaves it
//             unmounted for the "empty" scenario.
//   drive 2 : always unmounted / empty (the Disk II is a 2-drive controller;
//             only drive 1 is populated - "add one Disk II drive").
//
// Wiring mirrors rtl/apple2_top.v + verilator/sim.v EXACTLY (disk_ii at
// apple2_top.v:528, floppy_track at sim.v:645/674, PD mux at
// apple2_top.v:389):
//   * core.PD  = disk_ii.D_OUT   (disk is the only slot peripheral here)
//   * disk_ii  : IO_SELECT[6]/DEVICE_SELECT[6], A=ADDR, D_IN=D (CPU data out)
//   * track bus: disk_ii.TRACKx -> floppy_track.ram_* ; floppy_track.ram_do
//                -> disk_ii.TRACKx_DO ; floppy_track.busy -> TRACKx_BUSY
//   * floppy_track.active = disk_ii.Dx_ACTIVE ; floppy_track.ready ->
//     disk_ii.DISK_READY[x] ; floppy_track.mount/change/protect = host regs
//   * the SD/blkdev side (sd_lba/sd_rd/sd_wr/sd_ack/sd_buff_*) is driven by
//     the C++ host, which serves .nib track data (read-only) - the RTL side
//     is the real floppy_track.
//
// The machine COLD-BOOTS at t=0 (the power-on chain below mirrors
// apple2_top.v, incl. the 2^22-cycle power-on hold and the cold-reset $3F4
// RAM force that arms the ROM's disk-boot routine).  With a disk mounted on
// drive 1 the ROM should boot DOS 3.3 from it; with no disk the machine
// falls to the ROM monitor (as in level_1).
//
// C++ <-> TB interface (module-scope regs/wires, exposed by -public):
//   in  (C++ writes):  sd_ack[1:0], sd_buff_addr[8:0], sd_buff_dout[7:0],
//                      sd_buff_wr, disk_mount[1:0], disk_change[1:0],
//                      disk_protect[1:0], stall, reset_cold, ps2_key[10:0],
//                      flash_div[22:0], romsw,
//                      dbg_ft_wr_en/addr/data (write-test injection),
//                      use_composite, comp_sat[7:0], comp_hue[7:0],
//                      comp_bright[7:0], comp_contrast[7:0]
//                      (composite video path, 2026-09-07),
//                      ss_save_req, ss_load_req (save-state, 2026-09-08)
//   out (C++ reads):   sd_rd[1:0], sd_wr[1:0], sd_lba_a/b[31:0],
//                      sd_buff_din_a/b[7:0], disk_ready[1:0], d1_active,
//                      d1_motor_on, d1_io_active, d1_step_active,
//                      d1_track_zero_step, d1_track, frame_valid,
//                      frame[512], frame_count, screen_ink, dbg_addr,
//                      dbg_motor1_cnt, dbg_track1_cnt, dbg_sdwr_cnt,
//                      phzf_cnt, dbg_2m_*, dbg_t1a_*, dbg_wra/wrb_cnt,
//                      dbg_wri_cnt, h_t1_busy, errors,
//                      comp_ink/comp_nongray[15:0], comp_gmin/comp_gmax[7:0],
//                      comp_dark_n/sr/sg/sb, comp_bri_n/sr/sg/sb,
//                      comp_p0..p3_n/sr/sg/sb, comp_bg_n/sr/sg/sb
//                      (color-aware palette probe, 2026-09-09)
//                      (per-frame composite-decoder stats, use_composite=1),
//                      ss_busy, ss_done, ss_error (save-state, 2026-09-08)
//
// The binary MUST run with the process CWD at the REPO ROOT: the DUT's
// $readmemh ROM paths (rtl/roms/*.hex, incl. diskii.hex) are CWD-relative.
// ============================================================================

module tb_l2 (
    // C++-driven host inputs.  These MUST be top-level PORTS (exactly
    // like sim.v in the full sim): the Verilator v5 event model only
    // re-evaluates combinational cones when top-level port values
    // change.  If these are module-scope regs written from C++, the
    // cones they feed (the track dpram wren_a/data_a) are optimized
    // into the stable region and evaluated once at init - freezing at
    // 0 so the track RAM never receives its host bytes.
    input logic        clk_14m,
    input logic [1:0]  sd_ack,
    input logic [8:0]  sd_buff_addr,
    input logic [7:0]  sd_buff_dout,
    input logic        sd_buff_wr,
    input logic [1:0]  disk_mount,
    input logic [1:0]  disk_change,
    input logic [1:0]  disk_protect,
    // L2 write-test debug injection (2026-09-06): C++ forces port-B
    // (drive-side) track-RAM writes into ft1 so the track becomes
    // `dirty` in exactly the way a machine DISK WRITE would; the DUT's
    // own dirty-track flush logic must then save the track back over
    // sd_wr (module_tests/floppy_track S3, at the machine level).
    // Purely a testbench input: low (default) = zero effect on the DUT.
    input logic        dbg_ft_wr_en,
    input logic [12:0] dbg_ft_wr_addr,
    input logic [7:0]  dbg_ft_wr_data,
    // Composite video path (2026-09-07): C++ selects the decoded composite
    // display and its decoder knobs.  use_composite=0 (default) freezes the
    // composite DUT (ce=0) and gates its stat sampling: the default mono
    // run is byte-identical to before this change.
    input logic        use_composite,
    input logic [7:0]  comp_sat,
    input logic [7:0]  comp_hue,
    input logic [7:0]  comp_bright,
    input logic [7:0]  comp_contrast,
    // Save-state requests (level_1b port, 2026-09-08): C++-driven
    // one-shot pulses into the savestate_manager_l1b coordinator -
    // the same manager + DDR bridge the level_2 mister build uses.
    input logic        ss_save_req,
    input logic        ss_load_req
);

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
      cpu_name = (plus_cpu == 0) ? "nmos" : "wdc";
    end
    $display("L2 CPU=%0d %s", cpu_sel, cpu_name);
  end

  // ------------------------------------------------------------------
  // 14.3 MHz master clock (35 ns per half-period), driven from C++.
  //
  // 14.3 MHz master clock: driven from C++ (one toggle per 35 ns),
  // declared as a module port above, exactly like the full sim's
  // C++-driven clk_sys port.  A TB-internal `always #35_000` clock
  // would require --timing, which this harness does not use.
  // ------------------------------------------------------------------

  // ------------------------------------------------------------------
  // Core output wires
  // ------------------------------------------------------------------
  wire        w_video;
  wire        w_col_line;
  wire        w_text_mode;
  wire        w_hbl;
  wire        w_vbl;
  wire [15:0] w_addr;
  wire [17:0] w_ram_addr;
  wire [7:0]  w_ram_di;
  wire        w_ram_aux;
  wire        w_ram_we;
  wire        w_cpu_we;
  wire [7:0]  w_an;
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
  wire [15:0]  ram_do;
  wire        read_key, soft_reset;
  wire [7:0]  kb_K;
  wire        kb_akd;

  // ------------------------------------------------------------------
  // TB-controlled DUT inputs (C++ writes)
  // ------------------------------------------------------------------
  reg  [22:0] flash_div  = 23'b0;
  wire        flash_clk  = flash_div[22];
  reg         romsw      = 1'b0;
  reg         stall      = 1'b0;
  reg         reset_cold = 1'b0;
  reg         reset_warm = 1'b0;
  reg  [10:0] ps2_key    = 11'b0;

  // ------------------------------------------------------------------
  // 60Hz IRQ (mirrors level_1): one short IRQ pulse per frame, derived
  // from the VBL rising edge.  The ROM's 60Hz handler keeps the OS
  // 1-second counter the power-up/boot path waits on.
  // ------------------------------------------------------------------
  reg     [4:0] irq_60hz_cnt = 5'd0;
  reg         vbl_d          = 1'b0;
  wire        irq_60hz_pulse = (irq_60hz_cnt != 5'd0);
  always @(posedge clk_14m) begin
    vbl_d <= w_vbl;
    if (w_vbl && !vbl_d)
      irq_60hz_cnt <= 5'd16;
    else if (irq_60hz_cnt != 5'd0)
      irq_60hz_cnt <= irq_60hz_cnt - 5'd1;
  end

  // ------------------------------------------------------------------
  // SD/blkdev host interface - C++-driven (writes) and C++-read (wires).
  // The C++ host (main_l2.cpp) owns the sector-streaming state machine
  // (mirrors verilator/sim/sim_blkdevice.cpp, read-only) and drives the
  // *_in regs each eval step; the real floppy_track drives the *_out
  // wires.
  // ------------------------------------------------------------------
  // C++ writes (declared as module ports above; driven via top->X)
  // C++ reads (driven by the floppy_track instances below)
  wire [1:0]  sd_rd;
  wire [1:0]  sd_wr;
  wire [31:0] sd_lba_a;
  wire [31:0] sd_lba_b;
  wire [7:0]  sd_buff_din_a;
  wire [7:0]  sd_buff_din_b;
  wire [1:0]  disk_ready;

  // Disk II drive status (from disk_ii)
  wire        d1_active, d2_active;
  wire        d1_motor_on, d2_motor_on;
  wire        d1_io_active, d2_io_active;
  wire        d1_step_active, d2_step_active;
  wire        d1_track_zero_step, d2_track_zero_step;
  wire [5:0]  d1_track, d2_track;

  // Disk II track bus (disk_ii <-> floppy_track)
  wire [5:0]  t1_track, t2_track;
  wire [12:0] t1_addr, t2_addr;
  wire [7:0]  t1_di, t2_di, t1_do, t2_do;
  wire        t1_we, t2_we, t1_busy, t2_busy;
  wire [7:0]  disk_do;   // disk_ii.D_OUT -> core.PD

  // ------------------------------------------------------------------
  // apple2: the machine core (level_1 wiring, but PD = disk_ii.D_OUT)
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
    // OSD-style pause (C++ `stall`) + save-state freeze (ss_busy).
    .STALL       (stall || ss_busy),
    .ADDR        (w_addr),
    .ram_addr    (w_ram_addr),
    .D           (w_ram_di),
    .ram_do      (ram_do),
    .aux         (w_ram_aux),
    .PD          (disk_do),
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
    .DBG_ROM_OUT (w_dbg_romo),
    // Save-state (level_1b port, 2026-09-08): machine_ce is the
    // manager's freeze - 1 only in IDLE/FREEZE, 0 during the
    // register/RAM walk (unconnected it is 0 in two-state Verilator
    // and the machine would be dead).  The ss_* bus carries the
    // per-word register capture/apply; the wrapper mux below owns
    // words 8/9/10 (reset/flash state, spare, CPU select).
    .machine_ce  (machine_ce),
    .ss_wren     (ss_wren),
    .ss_addr     (ss_addr),
    .ss_wdata    (ss_wdata),
    .ss_rdata    (core_ss_rdata),
    .cpu_frozen  (cpu_frozen)
  );

  // ------------------------------------------------------------------
  // keyboard: real PS/2 interface (mirrors level_1)
  // ------------------------------------------------------------------
  wire kb_ooa, kb_coa, kb_vt, kb_pt;
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
  // disk_ii: the Disk II slot controller (slot 6) - mirrors
  // apple2_top.v:528.  RESET = the power-on reset (held during POR).
  // ------------------------------------------------------------------
  disk_ii disk (
    .CLK_14M(clk_14m),
    .CLK_2M(w_clk_2m),
    .PHASE_ZERO(w_pz),
    .IO_SELECT(w_io_sel[6]),
    .DEVICE_SELECT(w_dev_sel[6]),
    .RESET(reset_sync),
    .DISK_READY(disk_ready),
    .A(w_addr),
    .D_IN(w_ram_di),
    .D_OUT(disk_do),
    .D1_ACTIVE(d1_active),
    .D2_ACTIVE(d2_active),
    .D1_MOTOR_ON(d1_motor_on),
    .D2_MOTOR_ON(d2_motor_on),
    .D1_IO_ACTIVE(d1_io_active),
    .D2_IO_ACTIVE(d2_io_active),
    .D1_STEP_ACTIVE(d1_step_active),
    .D2_STEP_ACTIVE(d2_step_active),
    .D1_TRACK_ZERO_STEP(d1_track_zero_step),
    .D2_TRACK_ZERO_STEP(d2_track_zero_step),
    .D1_WP(disk_protect[0]),
    .D2_WP(disk_protect[1]),
    .TRACK1(t1_track),
    .TRACK1_ADDR(t1_addr),
    .TRACK1_DO(t1_do),
    .TRACK1_DI(t1_di),
    .TRACK1_WE(t1_we),
    .TRACK1_BUSY(t1_busy),
    .TRACK2(t2_track),
    .TRACK2_ADDR(t2_addr),
    .TRACK2_DO(t2_do),
    .TRACK2_DI(t2_di),
    .TRACK2_WE(t2_we),
    .TRACK2_BUSY(t2_busy)
  );

  // ------------------------------------------------------------------
  // floppy_track x2: the physical track buffers + SD interface - mirrors
  // the full-sim sim.v:645/674.  Clock = clk_14m (level_1's master); the
  // full sim uses clk_sys, but the handshake is edge/byte based, so the
  // clock domain is irrelevant to correctness here.
  // ------------------------------------------------------------------
  // ------------------------------------------------------------------
  // Write-test debug injection mux (2026-09-06): while dbg_ft_wr_en is
  // high the ft1 track-RAM port-B inputs come from the C++ debug ports
  // instead of the disk_ii drive signals.  The DUT (disk_ii, drive_ii,
  // floppy_track, dpram) is unmodified; this only selects which driver
  // feeds ft1's port-B inputs and is inert while the bit is low.
  // ------------------------------------------------------------------
  wire        t1_we_eff   = t1_we | dbg_ft_wr_en;
  wire [7:0]  t1_di_eff   = dbg_ft_wr_en ? dbg_ft_wr_data : t1_di;
  wire [12:0] t1_addr_eff = dbg_ft_wr_en ? dbg_ft_wr_addr : t1_addr;

  floppy_track ft1 (
    .clk(clk_14m),
    .reset(reset_sync),
    .ram_addr(t1_addr_eff),
    .ram_di(t1_di_eff),
    .ram_do(t1_do),
    .ram_we(t1_we_eff),
    .track(t1_track),
    .busy(t1_busy),
    .change(disk_change[0]),
    .mount(disk_mount[0]),
    .ready(disk_ready[0]),
    .active(d1_active),
    .sd_buff_addr(sd_buff_addr),
    .sd_buff_dout(sd_buff_dout),
    .sd_buff_din(sd_buff_din_a),
    .sd_buff_wr(sd_buff_wr),
    .sd_lba(sd_lba_a),
    .sd_rd(sd_rd[0]),
    .sd_wr(sd_wr[0]),
    .sd_ack(sd_ack[0])
  );

  floppy_track ft2 (
    .clk(clk_14m),
    .reset(reset_sync),
    .ram_addr(t2_addr),
    .ram_di(t2_di),
    .ram_do(t2_do),
    .ram_we(t2_we),
    .track(t2_track),
    .busy(t2_busy),
    .change(disk_change[1]),
    .mount(disk_mount[1]),
    .ready(disk_ready[1]),
    .active(d2_active),
    .sd_buff_addr(sd_buff_addr),
    .sd_buff_dout(sd_buff_dout),
    .sd_buff_din(sd_buff_din_b),
    .sd_buff_wr(sd_buff_wr),
    .sd_lba(sd_lba_b),
    .sd_rd(sd_rd[1]),
    .sd_wr(sd_wr[1]),
    .sd_ack(sd_ack[1])
  );

  // ------------------------------------------------------------------
  // Reset chain - mirrors apple2_top.v:315-330 exactly.  power_on_reset
  // starts held and releases only after flash_div reaches 2^22; a
  // reset_cold pulse re-arms the whole sequence.
  // ------------------------------------------------------------------
  reg power_on_reset = 1'b1;
  reg reset_sync;
  always @(posedge clk_14m) begin: reset_chain
    reset_sync <= reset_warm | power_on_reset;
    // Save-state restore (level_1b pattern): register word 8 carries
    // the wrapper reset/flash state so a load reproduces the exact
    // power-on phase.
    if (ss_wren && (ss_addr == 10'd8)) begin
      flash_div      <= ss_wdata[22:0];
      power_on_reset <= ss_wdata[23];
      reset_sync     <= ss_wdata[24];
    end else if (reset_cold == 1'b1 || soft_reset == 1'b1) begin
      power_on_reset <= 1'b1;
      flash_div      <= 23'b0;
    end else begin
      if (flash_div[22] == 1'b1)
        power_on_reset <= 1'b0;
      flash_div <= flash_div + 1'b1;
    end
  end

  // ------------------------------------------------------------------
  // Cold-reset RAM force - mirrors apple2_top.v:385-387: while reset_cold
  // the RAM interface is held at (we=1, addr=$3F4, data=0).  This clears
  // the ROM's cold-boot flag so the disk-boot routine runs on cold boot.
  // ------------------------------------------------------------------
  wire        ram_we_eff   = reset_cold ? 1'b1   : w_ram_we;
  wire [17:0] ram_addr_eff = reset_cold ? 18'h03F4 : w_ram_addr;
  wire [7:0]  ram_di_eff   = reset_cold ? 8'b0    : w_ram_di;

  // ------------------------------------------------------------------
  // TB RAM - the verilator/sim.v pattern: 1-ce latch, main + aux
  // ------------------------------------------------------------------
  // Save-state RAM client port (savestate_manager_l1b).  Mirrors the
  // mister wrapper EXACTLY (2026-09-08): two explicit dpram instances
  // (the Verilog behavioral model of the altsyncram dpram.vhd - the
  // same module the FPGA build instantiates), port A = the machine,
  // port B = the save-state walker, raw q_b for the ss read (port B's
  // registered address provides the manager's one-cycle read latency),
  // and one register stage on q_a to keep the original registered-read
  // machine timing.  Quartus 17 cannot infer the dual-client arrays
  // (Error 276003: "asynchronous read logic" / "unsupported
  // read-during-write behavior"), hence the explicit instances.
  wire        ram_ss_bank;
  wire [15:0] ram_ss_addr;
  wire        ram_ss_rd, ram_ss_wr;
  wire [7:0]  ram_ss_wdata, ram_ss_rdata;
  wire        ram_we_mach  = ram_we_eff && !ss_busy;

  wire [7:0] main_ram_q_a, main_ram_q_b;
  wire [7:0] aux_ram_q_a,  aux_ram_q_b;

  dpram #(16,8) main_ram (
    .address_a(ram_addr_eff[15:0]), .address_b(ram_ss_addr),
    .clock_a(clk_14m), .clock_b(clk_14m),
    .data_a(ram_di_eff), .data_b(ram_ss_wdata),
    .enable_a(1'b1), .enable_b(1'b1),
    .wren_a(ram_we_mach && !w_ram_aux),
    .wren_b(ram_ss_wr && !ram_ss_bank && !ss_reset),
    .q_a(main_ram_q_a), .q_b(main_ram_q_b)
  );

  dpram #(16,8) aux_ram (
    .address_a(ram_addr_eff[15:0]), .address_b(ram_ss_addr),
    .clock_a(clk_14m), .clock_b(clk_14m),
    .data_a(ram_di_eff), .data_b(ram_ss_wdata),
    .enable_a(1'b1), .enable_b(1'b1),
    .wren_a(ram_we_mach && w_ram_aux),
    .wren_b(ram_ss_wr && ram_ss_bank && !ss_reset),
    .q_a(aux_ram_q_a), .q_b(aux_ram_q_b)
  );

  // One register stage on the combinational NEW_DATA q_a: byte-identical
  // timing to the previously verified inferred RAM (write-through kept).
  always @(posedge clk_14m) begin: ram_do_reg
    ram_do[7:0]  <= main_ram_q_a;
    ram_do[15:8] <= aux_ram_q_a;
  end

  // Raw q_b: port B's registered address makes q_b in cycle N+1 hold
  // the byte at the address presented in cycle N (the manager's
  // protocol: ram_rd in N, ram_rdata sampled in N+1).
  assign ram_ss_rdata = ram_ss_bank ? aux_ram_q_b : main_ram_q_b;

  // ------------------------------------------------------------------
  // Save state (level_1b port, 2026-09-08): the same coordinator +
  // direct 64-bit DDRAM bridge the level_2 mister build instantiates.
  // The TB models the HPS DDRAM port: 64-bit beats, one acknowledged
  // transaction at a time, 4-cycle latency (the corrected level_1b
  // contract: beat base, stride 1, burst 1).  V1 scope: CPU +
  // main/aux RAM + machine latches + timing/video phase; the disk
  // path is NOT in the state (see SAVESTATE_V2_DISK_MAP.md).
  // ------------------------------------------------------------------
  wire [9:0]  ss_addr;
  wire [63:0] ss_wdata, ss_rdata, core_ss_rdata;
  wire        ss_wren;
  wire        machine_ce;
  wire        cpu_frozen;
  wire        ss_busy, ss_done, ss_error, ss_locked_cpu;
  wire        slot_rd, slot_wr, slot_ready;
  wire [14:0] slot_addr;
  wire [63:0] slot_wdata, slot_rdata;

  // Wrapper-owned register words (level_1b pattern): 8 = reset/flash
  // chain, 9 = spare, 10 = selected CPU.  Everything else is the core's.
  assign ss_rdata = (ss_addr == 10'd8) ?
                    {39'd0, reset_sync, power_on_reset, flash_div} :
                    (ss_addr == 10'd9) ? 64'd0 :
                    (ss_addr == 10'd10) ? {63'd0, cpu_sel} : core_ss_rdata;

  savestate_manager_l1b state_manager (
    .clk(clk_14m), .reset(reset_cold || reset_warm || soft_reset),
    .request_save(ss_save_req), .request_load(ss_load_req),
    .allow_save_state(1'b1), .cpu_type(cpu_sel), .cpu_frozen(cpu_frozen),
    .stall(), .machine_ce(machine_ce), .busy(ss_busy), .done(ss_done),
    .error(ss_error), .locked_cpu_type(ss_locked_cpu),
    .ss_addr(ss_addr), .ss_wdata(ss_wdata), .ss_wren(ss_wren), .ss_rdata(ss_rdata),
    .ram_bank(ram_ss_bank), .ram_addr(ram_ss_addr), .ram_rd(ram_ss_rd),
    .ram_wr(ram_ss_wr), .ram_wdata(ram_ss_wdata), .ram_rdata(ram_ss_rdata),
    .slot_addr(slot_addr), .slot_rd(slot_rd), .slot_wr(slot_wr),
    .slot_wdata(slot_wdata), .slot_rdata(slot_rdata), .slot_ready(slot_ready)
  );

  savestate_ddr_l1b #(.BASE_ADDR(29'd0)) ddr_ss (
    .clk(clk_14m), .reset(reset_cold || reset_warm || soft_reset),
    .slot_addr(slot_addr), .slot_rd(slot_rd), .slot_wr(slot_wr),
    .slot_wdata(slot_wdata), .slot_rdata(slot_rdata), .slot_ready(slot_ready),
    .ddram_clk(ddram_clk), .ddram_busy(ddram_busy), .ddram_burstcnt(ddram_burstcnt),
    .ddram_addr(ddram_addr), .ddram_dout(ddram_dout),
    .ddram_dout_ready(ddram_dout_ready), .ddram_rd(ddram_rd),
    .ddram_din(ddram_din), .ddram_be(ddram_be), .ddram_we(ddram_we)
  );

  // TB model of the HPS DDRAM port (64-bit beats, one acknowledged
  // transaction at a time).  The bridge only pulses ddram_rd/ddram_we
  // while !ddram_busy, so a 1-cycle pulse is never lost.
  wire        ddram_clk;
  wire        ddram_busy;
  wire [7:0]  ddram_burstcnt;
  wire [28:0] ddram_addr;
  wire [63:0] ddram_dout;
  wire        ddram_dout_ready;
  wire        ddram_rd;
  wire [63:0] ddram_din;
  wire [7:0]  ddram_be;
  wire        ddram_we;
  reg  [63:0] ddram_mem [0:32767];
  reg         ddram_busy_r = 1'b0;
  reg  [2:0]  ddram_lat_r  = 3'd0;
  reg         ddram_rd_r;
  reg  [14:0] ddram_addr_r;
  reg  [63:0] ddram_dout_r = 64'd0;
  reg         ddram_dout_ready_r = 1'b0;
  always @(posedge clk_14m) begin: tb_ddram
    ddram_dout_ready_r <= 1'b0;
    if (ddram_busy_r) begin
      if (ddram_lat_r == 3'd3) begin
        ddram_busy_r <= 1'b0;
        if (ddram_rd_r) begin
          ddram_dout_r       <= ddram_mem[ddram_addr_r];
          ddram_dout_ready_r <= 1'b1;
        end
      end else begin
        ddram_lat_r <= ddram_lat_r + 1'b1;
      end
    end else begin
      ddram_lat_r <= 3'd0;
      if (ddram_we) begin
        ddram_mem[ddram_addr[14:0]] <= ddram_din;
        ddram_busy_r <= 1'b1;
      end else if (ddram_rd) begin
        ddram_rd_r   <= 1'b1;
        ddram_addr_r <= ddram_addr[14:0];
        ddram_busy_r <= 1'b1;
      end
    end
  end
  assign ddram_busy       = ddram_busy_r;
  assign ddram_dout       = ddram_dout_r;
  assign ddram_dout_ready = ddram_dout_ready_r;

  // ------------------------------------------------------------------
  // Video sampler + frame pack (mirrors level_1): 1 sample per master
  // cycle (negedge), lines assembled from HBL edges, frames anchored at
  // the VBL falling edge.
  // ------------------------------------------------------------------
  reg  [1023:0] lines   [0:511];
  reg  [15:0]   line_len[0:511];
  reg  [15:0]   line_act[0:511];
  integer       line_cnt  = 0;
  integer       vbl_lines = 0;
  reg           hbl_s = 1'b0, vbl_s = 1'b0;
  reg           hbl_p = 1'b0;
  reg  [15:0]   smp = 16'd0;
  reg  [15:0]   act = 16'd0;

  always @(negedge clk_14m) begin: video_sampler
    hbl_s <= w_hbl;
    vbl_s <= w_vbl;
    hbl_p <= hbl_s;
    if (hbl_p == 1'b1 && hbl_s == 1'b0) begin
      lines[line_cnt & 511] <= 1024'b0;
      smp                   <= 16'd0;
      act                   <= 16'd0;
    end else if (hbl_p == 1'b0 && hbl_s == 1'b1) begin
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

  reg [15:0]   frame_base  = 16'd0;
  reg [1023:0] frame       [0:511];
  reg          frame_valid = 1'b0;
  reg [15:0]   frame_lines = 16'd0;
  integer      frame_count = 0;
  reg          vbl_p       = 1'b0;
  reg [15:0]   last_len    = 16'd0;
  reg [15:0]   last_act    = 16'd0;
  reg          text_mode_s = 1'b0;

  always @(negedge clk_14m) begin: frame_pack
    vbl_p <= vbl_s;
    text_mode_s <= w_text_mode;
    if (vbl_p == 1'b1 && vbl_s == 1'b0) begin
      if (frame_count > 0) begin
        frame_valid <= 1'b1;
        frame_lines <= line_cnt - frame_base;
      end
      frame_base  <= line_cnt;
      frame_count <= frame_count + 1;
    end
    if (hbl_p == 1'b0 && hbl_s == 1'b1) begin
      last_len <= smp + 1;
      last_act <= act;
      if (line_cnt >= frame_base && line_cnt < frame_base + 512)
        frame[line_cnt - frame_base] <= lines[line_cnt & 511];
    end
  end

  // ------------------------------------------------------------------
  // Composite video path (2026-09-07): rtl/apple_composite.sv (encoder +
  // SPC=4 decoder) fed from the REAL machine 1-bit VIDEO + blanking.
  // The core exposes blanking, not syncs, so the syncs are derived exactly
  // as the level-2 MiSTer wrapper does (mister/Apple-II.sv): HSYNC = 68
  // master cycles starting 130 cycles into HBL, VSYNC = 3 lines starting
  // 33 lines into VBL.  use_composite gates the DUT's ce (frozen idle
  // cone when 0, so the default mono run is unchanged) and the per-frame
  // stat accumulation below; the stats (last completed frame, latched at
  // the VBL falling edge) are read through tb_l2__DOT__comp_*.
  // ------------------------------------------------------------------
  localparam integer COMP_HSYNC_FRONT_PORCH = 130;
  localparam integer COMP_HSYNC_WIDTH       = 68;
  localparam integer COMP_VSYNC_FRONT_PORCH = 33;
  localparam integer COMP_VSYNC_LINES       = 3;

  // Master cycles since the start of the horizontal blanking interval.
  // HBL is ~352 cycles max, so 10 bits never overflows.
  reg [9:0] comp_hblank_cnt = 10'd0;
  always @(posedge clk_14m) begin
    if (w_hbl)
      comp_hblank_cnt <= comp_hblank_cnt + 10'd1;
    else
      comp_hblank_cnt <= 10'd0;
  end
  reg  comp_hbl_d    = 1'b0;
  wire comp_hbl_rise = w_hbl & ~comp_hbl_d;
  always @(posedge clk_14m) comp_hbl_d <= w_hbl;
  // Lines since the start of the vertical blanking interval, counted by
  // the HBL rising edges that occur while VBL is high.
  reg [6:0] comp_vblank_lines = 7'd0;
  always @(posedge clk_14m) begin
    if (w_vbl) begin
      if (comp_hbl_rise)
        comp_vblank_lines <= comp_vblank_lines + 7'd1;
    end else begin
      comp_vblank_lines <= 7'd0;
    end
  end
  wire comp_hsync = w_hbl &
                    (comp_hblank_cnt >= COMP_HSYNC_FRONT_PORCH) &
                    (comp_hblank_cnt < COMP_HSYNC_FRONT_PORCH + COMP_HSYNC_WIDTH);
  wire comp_vsync = w_vbl &
                    (comp_vblank_lines >= COMP_VSYNC_FRONT_PORCH) &
                    (comp_vblank_lines < COMP_VSYNC_FRONT_PORCH + COMP_VSYNC_LINES);

  wire [7:0] comp_r, comp_g, comp_b;
  apple_composite comp_dut (
    .clk    (clk_14m),
    .ce     (use_composite),
    .video  (w_video),
    .hs     (comp_hsync),
    .vs     (comp_vsync),
    .hb     (w_hbl),
    .vb     (w_vbl),
    .sat    (comp_sat),
    .hue    (comp_hue),
    .bright (comp_bright),
    .contrast (comp_contrast),
    .r      (comp_r),
    .g      (comp_g),
    .b      (comp_b),
    .ce_out (),
    .hs_out (),
    .vs_out (),
    .hb_out (),
    .vb_out ()
  );

  // Mono ink of the last COMPLETED frame, latched at the same VBL falling
  // edge as the composite stats (frame[] is already being refilled with the
  // next frame by the time $finish reads it, so it must not be used as the
  // same-frame mono reference).  hbl_s/hbl_p are the negedge-domain blank
  // delays shared with the video sampler; hbl_p==0 && hbl_s==1 is the HBL
  // rising edge, where lines[] holds the just-finished line.
  reg [19:0] mono_ink_acc = 20'd0;
  reg [19:0] mono_ink_frame_l = 20'd0;
  always @(negedge clk_14m) begin
    if (hbl_p == 1'b0 && hbl_s == 1'b1)
      mono_ink_acc <= mono_ink_acc + $countones(lines[line_cnt & 511]);
    if (vbl_p == 1'b1 && vbl_s == 1'b0) begin
      mono_ink_frame_l <= mono_ink_acc;
      mono_ink_acc     <= 20'd0;
    end
  end

  // Per-frame composite stats over the active samples (negedge, like the
  // video sampler): comp_ink = samples with g >= 128, comp_nongray =
  // samples with |r-g| > 16 or |g-b| > 16, comp_gmin/gmax = g range.
  // Latched from the accumulators at the VBL falling edge (the same frame
  // anchor as frame_pack); only when use_composite=1.
  reg [19:0] comp_ink     = 20'd0;
  reg [19:0] comp_nongray = 20'd0;
  reg [7:0]  comp_gmin    = 8'hFF;
  reg [7:0]  comp_gmax    = 8'h00;
  reg [19:0] comp_ci      = 20'd0;
  reg [19:0] comp_cn      = 20'd0;
  reg [7:0]  comp_gmin_a  = 8'hFF;
  reg [7:0]  comp_gmax_a  = 8'h00;
  // Color-aware palette probe (2026-09-09): per-luma-band averages over the
  // nongray samples.  The nongray gate (|r-g|>16 or |g-b|>16) excludes the
  // flat gray core of the 1-bit picture and keeps the artifact chroma;
  // dark band (g < 64) = the large dark field (background), bright band
  // (g >= 128) = the text/edge fringes.  C++ converts each band's sums to
  // an average RGB hue angle; the hue-knob matrix run reads these to pick
  // the knob value where the palette is the classic blue-background /
  // orange-text look (and to prove the sine path is linear: +16 knob steps
  // must rotate the angle by +22.5 deg).  Print-only in the harness - no
  // pass/fail gating.
  //
  // Phase-class probe (2026-09-09, matrix round 2): the band averages are
  // confounded because the nongray/band POPULATIONS shift across thresholds
  // as the palette rotates (measured: the k vs k+128 band angles agree to
  // 0.5 deg while the per-pixel colors are a 180-deg-flipped mix).  The
  // 1-bit picture's artifact palette is the set of colors the boxcar demod
  // gives the step transitions at the four subcarrier phases (the video bit
  // is held ~4 samples = one subcarrier cycle; only the 1-sample transitions
  // carry chroma, one per column mod 4).  These classes rotate RIGIDLY with
  // the hue knob (-22.5 deg per +16 knob steps), so per-class averages are
  // the right resolution for the knob matrix.  comp_pN_n/r/g/b (N = 0..3):
  // nongray pixels at line-sample phase N (line counter comp_lc, origin at
  // HBL rise - a fixed column grid, so the classes are stable across knob
  // values).  comp_bg_*: the flat dark background (gray pixels with g < 32)
  // - the decoded background tint (the user's "blue background").
  //
  // Round 2b (2026-09-09): per-class averages alone came back near-GRAY at
  // every knob (measured ~140,140,130) because each phase class contains
  // BOTH up-steps and down-steps (a character's left and right edges are 4
  // columns apart = the SAME class) and their chroma vectors are 180 deg
  // apart, so they cancel in the average.  Split by luma SLOPE instead: the
  // SPC=4 boxcar turns a 1-bit step into a ~4-sample luma ramp (the 4th,
  // full-bright window sample has zero chroma and fails the nongray gate),
  // so every nongray pixel sits on a ramp: slope g - g[s-2] > +16 = up-step
  // (bg -> text), < -16 = down-step.  comp_un/ur/ug/ub and comp_dn/dr/dg/db
  // (index = phase class) accumulate the up/down pixels separately.  The 4
  // up-class hues and 4 down-class hues each rotate rigidly -22.5 deg per
  // +16 knob; that rigid rotation is what the knob matrix needs.
  reg [19:0] comp_dark_n   = 20'd0;
  reg [23:0] comp_dark_sr  = 24'd0;
  reg [23:0] comp_dark_sg  = 24'd0;
  reg [23:0] comp_dark_sb  = 24'd0;
  reg [19:0] comp_bri_n    = 20'd0;
  reg [23:0] comp_bri_sr   = 24'd0;
  reg [23:0] comp_bri_sg   = 24'd0;
  reg [23:0] comp_bri_sb   = 24'd0;
  reg [19:0] comp_dark_na  = 20'd0;
  reg [23:0] comp_dark_sra = 24'd0;
  reg [23:0] comp_dark_sga = 24'd0;
  reg [23:0] comp_dark_sba = 24'd0;
  reg [19:0] comp_bri_na   = 20'd0;
  reg [23:0] comp_bri_sra  = 24'd0;
  reg [23:0] comp_bri_sga  = 24'd0;
  reg [23:0] comp_bri_sba  = 24'd0;
  // Phase-class + flat-background accumulators (matrix round 2, 2026-09-09).
  reg [19:0] comp_p0_n   = 20'd0;
  reg [23:0] comp_p0_sr  = 24'd0;
  reg [23:0] comp_p0_sg  = 24'd0;
  reg [23:0] comp_p0_sb  = 24'd0;
  reg [19:0] comp_p1_n   = 20'd0;
  reg [23:0] comp_p1_sr  = 24'd0;
  reg [23:0] comp_p1_sg  = 24'd0;
  reg [23:0] comp_p1_sb  = 24'd0;
  reg [19:0] comp_p2_n   = 20'd0;
  reg [23:0] comp_p2_sr  = 24'd0;
  reg [23:0] comp_p2_sg  = 24'd0;
  reg [23:0] comp_p2_sb  = 24'd0;
  reg [19:0] comp_p3_n   = 20'd0;
  reg [23:0] comp_p3_sr  = 24'd0;
  reg [23:0] comp_p3_sg  = 24'd0;
  reg [23:0] comp_p3_sb  = 24'd0;
  reg [19:0] comp_bg_n   = 20'd0;
  reg [23:0] comp_bg_sr  = 24'd0;
  reg [23:0] comp_bg_sg  = 24'd0;
  reg [23:0] comp_bg_sb  = 24'd0;
  reg [19:0] comp_p0_na  = 20'd0;
  reg [23:0] comp_p0_sra = 24'd0;
  reg [23:0] comp_p0_sga = 24'd0;
  reg [23:0] comp_p0_sba = 24'd0;
  reg [19:0] comp_p1_na  = 20'd0;
  reg [23:0] comp_p1_sra = 24'd0;
  reg [23:0] comp_p1_sga = 24'd0;
  reg [23:0] comp_p1_sba = 24'd0;
  reg [19:0] comp_p2_na  = 20'd0;
  reg [23:0] comp_p2_sra = 24'd0;
  reg [23:0] comp_p2_sga = 24'd0;
  reg [23:0] comp_p2_sba = 24'd0;
  reg [19:0] comp_p3_na  = 20'd0;
  reg [23:0] comp_p3_sra = 24'd0;
  reg [23:0] comp_p3_sga = 24'd0;
  reg [23:0] comp_p3_sba = 24'd0;
  reg [19:0] comp_bg_na  = 20'd0;
  reg [23:0] comp_bg_sra = 24'd0;
  reg [23:0] comp_bg_sga = 24'd0;
  reg [23:0] comp_bg_sba = 24'd0;
  // Up/down edge accumulators per phase class (round 2b).  Unpacked arrays:
  // with --public each element is C++-visible as tb_l2__DOT__<name>[i].
  reg [19:0] comp_un [0:3];
  reg [23:0] comp_ur [0:3];
  reg [23:0] comp_ug [0:3];
  reg [23:0] comp_ub [0:3];
  reg [19:0] comp_dn [0:3];
  reg [23:0] comp_dr [0:3];
  reg [23:0] comp_dg [0:3];
  reg [23:0] comp_db [0:3];
  reg [19:0] comp_una [0:3];
  reg [23:0] comp_ura [0:3];
  reg [23:0] comp_uga [0:3];
  reg [23:0] comp_uba [0:3];
  reg [19:0] comp_dna [0:3];
  reg [23:0] comp_dra [0:3];
  reg [23:0] comp_dga [0:3];
  reg [23:0] comp_dba [0:3];
  // Round 2c: raw demodulated I/Q per phase class.  Hierarchical tap into
  // the decoder's post-gain i8/q8 registers (BEFORE YIQ->RGB and the 0/255
  // clamps, which is why the post-RGB back-calculations were not rigid).
  // The sample set is UN-gated (pure geometry: the w_hbl window), so it is
  // knob-independent and each class sum rotates RIGIDLY with the hue knob
  // (the knob rotation is applied to every pixel's I/Q identically).
  // Flat pixels contribute ~0; the edge pixels dominate.  Signed 48 bits
  // cover ~240k samples x 131071 per frame.
  wire signed [17:0] comp_iq_i = comp_dut.u_dec.i8;
  wire signed [17:0] comp_iq_q = comp_dut.u_dec.q8;
  reg signed [47:0] comp_li8  [0:3];
  reg signed [47:0] comp_lq8  [0:3];
  reg signed [47:0] comp_li8u [0:3];
  reg signed [47:0] comp_lq8u [0:3];
  reg signed [47:0] comp_li8d [0:3];
  reg signed [47:0] comp_lq8d [0:3];
  reg signed [47:0] comp_ai8  [0:3];
  reg signed [47:0] comp_aq8  [0:3];
  reg signed [47:0] comp_ai8u [0:3];
  reg signed [47:0] comp_aq8u [0:3];
  reg signed [47:0] comp_ai8d [0:3];
  reg signed [47:0] comp_aq8d [0:3];
  reg [7:0]  comp_g_d1 = 8'd0;
  reg [7:0]  comp_g_d2 = 8'd0;
  // Sample index within the 912-sample line; the subcarrier phase class is
  // comp_lc[1:0] (4 samples per 3.58 MHz subcarrier cycle; the drift over a
  // line is ~0.1 samples, negligible for averaging).  Origin at the HBL
  // rise (fixed column grid -> the classes are identical across knob runs).
  reg [10:0] comp_lc = 11'd0;
  always @(negedge clk_14m) begin
    if (comp_hbl_rise) comp_lc <= 11'd0;
    else               comp_lc <= comp_lc + 11'd1;
  end
  wire [1:0] comp_ph4 = comp_lc[1:0];
  always @(negedge clk_14m) begin
    comp_g_d1 <= comp_g;
    comp_g_d2 <= comp_g_d1;
  end
  wire signed [8:0] comp_slope = $signed({1'b0, comp_g}) - $signed({1'b0, comp_g_d2});
  wire comp_ng = (comp_drg >  9'sd16 || comp_drg < -9'sd16 ||
                  comp_dgb >  9'sd16 || comp_dgb < -9'sd16);
  wire signed [8:0] comp_drg = $signed({1'b0, comp_r}) - $signed({1'b0, comp_g});
  wire signed [8:0] comp_dgb = $signed({1'b0, comp_g}) - $signed({1'b0, comp_b});
  // Round 2d: PEAK-pixel I/Q per phase class.  For each up/down edge run
  // (consecutive pixels with the same slope sign, |slope|>16), the
  // strongest-chroma pixel is the boxcar peak; every peak pixel in class c
  // points at the SAME I/Q angle 90c + Phi(K) (K = hue knob), so the
  // per-class sums are high-SNR rigid vectors: Phi(K) = angle(c) - 90c is
  // the palette constant, and K* = Phi(0)/1.40625 (mod 256) puts class 0
  // on the red (I) axis.  xchk latches the LO phase word and the encoder
  // burst counter at a fixed column: (P-B) mod 4 = s_p - s_b, so the raw
  // burst angle must be 225 + 90*(P-B) (the independent 225-deg check).
  wire [39:0] comp_chroma2 =
      {4'b0, $unsigned(comp_iq_i * comp_iq_i)} +
      {4'b0, $unsigned(comp_iq_q * comp_iq_q)};
  reg  [39:0] comp_pk2_u = 40'd0, comp_pk2_d = 40'd0;
  reg  [17:0] comp_pki_u = 18'sd0, comp_pkq_u = 18'sd0;
  reg  [17:0] comp_pki_d = 18'sd0, comp_pkq_d = 18'sd0;
  reg  [10:0] comp_pkcol_u = 11'd0, comp_pkcol_d = 11'd0;
  reg signed [47:0] comp_pki  [0:3];
  reg signed [47:0] comp_pkq  [0:3];
  reg signed [47:0] comp_pkid [0:3];
  reg signed [47:0] comp_pkqd [0:3];
  reg [19:0] comp_pkn_u [0:3];
  reg [19:0] comp_pkn_d [0:3];
  reg signed [47:0] comp_lpki   [0:3];
  reg signed [47:0] comp_lpq    [0:3];
  reg signed [47:0] comp_lpki_d [0:3];
  reg signed [47:0] comp_lpq_d  [0:3];
  reg [19:0] comp_lpn_u [0:3];
  reg [19:0] comp_lpn_d [0:3];
  reg [1:0]  comp_xP = 2'd0, comp_xB = 2'd0;
  reg [1:0]  comp_lxP = 2'd0, comp_lxB = 2'd0;
  reg signed [15:0] comp_lxib = 16'sd0, comp_lxqb = 16'sd0;
  always @(negedge clk_14m) begin: comp_stats
    if (vbl_p == 1'b1 && vbl_s == 1'b0) begin
      if (use_composite) begin
        comp_ink     <= comp_ci;
        comp_nongray <= comp_cn;
        comp_gmin    <= comp_gmin_a;
        comp_gmax    <= comp_gmax_a;
        comp_dark_n  <= comp_dark_na;
        comp_dark_sr <= comp_dark_sra;
        comp_dark_sg <= comp_dark_sga;
        comp_dark_sb <= comp_dark_sba;
        comp_bri_n   <= comp_bri_na;
        comp_bri_sr  <= comp_bri_sra;
        comp_bri_sg  <= comp_bri_sga;
        comp_bri_sb  <= comp_bri_sba;
        comp_p0_n    <= comp_p0_na;
        comp_p0_sr   <= comp_p0_sra;
        comp_p0_sg   <= comp_p0_sga;
        comp_p0_sb   <= comp_p0_sba;
        comp_p1_n    <= comp_p1_na;
        comp_p1_sr   <= comp_p1_sra;
        comp_p1_sg   <= comp_p1_sga;
        comp_p1_sb   <= comp_p1_sba;
        comp_p2_n    <= comp_p2_na;
        comp_p2_sr   <= comp_p2_sra;
        comp_p2_sg   <= comp_p2_sga;
        comp_p2_sb   <= comp_p2_sba;
        comp_p3_n    <= comp_p3_na;
        comp_p3_sr   <= comp_p3_sra;
        comp_p3_sg   <= comp_p3_sga;
        comp_p3_sb   <= comp_p3_sba;
        comp_bg_n    <= comp_bg_na;
        comp_bg_sr   <= comp_bg_sra;
        comp_bg_sg   <= comp_bg_sga;
        comp_bg_sb   <= comp_bg_sba;
        comp_un      <= comp_una;
        comp_ur      <= comp_ura;
        comp_ug      <= comp_uga;
        comp_ub      <= comp_uba;
        comp_dn      <= comp_dna;
        comp_dr      <= comp_dra;
        comp_dg      <= comp_dga;
        comp_db      <= comp_dba;
        comp_li8     <= comp_ai8;
        comp_lq8     <= comp_aq8;
        comp_li8u    <= comp_ai8u;
        comp_lq8u    <= comp_aq8u;
        comp_li8d    <= comp_ai8d;
        comp_lq8d    <= comp_aq8d;
        comp_lpki    <= comp_pki;
        comp_lpq     <= comp_pkq;
        comp_lpki_d  <= comp_pkid;
        comp_lpq_d   <= comp_pkqd;
        comp_lpn_u   <= comp_pkn_u;
        comp_lpn_d   <= comp_pkn_d;
        comp_lxP     <= comp_xP;
        comp_lxB     <= comp_xB;
        comp_lxib    <= comp_dut.u_dec.ib;
        comp_lxqb    <= comp_dut.u_dec.qb;
      end
      comp_ci     <= 20'd0;
      comp_cn     <= 20'd0;
      comp_gmin_a <= 8'hFF;
      comp_gmax_a <= 8'h00;
      comp_dark_na  <= 20'd0;
      comp_dark_sra <= 24'd0;
      comp_dark_sga <= 24'd0;
      comp_dark_sba <= 24'd0;
      comp_bri_na   <= 20'd0;
      comp_bri_sra  <= 24'd0;
      comp_bri_sga  <= 24'd0;
      comp_bri_sba  <= 24'd0;
      comp_p0_na    <= 20'd0;
      comp_p0_sra   <= 24'd0;
      comp_p0_sga   <= 24'd0;
      comp_p0_sba   <= 24'd0;
      comp_p1_na    <= 20'd0;
      comp_p1_sra   <= 24'd0;
      comp_p1_sga   <= 24'd0;
      comp_p1_sba   <= 24'd0;
      comp_p2_na    <= 20'd0;
      comp_p2_sra   <= 24'd0;
      comp_p2_sga   <= 24'd0;
      comp_p2_sba   <= 24'd0;
      comp_p3_na    <= 20'd0;
      comp_p3_sra   <= 24'd0;
      comp_p3_sga   <= 24'd0;
      comp_p3_sba   <= 24'd0;
      comp_bg_na    <= 20'd0;
      comp_bg_sra   <= 24'd0;
      comp_bg_sga   <= 24'd0;
      comp_bg_sba   <= 24'd0;
      comp_una      <= '{default: 20'd0};
      comp_ura      <= '{default: 24'd0};
      comp_uga      <= '{default: 24'd0};
      comp_uba      <= '{default: 24'd0};
      comp_dna      <= '{default: 20'd0};
      comp_dra      <= '{default: 24'd0};
      comp_dga      <= '{default: 24'd0};
      comp_dba      <= '{default: 24'd0};
      comp_ai8      <= '{default: 48'sd0};
      comp_aq8      <= '{default: 48'sd0};
      comp_ai8u     <= '{default: 48'sd0};
      comp_aq8u     <= '{default: 48'sd0};
      comp_ai8d     <= '{default: 48'sd0};
      comp_aq8d     <= '{default: 48'sd0};
      comp_pki      <= '{default: 48'sd0};
      comp_pkq      <= '{default: 48'sd0};
      comp_pkid     <= '{default: 48'sd0};
      comp_pkqd     <= '{default: 48'sd0};
      comp_pkn_u    <= '{default: 20'd0};
      comp_pkn_d    <= '{default: 20'd0};
    end else if (use_composite && w_hbl == 1'b0) begin
      if (comp_g >= 8'd128) comp_ci <= comp_ci + 20'd1;
      if (comp_g <  comp_gmin_a) comp_gmin_a <= comp_g;
      if (comp_g >  comp_gmax_a) comp_gmax_a <= comp_g;
      if (comp_ng) begin
        comp_cn <= comp_cn + 20'd1;
        if (comp_g < 8'd64) begin
          comp_dark_na  <= comp_dark_na + 20'd1;
          comp_dark_sra <= comp_dark_sra + {16'd0, comp_r};
          comp_dark_sga <= comp_dark_sga + {16'd0, comp_g};
          comp_dark_sba <= comp_dark_sba + {16'd0, comp_b};
        end else if (comp_g >= 8'd128) begin
          comp_bri_na   <= comp_bri_na + 20'd1;
          comp_bri_sra  <= comp_bri_sra + {16'd0, comp_r};
          comp_bri_sga  <= comp_bri_sga + {16'd0, comp_g};
          comp_bri_sba  <= comp_bri_sba + {16'd0, comp_b};
        end
        case (comp_ph4)
          2'd0: begin
            comp_p0_na  <= comp_p0_na + 20'd1;
            comp_p0_sra <= comp_p0_sra + {16'd0, comp_r};
            comp_p0_sga <= comp_p0_sga + {16'd0, comp_g};
            comp_p0_sba <= comp_p0_sba + {16'd0, comp_b};
          end
          2'd1: begin
            comp_p1_na  <= comp_p1_na + 20'd1;
            comp_p1_sra <= comp_p1_sra + {16'd0, comp_r};
            comp_p1_sga <= comp_p1_sga + {16'd0, comp_g};
            comp_p1_sba <= comp_p1_sba + {16'd0, comp_b};
          end
          2'd2: begin
            comp_p2_na  <= comp_p2_na + 20'd1;
            comp_p2_sra <= comp_p2_sra + {16'd0, comp_r};
            comp_p2_sga <= comp_p2_sga + {16'd0, comp_g};
            comp_p2_sba <= comp_p2_sba + {16'd0, comp_b};
          end
          2'd3: begin
            comp_p3_na  <= comp_p3_na + 20'd1;
            comp_p3_sra <= comp_p3_sra + {16'd0, comp_r};
            comp_p3_sga <= comp_p3_sga + {16'd0, comp_g};
            comp_p3_sba <= comp_p3_sba + {16'd0, comp_b};
          end
        endcase
        if (comp_slope > 9'sd16) begin
          comp_una[comp_ph4]  <= comp_una[comp_ph4]  + 20'd1;
          comp_ura[comp_ph4]  <= comp_ura[comp_ph4]  + {16'd0, comp_r};
          comp_uga[comp_ph4]  <= comp_uga[comp_ph4]  + {16'd0, comp_g};
          comp_uba[comp_ph4]  <= comp_uba[comp_ph4]  + {16'd0, comp_b};
        end else if (comp_slope < -9'sd16) begin
          comp_dna[comp_ph4]  <= comp_dna[comp_ph4]  + 20'd1;
          comp_dra[comp_ph4]  <= comp_dra[comp_ph4]  + {16'd0, comp_r};
          comp_dga[comp_ph4]  <= comp_dga[comp_ph4]  + {16'd0, comp_g};
          comp_dba[comp_ph4]  <= comp_dba[comp_ph4]  + {16'd0, comp_b};
        end
        // Round 2c: un-gated I/Q class sums (rigid-rotation measurement).
        comp_ai8[comp_ph4] <= comp_ai8[comp_ph4] + comp_iq_i;
        comp_aq8[comp_ph4] <= comp_aq8[comp_ph4] + comp_iq_q;
        if (comp_slope > 9'sd16) begin
          comp_ai8u[comp_ph4] <= comp_ai8u[comp_ph4] + comp_iq_i;
          comp_aq8u[comp_ph4] <= comp_aq8u[comp_ph4] + comp_iq_q;
        end else if (comp_slope < -9'sd16) begin
          comp_ai8d[comp_ph4] <= comp_ai8d[comp_ph4] + comp_iq_i;
          comp_aq8d[comp_ph4] <= comp_aq8d[comp_ph4] + comp_iq_q;
        end
        // Round 2d: per-run peak tracking + cross-check latches.
        if (comp_lc == 11'd500) begin
          comp_xP <= comp_dut.u_dec.phase[23:22];
          comp_xB <= comp_dut.burst_cnt;
        end
        if (comp_slope > 9'sd16) begin
          if (comp_chroma2 > comp_pk2_u) begin
            comp_pk2_u   <= comp_chroma2;
            comp_pki_u   <= comp_iq_i;
            comp_pkq_u   <= comp_iq_q;
            comp_pkcol_u <= comp_lc;
          end
        end else begin
          if (comp_pk2_u > 40'd4096) begin
            comp_pki[comp_pkcol_u[1:0]] <=
                comp_pki[comp_pkcol_u[1:0]] + comp_pki_u;
            comp_pkq[comp_pkcol_u[1:0]] <=
                comp_pkq[comp_pkcol_u[1:0]] + comp_pkq_u;
            comp_pkn_u[comp_pkcol_u[1:0]] <=
                comp_pkn_u[comp_pkcol_u[1:0]] + 20'd1;
          end
          comp_pk2_u <= 40'd0;
        end
        if (comp_slope < -9'sd16) begin
          if (comp_chroma2 > comp_pk2_d) begin
            comp_pk2_d   <= comp_chroma2;
            comp_pki_d   <= comp_iq_i;
            comp_pkq_d   <= comp_iq_q;
            comp_pkcol_d <= comp_lc;
          end
        end else begin
          if (comp_pk2_d > 40'd4096) begin
            comp_pkid[comp_pkcol_d[1:0]] <=
                comp_pkid[comp_pkcol_d[1:0]] + comp_pki_d;
            comp_pkqd[comp_pkcol_d[1:0]] <=
                comp_pkqd[comp_pkcol_d[1:0]] + comp_pkq_d;
            comp_pkn_d[comp_pkcol_d[1:0]] <=
                comp_pkn_d[comp_pkcol_d[1:0]] + 20'd1;
          end
          comp_pk2_d <= 40'd0;
        end
      end else if (comp_g < 8'd32) begin
        // flat dark background (gray core of the 1-bit picture)
        comp_bg_na  <= comp_bg_na + 20'd1;
        comp_bg_sra <= comp_bg_sra + {16'd0, comp_r};
        comp_bg_sga <= comp_bg_sga + {16'd0, comp_g};
        comp_bg_sba <= comp_bg_sba + {16'd0, comp_b};
      end
    end
  end

  // ------------------------------------------------------------------
  // Diagnostics
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
        if (main_ram.mem[16'h0400 + si] !== 8'h00) n = n + 1;
      screen_ink <= n;
    end
  end

  // Disk-activity counters (C++ reads): drive 1 motor spin-ups, track
  // loads (t1_busy rising edges), and host sector writes (sd_buff_wr).
  reg d1_motor_p = 1'b0;
  reg t1_busy_p  = 1'b0;
  reg [31:0] dbg_motor1_cnt = 32'd0;
  reg [31:0] dbg_track1_cnt = 32'd0;
  reg [31:0] dbg_sdwr_cnt   = 32'd0;
  reg [31:0] dbg_rd1_cnt    = 32'd0;   // drive-1 sd_rd request pulses seen

  // Slot-6 (disk_ii) read capture: the machine reads the disk_ii at
  // $C600-$C6FF (ioselect[6] = A[10:8]==6).  Capture the low address byte
  // and the data returned (disk_do) on every such read, plus a counter.
  // This shows exactly which soft switch / data register the machine is
  // polling in its post-homing stall loop.
  reg [15:0] dbg_io6_cnt   = 16'd0;
  reg [7:0]  dbg_io6_addr  = 8'd0;
  reg [7:0]  dbg_io6_data  = 8'd0;
  always @(posedge clk_14m) begin: io6_cap
    if (w_io_sel[6]) begin
      dbg_io6_cnt  <= dbg_io6_cnt + 16'd1;
      dbg_io6_addr <= w_addr[7:0];
      dbg_io6_data <= disk_do;
    end
  end

  // Devselect[6] (disk_ii data register / read_disk port) read capture.
  // The machine reads the disk_ii's data register at $C0E0-$C0EF
  // (devselect[6], A[6:4]==6). The $C0EC read returns the MFM-decoded
  // byte (data_reg). Capture the low address nibble and the data returned
  // (disk_do) on every such read. This shows whether the machine is
  // reading valid disk data (the data_reg) or stuck on a constant value.
  reg [15:0] dbg_dev6_cnt   = 16'd0;
  reg [7:0]  dbg_dev6_addr  = 8'd0;
  reg [7:0]  dbg_dev6_data  = 8'd0;
  always @(posedge clk_14m) begin: dev6_cap
    if (w_dev_sel[6]) begin
      dbg_dev6_cnt  <= dbg_dev6_cnt + 16'd1;
      dbg_dev6_addr <= w_addr[3:0];
      dbg_dev6_data <= disk_do;
    end
  end

  // ------------------------------------------------------------------
  // $C0EC data-read history (added for the sync-search debug, 2026-09-05):
  // the 64 most recent values the CPU read from the disk_ii data register
  // ($C0EC = devselect[6] & A[3:0]==C, CPU read only), plus a total-read
  // counter and per-byte counters for the sync-search bytes D5/AA/96.
  // The bootstrap ($C65E-$C663) scans this stream for the D5 AA 96 sync
  // prefix; the history shows whether the stream the CPU actually sees
  // contains the sync bytes, and in what order.
  // ------------------------------------------------------------------
  reg [7:0]  dbg_c0ec_hist [0:63];
  reg [5:0]  dbg_c0ec_idx  = 6'd0;
  reg [31:0] dbg_c0ec_cnt  = 32'd0;
  reg [31:0] dbg_c0ec_d5   = 32'd0;
  reg [31:0] dbg_c0ec_aa   = 32'd0;
  reg [31:0] dbg_c0ec_96   = 32'd0;
  always @(posedge clk_14m) begin: c0ec_hist_cap
    if (w_dev_sel[6] && w_addr[3:0] == 4'hC && !w_cpu_we) begin
      dbg_c0ec_cnt <= dbg_c0ec_cnt + 32'd1;
      dbg_c0ec_hist[dbg_c0ec_idx] <= disk_do;
      dbg_c0ec_idx <= dbg_c0ec_idx + 6'd1;
      if (disk_do == 8'hD5) dbg_c0ec_d5 <= dbg_c0ec_d5 + 32'd1;
      if (disk_do == 8'hAA) dbg_c0ec_aa <= dbg_c0ec_aa + 32'd1;
      if (disk_do == 8'h96) dbg_c0ec_96 <= dbg_c0ec_96 + 32'd1;
    end
  end

  // DOS boot-block RAM checksum ($0800-$0BFF, 1 KiB). The DOS boot
  // sector is loaded into this region (NOT the text page $0400-$07BF).
  // A changing non-zero checksum indicates the machine is actually
  // loading the boot block into RAM (i.e., really booting) rather than
  // idling in the data-register poll loop with an empty RAM.
  reg [31:0] dbg_boot_sum = 32'd0;
  reg [15:0] dbg_boot_nz  = 16'd0;
  integer    bi;
  always @(posedge clk_14m) begin: boot_sum
    dbg_boot_sum = 32'd0;
    dbg_boot_nz  = 16'd0;
    for (bi = 0; bi < 1024; bi = bi + 1) begin
      if (main_ram.mem[16'h0800 + bi] !== 8'h00) begin
        dbg_boot_sum = dbg_boot_sum + {24'd0, main_ram.mem[16'h0800 + bi]};
        dbg_boot_nz  = dbg_boot_nz + 16'd1;
      end
    end
  end
  always @(posedge clk_14m) begin: disk_diag
    d1_motor_p <= d1_motor_on;
    t1_busy_p  <= t1_busy;
    if (d1_motor_on && !d1_motor_p) dbg_motor1_cnt <= dbg_motor1_cnt + 32'd1;
    if (t1_busy   && !t1_busy_p)    dbg_track1_cnt <= dbg_track1_cnt + 32'd1;
    if (sd_buff_wr)                 dbg_sdwr_cnt   <= dbg_sdwr_cnt + 32'd1;
    if (sd_rd[0])                   dbg_rd1_cnt    <= dbg_rd1_cnt + 32'd1;
  end

  // ------------------------------------------------------------------
  // Keyboard-chain diagnostics (GUI, 2026-09-06): count the DUT's $CNOP
  // reads of the keyboard, capture the K byte of the last read, and
  // count the master cycles the keyboard reports a key down (akd).
  // These let the GUI harness verify the C++-written module-scope
  // `ps2_key` reg reached the keyboard module in the LEGACY eval build
  // (the port-promotion trap above applies to cones fed by C++-written
  // regs; the GUI's per-half-cycle frame check and the --selfkey smoke
  // both rely on these).
  // ------------------------------------------------------------------
  reg [31:0] dbg_rd_cnt  = 32'd0;
  reg [7:0]  dbg_rd_k    = 8'd0;
  reg [31:0] dbg_akd_cnt = 32'd0;
  always @(posedge clk_14m) begin: kb_diag
    if (read_key) begin
      dbg_rd_cnt <= dbg_rd_cnt + 32'd1;
      dbg_rd_k   <= kb_K;
    end
    if (kb_akd)
      dbg_akd_cnt <= dbg_akd_cnt + 32'd1;
  end

  // ------------------------------------------------------------------
  // CLK_2M decode-gate probe: does the 2 MHz edge clock reach the
  // drive_ii, and is DISK_READY & DISK_ACTIVE high on those edges?
  // dbg_2m_cnt        = total w_clk_2m rising edges
  // dbg_2m_active_cnt = rising edges with disk_ready[0] & d1_active
  // dbg_2m_do         = t1_do (TRACK_DO) captured on last active edge
  // dbg_2m_addr       = t1_addr captured on last active edge
  // dbg_2m_do_nz      = 1 if dbg_2m_do was ever non-zero
  // ------------------------------------------------------------------
  reg [31:0] dbg_2m_cnt        = 32'd0;
  reg [31:0] dbg_2m_active_cnt = 32'd0;
  reg [7:0]  dbg_2m_do         = 8'd0;
  reg [12:0] dbg_2m_addr       = 13'd0;
  reg        dbg_2m_do_nz      = 1'b0;
  reg        w_clk_2m_d        = 1'b0;
  wire       w_clk_2m_rise     = (w_clk_2m == 1'b1) && (w_clk_2m_d == 1'b0);
  wire       w_2m_decode_gate  = w_clk_2m_rise && disk_ready[0] && d1_active;
  always @(posedge clk_14m) begin: clk2m_probe
    w_clk_2m_d <= w_clk_2m;
    if (w_clk_2m_rise) dbg_2m_cnt <= dbg_2m_cnt + 32'd1;
    if (w_2m_decode_gate) begin
      dbg_2m_active_cnt <= dbg_2m_active_cnt + 32'd1;
      dbg_2m_do         <= t1_do;
      dbg_2m_addr       <= t1_addr;
      if (t1_do != 8'd0) dbg_2m_do_nz <= 1'b1;
    end
  end

  // ------------------------------------------------------------------
  // t1_addr transition + dpram write-commit counters (diagnostics):
  // how the drive's 13-bit address actually moves each cycle (increment
  // / decrement / wrap 0x19FF->0 / jump-to-zero = reset), and how many
  // writes really commit on each dpram port (A = host sectors, B = drive
  // writes).  A healthy read path needs: port-A commits > 0 AND
  // track_byte_addr sweeping through the written windows.
  // ------------------------------------------------------------------
  reg [12:0] t1_addr_d     = 13'd0;
  reg [31:0] dbg_t1a_inc   = 32'd0;   // old->old+1 (normal step)
  reg [31:0] dbg_t1a_dec   = 32'd0;   // any other fall (should not happen)
  reg [31:0] dbg_t1a_wr    = 32'd0;   // wrap 0x19FF -> 0
  reg [31:0] dbg_t1a_rst   = 32'd0;   // transition to 0 from nonzero (RESET)
  reg [31:0] dbg_t1a_nz    = 32'd0;   // cycles with t1_addr != 0
  reg [31:0] dbg_rst1_cnt  = 32'd0;   // cycles with reset_sync == 1
  reg [31:0] dbg_rst_rise  = 32'd0;   // reset_sync 0->1 transitions
  reg        rst_d         = 1'b0;
  reg [31:0] dbg_wra_cnt   = 32'd0;   // dpram port-A write commits (host)
  reg [31:0] dbg_wra_nz    = 32'd0;   // ...with nonzero data
  reg [12:0] dbg_wra_addr  = 13'd0;   // last committed port-A address
  reg [7:0]  dbg_wra_data  = 8'd0;    // last committed port-A data
  reg [31:0] dbg_wrb_cnt   = 32'd0;   // dpram port-B write commits (drive)
  reg [31:0] dbg_wri_cnt   = 32'd0;   // debug-injection write ticks (write-test)
  always @(posedge clk_14m) begin: t1a_probe
    t1_addr_d <= t1_addr;
    rst_d     <= reset_sync;
    if (t1_addr_d == 13'h19FF && t1_addr == 13'd0)          dbg_t1a_wr  <= dbg_t1a_wr + 1;
    else if (t1_addr_d != 13'd0 && t1_addr == 13'd0)        dbg_t1a_rst <= dbg_t1a_rst + 1;
    else if (t1_addr == t1_addr_d + 13'd1)                  dbg_t1a_inc <= dbg_t1a_inc + 1;
    else if (t1_addr < t1_addr_d)                           dbg_t1a_dec <= dbg_t1a_dec + 1;
    if (t1_addr != 13'd0)                                   dbg_t1a_nz  <= dbg_t1a_nz + 1;
    if (reset_sync)                                         dbg_rst1_cnt <= dbg_rst1_cnt + 1;
    if (reset_sync && !rst_d)                               dbg_rst_rise <= dbg_rst_rise + 1;
    if (sd_buff_wr & sd_ack) begin
      dbg_wra_cnt  <= dbg_wra_cnt + 1;
      if (sd_buff_dout != 8'd0) dbg_wra_nz <= dbg_wra_nz + 1;
      dbg_wra_addr <= sd_buff_addr;
      dbg_wra_data <= sd_buff_dout;
    end
    if (t1_we) dbg_wrb_cnt <= dbg_wrb_cnt + 1;
    if (dbg_ft_wr_en) dbg_wri_cnt <= dbg_wri_cnt + 32'd1;
  end

  // ------------------------------------------------------------------
  // Host-read signal capture (1-cycle registered).  These signals are
  // driven by the floppy_track/disk_ii and consumed ONLY by the C++ host,
  // so Verilator can prune/alias the raw wires (the C++ field would stay
  // stale - the same trap level_1 hit with the VGA outputs, see
  // tb_l1_gui.sv:271-282).  The C++ reads these registers instead.  The
  // 1-cycle delay is harmless: floppy_track holds sd_rd high until the
  // host acks, so the host may react one cycle later.
  // ------------------------------------------------------------------
  reg [1:0]  h_sd_rd           = 2'b0;
  reg [1:0]  h_sd_wr           = 2'b0;
  reg [31:0] h_sd_lba_a        = 32'd0;
  reg [31:0] h_sd_lba_b        = 32'd0;
  reg [7:0]  h_sd_buff_din_a   = 8'd0;
  reg [7:0]  h_sd_buff_din_b   = 8'd0;
  reg [1:0]  h_disk_ready      = 2'b0;
  reg        h_d1_active       = 1'b0;
  reg        h_d1_motor_on     = 1'b0;
  reg        h_d1_io_active    = 1'b0;
  reg        h_d1_step_active  = 1'b0;
  reg        h_d1_trk0_step    = 1'b0;
  reg [5:0]  h_d1_track        = 6'd0;
  reg        h_t1_busy         = 1'b0;   // ft1 flush/load busy (write-test)
  always @(posedge clk_14m) begin: host_read_cap
    h_sd_rd           <= sd_rd;
    h_sd_wr           <= sd_wr;
    h_sd_lba_a        <= sd_lba_a;
    h_sd_lba_b        <= sd_lba_b;
    h_sd_buff_din_a   <= sd_buff_din_a;
    h_sd_buff_din_b   <= sd_buff_din_b;
    h_disk_ready      <= disk_ready;
    h_d1_active       <= d1_active;
    h_d1_motor_on     <= d1_motor_on;
    h_d1_io_active    <= d1_io_active;
    h_d1_step_active  <= d1_step_active;
    h_d1_trk0_step    <= d1_track_zero_step;
    h_d1_track        <= t1_track;
    h_t1_busy         <= t1_busy;
  end

  // ------------------------------------------------------------------
  // Disk slot 6 CPU port access logger (debug).
  // Captures the CPU's actual accesses to the Disk II slot so we can
  // see (a) which ports the firmware touches, (b) the raw data bytes
  // the CPU reads ($C08C), and (c) the control writes (motor/step).
  // ------------------------------------------------------------------
  reg [31:0]   io6_total      = 32'd0;
  reg [31:0]   io6_ioread     = 32'd0;
  reg [31:0]   io6_devrd      = 32'd0;
  reg [31:0]   io6_devwr      = 32'd0;
  reg [31:0]   io6_data_cnt   = 32'd0;
  reg [7:0]    io6_last_addr  = 8'd0;
  reg [7:0]    io6_last_dout  = 8'd0;
  reg [7:0]    io6_last_din   = 8'd0;
  reg [3:0]    io6_last_kind  = 4'd0;    // 1=io, 2=devrd, 3=devwr
  reg [7:0]    io6_io_min     = 8'd255;
  reg [7:0]    io6_io_max     = 8'd0;
  reg [7:0]    io6_iobmp [0:31];   // bitmap of IO-table indices used
  reg [7:0]    io6_data_log [0:127]; // 128 x 8-bit disk_do at $C08C
  reg [6:0]    io6_data_idx   = 7'd0;
  reg [15:0]   io6_wr_log [0:31];  // 32 x 16-bit {addr, din} writes
  reg [4:0]    io6_wr_idx     = 5'd0;
  always @(posedge clk_14m) begin: io6_log
    if (w_io_sel[6] || w_dev_sel[6]) begin
      io6_total     <= io6_total + 1'b1;
      io6_last_addr <= w_addr[7:0];
      io6_last_dout <= disk_do;
      io6_last_din  <= w_ram_di;
      if (w_io_sel[6]) begin
        io6_ioread    <= io6_ioread + 1'b1;
        io6_last_kind <= 4'd1;
        io6_iobmp[w_addr[7:0][5:0]] <=
            io6_iobmp[w_addr[7:0][5:0]] | (8'd1 << w_addr[7:0][2:0]);
        if (w_addr[7:0] < io6_io_min) io6_io_min <= w_addr[7:0];
        if (w_addr[7:0] > io6_io_max) io6_io_max <= w_addr[7:0];
      end else begin
        io6_last_kind <= w_cpu_we ? 4'd3 : 4'd2;
        if (w_cpu_we) begin
          io6_devwr  <= io6_devwr + 1'b1;
          io6_wr_log[io6_wr_idx[4:0]] <= {w_addr[7:0], w_ram_di};
          io6_wr_idx <= io6_wr_idx + 1'b1;
        end else begin
          io6_devrd  <= io6_devrd + 1'b1;
          if (w_addr[3:0] == 4'hC) begin
            io6_data_cnt   <= io6_data_cnt + 1'b1;
            io6_data_log[io6_data_idx[6:0]] <= disk_do;
            io6_data_idx   <= io6_data_idx + 1'b1;
          end
        end
      end
    end
  end

  // ------------------------------------------------------------------
  // Module-scope error counter (C++ checks; 0 = pass).  The C++ harness
  // does the per-scenario pass/fail logic; this is reserved for TB-
  // internal faults.
  // ------------------------------------------------------------------
  reg [15:0] errors = 16'd0;

endmodule
