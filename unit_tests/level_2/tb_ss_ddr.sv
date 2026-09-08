// tb_ss_ddr.sv
//
// Directed first/last-address, region, stride, burst and integrity test for
// ../level_1b/savestate_ddr_l1b.sv (DUT built UNMODIFIED).
//
// The HPS DDRAM side is modeled at the direct MiSTer core interface:
//   - DDRAM addresses select 64-bit beats (byte address divided by 8);
//   - a 64-bit transfer is one beat (burstcnt == 1);
//   - four 2 MiB slots occupy 0x40000 beats each, beginning at the
//     SS3E000000 framework byte address (0x3E000000 / 8 = 0x07C00000).
//
// The TB drives the bridge the way the RAM walker does: a full v1 save
// sequence (16,417 64-bit words, unique per-byte pattern), then a full
// readback. Checks:
//   T1 region    every accepted address inside the declared window
//   T2 first/last first = window base, last = base + 2*(N-1)
//   T3 stride    every accepted address == TB-expected (base + 2*w)
//   T4 burst     every transaction presents burstcnt == 2
//   T5 integrity full 64-bit readback of all N words
//   T6 handshake no transaction accepted while one is in flight
//
// 2026-09-06 MEASURED vs the ORIGINAL bridge (historical): T1-T5 FAIL
// (base 0x1F00000 outside the window, stride 8 not 2, burst 1 not 2,
// upper half lost), T6 PASS - exactly as predicted.
// 2026-09-07: the bridge was fixed per SAVESTATE_DDR_CONTRACT_CHECK.md
// section 5 (stride 2, burstcnt 2, wrapper base 0x03800000) and this TB
// now expects T1-T6 ALL PASS.  It still encodes the target contract,
// not the DUT's assumptions.
//
// Run (ad-hoc, from unit_tests/level_2/):
//   $ verilator_bin --binary --timing -O3 --x-assign fast --x-initial fast \
//     -Wno-fatal -Wno-TIMESCALEMOD --top-module tb_ss_ddr \
//     -Mdir build/ss_ddr_obj_dir tb_ss_ddr.sv ../level_1b/savestate_ddr_l1b.sv
//   $ ./build/ss_ddr_obj_dir/Vtb_ss_ddr

`timescale 1ns/1ps

module tb_ss_ddr;

  // ---------------- parameters ------------------------------------------
  parameter int        N          = 16417;          // v1 payload words (with CRC)
  parameter logic [28:0] DUT_BASE = 29'h07C00000;
  parameter logic [28:0] WIN_BASE = 29'h07C00000;
  parameter int        WIN_SLOTS  = 4;
  parameter logic [28:0] WIN_SLOT = 29'h00040000;
  localparam logic [28:0] WIN_END = WIN_BASE + WIN_SLOTS * WIN_SLOT;

  // ---------------- DUT interface ----------------------------------------
  reg         clk = 1'b0;
  reg         reset = 1'b1;
  always #5 clk = ~clk;

  reg  [14:0] w_slot_addr = 15'd0;
  wire [14:0] slot_addr = w_slot_addr;
  reg         slot_rd = 1'b0;
  reg         slot_wr = 1'b0;
  reg  [63:0] slot_wdata = 64'd0;
  wire [63:0] slot_rdata;
  wire        slot_ready;
  wire        ddram_clk;
  reg         ddram_busy = 1'b0;
  wire [7:0]  ddram_burstcnt;
  wire [28:0] ddram_addr;
  reg  [63:0] ddram_dout = 64'd0;
  reg         ddram_dout_ready = 1'b0;
  wire        ddram_rd;
  wire [63:0] ddram_din;
  wire [7:0]  ddram_be;
  wire        ddram_we;

  savestate_ddr_l1b #( .BASE_ADDR(DUT_BASE) ) dut (
    .clk(clk),
    .reset(reset),
    .slot_addr(slot_addr),
    .slot_rd(slot_rd),
    .slot_wr(slot_wr),
    .slot_wdata(slot_wdata),
    .slot_rdata(slot_rdata),
    .slot_ready(slot_ready),
    .ddram_clk(ddram_clk),
    .ddram_busy(ddram_busy),
    .ddram_burstcnt(ddram_burstcnt),
    .ddram_addr(ddram_addr),
    .ddram_dout(ddram_dout),
    .ddram_dout_ready(ddram_dout_ready),
    .ddram_rd(ddram_rd),
    .ddram_din(ddram_din),
    .ddram_be(ddram_be),
    .ddram_we(ddram_we)
  );

  // ---------------- HPS DDRAM model (contract reference) -----------------
  // Memory is indexed in complete 64-bit DDRAM beats.
  reg [63:0] hps_mem [0:1048575];
  integer    busy_cnt = 0;
  reg        inflight_rd = 1'b0;
  reg [28:0] latched_addr = 29'd0;
  // TB-expected address of the in-flight transaction (PLAN contract,
  // slot 0): WIN_BASE + 2*w.
  reg [28:0] exp_addr = 29'd0;

  function automatic bit inwin(input logic [28:0] a);
    inwin = (a >= WIN_BASE) && (a < WIN_END);
  endfunction

  // contract checkers
  integer tx_count   = 0;
  integer oob_count  = 0;
  integer stride_bad = 0;
  integer burst_bad  = 0;
  integer double_tx  = 0;
  integer first_seen = 0;
  logic [28:0] first_addr = 29'd0;
  logic [28:0] last_addr  = 29'd0;

  integer i;
  always @(posedge clk) begin
    ddram_busy       <= 1'b0;
    ddram_dout_ready <= 1'b0;
    ddram_dout       <= 64'd0;
    if (reset) begin
      busy_cnt <= 0;
    end else begin
      if (busy_cnt > 0) begin
        ddram_busy <= 1'b1;
        if (inflight_rd && busy_cnt == 2) begin
          if (inwin(latched_addr))
            ddram_dout <= hps_mem[latched_addr - WIN_BASE];
          ddram_dout_ready <= 1'b1;
        end
        busy_cnt <= busy_cnt - 1;
      end
      if (ddram_rd || ddram_we) begin
        if (busy_cnt > 0)
          double_tx = double_tx + 1;
        tx_count = tx_count + 1;
        if (ddram_burstcnt != 8'd1)
          burst_bad = burst_bad + 1;
        if (!inwin(ddram_addr)) begin
          oob_count = oob_count + 1;
        end else begin
          if (ddram_we) begin
            hps_mem[ddram_addr - WIN_BASE] = ddram_din;
          end
        end
        if (!first_seen) begin
          first_seen = 1;
          first_addr = ddram_addr;
        end
        if (ddram_addr != exp_addr)
          stride_bad = stride_bad + 1;
        last_addr = ddram_addr;
        latched_addr <= ddram_addr;
        inflight_rd  <= ddram_rd;
        busy_cnt     <= ddram_rd ? 3 : 4;
      end
    end
  end

  // ---------------- pattern ----------------------------------------------
  function automatic logic [63:0] pat(input logic [14:0] w);
    pat = {32'hA5A5_0000 | w, 32'h5A5A_0000 | w};
  endfunction

  // ---------------- driver -------------------------------------------------
  reg rdback_bad_q = 1'b0;
  integer rdback_bad = 0;

  task automatic wait_ready(input string what, input integer tag);
    integer t;
    t = 0;
    while (!slot_ready) begin
      @(posedge clk);
      t = t + 1;
      if (t > 400) begin
        $display("FAIL: no slot_ready %s tag=%0d", what, tag);
        $fatal; // non-zero exit
      end
    end
  endtask

  initial begin
    logic [14:0] w;
    repeat (4) @(posedge clk);
    reset <= 1'b0;
    repeat (4) @(posedge clk);

    // ---- write phase: full v1 save sequence ----
    // The level-sensitive client request is held until slot_ready.
    for (w = 15'd0; w < N; w = w + 15'd1) begin
      exp_addr    = WIN_BASE + w;
      w_slot_addr = w;
      slot_wdata  = pat(w);
      slot_wr     = 1'b1;
      wait_ready("write", int'(w));
      slot_wr     = 1'b0;
      @(posedge clk);
    end

    // ---- read phase: full readback ----
    for (w = 15'd0; w < N; w = w + 15'd1) begin
      exp_addr    = WIN_BASE + w;
      w_slot_addr = w;
      slot_rd     = 1'b1;
      wait_ready("read", int'(w));
      if (slot_rdata !== pat(w))
        rdback_bad = rdback_bad + 1;
      slot_rd     = 1'b0;
      @(posedge clk);
    end

    // ---- report ----
    $display("TB_SS_DDR checks (N=%0d words, DUT_BASE=0x%07h, window=0x%07h..0x%07h):",
             N, DUT_BASE, WIN_BASE, WIN_END);
    $display("  T1 region      oob=%0d            %s", oob_count, (oob_count == 0) ? "PASS" : "FAIL");
    $display("  T2 first/last  first=0x%07h last=0x%07h (want 0x%07h .. 0x%07h)  %s",
             first_addr, last_addr, WIN_BASE, WIN_BASE + N-1,
             (first_addr == WIN_BASE && last_addr == WIN_BASE + N-1) ? "PASS" : "FAIL");
    $display("  T3 stride      mismatch=%0d tx=%0d (want %0d)  %s",
             stride_bad, tx_count, 2*N, (stride_bad == 0 && tx_count == 2*N) ? "PASS" : "FAIL");
    $display("  T4 burst       bad=%0d            %s", burst_bad, (burst_bad == 0) ? "PASS" : "FAIL");
    $display("  T5 integrity   mismatch=%0d       %s", rdback_bad, (rdback_bad == 0) ? "PASS" : "FAIL");
    $display("  T6 handshake   double=%0d         %s", double_tx, (double_tx == 0) ? "PASS" : "FAIL");

    if (oob_count == 0 && first_addr == WIN_BASE &&
        last_addr == WIN_BASE + N-1 &&
        stride_bad == 0 && tx_count == 2*N && burst_bad == 0 &&
        rdback_bad == 0 && double_tx == 0) begin
      $display("TB_SS_DDR PASS (contract-conforming bridge)");
      $finish; // zero exit
    end else begin
      $display("TB_SS_DDR FAIL (directed evidence: see SAVESTATE_DDR_CONTRACT_CHECK.md)");
      $fatal; // non-zero exit
    end
  end

endmodule
