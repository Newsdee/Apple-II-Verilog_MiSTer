// huc6280_65c02_tb — canonical 65C02 (rtl/cpu_65c02.sv) single-step test bench.
//
// Part of the module_tests/huc6280 benchmark comparing the PC Engine HUC6280
// (VHDL, GHDL) against the canonical 65C02 core. This bench is the canonical
// side: it consumes the SAME batch file as huc6280_sst_tb.vhd (GHDL) and emits
// the SAME result-line format, so sst_driver.py can parse both and
// cross-compare per test.
//
// Modeled on module_tests/cpu_65c02/cpu65_sst_tb_v2.sv, but driving the v1
// core (rtl/cpu_65c02.sv), whose working-register set is smaller (no
// nmi_sync/rst_seq/int_i_mask/nop1_hold/irq_l1/irq_l2).
//
// Method (same as cpu65_sst_tb_v2.sv):
//   * 64K RAM filled with sentinel 0xEE; per-test patches applied.
//   * No reset: the DUT's power-on state (all zero) is S_FETCH with an empty
//     pipeline. Per test, at a negedge we assert stall and inject the full
//     architectural + working state via hierarchical writes (reg_pc, reg_s,
//     a/x/y, flags, and working regs ir/dl/ea/state/int_active/... plus
//     addr=pc so the first fetch reads the test PC). The next posedge is
//     stalled (no transition), giving one clean sample of op 0; stall is then
//     deasserted and the instruction runs.
//   * row c shows op c's bus activity (addr/rw/data) and the register state as
//     of after op c-1. The driver compares row c vs cycles[c] for c < ncyc and
//     row[ncyc]'s registers vs the expected final state.
//   * Writes are committed to mem (Verilator memory works fine) and logged for
//     restore. This is a superset of the GHDL bench's read-only model; for
//     single-instruction tests the two are behaviorally identical.
//
// Batch file format (one line per test, fixed-width tokens):
//   <idx:8d> <pc:4h> <sp:2h> <a:2h> <x:2h> <y:2h> <p:2h> <ncyc:3d> <npatch:3d> <AAAAVV...>
// Result line format:
//   R <idx:8d> then W groups of "<addr4><R|W><data2> <pc4><sp2><a2><x2><y2><p2>"
// P is emitted with R/B forced to 1 (the core hardwires them); the driver
// masks bits 7/4/5 when comparing.

`timescale 1ns/1ps

module huc6280_65c02_tb;
   localparam W = 16;          // capture window
   localparam HDR = 37;        // header width in chars before the patch string

   reg clk = 0;
   reg stall_sig = 0;
   reg running = 0;            // enables write commit
   reg irq_n = 1;
   reg nmi_n = 1;

   wire [15:0] addr;
   wire [7:0] din;
   wire [7:0] dout;
   wire we;
   wire sync;
   wire vector_pull, int_seq, rti_done, in_wai, in_stp;
   wire [63:0] ss_rdata;

   reg [7:0] mem [0:65535];

   always #5 clk = ~clk;

   cpu_65c02 dut (
      .clk(clk),
      .ce(1'b1),
      .ce_n(1'b0),
      .reset(1'b0),            // never reset: inject state directly instead
      .stall(stall_sig),
      .irq_n(irq_n),
      .nmi_n(nmi_n),
      .rdy(1'b1),
      .stp_nop(1'b1),
      .addr(addr),
      .dout(dout),
      .din(din),
      .we(we),
      .sync(sync),
      .vector_pull(vector_pull),
      .int_seq(int_seq),
      .rti_done(rti_done),
      .in_wai(in_wai),
      .in_stp(in_stp),
      .ss_addr(10'd0),
      .ss_wdata(64'd0),
      .ss_wren(1'b0),
      .ss_rdata(ss_rdata)
   );

   wire unused_ok = &{1'b0, vector_pull, rti_done, in_wai, in_stp, ss_rdata, int_seq};

   assign din = mem[addr];

   // Track written addresses so every test can restore the image exactly.
   reg [15:0] wr_log [0:63];
   integer wr_n;

   always @(posedge clk) begin
      if (running && we) begin
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
      if (line == "") line = "module_tests/huc6280/build/canonical_results.txt";
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

         // --- inject at a negedge, stalled -----------------------------
         @(negedge clk);
         running   = 1;
         wr_n      = 0;
         stall_sig = 1'b1;
         dut.reg_pc = t_pc;
         dut.addr   = t_pc;
         dut.reg_s  = t_sp;
         dut.reg_a  = t_a;
         dut.reg_x  = t_x;
         dut.reg_y  = t_y;
         // P byte: N=7 V=6 - 5 B=4 D=3 I=2 Z=1 C=0 (bit5 sticky-1 in the
         // suite; the core hardwires it, so it is not injected)
         dut.fl_n   = t_p[7];
         dut.fl_v   = t_p[6];
         dut.fl_d   = t_p[3];
         dut.fl_i   = t_p[2];
         dut.fl_z   = t_p[1];
         dut.fl_c   = t_p[0];
         // working state: clean fetch start
         dut.ir           = 8'h00;
         dut.dl           = 8'h00;
         dut.ea           = 16'h0000;
         dut.state        = 6'd0;      // S_FETCH
         dut.int_active   = 1'b0;
         dut.int_is_nmi   = 1'b0;
         dut.nmi_pending  = 1'b0;
         dut.nmi_last     = 1'b1;      // sampled NMI copy: pin is high
         dut.nop8_cnt     = 3'd0;
         dut.idx_carry    = 1'b0;
         dut.idx_reg      = 8'h00;
         dut.we           = 1'b0;
         dut.sync         = 1'b0;
         dut.vector_pull  = 1'b0;
         dut.in_wai       = 1'b0;
         dut.in_stp       = 1'b0;
         dut.dout         = 8'h00;

         // --- capture ----------------------------------------------------
         $fwrite(out_fd, "R %08d ", idx);
         for (c = 0; c < W; c = c + 1) begin
            @(negedge clk);   // posedge c has just passed
            #1;
            if (c == 0) stall_sig = 1'b0;   // release: next posedge runs op 0
            if (we) $fwrite(out_fd, "%04xW%02x ", addr, dout);
            else    $fwrite(out_fd, "%04xR%02x ", addr, din);
            $fwrite(out_fd, "%04x%02x%02x%02x%02x%02x",
                    dut.reg_pc, dut.reg_s, dut.reg_a, dut.reg_x, dut.reg_y,
                    {dut.fl_n, dut.fl_v, 2'b11, dut.fl_d, dut.fl_i, dut.fl_z, dut.fl_c});
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
      $display("huc6280_65c02 sst batch complete");
      $finish;
   end
endmodule
