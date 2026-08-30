// Throwaway probe: do NMI/IRQ actually enter the vector handler?
`timescale 1ns/1ps
module probe_tb;
   reg clk = 0;
   reg rst = 0;      // DUT reset ACTIVE-LOW
   reg nmi_n = 1, irq_n = 1;
   wire [7:0] di;
   wire [7:0] do_s;
   wire [15:0] addr;
   wire nwe, sync, sync_irq;
   wire [63:0] regs;

   always #5 clk = ~clk;

   R65C02 dut (
      .reset(rst), .clk(clk), .enable(1'b1),
      .nmi_n(nmi_n), .irq_n(irq_n),
      .di(di), .dout(do_s), .addr(addr),
      .nwe(nwe), .sync(sync), .sync_irq(sync_irq), .Regs(regs)
   );

   reg [7:0] mem [0:65535];
   integer i;
   initial begin
      for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
      // boot -> $1000
      mem[16'hFFFC] = 8'h00; mem[16'hFFFD] = 8'h10;
      // $1000: LDA #$5A ; 20x NOP loop (EA)
      mem[16'h1000] = 8'hA9; mem[16'h1001] = 8'h5A;
      for (i = 4098; i < 4114; i = i + 1) mem[i] = 8'hEA;
      mem[16'h1010] = 8'h4C; mem[16'h1011] = 8'h00; mem[16'h1012] = 8'h10;
      mem[16'h101E] = 8'h4C; mem[16'h101F] = 8'h00;
      // IRQ vector $FFFE/$FFFF -> $1020 : JMP $1000
      mem[16'hFFFE] = 8'h20; mem[16'hFFFF] = 8'h10;
      mem[16'h1020] = 8'h4C; mem[16'h1021] = 8'h00; mem[16'h1022] = 8'h10;
      // NMI vector $FFFA/$FFFB -> $1030 : JMP $1000
      mem[16'hFFFA] = 8'h30; mem[16'hFFFB] = 8'h10;
      mem[16'h1030] = 8'h4C; mem[16'h1031] = 8'h00; mem[16'h1032] = 8'h10;
   end

   assign di = mem[addr];

   always @(posedge clk) begin
      if (nwe == 1'b0) mem[addr] <= do_s;
   end

   integer cyc = 0;
   always @(negedge clk) begin
      rst   = (cyc < 4) ? 1'b0 : 1'b1;
      irq_n = (cyc >= 20 && cyc < 24) ? 1'b0 : 1'b1;  // IRQ pulse c=20..23
      nmi_n = (cyc >= 40 && cyc < 44) ? 1'b0 : 1'b1;  // NMI pulse c=40..43
      $display("c=%0d pc=%04h sp=%02h p=%02h a=%02h irqA=%b sync_irq=%b addr=%04h nwe=%b do=%02h",
               cyc, regs[63:48], regs[39:32], regs[31:24], regs[7:0],
               dut.irqActive, sync_irq, addr, nwe, do_s);
      if (cyc == 60) $finish;
      cyc = cyc + 1;
   end

endmodule
