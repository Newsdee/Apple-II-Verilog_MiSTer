`timescale 1ns/1ps
`default_nettype none
// ============================================================================
// unit_tests/level_neg1/tb_cpu.sv
//
// Config -1: an isolated 6502-class CPU testbench (no Apple II machine, no
// video/audio/slots).  This is the bottom rung of the unit-test ladder and the
// first bisection level: it proves the bare CPU core + memory + the
// savestate bus work before any machine context is added.
//
// What it checks
//   1. SELF-CHECK (positive): a short known program produces hand-computed
//      A/X/Y/S/flags and RAM bytes.  Catches harness/timing errors and a
//      fundamentally wrong CPU.
//   2. SAVE/RESTORE C (execution equivalence, the "killer" test): a reference
//      run vs a save->perturb->restore->continue run must reach identical CPU
//      state AND identical RAM.  Proves the savestate capture is COMPLETE
//      (every field the CPU needs is captured and re-applied).
//   3. SAVE/RESTORE B (RAM restore): save, stomp RAM with garbage, restore,
//      and confirm RAM is back to the saved snapshot (garbage gone).
//   4. INT1/INT2 (NMI + IRQ vector fetch): the vector addresses hold RAM
//      stubs (LDA #marker / STA marker-addr / RTI); the payload loop
//      (NOP NOP CLI JMP) is entered through the RAM reset vector; the
//      interrupt is fired NON-INVASIVELY (an always block asserts the line
//      when the core is at the loop's 1-cycle NOP) and the pushed PC/P and
//      the RTI restore are checked.  Ported from level_0's T3/T4 so the
//      core's interrupt path can be bisected in isolation (no ROM, no
//      machine decode - everything here is harness-controlled RAM).
//
// Bus timing (matched to rtl/apple2.v's proven CPU_DL latch)
//   * ce is the falling edge of a 2-phase clock (== apple2.v CPU_EN); the
//     clock/ce generator is the shared common/tb_ce_gen.sv.
//   * reads: the core presents `addr` this ce cycle and samples `din` the next
//     ce cycle, so din is latched from mem[addr] one ce cycle after addr is
//     driven (common/tb_ram_mem.sv, 1-ce delayed read).
//   * writes: the core asserts we/addr/dout and the byte commits to mem[].
//   * program load / snapshot / restore use tb_ram_mem's TB direct access
//     (one byte per clk; the core is held stalled during bulk passes).
//
// CPU select
//   default (no define)  -> nmos6502 #(.WDC_MODE(1'b0))
//   +define+CPU_WDC      -> wdc65c02 #(.WDC_MODE(1'b1))
//
// Build: see the Makefile in this directory (verilator --cc --timing -exe,
// two-stage: generate, then `make -f Vtb_cpu.mk` inside obj_dir).
// ============================================================================

`ifdef CPU_WDC
  `define CPU_NAME "wdc65c02"
`else
  `define CPU_NAME "nmos6502"
`endif

module tb_cpu;

  // ------------------------------------- shared clock/ce + memory (common)
  wire clk;
  wire phase_zero;
  wire ce;
  tb_ce_gen ceg (
    .clk(clk),
    .phase_zero(phase_zero),
    .ce(ce)
  );

  // ------------------------------------------------------- control / inputs
  reg reset   = 1'b1;
  reg ce_n    = 1'b0;
  reg stall   = 1'b0;
  reg rdy     = 1'b1;
  reg irq_n   = 1'b1;                   // deasserted; the INT1/INT2 always-block drives it
  reg nmi_n   = 1'b1;                   // deasserted; the INT1/INT2 always-block drives it
  reg so_n    = 1'b1;                   // nmos only: tie high (unused)
  reg be      = 1'b1;                   // nmos only: bus always enabled
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

  // Savestate register bus
  reg  [9:0]  ss_addr  = '0;
  reg  [63:0] ss_wdata = '0;
  reg         ss_wren  = 1'b0;
  wire [63:0] ss_rdata;

  // ------------------------------------------- behavioral 64K memory -------
  // 1-ce-cycle delayed read (CPU_DL equivalent); write commits when we is
  // high.  Shared model: common/tb_ram_mem.sv.  The core drives addr at a ce
  // edge and samples din at the NEXT ce edge, so din latches one ce after
  // addr is driven (latched at the negedge of phase_zero inside the module).
  reg  [15:0]  tb_addr     = 16'h0000;
  reg  [7:0]   tb_data     = 8'h00;
  reg          tb_write_en = 1'b0;
  wire [7:0]   tb_read_data;
  tb_ram_mem #(.AW(16), .DW(8)) mem (
    .clk(clk),
    .phase_zero(phase_zero),
    .addr(addr),
    .dout(dout),
    .we(we),
    .din(din),
    .tb_addr(tb_addr),
    .tb_data(tb_data),
    .tb_write_en(tb_write_en),
    .tb_read_data(tb_read_data)
  );

  // TB-side single-byte read.  The #1 delays move the tb_addr change and the
  // result read OFF the clock-edge deltas so the combinational read cannot
  // race an edge-triggered evaluation; one clk is kept for cadence (the core
  // is stalled or between ce pulses during these passes).
  task mrd(input [15:0] a, output [7:0] d);
    begin
      #1;
      tb_addr = a;
      @(posedge clk);
      #1;
      d = tb_read_data;
    end
  endtask

  // TB-side single-byte write.  tb_write_en is set for one clk period
  // straddling the commit posedge, with every TB assignment made OFF the
  // clock edges (#1) so the module's edge-triggered sample never races a
  // TB change (setting an input in the same delta as the commit edge is a
  // non-deterministic race in Verilator).
  task mwr(input [15:0] a, input [7:0] d);
    begin
      #1;
      tb_addr = a;
      tb_data = d;
      tb_write_en = 1'b1;
      @(posedge clk);
      #1;
      tb_write_en = 1'b0;
    end
  endtask

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

  // ------------------------------------------------------ test scaffolding --
  // ce-by-ce hang trace (INT1/INT2 bisection aid): while trace_en, sample at
  // negedge clk (end of each ce) and log to hang_trace.txt the values valid
  // DURING that ce.  Core internals resolve hierarchically (same signals the
  // --trace VCD dumps).  pend=nmi_pending act=int_active inm=int_i_mask
  // isnm=int_is_nmi nms=nmi_sync nml=nmi_last ql1=irq_l1 ql2=irq_l2
  // rst=rst_seq.
  integer    trace_fd;
  reg        trace_en  = 1'b0;
  reg [1:0]  trace_tag = 2'b00;
  reg [9:0]  trace_cnt = 10'd0;
  initial trace_fd = $fopen("hang_trace.txt");
  always @(negedge clk) begin
    if (trace_en && ce) begin
      trace_cnt = trace_cnt + 1;
      $fdisplay(trace_fd, "T%0d %0d st=%0d pc=%04h ir=%02h s=%02h a=%02h x=%02h addr=%04h din=%02h dout=%02h we=%b nmi_n=%b irq_n=%b pend=%b act=%b inm=%b isnm=%b nms=%b nml=%b ql1=%b ql2=%b rst=%b%s",
        trace_tag, trace_cnt,
        dut.state, dut.reg_pc, dut.ir, dut.reg_s, dut.reg_a, dut.reg_x,
        addr, din, dout, we, nmi_n, irq_n,
        dut.nmi_pending, dut.int_active, dut.int_i_mask, dut.int_is_nmi,
        dut.nmi_sync, dut.nmi_last, dut.irq_l1, dut.irq_l2, dut.rst_seq,
        (we ? " WR" : ""));
      if (trace_cnt >= 160) begin
        trace_en  = 1'b0;
        trace_cnt = 10'd0;
      end
    end
  end

  reg [15:0] errors = 0;                // failure count (read by the C++ main)
  integer i, k;
  reg [63:0] sav  [0:2];                // 3 saved savestate words
  reg [7:0]  snap [0:65535];            // RAM snapshot
  reg [7:0]  ref_ram [0:65535];         // reference-run RAM

  // Reset the CPU and let the reset sequence settle.
  task reset_cpu;
    begin
      reset = 1'b1;
      repeat (8) @(posedge clk);
      reset = 1'b0;
      repeat (8) @(posedge clk);
    end
  endtask

  // Advance exactly n ce cycles: the core executes a pulse when it ends
  // (ce fall) with stall low, so each counted pulse runs from its ce rise to
  // its ce fall.  The count is phase-independent at entry:
  //   * stall high  -> release at the NEXT ce rise (10 ns before the core's
  //     advancing edge; race-free by construction) and count that pulse;
  //   * stall low, mid-pulse -> the in-progress pulse will advance at its
  //     fall, so count it;
  //   * stall low, gap -> count full pulses from the next rise.
  // (Deasserting stall on a ce-fall edge would race the core's advance at
  // that same edge and slip the count by one.)
  task run_ce(input integer n);
    integer nrem;
    begin
      nrem = n;
      if (stall) begin
        @(posedge ce);
        stall = 1'b0;
        @(negedge ce);
        nrem = nrem - 1;
      end else if (ce) begin
        @(negedge ce);
        nrem = nrem - 1;
      end
      for (k = 0; k < nrem; k++) begin
        @(posedge ce);
        @(negedge ce);
      end
    end
  endtask

  // Read all 3 savestate words from one consistent (stalled) CPU state.
  task read_cpu_3words(output [63:0] w0, output [63:0] w1, output [63:0] w2);
    begin
      stall = 1'b1;
      repeat (2) @(posedge clk);
      ss_addr = 10'd0; @(posedge clk); w0 = ss_rdata;
      ss_addr = 10'd1; @(posedge clk); w1 = ss_rdata;
      ss_addr = 10'd2; @(posedge clk); w2 = ss_rdata;
      stall = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  // PC / S peeks via the combinational savestate readout (word0).  Both
  // leave ss_addr == 0, so the non-invasive interrupt monitor below (which
  // reads ss_rdata[63:48] as the PC) keeps seeing word0 while armed.
  task peek_pc(output [15:0] pc);
    begin
      stall = 1'b1;
      repeat (2) @(posedge clk);
      ss_addr = 10'd0; @(posedge clk);
      pc = ss_rdata[63:48];
      stall = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask
  task peek_s(output [7:0] s);
    begin
      stall = 1'b1;
      repeat (2) @(posedge clk);
      ss_addr = 10'd0; @(posedge clk);
      s = ss_rdata[23:16];
      stall = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  // Hang characterization (INT1/INT2 bisection): freeze the core, read all
  // three savestate words, then let it run 20 ce and read again to tell a
  // hard-stuck microstate (S/addr frozen) from a repeating push sequence
  // (S keeps decrementing).  State values: 0=S_FETCH 1=S_OP2 10=S_READ
  // 14=S_WRITE 17=S_PUSH 19=S_PULL 28/29/30=S_RTI_P/PL/PH 34/35=S_VEC_LO/HI.
  task dump_hang(input string tag);
    reg [63:0] w0, w1, w2, w0b, w1b;
    begin
      stall = 1'b1;
      repeat (2) @(posedge clk);
      ss_addr = 10'd0; @(posedge clk); w0 = ss_rdata;
      ss_addr = 10'd1; @(posedge clk); w1 = ss_rdata;
      ss_addr = 10'd2; @(posedge clk); w2 = ss_rdata;
      stall = 1'b0;
      repeat (2) @(posedge clk);
      $display("  DBG %s frozen: PC=%04h A=%02h X=%02h Y=%02h S=%02h IR=%02h",
               tag, w0[63:48], w0[47:40], w0[39:32], w0[31:24], w0[23:16], w0[7:0]);
      $display("  DBG %s   w1: state=%0d dl=%02h ea=%04h addr=%04h nmi_pending=%b nmi_last=%b int_active=%b int_is_nmi=%b in_wai=%b in_stp=%b idx_carry=%b idx_reg=%02h nop8=%0d",
               tag, w1[39:34], w1[63:56], w1[55:40], w1[15:0], w1[33], w1[32],
               w1[31], w1[30], w1[29], w1[28], w1[27], w1[26:19], w1[18:16]);
      $display("  DBG %s   w2: phi2=%b so_last=%b so_sync=%b irq_l2=%b irq_l1=%b rst_seq=%b nmi_sync=%b nop1_hold=%b int_i_mask=%b we=%b sync=%b vector_pull=%b dout=%02h",
               tag, w2[19], w2[18], w2[17], w2[16], w2[15], w2[14], w2[13],
               w2[12], w2[11], w2[10], w2[9], w2[8], w2[7:0]);
      run_ce(20);
      stall = 1'b1;
      repeat (2) @(posedge clk);
      ss_addr = 10'd0; @(posedge clk); w0b = ss_rdata;
      ss_addr = 10'd1; @(posedge clk); w1b = ss_rdata;
      ss_addr = 10'd0;
      stall = 1'b0;
      repeat (2) @(posedge clk);
      $display("  DBG %s   +20ce: PC=%04h S=%02h addr=%04h state=%0d int_active=%b nmi_pending=%b (S moved=%b addr moved=%b)",
               tag, w0b[63:48], w0b[23:16], w1b[15:0], w1b[39:34], w1b[31],
               w1b[33], (w0b[23:16] !== w0[23:16]), (w1b[15:0] !== w1[15:0]));
    end
  endtask

  // SS_BASE word0 field extraction: common/tb_ss_pkg.sv (tb_ss_pkg::a(w0),
  // tb_ss_pkg::x(w0), ...).  PC = w0[63:48], A = w0[47:40], X = w0[39:32],
  // Y = w0[31:24], S = w0[23:16], flags N/V/1/1/D/I/Z/C = w0[15:8],
  // IR = w0[7:0].

  task check(input [63:0] got, input [63:0] exp, input string msg);
    begin
      if (got !== exp) begin
        errors = errors + 1;
        $display("  CHECK FAIL: %0s  got=0x%016x exp=0x%016x", msg, got, exp);
      end
    end
  endtask

  // Save: hold the core stalled, capture the 3 savestate words + full RAM.
  // Leaves the core STALLED; the next run_ce releases it on its first
  // counted ce pulse (see run_ce), so the pulse count stays exact.
  task save_state;
    begin
      stall = 1'b1;
      repeat (2) @(posedge clk);
      ss_addr = 10'd0; @(posedge clk); sav[0] = ss_rdata;
      ss_addr = 10'd1; @(posedge clk); sav[1] = ss_rdata;
      ss_addr = 10'd2; @(posedge clk); sav[2] = ss_rdata;
      for (i = 0; i < 65536; i++) mrd(i, snap[i]);
    end
  endtask

  // Restore: hold the core stalled, write the 3 words back (one clk pulse
  // each, applied on the posedge; the ss block is not ce/stall-gated),
  // restore RAM.  Like save_state, leaves the core STALLED for the next
  // run_ce to release (see run_ce).
  task restore_state;
    begin
      stall = 1'b1;
      repeat (2) @(posedge clk);
      ss_addr = 10'd0; ss_wdata = sav[0]; ss_wren = 1'b1; @(posedge clk); ss_wren = 1'b0;
      ss_addr = 10'd1; ss_wdata = sav[1]; ss_wren = 1'b1; @(posedge clk); ss_wren = 1'b0;
      ss_addr = 10'd2; ss_wdata = sav[2]; ss_wren = 1'b1; @(posedge clk); ss_wren = 1'b0;
      for (i = 0; i < 65536; i++) mwr(i, snap[i]);
    end
  endtask

  // DEBUG: bus trace for the first few microseconds (temporary)
  integer tf;
  initial tf = $fopen("bus_trace.txt");
  always @(posedge clk) if (ce && $time < 6000)
    $fwrite(tf, "t=%0t addr=%h din=%h we=%b dout=%h PC=%h A=%h X=%h Y=%h S=%h\n",
            $time, addr, din, we, dout,
            ss_rdata[63:48], tb_ss_pkg::a(ss_rdata), tb_ss_pkg::x(ss_rdata),
            tb_ss_pkg::y(ss_rdata), tb_ss_pkg::s(ss_rdata));

  // Stomp all of RAM with a known garbage pattern (harness-side write).
  task stomp_ram;
    begin
      for (i = 0; i < 65536; i++) mwr(i, 8'hA5);
    end
  endtask

  // ------------------------------------------------- non-invasive interrupt
  // INT1/INT2 (NMI/IRQ vector fetch with RAM stubs): the ce-by-ce peek
  // alignment corrupts the 1-ce delayed read (din), so the interrupt is
  // fired NON-INVASIVELY: this always block watches ss_rdata[63:48] (the
  // combinational reg_pc, word0 - ss_addr MUST be 0 while armed; the driver
  // arms only after a peek that leaves ss_addr 0) and, when armed, asserts
  // the interrupt line low for the ce cycle in which the core is at $0800
  // (about to fetch the 1-cycle NOP at $0800).  The core latches the
  // interrupt as the NOP completes, so the pushed PC is $0801.
  //
  // The pushed P / PCLo / PCHi are captured non-invasively from the RAM
  // (hierarchical read of mem.mem[]) once the three pushes have landed
  // (S == s_before - 3); that window persists through the vector fetch and
  // the stub (LDA/STA) until the RTI pops the bytes, so it is a stable
  // ~11-ce window to read the stack without stalling.
  //
  //   int_arm:     00=off, 01=NMI, 10=IRQ (driven by the test driver).
  //   int_reset:   driver-set: clear the interrupt state between tests.
  //   int_done:    the three pushes landed and were captured.
  //   int_complete: RTI finished (S back to s_before); the driver may then
  //                 do settled-point peeks (single peeks are safe).
  reg [1:0]  int_arm       = 2'b00;
  reg        int_reset     = 1'b0;
  reg        int_fired     = 1'b0;
  reg        int_done      = 1'b0;
  reg        int_complete  = 1'b0;
  reg        int_deassert  = 1'b0;
  reg [7:0]  int_s_before  = 8'h00;
  reg [15:0] int_pushed_pc = 16'h0000;
  reg [7:0]  int_pushed_p  = 8'h00;
  always @(negedge clk) begin
    if (int_reset) begin
      int_fired    = 1'b0;
      int_done     = 1'b0;
      int_complete = 1'b0;
      int_deassert = 1'b0;
    end
    else begin
      // Fire: the core is at $0800 (about to fetch the NOP).  Assert the
      // line low for this ce; the 2-stage synchronizer latches the falling
      // edge on the next ce's posedge clk, i.e. exactly as the NOP
      // completes.
      if (int_arm !== 2'b00 && ce && !int_fired && ss_rdata[63:48] == 16'h0800) begin
        int_fired    = 1'b1;
        int_done     = 1'b0;
        int_complete = 1'b0;
        int_s_before = ss_rdata[23:16];
        int_deassert = 1'b1;
        if (int_arm == 2'b01) nmi_n <= 1'b0; else irq_n <= 1'b0;
      end
      // Deassert on the following ce (keeps the line low across the next
      // posedge clk so the falling edge is sampled exactly once).
      else if (int_deassert) begin
        int_deassert = 1'b0;
        nmi_n <= 1'b1;
        irq_n <= 1'b1;
      end
      // Capture the pushed bytes once the three pushes have landed
      // (S == s_before - 3).  The core pushes PCHi first (to $0100+s_before),
      // then PCLo ($0100+s_before-1), then P ($0100+s_before-2); after the
      // three pushes reg_s == s_before - 3.
      if (int_fired && ce && !int_done && int_s_before !== 8'h00 &&
          ss_rdata[23:16] == (int_s_before - 3)) begin
        int_pushed_pc = {mem.mem[16'h0100 + int_s_before],
                         mem.mem[16'h0100 + int_s_before - 1]};
        int_pushed_p  = mem.mem[16'h0100 + int_s_before - 2];
        int_done      = 1'b1;
      end
      // int_complete: S returns to s_before (RTI done) after the capture.
      if (int_done && ce && !int_complete && ss_rdata[23:16] == int_s_before)
        int_complete = 1'b1;
    end
  end

  // -------------------------------------------------------- program loaders
  // Self-check program (ends in a NOP self-loop so the final state is stable).
  //   LDA #$42 / STA $0200 / LDX #$34 / LDY #$28 / STA $0400,Y / TYA / NOP / JMP
  task load_selfcheck;
    begin
      mwr(16'h0800, 8'hA9); mwr(16'h0801, 8'h42);   // LDA #$42
      mwr(16'h0802, 8'h8D); mwr(16'h0803, 8'h00); mwr(16'h0804, 8'h02); // STA $0200
      mwr(16'h0805, 8'hA2); mwr(16'h0806, 8'h34);   // LDX #$34
      mwr(16'h0807, 8'hA0); mwr(16'h0808, 8'h28);   // LDY #$28
      mwr(16'h0809, 8'h99); mwr(16'h080A, 8'h00); mwr(16'h080B, 8'h04); // STA $0400,Y
      mwr(16'h080C, 8'h98);                        // TYA
      mwr(16'h080D, 8'hEA);                        // NOP
      mwr(16'h080E, 8'h4C); mwr(16'h080F, 8'h0D); mwr(16'h0810, 8'h08); // JMP $080D
      mwr(16'hFFFC, 8'h00); mwr(16'hFFFD, 8'h08);  // reset vector -> 0x0800
    end
  endtask

  // Long deterministic loop program P (JMP back to LOOP at 0x0803).
  task load_prog_p;
    begin
      mwr(16'h0800, 8'hA9); mwr(16'h0801, 8'h00);   // LDA #$00
      mwr(16'h0802, 8'hAA);                         // TAX
      mwr(16'h0803, 8'hCA);                         // DEX   (LOOP)
      mwr(16'h0804, 8'h6A);                         // ROR A
      mwr(16'h0805, 8'h8E); mwr(16'h0806, 8'h00); mwr(16'h0807, 8'h02); // STX $0200
      mwr(16'h0808, 8'h8A);                         // TXA
      mwr(16'h0809, 8'h8D); mwr(16'h080A, 8'h01); mwr(16'h080B, 8'h02); // STA $0201
      mwr(16'h080C, 8'h4C); mwr(16'h080D, 8'h03); mwr(16'h080E, 8'h08); // JMP $0803
      mwr(16'hFFFC, 8'h00); mwr(16'hFFFD, 8'h08);  // reset vector -> 0x0800
    end
  endtask

  // Interrupt test program (INT1/INT2): payload + NMI/IRQ stubs + vectors,
  // all in plain RAM (neg1 has no ROM; the vector addresses are RAM).
  //   payload @ $0800 : NOP NOP CLI JMP $0800 (loop period 6 ce; the CLI
  //     clears I every pass so an IRQ can fire).
  //   NMI stub @ $0600: LDA #$A1 / STA $0200 (abs) / RTI.
  //   IRQ stub @ $0610: LDA #$A2 / STA $0201 (abs) / RTI.
  //   vectors: $FFFC/$FFFD -> $0800 (reset into the payload),
  //            $FFFA/$FFFB -> $0600 (NMI stub), $FFFE/$FFFF -> $0610 (IRQ).
  //   markers $0200/$0201 are cleared so a stale value cannot pass.
  task load_interrupt_test;
    begin
      mwr(16'h0800, 8'hEA);
      mwr(16'h0801, 8'hEA);
      mwr(16'h0802, 8'h58);
      mwr(16'h0803, 8'h4C);
      mwr(16'h0804, 8'h00);
      mwr(16'h0805, 8'h08);
      mwr(16'h0600, 8'hA9); mwr(16'h0601, 8'hA1);
      mwr(16'h0602, 8'h8D); mwr(16'h0603, 8'h00); mwr(16'h0604, 8'h02);
      mwr(16'h0605, 8'h40);
      mwr(16'h0610, 8'hA9); mwr(16'h0611, 8'hA2);
      mwr(16'h0612, 8'h8D); mwr(16'h0613, 8'h01); mwr(16'h0614, 8'h02);
      mwr(16'h0615, 8'h40);
      mwr(16'hFFFC, 8'h00); mwr(16'hFFFD, 8'h08);   // reset -> payload
      mwr(16'hFFFA, 8'h00); mwr(16'hFFFB, 8'h06);   // NMI  -> $0600 stub
      mwr(16'hFFFE, 8'h10); mwr(16'hFFFF, 8'h06);   // IRQ  -> $0610 stub
      mwr(16'h0200, 8'h00); mwr(16'h0201, 8'h00);   // clear the markers
    end
  endtask

  // ------------------------------------------------------------ test driver
  reg [63:0] ref_w0, ref_w1, ref_w2, cur_w0, cur_w1, cur_w2;
  reg [7:0]  m0;
  reg [7:0]  found_byte;                              // byte at the first mismatch
  reg [15:0] pc_now;                                  // INT1/INT2 PC peeks
  reg [7:0]  s_now;                                   // INT1/INT2 S peeks
  integer T1 = 200, T2 = 200;                        // ce-cycle lengths
  integer m;

  initial begin
    $display("CPU_NEG1: CPU=%0s  (config -1, isolated CPU + memory + savestate)", `CPU_NAME);

    // ---------------------------------------------------------- self-check
    load_selfcheck;
    reset_cpu;
    run_ce(80);                                       // run into the NOP self-loop
    read_cpu_3words(cur_w0, cur_w1, cur_w2);
    check(tb_ss_pkg::a(cur_w0), 64'h28, "self A");
    check(tb_ss_pkg::x(cur_w0), 64'h34, "self X");
    check(tb_ss_pkg::y(cur_w0), 64'h28, "self Y");
    // S after reset: the core resets S to 00 and the 7-cycle reset sequence
    // does three fake stack pushes (00 -> FF -> FE -> FD); verified against
    // the core's documented reset sequence and the bus trace.
    check(tb_ss_pkg::s(cur_w0), 64'hFD, "self S");
    check({56'b0, tb_ss_pkg::fl_n(cur_w0)}, 64'h00, "self N");
    check({56'b0, tb_ss_pkg::fl_i(cur_w0)}, 64'h01, "self I");
    check({56'b0, tb_ss_pkg::fl_z(cur_w0)}, 64'h00, "self Z");
    check({56'b0, tb_ss_pkg::fl_c(cur_w0)}, 64'h00, "self C");
    mrd(16'h0200, m0);
    check({56'b0, m0}, 64'h42, "self RAM[$0200]");
    mrd(16'h0428, m0);
    check({56'b0, m0}, 64'h42, "self RAM[$0428]");

    // ------------------------------------------ save/restore (program P)
    load_prog_p;

    // Reference run: P for T1+T2 -> record CPU words + full RAM.
    reset_cpu;
    run_ce(T1 + T2);
    read_cpu_3words(ref_w0, ref_w1, ref_w2);
    for (i = 0; i < 65536; i++) mrd(i, ref_ram[i]);

    // Save/restore run: P for T1, SAVE, perturb T2, RESTORE, continue T2.
    reset_cpu;
    run_ce(T1);
    save_state;
    run_ce(T2);                                       // perturb (state + RAM change)
    restore_state;                                    // restore CPU words + RAM
    run_ce(T2);                                       // continue P for T2 more
    read_cpu_3words(cur_w0, cur_w1, cur_w2);
    check(cur_w0, ref_w0, "save/restore CPU word0");
    check(cur_w1, ref_w1, "save/restore CPU word1");
    check(cur_w2, ref_w2, "save/restore CPU word2");
    m = -1;
    for (i = 0; i < 65536; i++) begin
      mrd(i, m0);
      if (m0 !== ref_ram[i] && m < 0) begin
        m = i;
        found_byte = m0;
      end
    end
    if (m >= 0) begin
      errors = errors + 1;
      $display("  CHECK FAIL: save/restore RAM  ram[0x%04x]=0x%02x exp=0x%02x",
               m, found_byte, ref_ram[m]);
    end

    // Stomp test: save at T1, overwrite RAM with garbage, restore -> clean.
    reset_cpu;
    run_ce(T1);
    save_state;
    stomp_ram;
    restore_state;
    m = -1;
    for (i = 0; i < 65536; i++) begin
      mrd(i, m0);
      if (m0 !== snap[i] && m < 0) begin
        m = i;
        found_byte = m0;
      end
    end
    if (m >= 0) begin
      errors = errors + 1;
      $display("  CHECK FAIL: stomp RAM  ram[0x%04x]=0x%02x exp=0x%02x",
               m, found_byte, snap[m]);
    end

    // ------------------------------------------------- INT1/INT2: NMI/IRQ
    // Vector fetch + stub execution + RTI, fired non-invasively.  Ported
    // from level_0's T3/T4 (which failed under the machine decode + ROM
    // patching); here every byte is harness-controlled RAM, so a failure
    // isolates the core's interrupt path.
    $display("INT1/INT2: NMI/IRQ vector fetch + stub + RTI...");
    stall = 1'b1;                           // hold while loading (the core
                                            // is in the prog_p loop, which
                                            // overlaps $0800-$080C)
    load_interrupt_test;
    stall = 1'b0;
    reset_cpu;
    run_ce(40);                             // into the payload loop
    // Sanity: the payload must be running (PC in the loop range).  peek_pc
    // also leaves ss_addr == 0 for the non-invasive monitor.
    peek_pc(pc_now);
    if (pc_now < 16'h0800 || pc_now > 16'h0805) begin
      errors = errors + 1;
      $display("  CHECK FAIL: INT1 setup PC=0x%04h not in the payload loop", pc_now);
    end

    // INT1: NMI (vector $FFFA/$FFFB -> stub $0600, marker $A1 at $0200).
    int_arm = 2'b01;
    trace_tag = 2'd1; trace_en = 1'b1;  // ce-by-ce trace of the NMI window
    begin : int1_wait
      integer tries = 0;
      while (!int_complete && tries < 100) begin run_ce(1); tries = tries + 1; end
    end
    int_arm = 2'b00;
    dump_hang("INT1-NMI");
    if (!int_done) begin
      errors = errors + 1;
      $display("  CHECK FAIL: INT1 NMI: pushes not captured (s_before=%02h pc=%04h)",
               int_s_before, int_pushed_pc);
    end
    check({48'h0, int_pushed_pc}, {48'h0, 16'h0801}, "INT1 NMI pushed PC ($0801)");
    if (int_pushed_p[3] !== 1'b0) begin
      errors = errors + 1;
      $display("  CHECK FAIL: INT1 NMI pushed P=0x%02h: I bit set (CLI did not run)",
               int_pushed_p);
    end
    // Let the stub + RTI finish and the loop settle, then check at settled
    // points (single peeks are safe).
    run_ce(16);
    mrd(16'h0200, m0);
    check({56'h0, m0}, 64'hA1, "INT1 NMI stub marker (STA $0200)");
    peek_s(s_now);
    check({56'h0, s_now}, {56'h0, int_s_before}, "INT1 S restored after RTI");
    peek_pc(pc_now);
    if (pc_now < 16'h0800 || pc_now > 16'h0805) begin
      errors = errors + 1;
      $display("  CHECK FAIL: INT1 NMI: PC=0x%04h not back in the loop after RTI", pc_now);
    end

    // Reset the non-invasive interrupt state for INT2.
    int_reset = 1'b1;
    run_ce(1);
    int_reset = 1'b0;

    // INT2: IRQ (vector $FFFE/$FFFF -> stub $0610, marker $A2 at $0201).
    int_arm = 2'b10;
    trace_tag = 2'd2; trace_en = 1'b1;  // ce-by-ce trace of the IRQ window
    begin : int2_wait
      integer tries = 0;
      while (!int_complete && tries < 100) begin run_ce(1); tries = tries + 1; end
    end
    int_arm = 2'b00;
    dump_hang("INT2-IRQ");
    if (!int_done) begin
      errors = errors + 1;
      $display("  CHECK FAIL: INT2 IRQ: pushes not captured (s_before=%02h pc=%04h)",
               int_s_before, int_pushed_pc);
    end
    check({48'h0, int_pushed_pc}, {48'h0, 16'h0801}, "INT2 IRQ pushed PC ($0801)");
    if (int_pushed_p[3] !== 1'b0) begin
      errors = errors + 1;
      $display("  CHECK FAIL: INT2 IRQ pushed P=0x%02h: I bit set (CLI did not run)",
               int_pushed_p);
    end
    run_ce(16);
    mrd(16'h0201, m0);
    check({56'h0, m0}, 64'hA2, "INT2 IRQ stub marker (STA $0201)");
    peek_s(s_now);
    check({56'h0, s_now}, {56'h0, int_s_before}, "INT2 S restored after RTI");
    peek_pc(pc_now);
    if (pc_now < 16'h0800 || pc_now > 16'h0805) begin
      errors = errors + 1;
      $display("  CHECK FAIL: INT2 IRQ: PC=0x%04h not back in the loop after RTI", pc_now);
    end

    // -------------------------------------------------------------- summary
    if (errors == 0)
      $display("CPU_NEG1 PASS  cpu=%0s  (self-check + save/restore equiv + RAM restore + NMI/IRQ vectors)", `CPU_NAME);
    else
      $display("CPU_NEG1 FAIL  cpu=%0s  (errors=%0d)", `CPU_NAME, errors);
    $finish;
  end

endmodule
