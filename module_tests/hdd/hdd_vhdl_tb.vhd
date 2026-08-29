-- hdd_vhdl_tb.vhd
--
-- Cycle-equivalence testbench (golden side) for the VHDL hdd (ProDOS HDD
-- interface). The candidate side is hdd_verilog_tb.sv with the IDENTICAL
-- stimulus schedule (both generated from gen_stim.ps1) and CSV schema.
--
-- Machine model / timing convention:
--   * CLK toggles every 5 ns. Stimulus is updated at the falling edge of
--     cycle N and the DUT latches it at the rising edge ending cycle N.
--     Outputs are sampled at rising edge + 1 ns, so the row for cycle N
--     shows the DUT's response to cycle N's stimulus.
--   * Cycles 0..19: power-on reset (RESET=1, all other inputs 0).
--   * From cycle 20: one transaction per 8 cycles. T = (N-20)/8, P=(N-20)%8.
--     The transaction word w = TXN(T) (see gen_stim.ps1 for the bit layout):
--       ds  = (P=0 or w(4)) and not w(5)          -- DEVICE_SELECT window
--       act = ds or (P=0 and w(5))                -- A/RD/IO_SELECT window
--       RESET = (T=791 or T=792)                  -- mid-test reset
--       DEVICE_SELECT = ds
--       IO_SELECT     = (P<2 and w(5))  -- 2-cycle window (ROM path has two
--                                        -- registered stages; ROM[a] shows
--                                        -- at P=1)
--       RD            = act and w(0)
--       A             = w(21:6) when act else 0
--       D_IN          = w(29:22)
--       hdd_mounted   = w(1)
--       hdd_protect   = w(2)
--       ram_we        = (P=0 and w(3))
--       ram_addr      = w(38:30)
--       ram_di        = w(46:39)
--
-- Trace (every cycle):
--   CYCLE,D_OUT,SECTOR,HDD_READ,HDD_WRITE,RAM_DO,A,RD,IO_SELECT,
--   DEVICE_SELECT,RESET,D_IN,MOUNTED,PROTECT,RAM_ADDR,RAM_DI,RAM_WE
-- Hex columns are zero-padded to whole nibbles (to_hstring behavior);
-- the Verilog side uses matching %0Nh formats.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.stim_pkg.all;

entity hdd_vhdl_tb is
end entity hdd_vhdl_tb;

architecture sim of hdd_vhdl_tb is
  constant TOTAL : integer := 6416;
  constant TRACE_FILE : string := "module_tests/hdd/build/vhdl_trace.csv";
  signal clk         : std_logic := '0';
  signal io_select   : std_logic := '0';
  signal dev_select  : std_logic := '0';
  signal reset_sig   : std_logic := '1';
  signal a           : unsigned(15 downto 0) := (others => '0');
  signal rd          : std_logic := '0';
  signal d_in        : unsigned(7 downto 0) := (others => '0');
  signal d_out       : unsigned(7 downto 0);
  signal sector      : unsigned(15 downto 0);
  signal hdd_read    : std_logic;
  signal hdd_write   : std_logic;
  signal hdd_mounted : std_logic := '0';
  signal hdd_protect : std_logic := '0';
  signal ram_addr    : unsigned(8 downto 0) := (others => '0');
  signal ram_di      : unsigned(7 downto 0) := (others => '0');
  signal ram_do      : unsigned(7 downto 0);
  signal ram_we      : std_logic := '0';
begin
  clk <= not clk after 5 ns;

  dut : entity work.hdd
    port map (
      CLK_14M     => clk,
      IO_SELECT   => io_select,
      DEVICE_SELECT => dev_select,
      RESET       => reset_sig,
      A           => a,
      RD          => rd,
      D_IN        => d_in,
      D_OUT       => d_out,
      sector      => sector,
      hdd_read    => hdd_read,
      hdd_write   => hdd_write,
      hdd_mounted => hdd_mounted,
      hdd_protect => hdd_protect,
      ram_addr    => ram_addr,
      ram_di      => ram_di,
      ram_do      => ram_do,
      ram_we      => ram_we);

  stim : process
    variable w    : unsigned(63 downto 0);
    variable t    : integer;
    variable p    : integer;
    variable ds   : boolean;
    variable act  : boolean;
    file f    : text open write_mode is TRACE_FILE;
    variable trc_line : line;
  begin
    write(trc_line, string'("CYCLE,D_OUT,SECTOR,HDD_READ,HDD_WRITE,RAM_DO,A,RD,IO_SELECT,DEVICE_SELECT,RESET,D_IN,MOUNTED,PROTECT,RAM_ADDR,RAM_DI,RAM_WE"));
    writeline(f, trc_line);

    for n in 0 to TOTAL - 1 loop
      wait until falling_edge(clk);

      if n < 20 then
        reset_sig   <= '1';
        dev_select  <= '0';
        io_select   <= '0';
        rd          <= '0';
        a           <= (others => '0');
        d_in        <= (others => '0');
        hdd_mounted <= '0';
        hdd_protect <= '0';
        ram_we      <= '0';
        ram_addr    <= (others => '0');
        ram_di      <= (others => '0');
      else
        t := (n - 20) / 8;
        p := (n - 20) mod 8;
        if t < TXN'length then w := TXN(t); else w := (others => '0'); end if;
        ds  := (p = 0 or w(4) = '1') and w(5) = '0';
        -- io reads are active for P=0..1: the ROM path has two registered
        -- stages (rom_dout, D_OUT), so ROM[a] is only visible at P=1.
        act := ds or (p < 2 and w(5) = '1');
        reset_sig   <= '1' when (t = 791 or t = 792) else '0';
        dev_select  <= '1' when ds else '0';
        io_select   <= '1' when (p < 2 and w(5) = '1') else '0';
        rd          <= '1' when (act and w(0) = '1') else '0';
        a           <= w(21 downto 6) when act else (others => '0');
        d_in        <= w(29 downto 22);
        hdd_mounted <= w(1);
        hdd_protect <= w(2);
        ram_we      <= '1' when (p = 0 and w(3) = '1') else '0';
        ram_addr    <= w(38 downto 30);
        ram_di      <= w(46 downto 39);
      end if;

      wait until rising_edge(clk);
      wait for 1 ns;

      write(trc_line, integer'image(n));
      write(trc_line, string'(",")); write(trc_line, to_hstring(std_logic_vector(d_out)));
      write(trc_line, string'(",")); write(trc_line, to_hstring(std_logic_vector(sector)));
      write(trc_line, string'(",")); write(trc_line, hdd_read);
      write(trc_line, string'(",")); write(trc_line, hdd_write);
      write(trc_line, string'(",")); write(trc_line, to_hstring(std_logic_vector(ram_do)));
      write(trc_line, string'(",")); write(trc_line, to_hstring(std_logic_vector(a)));
      write(trc_line, string'(",")); write(trc_line, rd);
      write(trc_line, string'(",")); write(trc_line, io_select);
      write(trc_line, string'(",")); write(trc_line, dev_select);
      write(trc_line, string'(",")); write(trc_line, reset_sig);
      write(trc_line, string'(",")); write(trc_line, to_hstring(std_logic_vector(d_in)));
      write(trc_line, string'(",")); write(trc_line, hdd_mounted);
      write(trc_line, string'(",")); write(trc_line, hdd_protect);
      write(trc_line, string'(",")); write(trc_line, to_hstring(std_logic_vector(ram_addr)));
      write(trc_line, string'(",")); write(trc_line, to_hstring(std_logic_vector(ram_di)));
      write(trc_line, string'(",")); write(trc_line, ram_we);
      writeline(f, trc_line);
    end loop;

    report "VHDL trace complete" severity note;
    std.env.finish;
  end process stim;

end architecture sim;
