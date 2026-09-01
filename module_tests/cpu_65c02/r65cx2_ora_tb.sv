// One-shot experiment: does R65Cx2 (golden) write back on ORA zp?
// Program at $0000: LDA #$02 ; ORA $0034 ; NOP ; NOP...
// RAM[$0034] preset to $01. If ORA zp write-back exists, it becomes $03.
`timescale 1ns/1ps
module r65cx2_ora_tb;
  reg clk = 0, reset = 0, enable = 1, nmi_n = 1, irq_n = 1;   // R65Cx2: active-LOW reset
  reg [7:0] di;
  wire [7:0] dout;
  wire [15:0] addr;
  wire nwe, sync;
  wire sync_irq;
  wire [63:0] Regs;

  reg [7:0] mem [0:65535];
  integer i;

  initial begin
    for (i = 0; i < 65536; i++) mem[i] = 8'h00;
    // program
    mem[0]  = 8'hA9; mem[1]  = 8'h02;   // LDA #$02
    mem[2]  = 8'h05; mem[3]  = 8'h34;   // ORA $0034
    mem[4]  = 8'hEA;                     // NOP
    for (i = 5; i < 20; i++) mem[i] = 8'hEA;
    mem[52] = 8'h01;                     // data byte ($0034)
  end

  always @(*) di = mem[addr];

  R65C02 cpu (.*);

  always #10 clk = ~clk;

  integer c;
  initial begin
    repeat (4) @(negedge clk);
    reset = 1;   // release
  end
  always @(negedge clk) if (reset) begin
    c = c + 1;
    if (nwe === 1'b0)
      $display("c%0d W %04h <- %02h", c, addr, dout);
    else
      $display("c%0d R %04h = %02h sync=%b", c, addr, di, sync);
    if (nwe === 1'b0) mem[addr] = dout;
  end

  initial begin
    repeat (60) @(negedge clk);
    $display("FINAL RAM[0034] = %02h  (01=no write-back, 03=write-back)", mem[52]);
    $finish;
  end
endmodule
