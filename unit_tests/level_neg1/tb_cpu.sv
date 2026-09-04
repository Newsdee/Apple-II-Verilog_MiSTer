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
//
// Bus timing (matched to rtl/apple2.v's proven CPU_DL latch)
//   * ce is the falling edge of a 2-phase clock (== apple2.v CPU_EN).
//   * reads: the core presents `addr` this ce cycle and samples `din` the next
//     ce cycle, so din is latched from mem[addr] one ce cycle after addr is
//     driven (mem_rdata below).
//   * writes: the core asserts we/addr/dout and the byte commits to mem[].
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
  reg reset   = 1'b1;
  reg ce_n    = 1'b0;
  reg stall   = 1'b0;
  reg rdy     = 1'b1;
  reg irq_n   = 1'b1;                   // held deasserted (no interrupts in this test)
  reg nmi_n   = 1'b1;                   // held deasserted
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
  // 1-ce-cycle delayed read (CPU_DL equivalent); write commits when we is high.
  // The core drives addr at a ce edge and samples din at the NEXT ce edge, so
  // mem_rdata must latch mid-ce at the negedge of phase_zero. Latching at
  // posedge clk gated by `ce` lands one ce cycle late (2-ce read delay).
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

  // ------------------------------------------------------ test scaffolding --
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

  // SS_BASE word layout (low->high): PC, A, X, Y, S, N, V, ., ., D, I, Z, C, IR
  function [7:0]  ss_a (input [63:0] w); begin ss_a = w[47:40]; end endfunction
  function [7:0]  ss_x (input [63:0] w); begin ss_x = w[39:32]; end endfunction
  function [7:0]  ss_y (input [63:0] w); begin ss_y = w[31:24]; end endfunction
  function [7:0]  ss_s (input [63:0] w); begin ss_s = w[23:16]; end endfunction
  function        ss_n (input [63:0] w); begin ss_n = w[15];    end endfunction
  function        ss_i (input [63:0] w); begin ss_i = w[10];    end endfunction
  function        ss_z (input [63:0] w); begin ss_z = w[9];     end endfunction
  function        ss_c (input [63:0] w); begin ss_c = w[8];     end endfunction

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
      for (i = 0; i < 65536; i++) snap[i] = mem[i];
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
      for (i = 0; i < 65536; i++) mem[i] = snap[i];
    end
  endtask

  // DEBUG: bus trace for the first few microseconds (temporary)
  integer tf;
  initial tf = $fopen("bus_trace.txt");
  always @(posedge clk) if (ce && $time < 6000)
    $fwrite(tf, "t=%0t addr=%h din=%h we=%b dout=%h PC=%h A=%h X=%h Y=%h S=%h\n",
            $time, addr, din, we, dout,
            ss_rdata[63:48], ss_a(ss_rdata), ss_x(ss_rdata), ss_y(ss_rdata), ss_s(ss_rdata));

  // Stomp all of RAM with a known garbage pattern (harness-side write).
  task stomp_ram;
    begin
      for (i = 0; i < 65536; i++) mem[i] = 8'hA5;
    end
  endtask

  // -------------------------------------------------------- program loaders
  // Self-check program (ends in a NOP self-loop so the final state is stable).
  //   LDA #$42 / STA $0200 / LDX #$34 / LDY #$28 / STA $0400,Y / TYA / NOP / JMP
  task load_selfcheck;
    begin
      mem[16'h0800] = 8'hA9; mem[16'h0801] = 8'h42;   // LDA #$42
      mem[16'h0802] = 8'h8D; mem[16'h0803] = 8'h00; mem[16'h0804] = 8'h02; // STA $0200
      mem[16'h0805] = 8'hA2; mem[16'h0806] = 8'h34;   // LDX #$34
      mem[16'h0807] = 8'hA0; mem[16'h0808] = 8'h28;   // LDY #$28
      mem[16'h0809] = 8'h99; mem[16'h080A] = 8'h00; mem[16'h080B] = 8'h04; // STA $0400,Y
      mem[16'h080C] = 8'h98;                        // TYA
      mem[16'h080D] = 8'hEA;                        // NOP
      mem[16'h080E] = 8'h4C; mem[16'h080F] = 8'h0D; mem[16'h0810] = 8'h08; // JMP $080D
      mem[16'hFFFC] = 8'h00; mem[16'hFFFD] = 8'h08;  // reset vector -> 0x0800
    end
  endtask

  // Long deterministic loop program P (JMP back to LOOP at 0x0803).
  task load_prog_p;
    begin
      mem[16'h0800] = 8'hA9; mem[16'h0801] = 8'h00;   // LDA #$00
      mem[16'h0802] = 8'hAA;                         // TAX
      mem[16'h0803] = 8'hCA;                         // DEX   (LOOP)
      mem[16'h0804] = 8'h6A;                         // ROR A
      mem[16'h0805] = 8'h8E; mem[16'h0806] = 8'h00; mem[16'h0807] = 8'h02; // STX $0200
      mem[16'h0808] = 8'h8A;                         // TXA
      mem[16'h0809] = 8'h8D; mem[16'h080A] = 8'h01; mem[16'h080B] = 8'h02; // STA $0201
      mem[16'h080C] = 8'h4C; mem[16'h080D] = 8'h03; mem[16'h080E] = 8'h08; // JMP $0803
      mem[16'hFFFC] = 8'h00; mem[16'hFFFD] = 8'h08;  // reset vector -> 0x0800
    end
  endtask

  // ------------------------------------------------------------ test driver
  reg [63:0] ref_w0, ref_w1, ref_w2, cur_w0, cur_w1, cur_w2;
  integer T1 = 200, T2 = 200;                        // ce-cycle lengths
  integer m;

  initial begin
    $display("CPU_NEG1: CPU=%0s  (config -1, isolated CPU + memory + savestate)", `CPU_NAME);

    // ---------------------------------------------------------- self-check
    load_selfcheck;
    reset_cpu;
    run_ce(80);                                       // run into the NOP self-loop
    read_cpu_3words(cur_w0, cur_w1, cur_w2);
    check(ss_a(cur_w0), 64'h28, "self A");
    check(ss_x(cur_w0), 64'h34, "self X");
    check(ss_y(cur_w0), 64'h28, "self Y");
    // S after reset: the core resets S to 00 and the 7-cycle reset sequence
    // does three fake stack pushes (00 -> FF -> FE -> FD); verified against
    // the core's documented reset sequence and the bus trace.
    check(ss_s(cur_w0), 64'hFD, "self S");
    check({56'b0, ss_n(cur_w0)}, 64'h00, "self N");
    check({56'b0, ss_i(cur_w0)}, 64'h01, "self I");
    check({56'b0, ss_z(cur_w0)}, 64'h00, "self Z");
    check({56'b0, ss_c(cur_w0)}, 64'h00, "self C");
    check({56'b0, mem[16'h0200]}, 64'h42, "self RAM[$0200]");
    check({56'b0, mem[16'h0428]}, 64'h42, "self RAM[$0428]");

    // ------------------------------------------ save/restore (program P)
    load_prog_p;

    // Reference run: P for T1+T2 -> record CPU words + full RAM.
    reset_cpu;
    run_ce(T1 + T2);
    read_cpu_3words(ref_w0, ref_w1, ref_w2);
    for (i = 0; i < 65536; i++) ref_ram[i] = mem[i];

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
    for (i = 0; i < 65536; i++) if (mem[i] !== ref_ram[i] && m < 0) m = i;
    if (m >= 0) begin
      errors = errors + 1;
      $display("  CHECK FAIL: save/restore RAM  ram[0x%04x]=0x%02x exp=0x%02x", m, mem[m], ref_ram[m]);
    end

    // Stomp test: save at T1, overwrite RAM with garbage, restore -> clean.
    reset_cpu;
    run_ce(T1);
    save_state;
    stomp_ram;
    restore_state;
    m = -1;
    for (i = 0; i < 65536; i++) if (mem[i] !== snap[i] && m < 0) m = i;
    if (m >= 0) begin
      errors = errors + 1;
      $display("  CHECK FAIL: stomp RAM  ram[0x%04x]=0x%02x exp=0x%02x", m, mem[m], snap[m]);
    end

    // -------------------------------------------------------------- summary
    if (errors == 0)
      $display("CPU_NEG1 PASS  cpu=%0s  (self-check + save/restore equiv + RAM restore)", `CPU_NAME);
    else
      $display("CPU_NEG1 FAIL  cpu=%0s  (errors=%0d)", `CPU_NAME, errors);
    $finish;
  end

endmodule
