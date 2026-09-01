// R65Cx2 (golden 65C02) — 65x02 single-step test bench.
//
// Mirror of cpu65_sst_tb.sv for the golden R65Cx2 core, so the WDC suite can
// be replayed against it with the same driver (sst_driver.py). Same batch and
// result line formats.
//
// Method:
//   * 64K RAM filled with sentinel 0xEE.
//   * Reset is active-low and held inactive (1) forever. The `enable` input is
//     the stall: while low, theCpuCycle never advances. Per test, at a
//     negedge we hold enable=0 and inject the full architectural state via
//     hierarchical writes (PC, myAddr, A/X/Y/S, flags, T, theOpcode, opcInfo
//     regs, interrupt state). The first posedge is stalled -> clean op-0
//     sample; enable is released after row 0.
//   * Row c shows op c's bus activity and register state after op c-1.

`timescale 1ns/1ps

module r65cx2_sst_tb;
   localparam W = 16;          // capture window
   localparam HDR = 37;        // header width in chars before the patch string

   reg clk = 0;
   reg en_sig = 0;             // enable (stall when 0)
   reg running = 0;            // enables write commit
   reg irq_n = 1;
   reg nmi_n = 1;

   wire [15:0] addr;
   wire [7:0] din;
   wire [7:0] dout;
   wire nwe;
   wire sync, sync_irq;
   wire [63:0] regs_out;

   reg [7:0] mem [0:65535];

   always #5 clk = ~clk;

   R65C02 dut (
      .reset(1'b1),            // active-low: held inactive forever
      .clk(clk),
      .enable(en_sig),
      .nmi_n(nmi_n),
      .irq_n(irq_n),
      .di(din),
      .dout(dout),
      .addr(addr),
      .nwe(nwe),
      .sync(sync),
      .sync_irq(sync_irq),
      .Regs(regs_out)
   );

   wire unused_ok = &{1'b0, sync_irq, regs_out};

   assign din = mem[addr];

   // Track written addresses so every test can restore the image exactly.
   reg [15:0] wr_log [0:63];
   integer wr_n;

   always @(posedge clk) begin
      if (running && en_sig && ~nwe) begin
         mem[addr] <= dout;
         if (wr_n < 64) begin
            wr_log[wr_n] = addr;
            wr_n = wr_n + 1;
         end
      end
   end

   integer tests_fd, out_fd;
   string line;
   integer idx, npatch, i, c;
   reg [15:0] t_pc;
   reg [7:0]  t_sp, t_a, t_x, t_y, t_p;
   integer    t_ncyc;
   reg [23:0] pv;

   initial begin
      $value$plusargs("TESTS=%s", line);
      if (line == "") $fatal(1, "missing +TESTS=<file>");
      tests_fd = $fopen(line, "r");
      if (!tests_fd) $fatal(1, "cannot open test file %s", line);
      $value$plusargs("OUT=%s", line);
      if (line == "") line = "module_tests/cpu_65c02/build/sst_results.txt";
      out_fd = $fopen(line, "w");
      if (!out_fd) $fatal(1, "cannot open output %s", line);

      for (i = 0; i < 65536; i = i + 1) mem[i] = 8'hEE;

      while ($fgets(line, tests_fd)) begin
         if (line.len() < HDR) continue;
         $sscanf(line.substr(0, HDR - 1), "%d %h %h %h %h %h %h %d %d",
                 idx, t_pc, t_sp, t_a, t_x, t_y, t_p, t_ncyc, npatch);

         // apply patch (Verilator substr is inclusive-end)
         for (i = 0; i < npatch; i = i + 1) begin
            pv = 24'h0;
            $sscanf(line.substr(HDR + i*6, HDR + i*6 + 5), "%h", pv);
            mem[pv[23:8]] = pv[7:0];
         end

         // --- drain + two-phase inject -----------------------------------
         // theCpuCycle is an enum: not writable from outside. Drain the FSM
         // on sentinel RAM until it sits in opcodeFetch.
         //
         // R65Cx2 commits architectural register updates (A/X/Y/S/flags) on
         // the NEXT opcodeFetch cycle, latching the previous instruction's
         // ALU result. So the release posedge (the real fetch of the test
         // opcode) clobbers A/X/Y/S/flags with stale drain garbage. We
         // therefore inject those registers at row 1 (after the fetch has
         // latched the opcode), and address/interrupt state during the stall.
         @(negedge clk);
         running   = 1;
         wr_n      = 0;
         en_sig    = 1'b1;
         for (i = 0; i < 64 && int'(dut.theCpuCycle) != 5'd0; i = i + 1)
            @(negedge clk);
         if (int'(dut.theCpuCycle) != 5'd0)
            $fatal(1, "drain did not reach opcodeFetch");

         // stall; safe pre-fetch writes (not clobbered by the fetch latch)
         en_sig    = 1'b0;
         dut.PC        = t_pc;
         dut.myAddr    = t_pc;
         dut.T         = 8'h00;
         dut.irqActive = 1'b0;
         dut.processIrq = 1'b0;
         // Idle interrupt state = no NMI pending, irq_n held high.
         // nmiReg/irqReg must both be 1: with either at 0, calcInterrupt
         // computes processIrq=1 on release and R65Cx2 injects a synthetic
         // BRK (stack push + vector fetch) after the test opcode.
         dut.nmiReg    = 1'b1;
         dut.irqReg    = 1'b1;
         dut.soReg     = 1'b0;
         dut.dout      = 8'h00;
         dut.nwe       = 1'b1;   // drain may leave a stale write strobe

         // --- capture ----------------------------------------------------
         $fwrite(out_fd, "R %08d ", idx);
         if (idx == 0)
            $display(" DBG pre-capture cyc=%0d en=%b PC=%04h myAddr=%04h A=%02h S=%02h nmiReg=%b irqReg=%b procIrq=%b irqAct=%b opcIRQ=%b di=%02h",
                     int'(dut.theCpuCycle), en_sig, dut.PC, dut.myAddr,
                     dut.A, dut.S, dut.nmiReg, dut.irqReg, dut.processIrq,
                     dut.irqActive, dut.opcInfo[25], din);
         for (c = 0; c < W; c = c + 1) begin
            @(negedge clk);   // posedge c has just passed
            #1;
            if (idx == 0)
               $display(" DBG c%0d cyc=%0d en=%b PC=%04h myAddr=%04h A=%02h S=%02h nwe=%b di=%02h nmiReg=%b irqReg=%b procIrq=%b irqAct=%b opcIRQ=%b",
                        c, int'(dut.theCpuCycle), en_sig, dut.PC, dut.myAddr,
                        dut.A, dut.S, ~nwe, din, dut.nmiReg, dut.irqReg,
                        dut.processIrq, dut.irqActive, dut.opcInfo[25]);
            if (c == 0) begin
               en_sig = 1'b1;   // release: next posedge is the real fetch;
                                // it latches opcode/PC and clobbers A/X/Y/S/P
            end else if (c == 1) begin
               // fetch done: inject architectural state now. The instruction's
               // own updates land on its final opcodeFetch, after this point.
               dut.A = t_a;
               dut.X = t_x;
               dut.Y = t_y;
               dut.S = t_sp;
               dut.N = t_p[7];
               dut.V = t_p[6];
               dut.R = 1'b1;
               dut.B = 1'b0;
               dut.D = t_p[3];
               dut.I = t_p[2];
               dut.Z = t_p[1];
               dut.C = t_p[0];
               dut.T = 8'h00;
            end
            if (~nwe) $fwrite(out_fd, "%04xW%02x ", addr, dout);
            else      $fwrite(out_fd, "%04xR%02x ", addr, din);
            $fwrite(out_fd, "%04x%02x%02x%02x%02x%02x",
                    dut.PC, dut.S, dut.A, dut.X, dut.Y,
                    {dut.N, dut.V, 2'b11, dut.D, dut.I, dut.Z, dut.C});
         end
         $fwrite(out_fd, "\n");

         // restore image: patch entries + anything the instruction wrote
         for (i = 0; i < npatch; i = i + 1) begin
            pv = 24'h0;
            $sscanf(line.substr(HDR + i*6, HDR + i*6 + 5), "%h", pv);
            mem[pv[23:8]] = 8'hEE;
         end
         for (i = 0; i < wr_n; i = i + 1) mem[wr_log[i]] = 8'hEE;
      end

      $fclose(out_fd);
      $fclose(tests_fd);
      $display("R65Cx2 sst batch complete");
      $finish;
   end
endmodule
