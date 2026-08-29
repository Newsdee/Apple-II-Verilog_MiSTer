-- apple2_font_rom_vhdl_tb.vhd
--
-- Cycle-equivalence testbench (golden side) for the VHDL apple2_font_rom.
-- The candidate side is apple2_font_rom_verilog_tb.sv with the IDENTICAL
-- stimulus schedule (both generated from gen_stim.ps1) and CSV schema.
--
-- Machine model / timing convention:
--   * CLK toggles every 5 ns. Stimulus is updated at the falling edge of
--     cycle N and the DUT latches it at the rising edge ending cycle N.
--     Outputs are sampled at rising edge + 1 ns, so the row for cycle N
--     shows the DUT's response to cycle N's stimulus.
--   * No reset: the module has no reset port; initial state is ROM content.
--   * The golden instantiates work.spram; the runner analyzes
--     shared/spram_const.vhd (constant-array shim, same write-first
--     q <= data semantics as rtl/spram.vhd) instead of rtl/spram.vhd.
--   * KNOWN EXPECTED DIVERGENCE (see README.md): on a write cycle the
--     golden glyph_data (continuous from q) shows the NEW value while the
--     candidate (registered read of the pre-edge memory) shows the OLD
--     value. The runner characterizes this signature; any OTHER mismatch
--     is a real finding.
--
-- Stimulus phases (see gen_stim.ps1): A read sweep 0..4095, A2 CH6 probe
-- 4096..4103, B 32 write+readback pairs 4104..4199, B2 read-during-write
-- probes 4200..4211, C interleave 4212..4227. TOTAL = 4228 cycles.
--
-- Trace (every cycle):
--   CYCLE,ROMSWITCH,ALT,LOWER,CH,ROW,IOCTL_WR,IOCTL_ADDR,IOCTL_DATA,GLYPH_DATA
-- Hex columns are zero-padded to whole nibbles (to_hstring behavior):
-- CH=2, ROW=1, IOCTL_ADDR=4, IOCTL_DATA=2, GLYPH_DATA=2.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.stim_pkg.all;

entity apple2_font_rom_vhdl_tb is
end entity apple2_font_rom_vhdl_tb;

architecture sim of apple2_font_rom_vhdl_tb is
  constant TOTAL : integer := 4228;
  constant TRACE_FILE : string := "module_tests/apple2_font_rom/build/vhdl_trace.csv";
  signal clk        : std_logic := '0';
  signal romswitch  : std_logic := '0';
  signal alt        : std_logic := '0';
  signal lower      : std_logic := '0';
  signal ch         : std_logic_vector(6 downto 0) := (others => '0');
  signal row        : std_logic_vector(2 downto 0) := (others => '0');
  signal ioctl_addr : std_logic_vector(24 downto 0) := (others => '0');
  signal ioctl_data : std_logic_vector(7 downto 0) := (others => '0');
  signal ioctl_wr   : std_logic := '0';
  signal glyph_data : std_logic_vector(7 downto 0);
begin
  clk <= not clk after 5 ns;

  dut : entity work.apple2_font_rom
    port map (
      CLK_14M               => clk,
      ROMSWITCH             => romswitch,
      alternate_character   => alt,
      lowercase_character   => lower,
      character_code        => ch,
      glyph_row             => row,
      ioctl_addr            => ioctl_addr,
      ioctl_data            => ioctl_data,
      ioctl_wr              => ioctl_wr,
      glyph_data            => glyph_data);

  stim : process
    variable w : unsigned(63 downto 0);
    variable ws : std_logic_vector(63 downto 0);
    file f : text open write_mode is TRACE_FILE;
    variable trc_line : line;
  begin
    write(trc_line, string'("CYCLE,ROMSWITCH,ALT,LOWER,CH,ROW,IOCTL_WR,IOCTL_ADDR,IOCTL_DATA,GLYPH_DATA"));
    writeline(f, trc_line);

    for n in 0 to TOTAL - 1 loop
      wait until falling_edge(clk);

      if n < TXN'length then w := TXN(n); else w := (others => '0'); end if;
      ws := std_logic_vector(w);
      romswitch  <= w(1);
      alt        <= w(2);
      lower      <= w(3);
      ch         <= ws(10) & ws(9 downto 4);
      row        <= ws(13 downto 11);
      ioctl_addr <= (24 downto 13 => '0') & ws(26 downto 14);
      ioctl_data <= ws(34 downto 27);
      ioctl_wr   <= w(0);

      wait until rising_edge(clk);
      wait for 1 ns;

      write(trc_line, integer'image(n));
      write(trc_line, string'(",")); write(trc_line, romswitch);
      write(trc_line, string'(",")); write(trc_line, alt);
      write(trc_line, string'(",")); write(trc_line, lower);
      write(trc_line, string'(",")); write(trc_line, to_hstring(ch));
      write(trc_line, string'(",")); write(trc_line, to_hstring(row));
      write(trc_line, string'(",")); write(trc_line, ioctl_wr);
      write(trc_line, string'(",")); write(trc_line, to_hstring(ioctl_addr(12 downto 0)));
      write(trc_line, string'(",")); write(trc_line, to_hstring(ioctl_data));
      write(trc_line, string'(",")); write(trc_line, to_hstring(glyph_data));
      writeline(f, trc_line);
    end loop;

    report "VHDL trace complete" severity note;
    std.env.finish;
  end process stim;

end architecture sim;
