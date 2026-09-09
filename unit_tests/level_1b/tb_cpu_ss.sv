`timescale 1ns / 1ps

module tb_cpu_ss;
  reg clk = 1'b0;
  always #1 clk = ~clk;

  reg cpu_sel = 1'b0;
  reg reset = 1'b1;
  reg stall = 1'b1;
  reg [9:0] ss_addr = 10'd0;
  reg [63:0] ss_wdata = 64'd0;
  reg ss_wren = 1'b0;
  reg machine_ce = 1'b1;

  wire [17:0] ram_addr;
  wire [7:0] ram_din;
  wire [15:0] ram_dout;
  wire ram_aux;
  wire ram_we;
  reg [7:0] ram_main [0:65535];
  reg [7:0] ram_aux_mem [0:65535];

  wire phase_zero;
  wire phase_zero_r;
  wire phase_zero_f;
  wire [15:0] cpu_addr;
  wire [7:0] cpu_data;
  wire [63:0] ss_rdata;
  wire cpu_frozen;
  integer errors = 0;
  integer plus_cpu;
  integer index;
  reg [63:0] expected [0:7];

  initial begin
    if ($value$plusargs("cpu=%d", plus_cpu))
      cpu_sel = (plus_cpu != 0);
    expected[0] = 64'h2468_12A5_5A3C_309A;
    expected[1] = 64'h7E12_3456_0000_1200;
    expected[2] = 64'h0000_0000_0000_00C3;
    expected[3] = 64'h0000_0000_0006_D5A5;
    expected[4] = 64'h0000_0000_0312_345A;
    expected[5] = 64'h0000_0000_0055_0955;
    expected[6] = 64'h0000_0000_0000_00AD;
    expected[7] = 64'h0000_0000_0000_5C00;

    repeat (8) @(posedge clk);
    reset <= 1'b0;
    repeat (8) @(posedge clk);

    for (index = 0; index < 8; index = index + 1) begin
      ss_addr <= index[9:0];
      #0;
      if (ss_rdata === 64'hxxxxxxxxxxxxxxxx) begin
        $display("ERROR: unknown read data at word %0d", index);
        errors = errors + 1;
      end
    end

    for (index = 0; index < 8; index = index + 1) begin
      @(negedge clk);
      ss_addr <= index[9:0];
      ss_wdata <= expected[index] | ((index == 7) ? 64'hA6 : 64'd0);
      ss_wren <= 1'b1;
      @(posedge clk);
      ss_wren <= 1'b0;
      @(negedge clk);
      if (ss_rdata !== expected[index]) begin
        $display("ERROR: CPU %0d word %0d readback %016h expected %016h",
                 cpu_sel, index, ss_rdata, expected[index]);
        errors = errors + 1;
      end
    end

    // The bus remains readable while the CPU is held. A second sample after
    // a full clock confirms the restored state is not immediately overwritten.
    repeat (2) @(posedge clk);
    for (index = 0; index < 4; index = index + 1) begin
      if ((index == 1) || (index == 2))
        continue;
      ss_addr <= index[9:0];
      @(negedge clk);
      if (ss_rdata !== expected[index]) begin
        $display("ERROR: CPU %0d stable word %0d readback %016h expected %016h",
                 cpu_sel, index, ss_rdata, expected[index]);
        errors = errors + 1;
      end
    end

    while (!cpu_frozen)
      @(posedge clk);
    machine_ce <= 1'b0;
    repeat (4) @(posedge clk);
    if (!cpu_frozen) begin
      $display("ERROR: CPU did not report a frozen boundary");
      errors = errors + 1;
    end
    for (index = 0; index < 4; index = index + 1) begin
      if ((index == 1) || (index == 2))
        continue;
      ss_addr <= index[9:0];
      @(negedge clk);
      if (ss_rdata !== expected[index]) begin
        $display("ERROR: frozen word %0d changed to %016h expected %016h",
                 index, ss_rdata, expected[index]);
        errors = errors + 1;
      end
    end

    if (errors == 0)
      $display("L1B CPU SS PASS cpu=%0d words=8", cpu_sel);
    else
      $display("L1B CPU SS FAIL cpu=%0d errors=%0d", cpu_sel, errors);
    $finish;
  end

  always @(posedge clk) begin
    if (ram_we && !ram_aux) begin
      ram_main[ram_addr[15:0]] <= ram_din;
      ram_dout[7:0] <= ram_din;
    end else begin
      ram_dout[7:0] <= ram_main[ram_addr[15:0]];
    end
    if (ram_we && ram_aux) begin
      ram_aux_mem[ram_addr[15:0]] <= ram_din;
      ram_dout[15:8] <= ram_din;
    end else begin
      ram_dout[15:8] <= ram_aux_mem[ram_addr[15:0]];
    end
  end

  apple2 dut (
    .CLK_14M(clk),
    .CLK_2M(),
    .PALMODE(1'b0),
    .ROMSWITCH(1'b0),
    .CPU_WAIT(1'b0),
    .PHASE_ZERO(phase_zero),
    .PHASE_ZERO_R(phase_zero_r),
    .PHASE_ZERO_F(phase_zero_f),
    .FLASH_CLK(1'b0),
    .reset(reset),
    .cpu(cpu_sel),
    .STALL(stall),
    .ADDR(cpu_addr),
    .ram_addr(ram_addr),
    .D(ram_din),
    .ram_do(ram_dout),
    .aux(ram_aux),
    .PD(8'h00),
    .CPU_WE(),
    .IRQ_n(1'b1),
    .NMI_n(1'b1),
    .ram_we(ram_we),
    .VIDEO(),
    .COLOR_LINE(),
    .TEXT_MODE(),
    .HBL(),
    .VBL(),
    .K(8'h00),
    .READ_KEY(),
    .AKD(1'b0),
    .AN(),
    .GAMEPORT(8'h00),
    .PDL_STROBE(),
    .STB(),
    .IO_SELECT(),
    .DEVICE_SELECT(),
    .IO_STROBE(),
    .ioctl_addr(25'd0),
    .ioctl_data(8'd0),
    .ioctl_index(8'd0),
    .ioctl_download(1'b0),
    .ioctl_wr(1'b0),
    .saturn_5_inslot(1'b0),
    .speaker(),
    .DBG_T65_REGS(),
    .DBG_DI(),
    .DBG_ROM_ADDR(),
    .DBG_ROM_OUT(),
    .ss_addr(ss_addr),
    .ss_wdata(ss_wdata),
    .ss_wren(ss_wren),
    .ss_rdata(ss_rdata),
    .machine_ce(machine_ce),
    .cpu_frozen(cpu_frozen)
  );
endmodule
