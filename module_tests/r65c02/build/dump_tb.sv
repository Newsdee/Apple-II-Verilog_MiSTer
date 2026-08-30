// Dump all table entries + localparams (compiled truth).
`timescale 1ns/1ps
module dump_tb;
   logic clk = 0, reset = 1, enable = 1, nmi_n = 1, irq_n = 1;
   logic [7:0] di = 0;
   logic [7:0] dout_;
   logic [15:0] addr;
   logic nwe, sync, sync_irq;
   logic [63:0] regs_;

   R65C02 dut (
      .reset(reset), .clk(clk), .enable(enable),
      .nmi_n(nmi_n), .irq_n(irq_n),
      .di(di), .dout(dout_), .addr(addr),
      .nwe(nwe), .sync(sync), .sync_irq(sync_irq),
      .Regs(regs_)
   );

   initial begin
      integer i;
      for (i = 0; i < 256; i = i + 1)
         $display("E%03d %011x", i, dut.opcodeInfoTable[i]);
      $display("P immediate %h", dut.immediate);
      $display("P implied   %h", dut.implied);
      $display("P readZp    %h", dut.readZp);
      $display("P writeZp   %h", dut.writeZp);
      $display("P rmwZp     %h", dut.rmwZp);
      $display("P readZpX   %h", dut.readZpX);
      $display("P writeZpX  %h", dut.writeZpX);
      $display("P rmwZpX    %h", dut.rmwZpX);
      $display("P readZpY   %h", dut.readZpY);
      $display("P writeZpY  %h", dut.writeZpY);
      $display("P rmwZpY    %h", dut.rmwZpY);
      $display("P readIndX  %h", dut.readIndX);
      $display("P writeIndX %h", dut.writeIndX);
      $display("P rmwIndX   %h", dut.rmwIndX);
      $display("P readIndY  %h", dut.readIndY);
      $display("P writeIndY %h", dut.writeIndY);
      $display("P rmwIndY   %h", dut.rmwIndY);
      $display("P rmwInd    %h", dut.rmwInd);
      $display("P readInd   %h", dut.readInd);
      $display("P writeInd  %h", dut.writeInd);
      $display("P readAbs   %h", dut.readAbs);
      $display("P writeAbs  %h", dut.writeAbs);
      $display("P rmwAbs    %h", dut.rmwAbs);
      $display("P readAbsX  %h", dut.readAbsX);
      $display("P writeAbsX %h", dut.writeAbsX);
      $display("P rmwAbsX   %h", dut.rmwAbsX);
      $display("P readAbsY  %h", dut.readAbsY);
      $display("P writeAbsY %h", dut.writeAbsY);
      $display("P rmwAbsY   %h", dut.rmwAbsY);
      $display("P push      %h", dut.push);
      $display("P pop       %h", dut.pop);
      $display("P jsr       %h", dut.jsr);
      $display("P jumpAbs   %h", dut.jumpAbs);
      $display("P jumpInd   %h", dut.jumpInd);
      $display("P jumpIndX  %h", dut.jumpIndX);
      $display("P relative  %h", dut.relative);
      $display("P rts       %h", dut.rts);
      $display("P rti       %h", dut.rti);
      $display("P brk       %h", dut.brk);
      $display("P aluInA    %h", dut.aluInA);
      $display("P aluInBrk  %h", dut.aluInBrk);
      $display("P aluInX    %h", dut.aluInX);
      $display("P aluInY    %h", dut.aluInY);
      $display("P aluInS    %h", dut.aluInS);
      $display("P aluInT    %h", dut.aluInT);
      $display("P aluInClr  %h", dut.aluInClr);
      $display("P aluModeInp %h", dut.aluModeInp);
      $display("P aluModeP  %h", dut.aluModeP);
      $display("P aluModeInc %h", dut.aluModeInc);
      $display("P aluModeDec %h", dut.aluModeDec);
      $display("P aluModeFlg %h", dut.aluModeFlg);
      $display("P aluModeCmp %h", dut.aluModeCmp);
      $display("P aluModeAdc %h", dut.aluModeAdc);
      $display("P aluModeSbc %h", dut.aluModeSbc);
      $display("P aluModeAnd %h", dut.aluModeAnd);
      $display("P aluModeOra %h", dut.aluModeOra);
      $display("P aluModeEor %h", dut.aluModeEor);
      $display("P aluModeNoF %h", dut.aluModeNoF);
      $finish;
   end
endmodule
