`timescale 1ns/1ps
`default_nettype none
// ============================================================================
// unit_tests/common/tb_ce_gen.sv
//
// Shared 2-phase clock + ce pulse generator for the unit-test ladder
// (level_neg1, level_0, ...).  Mirrors the machine's CPU clocking
// (rtl/apple2.v): the core's ce (== CPU_EN) is the falling edge of the
// 2-phase clock, i.e. the 1-clk-wide pulse where phase_zero goes 1->0.
//
//   clk         100 ns period free-running clock (only relative timing
//               matters; the ladder tests are cycle-count based).
//   phase_zero  toggles on every posedge of clk (200 ns per phase).
//   ce          1-clk-wide enable pulse on each phase_zero 1->0 edge.
//
// The same edge set (negedge of phase_zero) is used by tb_ram_mem as its
// read-latch point; both extract the identical blocks that used to live
// inline in level_neg1/tb_cpu.sv (behavior-preserving extraction).
// ============================================================================

module tb_ce_gen (
  output reg  clk,
  output reg  phase_zero,
  output wire ce
);

  reg phase_zero_d;

  initial begin
    clk = 1'b0;
    phase_zero = 1'b0;
    phase_zero_d = 1'b0;
  end

  always #5 clk = ~clk;                 // 100 ns period

  always @(posedge clk) begin
    phase_zero_d <= phase_zero;
    phase_zero   <= ~phase_zero;
  end

  assign ce = phase_zero_d & ~phase_zero; // 1-clk-wide enable pulse each phase

endmodule
