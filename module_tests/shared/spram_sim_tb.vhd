-- Bounded smoke test for the simulation-only spram shim (spram_sim.vhd).
--
-- Verifies that the shim loads "rtl/roms/keyboard.hex" (derived from the
-- "rtl/roms/keyboard.mif" init_file generic) and serves it on synchronous
-- reads. Run with CWD = Verilator repo root so the relative hex path
-- resolves. The first 6 bytes of keyboard.hex are:
--   addr 0..5 : 1B 1B 1B 1B 21 31
--
-- Bounded by design: no bare `wait;`. Ends with std.env.finish so that
-- `ghdl -r` returns. Guard the run with `timeout` regardless.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity spram_sim_tb is
end entity;

architecture test of spram_sim_tb is
  signal clk     : std_logic := '0';
  signal address : std_logic_vector(10 downto 0) := (others => '0');
  signal q       : std_logic_vector(7 downto 0);
begin
  -- 100 MHz-ish smoke clock: period 10 ns, first rising edge at t = 5 ns.
  clk <= not clk after 5 ns;

  dut : entity work.spram
    generic map (
      addrbits  => 11,
      databits  => 8,
      init_file => "rtl/roms/keyboard.mif"
    )
    port map (
      address => address,
      clock   => clk,
      data    => (others => '0'),
      wren    => '0',
      q       => q
    );

  stimulus : process
    variable expected_byte : std_logic_vector(7 downto 0);
    variable all_ok        : boolean := true;
  begin
    -- t = 0: the shim's load process has already scheduled its mem writes;
    -- they are stable long before the first rising edge (t = 5 ns).
    address <= (others => '0');

    for i in 0 to 5 loop
      wait until rising_edge(clk);
      wait for 1 ns;  -- let the DUT's clocked q assignment settle
      report "spram_sim_tb: addr=" & integer'image(i) &
             " q=" & to_hstring(q) severity note;

      case i is
        when 0 | 1 | 2 | 3 => expected_byte := x"1B";
        when 4             => expected_byte := x"21";
        when others        => expected_byte := x"31";
      end case;

      if q /= expected_byte then
        report "spram_sim_tb: FAIL addr=" & integer'image(i) &
               " q=" & to_hstring(q) &
               " expected=" & to_hstring(expected_byte) severity failure;
        all_ok := false;
      end if;

      address <= std_logic_vector(to_unsigned(i + 1, 11));
    end loop;

    if not all_ok then
      assert false report "SPRAM SIM FAIL: ROM contents at addr 0..5 do not match keyboard.hex" severity failure;
    end if;

    report "SPRAM SIM PASS addr0..5 = 1B 1B 1B 1B 21 31 (keyboard.hex loaded, words=2048)" severity note;
    std.env.finish;
  end process;
end architecture;
