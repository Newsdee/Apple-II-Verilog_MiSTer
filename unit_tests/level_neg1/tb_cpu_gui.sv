`timescale 1ns/1ps
`default_nettype none
// ============================================================================
// unit_tests/level_neg1/tb_cpu_gui.sv
//
// GUI companion to tb_cpu.sv: the SAME isolated CPU + memory + savestate
// harness, but with NO test sequence and NO $finish - the imgui main
// (gui/main_gui.cpp) is the driver.
//
// Control model
//   * `stall` is driven EXCLUSIVELY from C++ (rootp member write from the
//     GUI's "Stall (pause core)" checkbox or the --stall-test harness).
//     Nothing in this module drives it, so there is no multi-driver race.
//     The DUT samples it on its ce edges exactly as in tb_cpu.sv.
//   * `reset` is pulsed once by the initial block, then left alone.
//
// What C++ can read (all flattened rootp members, naming
// <module>__DOT__<signal> / <module>__DOT__dut__DOT__<signal>):
//   tb_cpu_gui__DOT__ce_count    stall-gated core-advance counter (ticks
//                                while running, freezes when stalled)
//   tb_cpu_gui__DOT__addr/dout/din/we   live bus
//   tb_cpu_gui__DOT__ram0200/ram0201    RAM bytes the demo program writes
//                                every iteration (proves bus writes flow)
//   tb_cpu_gui__DOT__dut__DOT__reg_pc/reg_a/reg_x/reg_y/reg_s/reg_p/ir/state
//
// Demo program: same visible-activity loop as tb_cpu.sv's program P
// (DEX + STX $0200 + TXA + STA $0201 + JMP) - RAM writes and register
// changes every iteration, so the readouts are always moving.
//
// Build: `make CPU=nmos|wdc gui` (see Makefile; top module tb_cpu_gui).
// ============================================================================

`ifdef CPU_WDC
  `define CPU_NAME "wdc65c02"
`else
  `define CPU_NAME "nmos6502"
`endif

module tb_cpu_gui;

  // ------------------------------------------------------------- clock -----
  reg clk = 1'b0;
  always #5 clk = ~clk;                 // 100 ns period; only relative timing matters

  // 2-phase clock -> ce = falling edge of phase_zero (== apple2.v CPU_EN)
  reg  phase_zero   = 1'b0;
  reg  phase_zero_d = 1'b0;
  always @(posedge clk) phase_zero_d <= phase_zero;
  always @(posedge clk) phase_zero   <= ~phase_zero;
  wire ce = phase_zero_d & ~phase_zero; // 1-clk-wide enable pulse each phase

  // ------------------------------------------------------- control / inputs
  // C++ is the SOLE driver of `stall` (GUI checkbox / --stall-test).
  reg stall = 1'b0;
  reg reset = 1'b1;
  reg ce_n  = 1'b0;
  reg rdy   = 1'b1;
  reg irq_n = 1'b1;                     // held deasserted
  reg nmi_n = 1'b1;
  reg so_n  = 1'b1;                     // nmos only: tie high
  reg be    = 1'b1;                     // nmos only: bus always enabled
  reg stp_nop = 1'b1;                   // STP acts as NOP (matches apple2.v)

  // ---------------------------------------------------------------- bus ----
  wire [15:0] addr;
  wire [7:0]  dout;
  wire [7:0]  din;
  wire        we;
  wire        sync, vector_pull, int_seq, rti_done, in_wai, in_stp;
`ifndef CPU_WDC
  wire        ml_n, phi1o, phi2o, bus_oe, dout_oe;   // nmos-only outputs
`endif

  // Savestate register bus (wired, idle - the DUT requires the ports).
  reg  [9:0]  ss_addr  = '0;
  reg  [63:0] ss_wdata = '0;
  reg         ss_wren  = 1'b0;
  wire [63:0] ss_rdata;

  // ------------------------------------------- behavioral 64K memory -------
  // Identical 1-ce-cycle delayed read model as tb_cpu.sv.
  reg [7:0] mem       [0:65535];
  reg [7:0] mem_rdata = '0;
  always @(negedge phase_zero) mem_rdata <= mem[addr];
  always @(posedge clk) if (we) mem[addr] <= dout;
  assign din = mem_rdata;

  // ----------------------------------------------------------------- DUT ----
`ifdef CPU_WDC
  wdc65c02 #(.WDC_MODE(1'b1), .SS_BASE(10'd0)) dut (
    .clk(clk), .ce(ce), .ce_n(ce_n), .reset(reset), .stall(stall),
    .irq_n(irq_n), .nmi_n(nmi_n), .rdy(rdy),
    .stp_nop(stp_nop),
    .addr(addr), .dout(dout), .din(din), .we(we),
    .sync(sync), .vector_pull(vector_pull),
    .int_seq(int_seq), .rti_done(rti_done),
    .in_wai(in_wai), .in_stp(in_stp),
    .ss_addr(ss_addr), .ss_wdata(ss_wdata), .ss_wren(ss_wren), .ss_rdata(ss_rdata)
  );
`else
  nmos6502 #(.WDC_MODE(1'b0), .SS_BASE(10'd0)) dut (
    .clk(clk), .ce(ce), .ce_n(ce_n), .reset(reset), .stall(stall),
    .irq_n(irq_n), .nmi_n(nmi_n), .rdy(rdy),
    .so_n(so_n), .be(be), .stp_nop(stp_nop),
    .addr(addr), .dout(dout), .din(din), .we(we),
    .sync(sync), .vector_pull(vector_pull),
    .ml_n(ml_n), .phi1o(phi1o), .phi2o(phi2o),
    .bus_oe(bus_oe), .dout_oe(dout_oe),
    .int_seq(int_seq), .rti_done(rti_done),
    .in_wai(in_wai), .in_stp(in_stp),
    .ss_addr(ss_addr), .ss_wdata(ss_wdata), .ss_wren(ss_wren), .ss_rdata(ss_rdata)
  );
`endif

  // ------------------------------------------------- GUI-visible signals ---
  // Stall-gated ce counter: ticks only while the core is advancing.
  // This is the "is it being used" indicator - it freezes when the GUI
  // checks Stall.
  reg [31:0] ce_count = 32'd0;
  always @(posedge clk) if (ce && !stall) ce_count <= ce_count + 32'd1;

  // Mirror of the RAM bytes the demo program writes every iteration, so
  // C++ can show live memory content (unpacked `mem[]` has no rootp path).
  reg [7:0] ram0200 = 8'h00;
  reg [7:0] ram0201 = 8'h00;
  always @(posedge clk) if (we) begin
    if (addr == 16'h0200)      ram0200 <= dout;
    else if (addr == 16'h0201) ram0201 <= dout;
  end

  // --------------------------------------------------------- startup -------
  // Load the demo program, run the reset sequence once, then leave the core
  // RUNNING.  C++ owns `stall` from process start; no $finish anywhere.
  initial begin
    // Program P (visible activity: X decrements, $0200/$0201 written,
    // carry/zero flags move) in a JMP loop.
    mem[16'h0800] = 8'hA9; mem[16'h0801] = 8'h00;   // LDA #$00
    mem[16'h0802] = 8'hAA;                         // TAX
    mem[16'h0803] = 8'hCA;                         // DEX   (LOOP)
    mem[16'h0804] = 8'h6A;                         // ROR A
    mem[16'h0805] = 8'h8E; mem[16'h0806] = 8'h00; mem[16'h0807] = 8'h02; // STX $0200
    mem[16'h0808] = 8'h8A;                         // TXA
    mem[16'h0809] = 8'h8D; mem[16'h080A] = 8'h01; mem[16'h080B] = 8'h02; // STA $0201
    mem[16'h080C] = 8'h4C; mem[16'h080D] = 8'h03; mem[16'h080E] = 8'h08; // JMP $0803
    mem[16'hFFFC] = 8'h00; mem[16'hFFFD] = 8'h08;  // reset vector -> 0x0800

    reset = 1'b1;
    repeat (8) @(posedge clk);
    reset = 1'b0;
    repeat (8) @(posedge clk);
  end

endmodule
