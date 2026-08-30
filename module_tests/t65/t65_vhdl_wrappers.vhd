-- Phase wrappers for t65_vhdl_tb (GHDL 6.0.0 in this environment has no
-- generic-map option, so each phase gets its own top-level entity that
-- instantiates the shared testbench with fixed generics).
--
--   t65_vhdl_tb_prog : PHASE=0 ("prog", 320 cycles) -> build/vhdl_prog.csv
--   t65_vhdl_tb_boot : PHASE=1 ("boot", 500 cycles) -> build/vhdl_boot.csv

library ieee;
use ieee.std_logic_1164.all;

entity t65_vhdl_tb_prog is
end entity;

architecture prog of t65_vhdl_tb_prog is
begin
  dut : entity work.t65_vhdl_tb
    generic map (
      PHASE      => 0,
      TRACE_FILE => "module_tests/t65/build/vhdl_prog.csv"
    );
end architecture;

entity t65_vhdl_tb_boot is
end entity;

architecture boot of t65_vhdl_tb_boot is
begin
  dut : entity work.t65_vhdl_tb
    generic map (
      PHASE      => 1,
      TRACE_FILE => "module_tests/t65/build/vhdl_boot.csv"
    );
end architecture;
