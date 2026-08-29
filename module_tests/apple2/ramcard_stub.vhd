-- ramcard_stub.vhd
--
-- Test-side VHDL behavioral copy of the Verilog module `ramcard`
-- (rtl/ramcard.v, byte-identical in both repositories).
--
-- Why this file exists:
--   The golden side is the VHDL apple2 core from Apple-II_MiSTer_newsdee.
--   That project's rtl/ directory contains ramcard only as Verilog
--   (rtl/ramcard.v); GHDL cannot analyze it.  This stub is a cycle-exact
--   translation of that Verilog module so the VHDL entity `apple2` can be
--   elaborated under GHDL.  It is NOT a replacement for any golden RTL:
--   the port list matches the component declaration in apple2.vhd exactly,
--   and every register/assignment mirrors ramcard.v statement for statement.
--
-- This file lives in the module-test directory (like the sanctioned
-- module_tests/shared/spram_const.vhd shim) and is never used by Quartus.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ramcard is
  port (
    clk         : in  std_logic;
    reset_in    : in  std_logic;
    addr        : in  unsigned(15 downto 0);
    ram_addr    : out unsigned(17 downto 0);
    card_ram_we : out std_logic;
    card_ram_rd : out std_logic
  );
end entity;

architecture behavioral of ramcard is
  signal bankB       : std_logic := '0';
  signal sat_read_en : std_logic := '0';
  signal sat_write_en: std_logic := '0';
  signal sat_pre_wr_en : std_logic := '0';
  signal bank16k     : unsigned(2 downto 0) := (others => '0');
  signal addr2       : unsigned(15 downto 0) := (others => '0');
  signal Dxxx        : std_logic;
  signal DEF         : std_logic;
begin
  -- always @(posedge clk)
  seq : process (clk)
  begin
    if rising_edge(clk) then
      addr2 <= addr;
      if reset_in = '1' then
        bankB       <= '0';
        sat_read_en <= '0';
        sat_write_en<= '0';
        sat_pre_wr_en <= '0';
      else
        if (addr(15 downto 4) = x"C0D") and (addr2 /= addr) then
          -- Looks like Saturn128 Card in slot 5
          if addr(2) = '0' then
            -- State selection
            bankB       <= addr(3);
            sat_pre_wr_en <= addr(0);
            sat_write_en  <= addr(0) and sat_pre_wr_en;
            sat_read_en   <= not (addr(0) xor addr(1));
          else
            -- 16K bank selection (Verilog: {addr[3], addr[1], addr[0]})
            bank16k <= addr(3) & addr(1) & addr(0);
          end if;
        end if;
      end if;
    end if;
  end process seq;

  Dxxx <= '1' when addr(15 downto 12) = x"D" else '0';
  DEF  <= '1' when (addr(15 downto 14) = "11") and (addr(13 downto 12) /= "00") else '0';

  ram_addr    <= bank16k(2) & not bank16k(2) & bank16k(1 downto 0) &
                 addr(13) & (addr(12) and not (bankB and Dxxx)) & addr(11 downto 0);
  card_ram_we <= sat_write_en and DEF;
  card_ram_rd <= sat_read_en and DEF;

end architecture;
