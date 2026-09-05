`timescale 1ns/1ps
`default_nettype none
// ============================================================================
// unit_tests/common/tb_ram_mem.sv
//
// Behavioral RAM with the Apple II CPU's 1-ce read latency (the CPU_DL
// equivalent in rtl/apple2.v).  The core presents `addr` during a ce
// pulse and samples `din` the next ce cycle, so `din` latches
// mem[addr] at the ce rise (negedge of phase_zero).  Latching at
// posedge clk gated by `ce` would land one ce cycle late (2-ce read
// delay) - that is the timing level_neg1 verified against the core.
//
// Writes from the CPU bus commit when `we` is high (sampled at the
// posedge of clk, matching the core's we/addr/dout presentation).
//
// TB direct access (one byte per clk, used by the load/snapshot/restore
// tasks): `tb_write_en` + `tb_addr` + `tb_data` commit to mem[] at the
// next posedge clk with priority over the CPU write; `tb_read_data` is a
// combinational read of mem[tb_addr].  The direct access is harness-side
// (it does not model any machine bus); callers must hold the core
// stalled while doing bulk snapshots/restores so the core's ce activity
// cannot interleave with the TB writes.
// ============================================================================

module tb_ram_mem #(
  parameter AW = 16,                     // address width (64K at 16)
  parameter DW = 8                       // data width
) (
  input  wire         clk,
  input  wire         phase_zero,

  // CPU bus
  input  wire [AW-1:0] addr,
  input  wire [DW-1:0] dout,
  input  wire         we,
  output reg  [DW-1:0] din,

  // TB direct access
  input  wire [AW-1:0] tb_addr,
  input  wire [DW-1:0] tb_data,
  input  wire         tb_write_en,
  output wire [DW-1:0] tb_read_data
);

  reg [DW-1:0] mem [0:(1<<AW)-1];

  // 1-ce delayed CPU read (see header).
  always @(negedge phase_zero) din <= mem[addr];

  // CPU write commits on the clk edge with we high; the TB direct write
  // has priority (the core is held stalled during TB bulk writes).
  always @(posedge clk) begin
    if (tb_write_en)
      mem[tb_addr] <= tb_data;
    else if (we)
      mem[addr] <= dout;
  end

  assign tb_read_data = mem[tb_addr];    // combinational harness-side read

endmodule
