library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity dpram_vhdl_tb is
  generic (
    TRACE_FILE : string := "module_tests/dpram/build/vhdl_trace.csv"
  );
end entity;

architecture test of dpram_vhdl_tb is
  constant N : integer := 8192; -- 2 ** 13, full address space
  signal clk : std_logic := '0';
  signal addr_a, addr_b : std_logic_vector(12 downto 0) := (others => '0');
  signal data_a, data_b : std_logic_vector(7 downto 0) := (others => '0');
  signal wren_a, wren_b : std_logic := '0';
  signal q_a, q_b : std_logic_vector(7 downto 0);
begin
  clk <= not clk after 5 ns;

  -- Both clocks tied to the same oscillator, exactly as in floppy_track.sv.
  -- enable_a/enable_b left at their default '1' (unconnected in real use).
  dut : entity work.dpram
    generic map (addr_width_g => 13, data_width_g => 8)
    port map (
      address_a => addr_a,
      address_b => addr_b,
      clock_a => clk,
      clock_b => clk,
      data_a => data_a,
      data_b => data_b,
      enable_a => '1',
      enable_b => '1',
      wren_a => wren_a,
      wren_b => wren_b,
      q_a => q_a,
      q_b => q_b
    );

  stimulus : process
    file trace_output : text open write_mode is TRACE_FILE;
    variable trace_line : line;
    variable i : integer;
  begin
    write(trace_line, string'("CYCLE,Q_A,Q_B,WREN_A,WREN_B,ADDR_A,ADDR_B"));
    writeline(trace_output, trace_line);

    -- Phase schedule (identical in dpram_verilog_tb.sv):
    --   0..7       INIT:  no writes, read address 0 on both ports (init contents)
    --   8..23      AW:    port A writes addr i     <- 0xA0+i ; B reads addr 1000
    --   24..39     ARB:   port B reads back addr i (expect 0xA0+i); A reads 1000
    --   40..55     BW:    port B writes addr 16+i  <- 0xB0+i ; A reads addr 1000
    --   56..71     BRB:   port A reads back 16+i (expect 0xB0+i); B reads 1000
    --   72..95     SIM:   even i: both ports write simultaneously, distinct addrs
    --                    odd  i: A writes 300+i while B reads 300+i (conflict)
    --   96..8287   SW:    port A sweep write addr i <- P(i); B reads (i-1) mod N
    --   8288..16479 SRB:  port B reads back addr i; A reads (i-1) mod N
    --   16480..24671 BSW: port B sweep write addr i <- P(i); A reads (i-1) mod N
    --   24672..32863 ARBB: port A reads back addr i; B reads (i-1) mod N
    -- with P(i) = (7*i + 3) mod 256.

    for cycle in 0 to 32863 loop
      wait until falling_edge(clk);

      data_a <= (others => '0');
      data_b <= (others => '0');
      wren_a <= '0';
      wren_b <= '0';
      addr_a <= (others => '0');
      addr_b <= (others => '0');

      if cycle < 8 then
        null; -- INIT: everything zero
      elsif cycle < 24 then
        i := cycle - 8;
        wren_a <= '1';
        addr_a <= std_logic_vector(to_unsigned(i, 13));
        data_a <= std_logic_vector(to_unsigned(160 + i, 8));
        addr_b <= std_logic_vector(to_unsigned(1000, 13));
      elsif cycle < 40 then
        i := cycle - 24;
        addr_b <= std_logic_vector(to_unsigned(i, 13));
        addr_a <= std_logic_vector(to_unsigned(1000, 13));
      elsif cycle < 56 then
        i := cycle - 40;
        wren_b <= '1';
        addr_b <= std_logic_vector(to_unsigned(16 + i, 13));
        data_b <= std_logic_vector(to_unsigned(176 + i, 8));
        addr_a <= std_logic_vector(to_unsigned(1000, 13));
      elsif cycle < 72 then
        i := cycle - 56;
        addr_a <= std_logic_vector(to_unsigned(16 + i, 13));
        addr_b <= std_logic_vector(to_unsigned(1000, 13));
      elsif cycle < 96 then
        i := cycle - 72;
        if i mod 2 = 0 then
          wren_a <= '1';
          addr_a <= std_logic_vector(to_unsigned(100 + i, 13));
          data_a <= std_logic_vector(to_unsigned(192 + i, 8));
          wren_b <= '1';
          addr_b <= std_logic_vector(to_unsigned(200 + i, 13));
          data_b <= std_logic_vector(to_unsigned(208 + i, 8));
        else
          wren_a <= '1';
          addr_a <= std_logic_vector(to_unsigned(300 + i, 13));
          data_a <= std_logic_vector(to_unsigned(224 + i, 8));
          addr_b <= std_logic_vector(to_unsigned(300 + i, 13));
        end if;
      elsif cycle < 96 + N then
        i := cycle - 96;
        wren_a <= '1';
        addr_a <= std_logic_vector(to_unsigned(i, 13));
        data_a <= std_logic_vector(to_unsigned((7 * i + 3) mod 256, 8));
        addr_b <= std_logic_vector(to_unsigned((i - 1 + N) mod N, 13));
      elsif cycle < 96 + 2 * N then
        i := cycle - (96 + N);
        addr_b <= std_logic_vector(to_unsigned(i, 13));
        addr_a <= std_logic_vector(to_unsigned((i - 1 + N) mod N, 13));
      elsif cycle < 96 + 3 * N then
        i := cycle - (96 + 2 * N);
        wren_b <= '1';
        addr_b <= std_logic_vector(to_unsigned(i, 13));
        data_b <= std_logic_vector(to_unsigned((7 * i + 3) mod 256, 8));
        addr_a <= std_logic_vector(to_unsigned((i - 1 + N) mod N, 13));
      else
        i := cycle - (96 + 3 * N);
        addr_a <= std_logic_vector(to_unsigned(i, 13));
        addr_b <= std_logic_vector(to_unsigned((i - 1 + N) mod N, 13));
      end if;

      wait until rising_edge(clk);
      wait for 1 ns;

      write(trace_line, cycle);
      write(trace_line, string'(",")); write(trace_line, to_hstring(q_a));
      write(trace_line, string'(",")); write(trace_line, to_hstring(q_b));
      write(trace_line, string'(",")); write(trace_line, wren_a);
      write(trace_line, string'(",")); write(trace_line, wren_b);
      write(trace_line, string'(",")); write(trace_line, to_hstring(addr_a));
      write(trace_line, string'(",")); write(trace_line, to_hstring(addr_b));
      writeline(trace_output, trace_line);
    end loop;

    report "VHDL trace complete" severity note;
    std.env.finish;
  end process;
end architecture;
