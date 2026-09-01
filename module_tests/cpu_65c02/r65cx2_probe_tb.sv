`timescale 1ns/1ps
module r65cx2_probe_tb;
   reg clk = 0;
   always #5 clk = ~clk;
   wire [15:0] addr;
   wire [7:0] din, dout;
   wire nwe, sync, sync_irq;
   wire [63:0] regs_out;
   reg [7:0] mem [0:65535];
   initial begin
      integer i;
      for (i = 0; i < 65536; i = i + 1) mem[i] = 8'hEE;
   end
   R65C02 dut (.reset(1'b1), .clk(clk), .enable(1'b1), .nmi_n(1'b1),
               .irq_n(1'b1), .di(mem[addr]), .dout(dout), .addr(addr),
               .nwe(nwe), .sync(sync), .sync_irq(sync_irq), .Regs(regs_out));
   initial begin
      repeat (40) begin
         @(negedge clk);
         $display("cyc=%0d theCpuCycle=%0d int_cast=%0d PC=%04h A=%02h S=%02h nwe=%b",
                  $time/10, dut.theCpuCycle, int'(dut.theCpuCycle),
                  dut.PC, dut.A, dut.S, ~nwe);
      end
      $finish;
   end
endmodule
