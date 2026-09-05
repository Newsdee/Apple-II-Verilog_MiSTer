`default_nettype none
// ============================================================================
// unit_tests/common/tb_ss_pkg.sv
//
// Field extraction for the CPU cores' savestate register bus (the nmos6502
// and wdc65c02 cores share the same ss word layout; see the savestate
// blocks in rtl/cpu/*/cpu_65c02.sv).  SS_BASE word 0 holds the
// architectural registers:
//
//   ss_rdata[63:48] PC    [47:40] A     [39:32] X
//   ss_rdata[31:24] Y     [23:16] S     [15]    N
//   ss_rdata[14]  V       [13:12] 11    [11]    D
//   ss_rdata[10]  I       [9]     Z     [8]     C
//   ss_rdata[7:0] IR
//
// ss_rdata is combinational (no stall needed for a single-word peek); the
// multi-word save/restore tasks stall the core for a consistent snapshot.
// ============================================================================

package tb_ss_pkg;

  function automatic [15:0] pc (input [63:0] w); begin pc = w[63:48]; end endfunction
  function automatic [7:0]  a  (input [63:0] w); begin a  = w[47:40]; end endfunction
  function automatic [7:0]  x  (input [63:0] w); begin x  = w[39:32]; end endfunction
  function automatic [7:0]  y  (input [63:0] w); begin y  = w[31:24]; end endfunction
  function automatic [7:0]  s  (input [63:0] w); begin s  = w[23:16]; end endfunction
  function automatic [7:0]  p  (input [63:0] w); begin p  = w[15:8];  end endfunction
  function automatic        fl_n (input [63:0] w); begin fl_n = w[15]; end endfunction
  function automatic        fl_v (input [63:0] w); begin fl_v = w[14]; end endfunction
  function automatic        fl_d (input [63:0] w); begin fl_d = w[11]; end endfunction
  function automatic        fl_i (input [63:0] w); begin fl_i = w[10]; end endfunction
  function automatic        fl_z (input [63:0] w); begin fl_z = w[9];  end endfunction
  function automatic        fl_c (input [63:0] w); begin fl_c = w[8];  end endfunction
  function automatic [7:0]  ir (input [63:0] w); begin ir = w[7:0];  end endfunction

endpackage
